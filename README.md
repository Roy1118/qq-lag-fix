# qq-lag-fix

**诊断并修复 Windows 上 QQ（QQNT）的卡顿与打字延迟。**

针对的是"打完拼音选完字，字要等半秒才蹦到输入框里"、"几秒钟一顿"这类问题。
不是"清缓存""重装 QQ"那一套——那些对渲染延迟基本无效。

这是一个 [Claude Skill](https://docs.claude.com/en/docs/claude-code/skills)：把它放进 skills 目录，
Claude 遇到 QQ 卡顿的问题时会自动调用它。

---

## 它解决什么问题

新版 QQ（9.9.x）是 **Electron 应用**（QQNT）。Electron 把整个界面当作一块 GPU 合成的画布来画，
所以"帧生成 → 合成 → 上屏"这条链条上任何一环被拖慢，都会表现成**输入回显延迟**。

问题通常不在 QQ 本身，而在这台机器的渲染路径上。这个技能会按命中率从高到低排查：

| # | 根因 | 典型现象 |
|---|---|---|
| 1 | **跨适配器渲染** —— 显示器由独显驱动，QQ 却被钉在核显上 | 打字延迟、掉帧 |
| 2 | **Chromium 遮挡节流** —— Chromium 误判窗口被遮挡，按后台节奏出帧 | 打字延迟 |
| 3 | **虚拟显示驱动**（向日葵 / ToDesk 等）扰乱 DWM 合成 | 整体发涩 |
| 4 | **输入法 ↔ Chromium 的 TSF 桥接** | 仅输入延迟 |
| 5 | **系统级合成开销**（透明效果、Auto HDR、高刷+非整数缩放） | 整体偏慢 |
| 6 | **第三方 shell 扩展注入** | 资源管理器也卡 |

### 一个反直觉的点

网上流传最广的建议是**"新版 QQ 卡顿就把 QQ 设成集成显卡"**。
在**显示器由独显直驱**的机器上，这条建议**恰恰是反的**——它会让 QQ 每帧都跨适配器拷贝。

判断依据是 `Win32_VideoController` 的 `Availability`：
`3` = 正在驱动显示，`8` = Off Line（没在驱动任何显示）。
如果只有独显是 `3`，就不该把 QQ 钉在核显上。

---

## 怎么用

### 方式一：交给 Claude

把整个 `qq-lag-fix` 目录放进你的 skills 目录（例如 `~/.claude/skills/`），
然后直接说"我的 QQ 打字很卡"就行。

### 方式二：自己跑脚本

三个 PowerShell 脚本，只依赖系统自带的东西，不需要装任何软件。

```powershell
# 1) 先诊断（只读，不改任何东西）
powershell -ExecutionPolicy Bypass -File scripts\diagnose.ps1

# 2) 看报告，确认根因，再决定改什么
#    最常见的修法：把 QQ 指到独显
powershell -ExecutionPolicy Bypass -File scripts\apply-fix.ps1 -GpuPreference 2

# 3) 完全退出 QQ，重新启动，试打字

# 4) 不满意就一键回退
powershell -ExecutionPolicy Bypass -File scripts\revert-fix.ps1 -Latest
```

`apply-fix.ps1` 支持的开关：

| 参数 | 作用 |
|---|---|
| `-GpuPreference 0\|1\|2` | 0=让 Windows 决定，1=省电/核显，2=高性能/独显 |
| `-SkipGpu` | 只写 Chromium 开关，不改 GPU 偏好 |
| `-SkipFlags` | 只改 GPU 偏好，不写 Chromium 开关 |
| `-NoOcclusionFlags` | 不关遮挡节流（省电优先时用） |

**改之前会自动备份**，回退脚本写在 `%LOCALAPPDATA%\qq-lag-fix-backup\`。

---

## 目录结构

```
qq-lag-fix/
├── SKILL.md                              # 技能本体：诊断流程 + 修复优先级 + 踩坑记录
├── scripts/
│   ├── diagnose.ps1                      # 只读诊断，一次采集全部证据
│   ├── apply-fix.ps1                     # 应用修复，自动备份
│   └── revert-fix.ps1                    # 回退
├── references/
│   ├── case-2026-hybrid-gpu.md           # 实战案例：混合显卡 + 240Hz 笔记本上的"字迟到半秒"
│   └── why-chromium-flags.md             # 那几个 Chromium 开关在做什么、代价是什么
└── evals/                                # 测试用例与诊断快照
```

---

## 关于"代价"

修复里有一条（关掉 Chromium 遮挡节流）会让 **QQ 被遮住/最小化时仍继续渲染**，
笔记本上会多耗一点电。这个取舍技能里会明确告诉使用者，并提供了
`-NoOcclusionFlags` 来跳过。

---

## 免责声明

这些脚本会修改注册表（`HKCU` 下的 GPU 偏好和开机自启项）和快捷方式参数。
**每次改动前都会备份并生成回退脚本**，但仍然建议你先跑 `diagnose.ps1` 看看报告，
确认根因对得上再动手。

技能里的判读规则来自实测，但**不同机器的根因可能不同**——
诊断报告里的数字才是你的依据，不要照着结论抄。

## License

MIT
