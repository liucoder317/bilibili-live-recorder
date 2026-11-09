param(
    [ValidateSet('start', 'stop', 'status')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$paths = Get-AppPaths

function Get-StatusObject {
    $statusFile = Join-Path $paths.DataDir 'status.json'
    if (Test-Path -LiteralPath $statusFile) {
        try { return (Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ state = 'not_started'; updated_at = $null }
}

function Write-StatusOutput {
    $status = Get-StatusObject
    $status | ConvertTo-Json -Depth 8 -Compress
}

if ($Action -eq 'start') {
    if (-not (Test-Path -LiteralPath $paths.ConfigPath)) {
        throw '未找到 config.json，请先运行 安装.bat。'
    }
    if (-not (Test-Path -LiteralPath $paths.PythonwExe)) {
        throw '未找到便携 Python 运行时，请重新运行 安装.bat。'
    }
    $pauseFile = Join-Path $paths.DataDir 'PAUSED'
    if (Test-Path -LiteralPath $pauseFile) { Remove-Item -LiteralPath $pauseFile -Force }
    New-Item -ItemType Directory -Force -Path $paths.DataDir | Out-Null
    $recorder = Join-Path $paths.AppDir 'recorder.py'
    Start-Process -FilePath $paths.PythonwExe -ArgumentList ('"' + $recorder + '"') `
        -WorkingDirectory $paths.AppDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-StatusOutput
} elseif ($Action -eq 'stop') {
    New-Item -ItemType Directory -Force -Path $paths.DataDir | Out-Null
    $pauseFile = Join-Path $paths.DataDir 'PAUSED'
    Set-Content -LiteralPath $pauseFile -Value 'Paused by user' -Encoding UTF8
    for ($i = 0; $i -lt 25; $i++) {
        $status = Get-StatusObject
        if ($status.state -eq 'paused' -or $status.state -eq 'stopped' -or $status.state -eq 'not_started') { break }
        Start-Sleep -Seconds 1
    }
    Write-StatusOutput
} else {
    Write-StatusOutput
}
