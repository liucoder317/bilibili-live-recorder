param(
    [switch]$NonInteractive,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'B站直播录制 - 卸载'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-AppPaths

Write-Host ''
Write-Host '============================================================' -ForegroundColor Yellow
Write-Host '                   B站直播录制 - 卸载程序' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Yellow
Write-Host '将删除：每日计划任务、开始菜单/桌面快捷方式、录制程序运行状态。'
Write-Host '不会删除：已经录制的视频文件。'
Write-Host ''

if (-not $NonInteractive) {
    $answer = Read-Host '确认卸载？输入 y 继续，其他任意键取消'
    if (-not $answer -or $answer.Trim().ToLower() -notin @('y', 'yes', '是')) {
        Write-Host '已取消。'
        return
    }
}

$config = $null
if (Test-Path -LiteralPath $paths.ConfigPath) {
    try { $config = Get-AppConfig } catch { $config = $null }
}

if (-not $TestMode) {
    if ($config) {
        try { & (Join-Path $paths.AppDir 'control.ps1') -Action stop | Out-Null } catch { }
        Remove-DailyTask -TaskName ([string]$config.task_name)
        Remove-AppShortcuts -Config $config
    } else {
        Remove-DailyTask -TaskName 'BilibiliLiveRecorder_31462057_DailyStart'
    }
    Write-Host '计划任务和快捷方式已删除。'
}

$stateFiles = @('status.json', 'PAUSED', 'worker.lock', 'schedule-state.json', 'scheduled-start.lock')
foreach ($name in $stateFiles) {
    $file = Join-Path $paths.DataDir $name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}
if (Test-Path -LiteralPath $paths.ConfigPath) {
    Remove-Item -LiteralPath $paths.ConfigPath -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '卸载完成。录像文件保留在原保存目录。' -ForegroundColor Green
Write-Host '如需彻底清理，可手动删除整个程序文件夹。'
if (-not $NonInteractive) { Read-Host '按回车关闭' }
