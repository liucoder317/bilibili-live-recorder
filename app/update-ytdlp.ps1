param([switch]$NonInteractive)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'B站直播录制 - 更新解析器'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-AppPaths

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '                B站直播录制 - 更新解析器（yt-dlp）' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $paths.RuntimeDir)) {
    New-Item -ItemType Directory -Force -Path $paths.RuntimeDir | Out-Null
}

$oldVersion = '(未安装)'
if (Test-Path -LiteralPath $paths.YtDlpExe) {
    $oldRun = Invoke-ExeWithTimeout -FilePath $paths.YtDlpExe -Arguments @('--version') -TimeoutSeconds 90
    if ($oldRun.ExitCode -eq 0 -and -not $oldRun.TimedOut) { $oldVersion = $oldRun.Output.Trim() }
}
Write-Host ('当前版本: ' + $oldVersion)
Write-Host '正在从 GitHub 下载最新 yt-dlp.exe...'

$urls = @(
    'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
    'https://ghproxy.net/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
    'https://gh-proxy.com/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
)
$temp = Join-Path $paths.RuntimeDir ('yt-dlp-new_' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    Download-File -Urls $urls -Destination $temp -MinimumBytes 1000000 -TimeoutSeconds 600
    $newRun = Invoke-ExeWithTimeout -FilePath $temp -Arguments @('--version') -TimeoutSeconds 90
    $newVersion = $newRun.Output.Trim()
    if ($newRun.ExitCode -ne 0 -or $newRun.TimedOut) { throw '新下载的 yt-dlp 无法运行。' }
    if (Test-Path -LiteralPath $paths.YtDlpExe) {
        $backup = Join-Path $paths.RuntimeDir ('yt-dlp-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.exe')
        Move-Item -LiteralPath $paths.YtDlpExe -Destination $backup -Force
    }
    Move-Item -LiteralPath $temp -Destination $paths.YtDlpExe -Force
    Write-Host ('更新完成: ' + $oldVersion + ' -> ' + $newVersion) -ForegroundColor Green
} catch {
    Write-Host ('更新失败: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '提示: 如果正在录制，请先停止录制再更新；也可以按文档手动放置 yt-dlp.exe。'
    if ($env:BILILIVE_UPDATE_NO_PAUSE -ne '1') {
        if (-not $NonInteractive) { Read-Host '按回车关闭' }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

if (-not $NonInteractive) { Read-Host '按回车关闭' }
