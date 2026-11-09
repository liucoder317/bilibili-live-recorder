param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-AppPaths
$statusFile = Join-Path $paths.DataDir 'status.json'

$stateText = @{
    'not_started' = '尚未启动'
    'starting'    = '正在启动'
    'waiting'     = '未开播，等待中'
    'connecting'  = '正在连接直播流'
    'recording'   = '正在录制'
    'retrying'    = '出错，正在重试'
    'reconnecting' = '断流，正在重连'
    'low_disk'    = '磁盘空间不足，已暂停'
    'paused'      = '用户已停止'
    'stopped'     = '已停止'
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '                    B站直播录制状态' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $statusFile)) {
    Write-Host '尚未启动过录制。请双击桌面“启动B站录制”。' -ForegroundColor Yellow
} else {
    try {
        $s = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $state = [string]$s.state
        $text = $stateText[$state]
        if (-not $text) { $text = $state }
        Write-Host ('状态      : ' + $text)
        if ($s.display_name) { Write-Host ('主播      : ' + $s.display_name) }
        Write-Host ('房间号    : ' + $s.room_id)
        if ($s.title) { Write-Host ('直播标题  : ' + $s.title) }
        if ($s.output) { Write-Host ('录像目录  : ' + $s.output) }
        if ($s.session) { Write-Host ('本次文件  : ' + $s.session) }
        if ($null -ne $s.recorded_bytes) {
            Write-Host ('已录制    : ' + [Math]::Round([double]$s.recorded_bytes / 1GB, 2) + ' GB（' + $s.segment_count + ' 个分段）')
        }
        if ($s.current_file) { Write-Host ('当前文件  : ' + $s.current_file) }
        if ($null -ne $s.free_gib) { Write-Host ('磁盘剩余  : ' + $s.free_gib + ' GB') }
        if ($s.error_type) { Write-Host ('最近错误  : ' + $s.error_type) -ForegroundColor Yellow }
        if ($s.updated_at) {
            $updated = [datetimeoffset]::Parse([string]$s.updated_at)
            Write-Host ('更新时间  : ' + $updated.ToString('yyyy-MM-dd HH:mm:ss'))
            $age = ([datetimeoffset]::Now - $updated).TotalMinutes
            if ($age -gt 3 -and $state -notin @('paused', 'stopped', 'low_disk')) {
                Write-Host ('注意      : 状态已有 ' + [Math]::Round($age, 0) + ' 分钟未更新，程序可能已退出。') -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host ('状态文件读取失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
if (-not $NoPause) {
    Read-Host '按回车关闭'
}
