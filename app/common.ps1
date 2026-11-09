# 公共函数库：路径、配置、下载、快捷方式、计划任务
$ErrorActionPreference = 'Stop'
$script:BaseDir = Split-Path -Parent $PSScriptRoot
$script:AppDir = $PSScriptRoot

function Get-AppPaths {
    [pscustomobject]@{
        BaseDir    = $script:BaseDir
        AppDir     = $script:AppDir
        RuntimeDir = Join-Path $script:BaseDir 'runtime'
        DataDir    = Join-Path $script:BaseDir 'data'
        ConfigPath = Join-Path $script:BaseDir 'config.json'
        PythonDir  = Join-Path $script:BaseDir 'runtime\python'
        PythonExe  = Join-Path $script:BaseDir 'runtime\python\python.exe'
        PythonwExe = Join-Path $script:BaseDir 'runtime\python\pythonw.exe'
        FFmpegExe  = Join-Path $script:BaseDir 'runtime\ffmpeg\bin\ffmpeg.exe'
        YtDlpExe   = Join-Path $script:BaseDir 'runtime\yt-dlp.exe'
    }
}

function ConvertTo-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '主播' }
    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return '主播' }
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
    return $safe
}

function Get-AppConfig {
    param([string]$Path = (Join-Path $script:BaseDir 'config.json'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw '未找到 config.json，请先运行 安装.bat。'
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-AppConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$Path = (Join-Path $script:BaseDir 'config.json')
    )
    $json = $Config | ConvertTo-Json -Depth 8
    $temporary = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-AppConfig {
    param(
        [Parameter(Mandatory = $true)][int]$RoomId,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$DailyStart
    )
    $safeName = ConvertTo-SafeFileName $DisplayName
    $output = Join-Path $OutputRoot ($safeName + '_' + $RoomId)
    [pscustomobject][ordered]@{
        room_id                 = $RoomId
        room_url                = "https://live.bilibili.com/$RoomId"
        display_name            = $DisplayName
        output                  = $output
        daily_start             = $DailyStart
        timezone                = 'Asia/Shanghai'
        poll_seconds            = 30
        retry_seconds           = 10
        segment_seconds         = 1800
        stall_seconds           = 90
        min_free_gib            = 20
        keep_awake              = $true
        ffmpeg_tls_verify       = $true
        auto_resume_on_schedule = $true
        task_name               = "BilibiliLiveRecorder_${RoomId}_DailyStart"
        ffmpeg                  = 'runtime\ffmpeg\bin\ffmpeg.exe'
        yt_dlp                  = 'runtime\yt-dlp.exe'
    }
}

function Get-DefaultOutputRoot {
    if (Test-Path -LiteralPath 'D:\') {
        return 'D:\B站直播'
    }
    $videos = [Environment]::GetFolderPath('MyVideos')
    if ([string]::IsNullOrWhiteSpace($videos)) {
        $videos = Join-Path $env:USERPROFILE 'Videos'
    }
    return (Join-Path $videos 'B站直播')
}

function Get-PythonCommand {
    if ($script:PythonExe -and (Test-Path -LiteralPath $script:PythonExe)) {
        return $script:PythonExe
    }
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $command = Get-Command python3.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-PythonDownload {
    param([string]$Url, [string]$Destination)
    $ErrorActionPreference = 'Continue'
    $python = Get-PythonCommand
    if (-not $python) { return $false }
    $code = @'
import sys, urllib.request
url, dest = sys.argv[1], sys.argv[2]
ua = "Mozilla" + "/5.0 (Windows NT 10.0; Win64; x64)"
req = urllib.request.Request(url, headers={"User-Agent": ua})
with urllib.request.urlopen(req, timeout=180) as response, open(dest, "wb") as handle:
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        handle.write(chunk)
'@
    $tempScript = Join-Path $env:TEMP ('bililive_dl_' + [guid]::NewGuid().ToString('N') + '.py')
    try {
        [System.IO.File]::WriteAllText($tempScript, $code, (New-Object System.Text.UTF8Encoding($false)))
        & $python $tempScript $Url $Destination 2>$null
        return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0))
    } finally {
        if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue }
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string[]]$Urls,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$MinimumBytes = 1024,
        [int]$TimeoutSeconds = 900
    )
    $ErrorActionPreference = 'Continue'
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($url in $Urls) {
        try {
            Write-Host ("  尝试下载: " + $url)
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
            $ok = $false
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($curl) {
                & $curl.Source -L --fail --retry 2 --connect-timeout 30 --max-time $TimeoutSeconds -o $Destination $url 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -ge $MinimumBytes)) {
                    $ok = $true
                }
            }
            if (-not $ok) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSeconds
                    if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -ge $MinimumBytes)) {
                        $ok = $true
                    }
                } catch {
                    $errors.Add(($url + ' -> IWR: ' + $_.Exception.Message))
                }
            }
            if (-not $ok) {
                if (Invoke-PythonDownload -Url $url -Destination $Destination) {
                    if ((Get-Item -LiteralPath $Destination).Length -ge $MinimumBytes) { $ok = $true }
                } else {
                    $errors.Add(($url + ' -> Python download failed'))
                }
            }
            if ($ok) {
                Write-Host ("  下载完成: " + [Math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1) + ' MB')
                return
            }
        } catch {
            $errors.Add(($url + ' -> ' + $_.Exception.Message))
        }
    }
    throw ("所有下载源均失败。" + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
}

function Expand-ZipToDirectory {
    param([string]$ZipPath, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Invoke-ExeWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($Arguments | ForEach-Object {
        if ([string]$_ -match '\s') { '"' + $_ + '"' } else { [string]$_ }
    }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{ ExitCode = -1; TimedOut = $false; Output = '' }
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Output = '' }
        }
        $text = $process.StandardOutput.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $process.StandardError.ReadToEnd() }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; TimedOut = $false; Output = ([string]$text).Trim() }
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$Description = ''
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($Description) { $shortcut.Description = $Description }
    $shortcut.Save()
}

function Get-PowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return 'powershell.exe'
}

function Install-AppShortcuts {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$DesktopPath = '',
        [string]$StartupPath = ''
    )
    $paths = Get-AppPaths
    $ps = Get-PowerShellPath
    $desktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('Desktop') }
    $startup = if ($StartupPath) { $StartupPath } else { [Environment]::GetFolderPath('Startup') }
    $control = Join-Path $paths.AppDir 'control.ps1'
    $status = Join-Path $paths.AppDir 'status.ps1'
    $scheduled = Join-Path $paths.AppDir 'scheduled-start.ps1'
    $configBat = Join-Path $paths.BaseDir '配置.bat'

    New-Shortcut -Path (Join-Path $desktop '启动B站录制.lnk') -TargetPath $ps `
        -Arguments ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $control + '" -Action start') `
        -WorkingDirectory $paths.BaseDir -Description '启动 B 站直播后台录制'
    New-Shortcut -Path (Join-Path $desktop '停止B站录制.lnk') -TargetPath $ps `
        -Arguments ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $control + '" -Action stop') `
        -WorkingDirectory $paths.BaseDir -Description '停止 B 站直播后台录制'
    New-Shortcut -Path (Join-Path $desktop '查看录制状态.lnk') -TargetPath $ps `
        -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $status + '"') `
        -WorkingDirectory $paths.BaseDir -Description '查看 B 站直播录制状态'
    if (Test-Path -LiteralPath $configBat) {
        New-Shortcut -Path (Join-Path $desktop '配置B站录制.lnk') -TargetPath $configBat `
            -WorkingDirectory $paths.BaseDir -Description '修改直播间、保存目录或启动时间'
    }
    New-Shortcut -Path (Join-Path $startup ('B站直播录制_' + $Config.room_id + '.lnk')) -TargetPath $ps `
        -Arguments ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scheduled + '" -OnLogon') `
        -WorkingDirectory $paths.BaseDir -Description '登录时兜底启动 B 站直播录制'
}

function Remove-AppShortcuts {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$DesktopPath = '',
        [string]$StartupPath = ''
    )
    $desktop = if ($DesktopPath) { $DesktopPath } else { [Environment]::GetFolderPath('Desktop') }
    $startup = if ($StartupPath) { $StartupPath } else { [Environment]::GetFolderPath('Startup') }
    $names = @('启动B站录制.lnk', '停止B站录制.lnk', '查看录制状态.lnk', '配置B站录制.lnk')
    foreach ($name in $names) {
        $path = Join-Path $desktop $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $startupLink = Join-Path $startup ('B站直播录制_' + $Config.room_id + '.lnk')
    if (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink -Force }
}

function Test-DailyTask {
    param([string]$TaskName)
    $ErrorActionPreference = 'Continue'
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return $false }
    & schtasks.exe /Query /TN $TaskName >$null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Register-DailyTask {
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$DailyStart,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$XmlOutputPath = ''
    )
    $ErrorActionPreference = 'Continue'
    $ps = Get-PowerShellPath
    $userId = if ($env:USERDOMAIN) { $env:USERDOMAIN + '\' + $env:USERNAME } else { $env:USERNAME }
    $esc = { param($text) [System.Security.SecurityElement]::Escape([string]$text) }
    $startBoundary = (Get-Date -Format 'yyyy-MM-dd') + 'T' + $DailyStart + ':00'
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>B站直播录制每日自动启动</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$( & $esc $startBoundary )</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$( & $esc $userId )</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$( & $esc $ps )</Command>
      <Arguments>$( & $esc $arguments )</Arguments>
      <WorkingDirectory>$( & $esc $WorkingDirectory )</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    $tempXml = Join-Path $env:TEMP ('bililive_task_' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        [System.IO.File]::WriteAllText($tempXml, $xml, (New-Object System.Text.UnicodeEncoding($false, $true)))
        if ($XmlOutputPath) {
            Copy-Item -LiteralPath $tempXml -Destination $XmlOutputPath -Force
            return
        }
        $output = & schtasks.exe /Create /TN $TaskName /XML $tempXml /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            # 少数系统不允许 schtasks 读取 XML 时，退回到简单的 /TR 方式。
            $action = '"' + (Get-PowerShellPath) + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
            $fallback = & schtasks.exe /Create /TN $TaskName /TR $action /SC DAILY /ST $DailyStart /F 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ('计划任务创建失败：' + ($output -join ' ') + ' / ' + ($fallback -join ' '))
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tempXml) { Remove-Item -LiteralPath $tempXml -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-DailyTask {
    param([string]$TaskName)
    $ErrorActionPreference = 'Continue'
    if ([string]::IsNullOrWhiteSpace($TaskName)) { return }
    if (Test-DailyTask -TaskName $TaskName) {
        & schtasks.exe /Delete /TN $TaskName /F >$null 2>&1
    }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}
