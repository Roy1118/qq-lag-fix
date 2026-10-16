<#
.SYNOPSIS
    QQ (QQNT) 卡顿修复 —— 应用 GPU 偏好与 Chromium 反节流开关

.DESCRIPTION
    做两件事，都可单独跳过：
      1. 设置 QQ.exe 的 GPU 偏好（注册表 UserGpuPreferences）
      2. 把 Chromium 反节流开关写进 QQ 的三个启动入口（Run 键 + 开始菜单 + 桌面快捷方式）

    改之前会把所有原始值备份到 %LOCALAPPDATA%\qq-lag-fix-backup\，
    并生成一个 RESTORE-<时间戳>.ps1，回退就是跑它。

    注意：QQ 必须完全退出后重新启动，改动才生效。

.PARAMETER GpuPreference
    0 = 让 Windows 决定，1 = 省电(核显)，2 = 高性能(独显)。
    不传则不改 GPU 偏好。判读见 SKILL.md 第 3 步。

.PARAMETER SkipFlags
    只改 GPU 偏好，不写 Chromium 开关。

.PARAMETER SkipGpu
    只写 Chromium 开关，不改 GPU 偏好。

.PARAMETER NoOcclusionFlags
    不关遮挡节流（默认会关）。
    如果你只想处理跨适配器问题、又不想让 QQ 在后台继续渲染耗电，用这个开关。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File apply-fix.ps1 -GpuPreference 2

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File apply-fix.ps1 -GpuPreference 2 -SkipFlags
#>
[CmdletBinding()]
param(
    [ValidateSet(0, 1, 2)]
    [int]$GpuPreference,

    [switch]$SkipFlags,
    [switch]$SkipGpu,
    [switch]$NoOcclusionFlags
)

$ErrorActionPreference = 'Stop'

$qqExe   = 'C:\Program Files\Tencent\QQNT\QQ.exe'
$backupDir = Join-Path $env:LOCALAPPDATA 'qq-lag-fix-backup'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$restorePath = Join-Path $backupDir "RESTORE-$stamp.ps1"

$restore = New-Object System.Collections.Generic.List[string]
$restore.Add('# QQ 卡顿修复 —— 回退脚本，由 apply-fix.ps1 生成')
$restore.Add('# 用法: powershell -ExecutionPolicy Bypass -File <本文件>')
$restore.Add('# 需要管理员权限（开始菜单快捷方式在 ProgramData 下）')
$restore.Add('')
$restore.Add("`$ErrorActionPreference = 'Continue'")

function Note([string]$t) { Write-Host $t }

if (-not (Test-Path $qqExe)) {
    throw "找不到 $qqExe —— 请确认用户装的是 QQNT（新版 QQ）。"
}

Note ''
Note '============================================================'
Note ' QQ 卡顿修复'
Note '============================================================'

# ---------------------------------------------------------------- GPU 偏好
if (-not $SkipGpu) {
    Note ''
    Note '[1] GPU 偏好'
    $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (-not (Test-Path $k)) {
        New-Item -Path $k -Force | Out-Null
        Note '    创建 UserGpuPreferences 键'
        $restore.Add("# 原本不存在 UserGpuPreferences 键")
        $restore.Add("Remove-Item -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Recurse -Force -ErrorAction SilentlyContinue")
    } else {
        $old = (Get-Item $k).GetValue($qqExe)
        Note "    原值: $(if ($old) { $old } else { '(未设置)' })"
        if ($old) {
            $restore.Add("Set-ItemProperty -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name '$qqExe' -Value '$old' -Type String")
        } else {
            $restore.Add("Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name '$qqExe' -ErrorAction SilentlyContinue")
        }
    }

    $label = switch ($GpuPreference) { 0 { '让 Windows 决定' } 1 { '省电/核显' } 2 { '高性能/独显' } }
    Set-ItemProperty -Path $k -Name $qqExe -Value "GpuPreference=$GpuPreference;" -Type String
    Note "    新值: GpuPreference=$GpuPreference;   ($label)"
} else {
    Note ''
    Note '[1] GPU 偏好 —— 已跳过 (-SkipGpu)'
}

# ---------------------------------------------------------------- Chromium 开关
if (-not $SkipFlags) {
    Note ''
    Note '[2] Chromium 反节流开关'

    $flagList = @()
    if (-not $NoOcclusionFlags) {
        $flagList += '--disable-features=CalculateNativeWinOcclusion'
        $flagList += '--disable-backgrounding-occluded-windows'
        $flagList += '--disable-renderer-backgrounding'
    }
    if ($flagList.Count -eq 0) {
        Note '    没有要写的开关（-NoOcclusionFlags 且无其它开关）'
    } else {
        $flags = $flagList -join ' '
        Note "    开关: $flags"

        # --- Run 键 ---
        $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $oldRun = (Get-ItemProperty $rk -Name QQNT -ErrorAction SilentlyContinue).QQNT
        Note ''
        Note '    Run\QQNT (开机自启)'
        Note "      原值: $(if ($oldRun) { $oldRun } else { '(不存在)' })"
        $newRun = '"' + $qqExe + '" /background ' + $flags
        Set-ItemProperty -Path $rk -Name QQNT -Value $newRun -Type String
        Note "      新值: $newRun"
        if ($oldRun) {
            $restore.Add("Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name QQNT -Value '$oldRun' -Type String")
        } else {
            $restore.Add("Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name QQNT -ErrorAction SilentlyContinue")
        }

        # --- 快捷方式（路径按语言/厂商会变，所以搜索而不是硬编码）---
        $searchRoots = @(
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
            [Environment]::GetFolderPath('Desktop'),
            "$env:PUBLIC\Desktop",
            "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        )
        $lnks = foreach ($r in $searchRoots) {
            if (Test-Path $r) {
                Get-ChildItem $r -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'QQ' }
            }
        }
        $sh = New-Object -ComObject WScript.Shell
        $touched = 0
        Note ''
        Note '    快捷方式'
        foreach ($lnk in $lnks) {
            try {
                $l = $sh.CreateShortcut($lnk.FullName)
                if ($l.TargetPath -notlike '*QQNT\QQ.exe') { continue }   # 排除"腾讯会议"之类
                Note "      $($lnk.FullName)"
                Note "        原参数: '$($l.Arguments)'"
                $restore.Add("`$s = New-Object -ComObject WScript.Shell; `$k = `$s.CreateShortcut('$($lnk.FullName)'); `$k.Arguments = '$($l.Arguments)'; `$k.Save()")
                $l.Arguments = $flags
                $l.Save()
                $touched++
                Note '        -> 已更新'
            } catch {
                Note "        跳过（$($_.Exception.Message)）"
                Note '        （ProgramData 下的快捷方式需要管理员权限）'
            }
        }
        if ($touched -eq 0) {
            Note '      没有找到 QQ 的快捷方式 —— 用户可能从任务栏或开始菜单磁贴启动，'
            Note '      那种情况需要手工在快捷方式上加参数。'
        }
    }
} else {
    Note ''
    Note '[2] Chromium 开关 —— 已跳过 (-SkipFlags)'
}

# ---------------------------------------------------------------- 落盘
$restore.Add('')
$restore.Add('Write-Host "回退完成。请完全退出 QQ 再重新启动。" -ForegroundColor Green')
$restore | Out-File -FilePath $restorePath -Encoding UTF8

Note ''
Note '============================================================'
Note " 备份/回退脚本: $restorePath"
Note '============================================================'
Note ''
Note '接下来（重要）:'
Note '  1. 完全退出 QQ（所有进程，包括托盘图标）'
Note '  2. 重新启动 QQ'
Note '  3. 让用户当场试 —— 打字、滚动、切换聊天窗口'
Note '  4. 如果没改善，跑回退脚本还原，再考虑 SKILL.md 里的下一项'
Note ''
if (-not $SkipFlags -and -not $NoOcclusionFlags) {
    Note ' 提醒用户: 关掉遮挡节流后，QQ 被遮住/最小化时仍会继续渲染，'
    Note '           笔记本上会多耗一点电。不想要这个代价就用 -NoOcclusionFlags。'
    Note ''
}
