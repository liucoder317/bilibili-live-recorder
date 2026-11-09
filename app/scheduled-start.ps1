param(
    [switch]$ValidateOnly,
    [switch]$OnLogon
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-AppPaths

function Get-ScheduleDecision {
    param(
        [datetime]$NowBeijing,
        [string]$LastDate,
        [Nullable[datetime]]$PauseBeijing,
        [string]$DailyStart,
        [bool]$Enabled
    )
    if (-not $Enabled) { return 'disabled' }
    $due = $NowBeijing.Date.Add([TimeSpan]::Parse($DailyStart))
    if ($NowBeijing -lt $due) { return 'before_schedule' }
    if ($LastDate -eq $NowBeijing.ToString('yyyy-MM-dd')) { return 'already_handled' }
    if ($null -ne $PauseBeijing -and $PauseBeijing -gt $due) { return 'user_paused_after_schedule' }
    return 'start'
}

if ($ValidateOnly) {
    $config = Get-AppConfig
    $dailyStart = [string]$config.daily_start
    if (-not (Test-Path -LiteralPath (Join-Path $paths.AppDir 'control.ps1'))) {
        throw 'Missing recorder control script'
    }
    if (-not (Test-Path -LiteralPath $paths.PythonwExe)) {
        throw 'Missing portable Python runtime'
    }
    $due = [datetime]('2026-10-30 ' + $dailyStart)
    $cases = @(
        @{ Now = $due.AddHours(-12); Last = ''; Pause = $due.AddHours(-13); Expected = 'before_schedule' },
        @{ Now = $due; Last = ''; Pause = $due.AddHours(-13); Expected = 'start' },
        @{ Now = $due.AddMinutes(10); Last = ''; Pause = $due.AddMinutes(5); Expected = 'user_paused_after_schedule' },
        @{ Now = $due.AddMinutes(10); Last = '2026-10-30'; Pause = $due.AddMinutes(5); Expected = 'already_handled' },
        @{ Now = $due.AddDays(1); Last = '2026-10-30'; Pause = $due.AddMinutes(5); Expected = 'start' }
    )
    $enabled = [bool]$config.auto_resume_on_schedule
    foreach ($case in $cases) {
        $actual = Get-ScheduleDecision -NowBeijing $case.Now -LastDate $case.Last `
            -PauseBeijing $case.Pause -DailyStart $dailyStart -Enabled $enabled
        if ($actual -ne $case.Expected) {
            throw ('Schedule decision mismatch: expected ' + $case.Expected + ', got ' + $actual)
        }
    }
    [pscustomobject]@{ Validation = 'passed'; Cases = $cases.Count; StartedRecorder = $false } |
        ConvertTo-Json -Compress
    exit 0
}

New-Item -ItemType Directory -Force -Path $paths.DataDir | Out-Null
$stateFile = Join-Path $paths.DataDir 'schedule-state.json'
$pauseFile = Join-Path $paths.DataDir 'PAUSED'
$lockFile = Join-Path $paths.DataDir 'scheduled-start.lock'

$lock = $null
try {
    $lock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch [System.IO.IOException] {
    [pscustomobject]@{ Result = 'another_invocation_running' } | ConvertTo-Json -Compress
    exit 0
}

function Save-ScheduleState {
    param([hashtable]$Value)
    $temporary = $stateFile + '.tmp'
    $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $stateFile -Force
}

try {
    $config = Get-AppConfig
    $nowBeijing = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).DateTime
    $previousDate = ''
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $previous = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $previousDate = [string]$previous.last_scheduled_date
        } catch { $previousDate = '' }
    }
    $pauseBeijing = $null
    if (Test-Path -LiteralPath $pauseFile) {
        $pauseBeijing = (Get-Item -LiteralPath $pauseFile).LastWriteTimeUtc.AddHours(8)
    }
    $enabled = [bool]$config.auto_resume_on_schedule
    $decision = Get-ScheduleDecision -NowBeijing $nowBeijing -LastDate $previousDate `
        -PauseBeijing $pauseBeijing -DailyStart ([string]$config.daily_start) -Enabled $enabled

    if ($decision -eq 'already_handled' -and $OnLogon -and -not (Test-Path -LiteralPath $pauseFile)) {
        # 当天已经处理过，登录时只恢复未被暂停的会话，不重复清暂停。
        $controlOutput = & (Join-Path $paths.AppDir 'control.ps1') -Action start | Out-String
        $recordState = ($controlOutput | ConvertFrom-Json).state
        [pscustomobject]@{ Result = 'resume_unpaused_session'; StartedRecorder = $true; state = $recordState } |
            ConvertTo-Json -Compress
    } elseif ($decision -ne 'start') {
        [pscustomobject]@{ Result = $decision; StartedRecorder = $false } | ConvertTo-Json -Compress
    } else {
        # 先记录当天尝试，再启动；延迟的健康检查不会撤销用户的手动暂停。
        $state = @{
            last_scheduled_date = $nowBeijing.ToString('yyyy-MM-dd')
            requested_at         = ([DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8))).ToString('o')
            result               = 'starting'
            timezone             = 'Asia/Shanghai'
            daily_start          = [string]$config.daily_start
        }
        Save-ScheduleState $state
        try {
            $controlOutput = & (Join-Path $paths.AppDir 'control.ps1') -Action start | Out-String
            $recording = $controlOutput | ConvertFrom-Json
            $state.result = 'start_requested'
            $state.observed_recorder_state = [string]$recording.state
            $state.completed_at = ([DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8))).ToString('o')
            Save-ScheduleState $state
            $state | ConvertTo-Json -Compress
        } catch {
            $state.result = 'failed'
            $state.error_type = $_.Exception.GetType().FullName
            Save-ScheduleState $state
            throw
        }
    }
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
