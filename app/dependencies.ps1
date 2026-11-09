# 依赖检测与自动下载：便携 Python、ffmpeg、yt-dlp
$ErrorActionPreference = 'Stop'

function Test-PythonRuntime {
    param([string]$PythonDir)
    $ErrorActionPreference = 'Continue'
    $exe = Join-Path $PythonDir 'python.exe'
    $pyw = Join-Path $PythonDir 'pythonw.exe'
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $pyw)) { return $false }
    & $exe -c "import sys, ctypes, msvcrt, json, urllib.request, logging.handlers" >$null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Get-PythonEmbedUrls {
    param([string]$Version)
    return @(
        "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip",
        "https://mirrors.aliyun.com/python-release/windows/python-$Version-embed-amd64.zip",
        "https://repo.huaweicloud.com/python/$Version/python-$Version-embed-amd64.zip",
        "https://registry.npmmirror.com/-/binary/python/$Version/python-$Version-embed-amd64.zip",
        "https://mirrors.tuna.tsinghua.edu.cn/python/$Version/python-$Version-embed-amd64.zip"
    )
}

function Install-PythonEmbed {
    param([string]$RuntimeDir)
    $pythonDir = Join-Path $RuntimeDir 'python'
    $versions = @()
    if ($env:BILILIVE_PYTHON_VERSION) { $versions += $env:BILILIVE_PYTHON_VERSION }
    $versions += @('3.13.17', '3.13.16', '3.13.15', '3.13.14', '3.13.13', '3.13.12', '3.13.11', '3.13.10', '3.13.9', '3.13.8', '3.12.10', '3.12.9')
    $versions = @($versions | Select-Object -Unique)
    $tempZip = Join-Path $env:TEMP ('bililive_python_' + [guid]::NewGuid().ToString('N') + '.zip')
    $tempDir = Join-Path $env:TEMP ('bililive_python_' + [guid]::NewGuid().ToString('N'))
    try {
        $downloaded = $false
        foreach ($version in $versions) {
            try {
                Write-Host ("[Python] 尝试 Python " + $version + " 嵌入式包...")
                Download-File -Urls (Get-PythonEmbedUrls -Version $version) -Destination $tempZip -MinimumBytes 5000000
                $downloaded = $true
                break
            } catch {
                Write-Host ("[Python] " + $version + " 不可用，继续尝试下一版本。")
            }
        }
        if (-not $downloaded) { throw '无法下载 Python 嵌入式包，请按《环境说明与配置文档》手动放置。' }
        Expand-ZipToDirectory -ZipPath $tempZip -Destination $pythonDir
        $pth = Get-ChildItem -LiteralPath $pythonDir -Filter 'python*._pth' -File | Select-Object -First 1
        if ($pth) {
            $lines = @(Get-Content -LiteralPath $pth.FullName)
            if ($lines -notcontains 'DLLs') {
                Add-Content -LiteralPath $pth.FullName -Value 'DLLs' -Encoding ASCII
            }
        }
        if (-not (Test-PythonRuntime -PythonDir $pythonDir)) {
            throw 'Python 嵌入式包解压后自检失败。'
        }
        Write-Host '[Python] 便携运行时已就绪。'
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-FFmpegRuntime {
    param([string]$FFmpegExe)
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $FFmpegExe)) { return $false }
    & $FFmpegExe -version >$null 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Install-FFmpeg {
    param([string]$RuntimeDir)
    $targetDir = Join-Path $RuntimeDir 'ffmpeg\bin'
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $urls = @(
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
        'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip',
        'https://ghproxy.net/https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip',
        'https://gh-proxy.com/https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip',
        'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    )
    $tempZip = Join-Path $env:TEMP ('bililive_ffmpeg_' + [guid]::NewGuid().ToString('N') + '.zip')
    $tempDir = Join-Path $env:TEMP ('bililive_ffmpeg_' + [guid]::NewGuid().ToString('N'))
    try {
        Write-Host '[FFmpeg] 正在下载 ffmpeg（约 100 MB，请耐心等待）...'
        Download-File -Urls $urls -Destination $tempZip -MinimumBytes 20000000 -TimeoutSeconds 1800
        Expand-ZipToDirectory -ZipPath $tempZip -Destination $tempDir
        $exe = Get-ChildItem -LiteralPath $tempDir -Recurse -File -Filter 'ffmpeg.exe' | Select-Object -First 1
        if (-not $exe) { throw '下载的 ffmpeg 压缩包中未找到 ffmpeg.exe。' }
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $targetDir 'ffmpeg.exe') -Force
        $license = Get-ChildItem -LiteralPath $tempDir -Recurse -File -Include 'LICENSE*','README*' | Select-Object -First 1
        if ($license) { Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $RuntimeDir 'ffmpeg') -Force }
        if (-not (Test-FFmpegRuntime -FFmpegExe (Join-Path $targetDir 'ffmpeg.exe'))) {
            throw 'ffmpeg 下载后自检失败。'
        }
        Write-Host '[FFmpeg] 已就绪。'
    } finally {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-YtDlpRuntime {
    param([string]$YtDlpExe)
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $YtDlpExe)) { return $false }
    $run = Invoke-ExeWithTimeout -FilePath $YtDlpExe -Arguments @('--version') -TimeoutSeconds 90
    return ($run.ExitCode -eq 0 -and -not $run.TimedOut -and -not [string]::IsNullOrWhiteSpace($run.Output))
}

function Install-YtDlp {
    param([string]$RuntimeDir)
    $target = Join-Path $RuntimeDir 'yt-dlp.exe'
    $temp = Join-Path $RuntimeDir ('yt-dlp_' + [guid]::NewGuid().ToString('N') + '.tmp')
    $urls = @(
        'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp.exe',
        'https://ghproxy.net/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        'https://gh-proxy.com/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        'https://ghfast.top/https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
    )
    try {
        Write-Host '[yt-dlp] 正在下载最新解析器...'
        Download-File -Urls $urls -Destination $temp -MinimumBytes 1000000 -TimeoutSeconds 600
        $run = Invoke-ExeWithTimeout -FilePath $temp -Arguments @('--version') -TimeoutSeconds 90
        if ($run.ExitCode -ne 0 -or $run.TimedOut) { throw 'yt-dlp 下载后无法运行。' }
        Move-Item -LiteralPath $temp -Destination $target -Force
        Write-Host ('[yt-dlp] 已就绪，版本 ' + $run.Output)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Install-AllDependencies {
    param([switch]$Force)
    $paths = Get-AppPaths
    New-Item -ItemType Directory -Force -Path $paths.RuntimeDir | Out-Null
    $pythonOk = (Test-PythonRuntime -PythonDir $paths.PythonDir)
    if ($Force -or -not $pythonOk) { Install-PythonEmbed -RuntimeDir $paths.RuntimeDir }
    $script:PythonExe = $paths.PythonExe
    if ($Force -or -not (Test-FFmpegRuntime -FFmpegExe $paths.FFmpegExe)) { Install-FFmpeg -RuntimeDir $paths.RuntimeDir }
    if ($Force -or -not (Test-YtDlpRuntime -YtDlpExe $paths.YtDlpExe)) { Install-YtDlp -RuntimeDir $paths.RuntimeDir }
    $ytRun = Invoke-ExeWithTimeout -FilePath $paths.YtDlpExe -Arguments @('--version') -TimeoutSeconds 90
    return [pscustomobject]@{
        Python = (& $paths.PythonExe --version 2>&1 | Select-Object -First 1)
        FFmpeg = (& $paths.FFmpegExe -version 2>&1 | Select-Object -First 1)
        YtDlp  = if ($ytRun.ExitCode -eq 0) { $ytRun.Output } else { 'unknown' }
    }
}
