# 实战案例：混合显卡 + 240Hz 笔记本上的"字迟到半秒"

这是 `qq-lag-fix` 技能里那些判读规则的实际来源。想知道"为什么 GpuPreference 是重点"
或者"为什么要先量资源"，读这一份。

## 症状（用户原话）

> 电脑 QQ 很卡，几秒就一顿一顿的
> 我觉得是渲染问题，就是候选输入后有时隔个半秒才在文本框出现文字

注意用户自己就判断对了方向——**渲染问题**。这个判断值得尊重，
不要因为"用户不懂技术"就把他往"清缓存/重装"方向带。

## 机器

| 项 | 值 |
|---|---|
| 系统 | Windows 11 25H2，Build 26200.9457 |
| CPU | 32 逻辑处理器 |
| 内存 | 31.6 GB（用 43%，空闲 18 GB） |
| 独显 | NVIDIA GeForce RTX 4060 Laptop，驱动 32.0.15.9636 |
| 核显 | Intel UHD Graphics，驱动 32.0.101.6790 |
| 显示器 | 2560×1600 @ 240 Hz，150% 缩放 |
| 虚拟显示 | `OrayIddDriver Device`（向日葵）作为独立显示适配器存在 |
| QQ | QQNT 9.9.36-53644（Electron），8 个进程 |

## 第 1 步：证明不是资源瓶颈

| 指标 | 实测 | 判断 |
|---|---|---|
| 总 CPU | ~6% | 干净 |
| % DPC Time | 0.21% | 干净 |
| % Interrupt Time | 0.51% | 干净 |
| % Disk Time | 0.677% | 干净 |
| Disk Queue Length | 0 | 干净 |
| 内存已用 | 43% | 干净 |
| QQ 全部进程 25 秒内 CPU | 812 ms | 干净——它在**等**，不是在**算** |

最后一行是关键洞察：**QQ 几乎不烧 CPU**。这排除了"QQ 在做重活"，
把方向锁定到"帧没有及时生成/上屏"。

## 第 2 步：版本

```
壳程序 QQ.exe 报的版本: 9.9.20.37625      ← 旧的，别信
versions\config.json:   curVersion = 9.9.36-53644   ← 真实运行版本
```

`versions\` 下只有 1 个版本，干净（多个残留版本可能加载错的那个）。

## 第 3 步：找到根因

```
Win32_VideoController:
  OrayIddDriver Device                 Availability = 8   (Off Line)
  NVIDIA GeForce RTX 4060 Laptop GPU   Availability = 3   (Running)  2560x1600 @240Hz
  Intel(R) UHD Graphics                Availability = 8   (Off Line)

UserGpuPreferences:
  C:\Program Files\Tencent\QQNT\QQ.exe = GpuPreference=1;   ← 省电/核显
  DirectXUserGlobalSettings = SwapEffectUpgradeEnable=1;AutoHDREnable=1;
```

**判读**：显示器（2560×1600@240Hz）由 **NVIDIA 独显**驱动，Intel 核显是 `Off Line`
（根本没在驱动任何显示）。而系统却把 QQ **钉在了核显**上。

于是 QQ 的每一帧都要在核显上渲染、再跨适配器拷贝到独显去上屏。这就是那"半秒"。

### 反直觉的地方（值得记住）

网上流传最广的"新版 QQ 卡顿解决方案"是**"把 QQ 设置成使用集成显卡"**。
用户早就照做了——`GpuPreference=1` 就是那条建议的结果。而在这台机器上，
这条建议**恰好是反的**，因为显示器挂在独显上。

所以：**别抄网上的结论，要看这台机器上"显示器由谁驱动"。**

另外注意到 QQ 进程同时出现在 **3 个不同的 GPU LUID** 上（Intel / NVIDIA / Oray 虚拟），
这是渲染路径混乱的旁证。

## 第 4 步：Chromium 开关透传

先怀疑 Chromium 的遮挡节流（它认为窗口被遮住就降低帧生成频率，输入回显就晚）。

关键问题是：**QQNT 能不能接受命令行开关？** 实测：

```powershell
$flags = '--disable-features=CalculateNativeWinOcclusion',
         '--disable-backgrounding-occluded-windows',
         '--disable-renderer-backgrounding'
Start-Process 'C:\Program Files\Tencent\QQNT\QQ.exe' -ArgumentList $flags
Start-Sleep -Seconds 25
Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" | ForEach-Object { ... }
```

结果：主进程和全部 7 个渲染/工具进程都收到了开关。**透传成功。**

（原理上说得通：`QQ.exe` 和 `QQEX.exe` 都调用了 `CommandLineToArgvW` / `GetCommandLineW`，
所以它们解析并转发了命令行。）

## 修复与结果

同时改了两处：

1. `GpuPreference` 从 `1`（核显）改成 `2`（独显）
2. 三个反节流开关写进 Run 键 + 开始菜单快捷方式 + 桌面快捷方式

用户反馈：**"完全不卡了"**。

### 没能隔离出来的部分

两处一起改的，所以**不知道是哪一处起的作用**（或者两者都需要）。
这是个可以改进的地方——下次应该先只改 GPU 偏好，让用户测一轮，再加开关。
因为反节流开关有代价（后台继续渲染、笔记本多耗电），
如果能只靠 GPU 偏好解决，就不该付这个代价。

## 踩过的坑

### 坑 1：把进程重启时间当成首次启动时间

诊断开机问题时看到：

```
explorer.exe  StartTime = 内核启动后 376.5 秒
```

于是下了结论："桌面卡了 6 分钟"。**错了。**

实际是：explorer 在开机 6 分钟后挂起（`AppHang` 事件），被系统杀掉并重启，
`StartTime` 是**重启时刻**。用户当场纠正："没五分钟这么恐怖吧，但 30 秒左右应该是有的"。

正确的做法是交叉验证：`Kernel-Boot` 事件、最早的用户态进程启动时间、
`User Profile Service` 的登录通知，几个来源对上了才下结论。

顺带修正后的真实开机时间线（用**最早的用户态进程**推断）：

| 阶段 | 耗时 |
|---|---|
| 固件 POST（Kernel-Boot Event 30 的 `ResetEndStart` → `ExitBootServicesExit`） | 0.4 → 9.7 s |
| 内核 → 用户会话（最早用户态进程 +12.8 s） | 12.8 s |
| shell 就绪（`sihost` +15.0 s） | 15.0 s |
| **开机 → 桌面可用** | **≈ 25 s** |

### 坑 2：注册表路径写错

GPU 偏好是 `HKCU\Software\Microsoft\DirectX\UserGpuPreferences`，
**没有** `Windows\CurrentVersion` 这一段。写错不会报错，只是静默返回空——
差点让人以为"偏好被系统重置了"。

### 坑 3：`-match` 误伤

用 `-match 'ASUS'` 去筛计划任务，把 Windows 自带的 `ScanForUpdatesAsUser`
也匹配上了（里面含 `sAsUs`，`-match` 大小写不敏感）。筛名字用 `-like 'ASUS*'`。

### 坑 4：`foreach (...) { } | Format-Table` 解析报错

PowerShell 5.1 里管道不能直接接在 `foreach` 语句后面。先赋值给变量再管道。

## 这台机器上还顺手发现的相关问题

虽然不在本技能范围内，但和"整体手感"有关，记下来当线索：

- **explorer.exe 反复挂起**：10/1、10/9、10/12（崩溃）、10/13 ×3、10/16。
  挂起报告里 `Waiting on Application: explorer.exe`，说明开始菜单也被它拖住。
  从 WER 报告的 `LoadedModule` 里挖出注入的第三方 shell 扩展：
  百度网盘 `YunShellExtV164.dll`（11 个 CLSID）、Adobe `CoreSync_x64.dll`（4 个）、
  RaiDrive、迅雷 `ThunderMyComputerIcon64.dll`。
  用官方 Blocked 机制禁用后，explorer 注入模块 **411 → 317**（少 94 个 DLL）。
- **OrayIddDriver**（向日葵虚拟显示器）一直作为显示适配器存在，
  即使用户不开向日葵。虚拟显示适配器是 DWM 合成与遮挡判定出错的常见来源。
- **Auto HDR 全局开启**（`AutoHDREnable=1`）+ **透明效果开启**（`EnableTransparency=1`），
  都在给每帧加成本。
