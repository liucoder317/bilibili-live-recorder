# 第三方组件与许可证

本程序在安装时自动下载以下第三方组件，并保留其许可证文件：

| 组件 | 版本 | 来源 | 许可证 |
|---|---|---|---|
| Python embeddable | 3.13.17（默认；旧版 3.13.x 可回退） | https://www.python.org/ftp/python/3.13.17/python-3.13.17-embed-amd64.zip | PSF License，见 `Python-LICENSE.txt` |
| ffmpeg | 9.0.2 essentials build | https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip | GPL 构建，见 `FFmpeg-LICENSE.txt` 和 `FFmpeg-README.txt` |
| yt-dlp | 2026.10.26 或更新 | https://github.com/yt-dlp/yt-dlp/releases | Unlicense，见 `yt-dlp-LICENSE.txt` |

这些组件由各自的版权持有人提供，本程序只负责下载和调用，不修改其代码。重新分发安装包时请一并保留本目录和 `runtime` 目录中各自下载产生的许可证文件。
