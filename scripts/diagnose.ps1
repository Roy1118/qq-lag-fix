<#
.SYNOPSIS
    QQ (QQNT / Electron) 卡顿与打字延迟 —— 只读诊断脚本

.DESCRIPTION
    采集渲染路径相关证据，不做任何修改。输出一份可读报告。
    对应 SKILL.md 的第 1~7 步。

.PARAMETER OutputPath
    报告保存路径。默认写到 %LOCALAPPDATA%\qq-lag-fix-backup\diagnose-<时间戳>.txt

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File diagnose.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Continue'

if (-not $OutputPath) {
    $dir = Join-Path $env:LOCALAPPDATA 'qq-lag-fix-backup'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $OutputPath = Join-Path $dir ("diagnose-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".txt")
}

$script:lines = New-Object System.Collections.Generic.List[string]
function Say([string]$text = '') { $script:lines.Add($text) | Out-Null }
function Head([string]$title) { Say ''; Say ('=' * 72); Say $title; Say ('=' * 72) }
function KV([string]$k, $v) { Say ('  {0,-26} {1}' -f $k, $v) }

# ---------------------------------------------------------------- 0. 环境
Head '0. 环境'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    KV 'Windows' ("{0} Build {1}.{2}" -f $os.Caption, $os.BuildNumber, $os.Version)
    KV '逻辑处理器' $cs.NumberOfLogicalProcessors
    # 注意：参数模式下 [math]::Round(a, b) 里的逗号会被当成参数分隔符，
    # 必须整体加括号（或先赋值给变量）。这是个很容易踩的坑。
    KV '物理内存(GB)' ([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
    KV '已用内存(%)' ([math]::Round(100 - ([double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize * 100), 1))
    KV '开机时长' ((Get-Date) - $os.LastBootUpTime).ToString('d\.hh\:mm\:ss')
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 1. 资源瓶颈
Head '1. 资源瓶颈（判读：DPC<2% 中断<2% 磁盘<20% 队列≈0 才算干净）'
try {
    $counters = @(
        '\Processor(_Total)\% DPC Time',
        '\Processor(_Total)\% Interrupt Time',
        '\PhysicalDisk(_Total)\% Disk Time',
        '\PhysicalDisk(_Total)\Current Disk Queue Length',
        '\PhysicalDisk(_Total)\Avg. Disk sec/Transfer',
        '\Memory\Pages/sec'
    )
    Get-Counter -Counter $counters -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop |
        Select-Object -ExpandProperty CounterSamples |
        Group-Object Path | ForEach-Object {
            KV ($_.Name -replace '.*\\', '') ([math]::Round((($_.Group | Measure-Object CookedValue -Average).Average), 3))
        }
} catch { Say "  性能计数器不可用: $_" }

Say ''
Say '  --- QQ 各进程 CPU 占用（10 秒增量，累计 CPU 秒数无法直接当占用率看）---'
try {
    $n = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $prev = @{}
    Get-Process QQ -ErrorAction SilentlyContinue | ForEach-Object { $prev[$_.Id] = $_.CPU }
    if ($prev.Count -eq 0) {
        Say '  QQ 未在运行（先启动 QQ 再跑本脚本，才能采到渲染路径证据）'
    } else {
        Start-Sleep -Seconds 10
        Get-Process QQ -ErrorAction SilentlyContinue | ForEach-Object {
            if ($prev.ContainsKey($_.Id)) {
                KV ("PID $($_.Id)") ('CPU% {0,6:N2}   内存MB {1,6:N0}   线程 {2}' -f (($_.CPU - $prev[$_.Id]) / 10 / $n * 100), ($_.WS / 1MB), $_.Threads.Count)
            }
        }
    }
} catch { Say "  采样失败: $_" }

# ---------------------------------------------------------------- 2. QQNT 版本
Head '2. QQ 安装与版本'
$qqExe = 'C:\Program Files\Tencent\QQNT\QQ.exe'
try {
    if (Test-Path $qqExe) {
        KV '主程序' $qqExe
        KV '壳版本(旧)' (Get-Item $qqExe).VersionInfo.FileVersion
    } else {
        Say "  未找到 $qqExe —— 可能不是 QQNT，或装在别处。请确认用户用的是新版 QQ。"
        $alt = Get-ChildItem 'C:\Program Files*\Tencent' -Filter 'QQ.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
               Select-Object -First 3 -ExpandProperty FullName
        if ($alt) { Say ('  找到候选: ' + ($alt -join ', ')) }
    }
    $cfg = 'C:\Program Files\Tencent\QQNT\versions\config.json'
    if (Test-Path $cfg) {
        Say '  versions\config.json:'
        Get-Content $cfg | ForEach-Object { Say ('    ' + $_) }
    }
    $vers = Get-ChildItem 'C:\Program Files\Tencent\QQNT\versions' -Directory -ErrorAction SilentlyContinue
    if ($vers) {
        Say '  versions\ 下已安装的版本（多个说明有热更新残留）:'
        $vers | ForEach-Object { Say ('    ' + $_.Name) }
    }
    $procs = Get-Process QQ -ErrorAction SilentlyContinue
    KV 'QQ 进程数' $(if ($procs) { $procs.Count } else { 0 })
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 3. GPU 路径
Head '3. GPU 渲染路径（本技能的核心证据）'
Say '  Availability: 3=正在运行  8=Off Line(没在驱动任何显示)'
try {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Say ''
        KV '名称' $_.Name
        KV '驱动版本' $_.DriverVersion
        KV '显示模式' $_.VideoModeDescription
        KV '刷新率' $_.CurrentRefreshRate
        KV 'Availability' $_.Availability
        KV 'PNPDeviceID' $_.PNPDeviceID
    }
} catch { Say "  采集失败: $_" }

Say ''
Say '  --- 系统给 QQ 指定的 GPU 偏好 ---'
Say '  含义: 0=让 Windows 决定  1=省电/核显  2=高性能/独显'
try {
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path $k) {
        $v = (Get-Item $k).GetValue($qqExe)
        KV 'QQ.exe GpuPreference' $(if ($v) { $v } else { '(未设置 → 走全局默认)' })
        KV '全局 DirectX 设置' (Get-Item $k).GetValue('DirectXUserGlobalSettings')
    } else {
        Say '  UserGpuPreferences 键不存在 → QQ 使用系统默认 GPU 选择'
    }
} catch { Say "  采集失败: $_" }

Say ''
Say '  --- 虚拟显示驱动（向日葵/ToDesk 等，会扰乱 DWM 合成与遮挡判定）---'
try {
    $virt = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -match 'Oray|Idd|Virtual|Mirror|Dummy|ToDesk|Sunlogin|Parsec|DisplayLink' }
    if ($virt) { $virt | ForEach-Object { KV $_.Name "Availability=$($_.Availability)  $($_.PNPDeviceID)" } }
    else { Say '  未发现虚拟显示适配器' }
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 4. 渲染进程与开关
Head '4. Chromium 渲染进程与已生效的开关'
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) { Say '  QQ 未在运行' }
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        $type = if ($cl -match '--type=(\w+)') { $Matches[1] } else { 'main' }
        $switches = @()
        foreach ($s in 'CalculateNativeWinOcclusion', 'disable-backgrounding-occluded-windows',
                       'disable-renderer-backgrounding', 'disable-gpu', 'disable-gpu-compositing') {
            if ($cl -match [regex]::Escape($s)) { $switches += $s }
        }
        KV ("PID $($p.ProcessId) [$type]") $(if ($switches) { $switches -join ', ' } else { '(无相关开关)' })
    }
    Say ''
    Say '  如果主进程和渲染进程都没收到开关 → 反节流开关还没落地（见 SKILL.md 第 4 步）'
    Say '  如果 --disable-gpu 出现在这里 → 可能反而有害，NapCatQQ#1332 记录过 QQNT 起不来'
} catch { Say "  采集失败: $_" }

Say ''
Say '  --- 启动入口（开关必须同时写进这三处）---'
try {
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    KV 'Run\QQNT' (Get-ItemProperty $rk -Name QQNT -ErrorAction SilentlyContinue).QQNT
    $sh = New-Object -ComObject WScript.Shell
    foreach ($lnk in @(
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\腾讯软件\QQ\QQ.lnk',
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'QQ.lnk')
    )) {
        if (Test-Path $lnk) {
            $l = $sh.CreateShortcut($lnk)
            KV '快捷方式' $lnk
            KV '  参数' $(if ($l.Arguments) { $l.Arguments } else { '(空)' })
        }
    }
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 5. 输入法
Head '5. 输入法'
try {
    Get-WinUserLanguageList | ForEach-Object { KV $_.LanguageTag ($_.InputMethodTips -join ', ') }
    $ime = Get-Process -ErrorAction SilentlyContinue |
           Where-Object { $_.ProcessName -match 'ChsIME|ctfmon|TextInputHost|Sogou|QQPinyin|WeChat' }
    if ($ime) { $ime | ForEach-Object { KV $_.ProcessName "PID $($_.Id)  $([math]::Round($_.WS/1MB))MB" } }
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 6. 合成开销
Head '6. 系统级合成开销'
try {
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path $k) { KV 'AutoHDR/全局' (Get-Item $k).GetValue('DirectXUserGlobalSettings') }
    KV '透明效果(1=开,建议关)' (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name EnableTransparency -ErrorAction SilentlyContinue).EnableTransparency
    KV '拖拽显示完整窗口' (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name DragFullWindows -ErrorAction SilentlyContinue).DragFullWindows
    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1
    if ($vc) { KV '当前分辨率/刷新率' "$($vc.VideoModeDescription) @ $($vc.CurrentRefreshRate)Hz" }
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 7. shell 扩展
Head '7. 可疑 shell 扩展（影响 explorer，也拖累整体手感）'
try {
    $reports = Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'explorer|AppHang' } | Sort-Object LastWriteTime -Descending
    if (-not $reports) {
        Say '  WER 里没有 explorer 挂起记录（这是好事）'
    } else {
        Say "  发现 $($reports.Count) 份挂起/崩溃报告，最近 3 份:"
        $reports | Select-Object -First 3 | ForEach-Object { Say ("    " + $_.LastWriteTime + "  " + $_.Name) }
        $latest = $reports | Select-Object -First 1
        $wer = Join-Path $latest.FullName 'Report.wer'
        # Report.wer 的 ACL 会拒绝非提权读取，Test-Path 本身就会抛权限错误，
        # 所以要 try/catch 而不是 -ErrorAction
        $canRead = $false
        try { $canRead = [System.IO.File]::Exists($wer) } catch { $canRead = $false }
        if ($canRead) {
            Say ''
            Say '  最近一份报告里的第三方模块（非 C:\Windows\）:'
            $mods = Get-Content $wer -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^LoadedModule\[\d+\]=' } |
                    ForEach-Object { ($_ -split '=', 2)[1] }
            $mods | Where-Object { $_ -notmatch '^[A-Za-z]:\\Windows\\' -and $_ -notmatch '\\dotnet\\' } |
                Sort-Object -Unique | ForEach-Object { Say ('    ' + $_) }
        } else {
            Say '  （读不到 Report.wer —— 需要管理员权限）'
        }
    }

    $bl = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    if (Test-Path $bl) {
        $props = (Get-Item $bl).Property
        KV '已禁用的 shell 扩展' $props.Count
    } else {
        Say '  尚未使用 Blocked 机制'
    }
} catch { Say "  采集失败: $_" }

# ---------------------------------------------------------------- 判读提示
Head '判读提示（结论不要直接给用户，先自己核对）'
Say @'
  1) 资源干净（DPC/中断/磁盘都低）→ 排除资源瓶颈，继续往下。
     若 DPC 或中断 > 5%，根因在某个驱动，不在 QQ。

  2) 若只有独显 Availability=3、核显=8，而 QQ 的 GpuPreference=1
     → 跨适配器渲染，改成 2。这是命中率最高的一条。
     注意：网上流传的"把 QQ 设成集成显卡"在独显直驱的机器上是反的。

  3) 若 QQ 进程命令行里没有反节流开关 → 见 SKILL.md 第 4 步落地。

  4) 改动之前先备份；改完让用户当场操作 QQ 试，一次只改一类。
'@

# ---------------------------------------------------------------- 落盘
$text = $script:lines -join "`r`n"
$text | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host $text
Write-Host ''
Write-Host "报告已保存: $OutputPath" -ForegroundColor Green
