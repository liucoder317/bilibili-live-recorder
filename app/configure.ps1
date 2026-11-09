param(
    [int]$RoomId = 0,
    [string]$DisplayName = '',
    [string]$OutputRoot = '',
    [string]$DailyStart = '',
    [switch]$NonInteractive,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$Host.UI.RawUI.WindowTitle = 'B站直播录制 - 配置'
. (Join-Path $PSScriptRoot 'common.ps1')

$paths = Get-AppPaths
if (-not (Test-Path -LiteralPath $paths.ConfigPath)) {
    throw '未找到 config.json，请先运行 安装.bat。'
}
$old = Get-AppConfig
$oldTaskName = [string]$old.task_name
$oldRoom = [int]$old.room_id
$oldOutput = [string]$old.output

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
Write-Host '                   B站直播录制 - 配置修改' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ('当前直播间: ' + $old.room_id + '（' + $old.display_name + '）')
Write-Host ('当前目录  : ' + $old.output)
Write-Host ('当前启动  : ' + $old.daily_start)
Write-Host ''

if ($RoomId -le 0) {
    $text = Read-Default -Prompt '直播间房间号' -Default ([string]$old.room_id)
    if ($text -notmatch '^\d{3,12}$') { throw '房间号格式不正确。' }
    $RoomId = [int]$text
}
$roomChanged = ($RoomId -ne $oldRoom)

if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    if ($roomChanged) {
        $DisplayName = Read-Default -Prompt '主播名称（留空自动获取）' -Default ''
    } else {
        $DisplayName = Read-Default -Prompt '主播名称' -Default ([string]$old.display_name)
    }
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $defaultRoot = Split-Path -Parent $oldOutput
    $OutputRoot = Read-Default -Prompt '录像保存根目录' -Default $defaultRoot
}
if ([string]::IsNullOrWhiteSpace($DailyStart)) {
    $DailyStart = Read-Default -Prompt '每天自动启动时间（HH:mm）' -Default ([string]$old.daily_start)
}
if ($DailyStart -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw '启动时间格式不正确。' }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$config = New-AppConfig -RoomId $RoomId -DisplayName $(if ($DisplayName) { $DisplayName } else { '主播' }) `
    -OutputRoot $OutputRoot -DailyStart $DailyStart
Save-AppConfig -Config $config

# 房间变化且未填名称时，自动查询主播名。
if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    try {
        $roomJson = & $paths.PythonExe (Join-Path $paths.AppDir 'recorder.py') --room-info 2>$null | Out-String
        $room = $roomJson.Trim() | ConvertFrom-Json
        if ($room -and -not $room.error -and $room.anchor_name) {
            $config.display_name = [string]$room.anchor_name
            $config.output = Join-Path $OutputRoot ((ConvertTo-SafeFileName $config.display_name) + '_' + $RoomId)
            Save-AppConfig -Config $config
        }
    } catch { }
}

New-Item -ItemType Directory -Force -Path ([string]$config.output) | Out-Null

Write-Host ''
Write-Host ('新直播间: ' + $config.room_id + '（' + $config.display_name + '）')
Write-Host ('新目录  : ' + $config.output)
Write-Host ('新启动  : ' + $config.daily_start)

if (-not $TestMode) {
    Remove-AppShortcuts -Config $old
    Install-AppShortcuts -Config $config
    Register-DailyTask -TaskName $config.task_name -DailyStart $config.daily_start `
        -ScriptPath (Join-Path $paths.AppDir 'scheduled-start.ps1') -WorkingDirectory $paths.BaseDir
    if ($oldTaskName -and $oldTaskName -ne $config.task_name) {
        Remove-DailyTask -TaskName $oldTaskName
    }
    Write-Host '计划和快捷方式已更新。'
}

$restart = $true
if (-not $NonInteractive) {
    $answer = Read-Host '是否立即重启录制程序使配置生效？(Y/n)'
    if ($answer -and $answer.Trim().ToLower() -in @('n', 'no', '否')) { $restart = $false }
}
if ($restart -and -not $TestMode) {
    try {
        & (Join-Path $paths.AppDir 'control.ps1') -Action stop | Out-Null
        & (Join-Path $paths.AppDir 'control.ps1') -Action start | Out-Null
        Write-Host '录制程序已按新配置重启。'
    } catch {
        Write-Host ('重启失败，请手动停止并启动录制。' + $_.Exception.Message) -ForegroundColor Yellow
    }
}

if (-not $NonInteractive) { Read-Host '按回车关闭' }
