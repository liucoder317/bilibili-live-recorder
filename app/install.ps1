param(
    [int]$RoomId = 0,
    [string]$DisplayName = '',
    [string]$OutputRoot = '',
    [string]$DailyStart = '',
    [switch]$NonInteractive,
    [switch]$TestMode,
    [switch]$SkipDependencies
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$Host.UI.RawUI.WindowTitle = 'B站直播录制 - 安装程序'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'dependencies.ps1')

$paths = Get-AppPaths
$existing = $null
if (Test-Path -LiteralPath $paths.ConfigPath) {
    try { $existing = Get-AppConfig } catch { $existing = $null }
}

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if ($NonInteractive) { return $Default }
    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-Host $Prompt
    } else {
        $value = Read-Host ($Prompt + ' [默认: ' + $Default + ']')
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '                B站直播录制 - 一键安装程序' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '本程序会安装：后台录制工具、桌面快捷方式、每日计划任务。'
Write-Host '只录制 B 站公开直播，不读取浏览器 Cookie，不上传录像。'
Write-Host ''

if (-not [Environment]::Is64BitOperatingSystem) {
    throw '本工具仅支持 64 位 Windows。'
}
if ([Environment]::OSVersion.Version.Major -lt 10) {
    throw '本工具需要 Windows 10 或 Windows 11。'
}

# ---------- 交互参数 ----------
if ($RoomId -le 0) {
    $defaultRoom = 31462057
    if ($existing -and [int]$existing.room_id -gt 0) { $defaultRoom = [int]$existing.room_id }
    $roomText = Read-Default -Prompt '请输入 B 站直播间房间号（纯数字）' -Default ([string]$defaultRoom)
    if ($roomText -notmatch '^\d{3,12}$') { throw '房间号格式不正确。' }
    $RoomId = [int]$roomText
}

if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    if ($existing -and [int]$existing.room_id -eq $RoomId -and -not [string]::IsNullOrWhiteSpace($existing.display_name)) {
        $DisplayName = [string]$existing.display_name
    } elseif ($RoomId -eq 31462057) {
        $DisplayName = '立芯'
    }
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if ($existing -and -not [string]::IsNullOrWhiteSpace($existing.output)) {
        $OutputRoot = Split-Path -Parent ([string]$existing.output)
    } else {
        $OutputRoot = Get-DefaultOutputRoot
    }
}

if (-not $NonInteractive) {
    $displayPrompt = '主播名称（用于文件夹命名，留空自动获取）'
    if ($DisplayName) {
        $DisplayName = Read-Default -Prompt $displayPrompt -Default $DisplayName
    } else {
        $DisplayName = Read-Default -Prompt $displayPrompt -Default ''
    }
    $OutputRoot = Read-Default -Prompt '录像保存根目录' -Default $OutputRoot
}

if ([string]::IsNullOrWhiteSpace($DailyStart)) {
    if ($existing -and -not [string]::IsNullOrWhiteSpace($existing.daily_start)) {
        $DailyStart = [string]$existing.daily_start
    } else {
        $DailyStart = '21:30'
    }
}
if (-not $NonInteractive) {
    $DailyStart = Read-Default -Prompt '每天自动启动时间（24 小时制 HH:mm）' -Default $DailyStart
}
if ($DailyStart -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
    throw '启动时间格式不正确，应为 HH:mm，例如 21:30。'
}

$OutputRoot = [Environment]::ExpandEnvironmentVariables($OutputRoot.Trim())
try {
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
} catch {
    throw ('保存目录无法创建：' + $OutputRoot)
}

Write-Host ''
Write-Host '安装配置：' -ForegroundColor Yellow
Write-Host ('  直播间房间号 : ' + $RoomId)
Write-Host ('  主播名称     : ' + $(if ($DisplayName) { $DisplayName } else { '自动获取' }))
Write-Host ('  录像保存根目录: ' + $OutputRoot)
Write-Host ('  每日启动时间 : ' + $DailyStart)
if (-not $NonInteractive) {
    $confirm = Read-Host '确认按以上配置安装？(Y/n)'
    if ($confirm -and $confirm.Trim().ToLower() -notin @('y', 'yes', '是', '')) {
        Write-Host '已取消安装。'
        return
    }
}

# ---------- 依赖 ----------
Write-Host ''
Write-Host '[1/3] 检查并安装运行依赖...' -ForegroundColor Cyan
if ($SkipDependencies) {
    if (-not (Test-PythonRuntime -PythonDir $paths.PythonDir)) { throw '已跳过下载，但便携 Python 不存在。' }
    if (-not (Test-FFmpegRuntime -FFmpegExe $paths.FFmpegExe)) { throw '已跳过下载，但 ffmpeg 不存在。' }
    if (-not (Test-YtDlpRuntime -YtDlpExe $paths.YtDlpExe)) { throw '已跳过下载，但 yt-dlp 不存在。' }
    $script:PythonExe = $paths.PythonExe
    $ytRun = Invoke-ExeWithTimeout -FilePath $paths.YtDlpExe -Arguments @('--version') -TimeoutSeconds 45
    $depResult = [pscustomobject]@{
        Python = (& $paths.PythonExe --version 2>&1 | Select-Object -First 1)
        FFmpeg = (& $paths.FFmpegExe -version 2>&1 | Select-Object -First 1)
        YtDlp  = if ($ytRun.ExitCode -eq 0) { $ytRun.Output } else { 'unknown' }
    }
} else {
    $depResult = Install-AllDependencies
}
Write-Host ('  ' + $depResult.Python)
Write-Host ('  ' + $depResult.FFmpeg)
Write-Host ('  yt-dlp ' + $depResult.YtDlp)

# ---------- 生成配置 ----------
Write-Host ''
Write-Host '[2/3] 写入配置并检查直播间...' -ForegroundColor Cyan
$oldTaskName = ''
$oldConfig = $existing
if ($existing -and -not [string]::IsNullOrWhiteSpace($existing.task_name)) {
    $oldTaskName = [string]$existing.task_name
}

$config = New-AppConfig -RoomId $RoomId -DisplayName $(if ($DisplayName) { $DisplayName } else { '主播' }) `
    -OutputRoot $OutputRoot -DailyStart $DailyStart
Save-AppConfig -Config $config

# 用便携 Python 查询主播名和直播状态；失败不影响安装。
try {
    $roomJson = & $paths.PythonExe (Join-Path $paths.AppDir 'recorder.py') --room-info 2>$null | Out-String
    $room = $roomJson.Trim() | ConvertFrom-Json
    if ($room -and -not $room.error) {
        if ([string]::IsNullOrWhiteSpace($DisplayName) -and $room.anchor_name) {
            $config.display_name = [string]$room.anchor_name
            $config.output = Join-Path $OutputRoot ((ConvertTo-SafeFileName $config.display_name) + '_' + $RoomId)
            Save-AppConfig -Config $config
        }
        Write-Host ('  直播间: ' + $room.title + '（主播: ' + $(if ($room.anchor_name) { $room.anchor_name } else { '未知' }) + '）')
        if ([int]$room.live_status -eq 1) { Write-Host '  当前状态: 正在直播' } else { Write-Host '  当前状态: 未开播' }
    }
} catch {
    Write-Host '  提示: 暂时无法连接 B 站接口，稍后程序会自动重试。' -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path ([string]$config.output) | Out-Null
New-Item -ItemType Directory -Force -Path $paths.DataDir | Out-Null

# ---------- 系统集成 ----------
Write-Host ''
Write-Host '[3/3] 创建快捷方式和计划任务...' -ForegroundColor Cyan
if (-not $TestMode) {
    if ($oldConfig) { Remove-AppShortcuts -Config $oldConfig }
    Install-AppShortcuts -Config $config
    Register-DailyTask -TaskName $config.task_name -DailyStart $config.daily_start `
        -ScriptPath (Join-Path $paths.AppDir 'scheduled-start.ps1') -WorkingDirectory $paths.BaseDir
    if ($oldTaskName -and $oldTaskName -ne $config.task_name) {
        Remove-DailyTask -TaskName $oldTaskName
    }
    Write-Host ('  计划任务: ' + $config.task_name + '（每天 ' + $config.daily_start + '）')
    Write-Host '  桌面快捷方式: 启动 / 停止 / 查看状态 / 配置'
} else {
    Write-Host '  测试模式：已跳过快捷方式和计划任务创建。'
}

$result = [pscustomobject]@{
    installed_at  = (Get-Date).ToString('o')
    package_root  = $paths.BaseDir
    room_id       = $config.room_id
    display_name  = $config.display_name
    output        = $config.output
    daily_start   = $config.daily_start
    task_name     = $config.task_name
    test_mode     = [bool]$TestMode
    dependencies  = $depResult
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $paths.DataDir 'install-result.json') -Encoding UTF8

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host '安装完成。' -ForegroundColor Green
Write-Host ('录像目录: ' + $config.output)
Write-Host ('每日启动: ' + $config.daily_start + '（电脑需开机并已登录）')
Write-Host '使用桌面快捷方式“启动B站录制”可立即开始监测。'
Write-Host '============================================================' -ForegroundColor Green
if (-not $NonInteractive) {
    Read-Host '按回车关闭安装程序'
}
