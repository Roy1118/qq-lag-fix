<#
.SYNOPSIS
    QQ 卡顿修复 —— 回退

.DESCRIPTION
    apply-fix.ps1 每次运行都会在 %LOCALAPPDATA%\qq-lag-fix-backup\ 下生成
    一份 RESTORE-<时间戳>.ps1。本脚本负责找到并执行它。

    不带参数运行 → 列出所有可用的回退点，让你和用户挑一个。
    带 -BackupFile   → 直接执行指定那份。
    带 -Latest       → 执行最新那份。

    注意：备份脚本里既有 HKCU 改动（不需要管理员），也有 ProgramData 下的
    快捷方式改动（需要管理员）。所以本脚本会以管理员身份重新启动自己。

.PARAMETER BackupFile
    要执行的 RESTORE-*.ps1 完整路径。

.PARAMETER Latest
    执行最新的一份备份。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File revert-fix.ps1
    powershell -ExecutionPolicy Bypass -File revert-fix.ps1 -Latest
#>
[CmdletBinding()]
param(
    [string]$BackupFile,
    [switch]$Latest
)

$ErrorActionPreference = 'Continue'
$backupDir = Join-Path $env:LOCALAPPDATA 'qq-lag-fix-backup'

if (-not (Test-Path $backupDir)) {
    Write-Host "没有找到备份目录: $backupDir" -ForegroundColor Yellow
    Write-Host '说明 apply-fix.ps1 还没运行过。如果之前是手工改的，只能手工改回去。'
    exit 0
}

$all = Get-ChildItem $backupDir -Filter 'RESTORE-*.ps1' -File -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending

if (-not $all) {
    Write-Host "备份目录里没有 RESTORE-*.ps1" -ForegroundColor Yellow
    Write-Host '如果之前是手工改的，只能手工改回去。'
    exit 0
}

if (-not $BackupFile -and -not $Latest) {
    Write-Host ''
    Write-Host '可用的回退点（新 → 旧）:' -ForegroundColor Cyan
    Write-Host ''
    $i = 1
    foreach ($f in $all) {
        Write-Host ("  [{0}] {1}   {2}" -f $i, $f.Name, $f.LastWriteTime)
        $i++
    }
    Write-Host ''
    Write-Host '挑一个再跑: powershell -ExecutionPolicy Bypass -File revert-fix.ps1 -BackupFile <路径>' -ForegroundColor Cyan
    Write-Host '或者直接回退到最新: ... -Latest' -ForegroundColor Cyan
    exit 0
}

if ($Latest -and -not $BackupFile) { $BackupFile = $all[0].FullName }

if (-not (Test-Path $BackupFile)) {
    Write-Host "找不到: $BackupFile" -ForegroundColor Red
    exit 1
}

# 提权执行（快捷方式那部分需要管理员）
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限（开始菜单快捷方式在 ProgramData 下），正在提权...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BackupFile
    ) -Wait
    Write-Host '回退脚本已执行。' -ForegroundColor Green
} else {
    & $BackupFile
}

Write-Host ''
Write-Host '回退完成。请完全退出 QQ 再重新启动，让改动生效。' -ForegroundColor Green
