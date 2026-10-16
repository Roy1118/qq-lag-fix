---
name: qq-lag-fix
description: 诊断并修复 Windows 上 QQ（QQNT / Electron 版）的卡顿、打字延迟、输入框出字慢、UI 一顿一顿、掉帧、反应迟钝。只要用户抱怨 QQ 卡、QQ 打字有延迟、QQ 输入框半天不出字、QQ 一卡一卡的、新版 QQ 很卡、QQNT 卡顿、QQ 打字跟不上手，就用这个技能——哪怕用户完全没提 "QQNT"、"Electron"、"渲染" 这些词，哪怕他描述得很模糊（"就是感觉不跟手"）。这个技能针对的是渲染路径的根因，不是"清缓存""重装 QQ""换网络"这类常规建议；用户通常已经试过那些了。不适用于：QQ 无法登录、QQ 闪退、QQ 占用磁盘等与渲染无关的问题。
---

# QQ（QQNT）卡顿与打字延迟

## 先记住这一句

**新版 QQ 是 Electron 应用。它卡，几乎总是这台机器的"渲染路径"问题，不是 QQ 的 bug。**

Electron 把整个界面当一块 GPU 合成的画布来画。所以从"你敲下键盘"到"你看见字"要走：

```
键盘 → 输入法 → 渲染进程生成帧 → GPU 进程合成 → DWM → 屏幕
```

**这条链上任何一环被降级，都表现成"字打完半秒才出来"。**

推论：**别建议清缓存、重装 QQ、换网络。** 那些对渲染延迟无效，而且用户一定已经试过了。

## 真正的修法就两条

### 修法 1：让 QQ 在正确的 GPU 上渲染

混合显卡笔记本上，**"显示器由哪块 GPU 驱动"和"QQ 在哪块 GPU 上渲染"是两件事**，
不一致就要每帧跨适配器拷贝。

```powershell
# Availability: 3=正在驱动显示, 8=Off Line(没在驱动任何显示)
Get-CimInstance Win32_VideoController | Select-Object Name,VideoModeDescription,CurrentRefreshRate,Availability

# 系统给 QQ 指定的 GPU
$k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
(Get-Item $k).GetValue('C:\Program Files\Tencent\QQNT\QQ.exe')
```

`GpuPreference`：**0=让 Windows 决定，1=省电/核显，2=高性能/独显**。

> ⚠️ **反直觉的地方**：网上流传最广的建议是"QQ 卡就设成集成显卡"。
> 在**显示器由独显直驱**的机器上，这条建议**恰恰是反的**——它让 QQ 每帧跨适配器拷贝。
> 判断依据就是上面那个 `Availability`：**如果只有独显是 3，就不该把 QQ 钉在核显上。**

### 修法 2：关掉 Chromium 的窗口节流

Chromium 认为窗口被遮挡/在后台时会降低帧生成频率。在混合显卡 + 虚拟显示器的机器上
这个判定经常**判错**——窗口明明在你眼前，帧却按后台节奏出，输入回显就慢半拍。

QQNT **接受命令行开关透传**（实测有效）。三个开关：

```
--disable-features=CalculateNativeWinOcclusion     ← 别算遮挡，最直接对应"打字延迟"
--disable-backgrounding-occluded-windows           ← 就算算错也别降级
--disable-renderer-backgrounding                   ← 别压渲染进程优先级
```

先验证透传，再落地：

```powershell
# 必须先把 QQ 完全退出
Start-Process 'C:\Program Files\Tencent\QQNT\QQ.exe' -ArgumentList @(
  '--disable-features=CalculateNativeWinOcclusion',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding'
)
Start-Sleep 25
Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" |
  ForEach-Object { "PID $($_.ProcessId)  $($_.CommandLine)" }
```

主进程和渲染进程都该看到开关。**看不到就是没透传，换思路。**

然后写进**全部三个启动入口**（漏一个，用户下次从那里启动就白搭，
表现成"有时好有时不好"）：

1. `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `QQNT` 值
2. 开始菜单快捷方式
3. 桌面快捷方式

**代价要告诉用户**：QQ 被遮住/最小化时仍会继续渲染，笔记本上多耗一点电。

## 先花 2 分钟排除资源瓶颈

目的是**证明**不是 CPU/内存/磁盘，这样才有底气往渲染方向走。

```powershell
Get-Counter '\Processor(_Total)\% DPC Time','\Processor(_Total)\% Interrupt Time',
  '\PhysicalDisk(_Total)\% Disk Time','\Memory\Pages/sec' -SampleInterval 2 -MaxSamples 3 |
  Select-Object -ExpandProperty CounterSamples | Group-Object Path | ForEach-Object {
    "{0,-30} {1}" -f ($_.Name -replace '.*\\',''), [math]::Round((($_.Group|Measure-Object CookedValue -Average).Average),2)
  }
```

判读：**DPC < 2%、中断 < 2%、磁盘 < 20%** 才算干净。

**如果 DPC 或中断 > 5%，停下来。** 根因在某个内核驱动，不在 QQ——
那是系统级问题，改 QQ 的任何设置都救不了，该去查驱动（LatencyMon / WPR）。
这条要明确告诉用户，别硬往 QQ 上套。

再确认 QQ 自己在"等"而不是在"算"：QQ 空闲时每个进程 CPU < 1% 是正常的。
（注意 `Get-Process` 的 `CPU` 是**累计秒数**不是占用率，要看增量。）

## 次要项（前两条无效再看）

- **虚拟显示驱动**（向日葵 `OrayIddDriver`、ToDesk 等）会作为独立显示适配器出现，
  扰乱 DWM 合成与遮挡判定。用户不用远程控制的话，卸载它有额外收益。
- **透明效果**：`HKCU\...\Themes\Personalize\EnableTransparency = 0`
- **Auto HDR**：`AutoHDREnable=1` 给每帧加成本。但用户玩游戏可能就是要它，别擅自关。
- **输入法**：Chromium + 微软拼音的 TSF 桥接有已知延迟。可换第三方输入法对比，
  或开微软拼音兼容模式。
- **shell 扩展注入**：如果资源管理器本身也卡/反复挂起，从
  `C:\ProgramData\Microsoft\Windows\WER\ReportArchive` 的 `Report.wer` 里读
  `LoadedModule[N]=`，筛出非 `C:\Windows\` 的项。常见嫌疑：百度网盘 `YunShellExt*.dll`、
  Adobe `CoreSync_x64.dll`、RaiDrive、迅雷 `ThunderMyComputerIcon*.dll`。
  用官方 Blocked 机制禁用（CLSID 写进
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked`，
  32 位扩展还要写 `WOW6432Node` 下同名键）。

## 工作方式

- **先量再改**，别靠猜。
- **改之前备份，改之后给回退。** 用户几天后会说"好像变差了"，那时你得能一键还原。
- **一次只改一类，改完让用户当场试。** 两处一起改就分不清是哪一处的功劳，
  下次复发无从下手。
- 沟通上：用户描述的是主观感受，先说"我先量一下是不是资源瓶颈"，再给结论。

## 脚本

| 脚本 | 用途 | 改系统 |
|---|---|---|
| `scripts/diagnose.ps1` | 一次性采集上面全部证据 | 否 |
| `scripts/apply-fix.ps1` | 落地修法 1 + 2，自动备份 + 生成回退脚本 | 是 |
| `scripts/revert-fix.ps1` | 回退 | 是 |

```powershell
powershell -ExecutionPolicy Bypass -File scripts\diagnose.ps1
powershell -ExecutionPolicy Bypass -File scripts\apply-fix.ps1 -GpuPreference 2
powershell -ExecutionPolicy Bypass -File scripts\revert-fix.ps1 -Latest
```

`apply-fix.ps1` 参数：`-GpuPreference 0|1|2`、`-SkipGpu`、`-SkipFlags`、
`-NoOcclusionFlags`（不关节流，省电优先时用）。

改注册表和快捷方式要管理员权限。没提权就用
`Start-Process powershell -Verb RunAs`，**输出写到临时文件再读回来**（提权进程的 stdout 拿不到）。

## 踩坑记录（都真实踩过）

1. **`[类型]::方法(a, b)` 当命令参数时必须整体加括号。** 最阴的一个：
   ```powershell
   function KV($k,$v){ "$k : $v" }
   KV '内存%' [math]::Round(100 - ($a/$b*100), 1)    # ✗ 报 "op_Subtraction on Object[]"
   KV '内存%' ([math]::Round(100 - ($a/$b*100), 1))  # ✓
   ```
   参数模式下逗号被当成**参数分隔符**，`Round` 的两个参数被拆开传给了外层函数。
   报错信息完全指向别处，极难查。

2. **进程 `StartTime` 可能是重启后的时间。** 一个挂起后被系统重启的进程，`StartTime`
   是重启时刻，不是首次启动时刻。用它能得出离谱结论——实测差点因此误判
   "桌面卡了 6 分钟"（实际那是一次挂起后的重启）。要交叉验证事件日志。

3. **GPU 偏好路径别写错**：是 `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`，
   **没有** `Windows\CurrentVersion` 这一段。写错静默返回空。

4. **`foreach (...) { } | Format-Table` 会解析报错**（PS 5.1）。先赋值给变量再管道。

5. **`.ps1` 存成无 BOM 的 UTF-8 会被 PS 5.1 当 ANSI 读，中文全乱码。** 用带 BOM 的 UTF-8。

6. **`Get-Process` 的 `CPU` 是累计秒数，不是占用率。**

7. **`-match` 大小写不敏感**，用 `'ASUS'` 匹配会误伤 `ScanForUpdatesAsUser`（含 `sAsUs`）。

8. **`Test-Path` 遇 ACL 拒绝会抛错，`-ErrorAction SilentlyContinue` 拦不住。**
   WER 的 `Report.wer` 就是这种，要 `try/catch`。

9. **别信 `Test-Path C:\hiberfil.sys`**——它的 ACL 连管理员都读不到，用
   `cmd /c 'dir /a C:\hiberfil.sys'`。

## 延伸阅读

- `references/case-2026-hybrid-gpu.md` — 一次完整的实战记录，含全部实测数据。
  想知道上面这些判读规则是怎么来的就读它。
- `references/why-chromium-flags.md` — 那三个开关各自在做什么、代价是什么。
