"""仅录制指定的 B 站公开直播间；不读取浏览器 Cookie，不上传或删除录像。

配置文件位于程序根目录的 config.json，运行数据（状态、日志、锁）位于 data 目录。
"""
from __future__ import annotations

import argparse
import ctypes
import json
import logging
from logging.handlers import RotatingFileHandler
import msvcrt
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
BASE_DIR = APP_DIR.parent
CONFIG_PATH = BASE_DIR / 'config.json'
STATE_DIR = BASE_DIR / 'data'
TZ = timezone(timedelta(hours=8))
CREATE_NO_WINDOW = 0x08000000
UA = ('Mozilla' + '/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36')


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit('缺少配置文件: ' + str(CONFIG_PATH))
    try:
        return json.loads(CONFIG_PATH.read_text(encoding='utf-8-sig'))
    except Exception as exc:
        raise SystemExit('配置文件读取失败: ' + type(exc).__name__) from exc


CFG = load_config()
OUTPUT = Path(str(CFG['output']))
if not OUTPUT.is_absolute():
    OUTPUT = BASE_DIR / OUTPUT
STATUS = STATE_DIR / 'status.json'
PAUSED = STATE_DIR / 'PAUSED'
LOG_FILE = STATE_DIR / 'recorder.log'
FFMPEG_LOG = STATE_DIR / 'ffmpeg-current.log'
WORKER_LOCK = STATE_DIR / 'worker.lock'
SESSION = None


def resolve_tool(key: str, default_relative: str) -> Path:
    raw = str(CFG.get(key) or default_relative)
    path = Path(raw)
    return path if path.is_absolute() else (BASE_DIR / path)


FFMPEG = resolve_tool('ffmpeg', r'runtime\ffmpeg\bin\ffmpeg.exe')
YT_DLP = resolve_tool('yt_dlp', r'runtime\yt-dlp.exe')


def stamp() -> str:
    return datetime.now(TZ).isoformat()


def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def save_status(state: str, **fields) -> None:
    global SESSION
    ensure_state_dir()
    payload = {
        'updated_at': stamp(),
        'state': state,
        'worker_pid': os.getpid(),
        'room_id': CFG.get('room_id'),
        'room_url': CFG.get('room_url'),
        'display_name': CFG.get('display_name'),
        'output': str(OUTPUT),
        'session': SESSION,
        'min_free_gib': CFG.get('min_free_gib'),
        **fields,
    }
    temp = STATUS.with_suffix('.json.tmp')
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, STATUS)


def room_info() -> dict:
    req = urllib.request.Request(
        'https://api.live.bilibili.com/room/v1/Room/get_info?room_id=' + str(CFG['room_id']),
        headers={'User-Agent': UA, 'Referer': str(CFG['room_url'])})
    with urllib.request.urlopen(req, timeout=20) as response:
        data = json.load(response)
    if data.get('code') != 0 or not isinstance(data.get('data'), dict):
        raise RuntimeError('直播间状态接口返回异常: ' + str(data.get('code')))
    return data['data']


def anchor_info() -> dict:
    req = urllib.request.Request(
        'https://api.live.bilibili.com/live_user/v1/UserInfo/get_anchor_in_room?roomid='
        + str(CFG['room_id']),
        headers={'User-Agent': UA, 'Referer': str(CFG['room_url'])})
    with urllib.request.urlopen(req, timeout=20) as response:
        data = json.load(response)
    if data.get('code') != 0 or not isinstance(data.get('data'), dict):
        return {}
    return data['data'].get('info') or {}


def tool_version(path: Path, args: list[str]) -> dict:
    result = {'path': str(path), 'exists': path.exists()}
    if not path.exists():
        result['error'] = 'not_found'
        return result
    try:
        proc = subprocess.run([str(path), *args], capture_output=True, encoding='utf-8',
                              errors='replace', timeout=25, creationflags=CREATE_NO_WINDOW)
        text = (proc.stdout or '').strip() or (proc.stderr or '').strip()
        result['version'] = text.splitlines()[0][:200] if text else ''
        result['exit_code'] = proc.returncode
    except Exception as exc:
        result['error'] = type(exc).__name__
    return result


def stream_info() -> tuple[dict, dict]:
    args = [str(YT_DLP), '--ignore-config', '--no-warnings', '--socket-timeout', '15',
            '--retries', '1', '--skip-download', '-J', str(CFG['room_url'])]
    result = subprocess.run(args, capture_output=True, encoding='utf-8', errors='replace',
                            timeout=65, creationflags=CREATE_NO_WINDOW)
    if result.returncode:
        # 不把可能含临时签名 URL 的第三方完整输出写入状态。
        raise RuntimeError('yt-dlp 未能解析公开直播流，退出码 ' + str(result.returncode))
    info = json.loads(result.stdout)
    if info.get('is_live') is not True:
        raise RuntimeError('解析结果不是正在直播的视频')
    formats = info.get('formats', [])
    selected = [f for f in formats if f.get('url') and f.get('ext') == 'flv'
                and f.get('protocol') in ('http', 'https')]
    if not selected:
        selected = [f for f in formats if f.get('url') and not f.get('has_drm')
                    and f.get('protocol') in ('m3u8_native', 'm3u8', 'http', 'https')]
    if not selected:
        raise RuntimeError('未找到可直接访问的公开直播格式')
    # yt-dlp 输出按可用质量排序；优先直接 FLV，减少分片开销。
    chosen = selected[-1]
    return info, chosen


def wait(seconds: int) -> bool:
    for _ in range(seconds):
        if PAUSED.exists():
            return False
        time.sleep(1)
    return True


def stop_ffmpeg(child: subprocess.Popen) -> None:
    if child.poll() is not None:
        return
    try:
        child.stdin.write(b'q\n')
        child.stdin.flush()
        child.wait(timeout=12)
    except (OSError, subprocess.TimeoutExpired):
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)


def record(room: dict) -> bool:
    global SESSION
    info, fmt = stream_info()
    now = datetime.now(TZ)
    directory = OUTPUT / now.strftime('%Y-%m-%d')
    directory.mkdir(parents=True, exist_ok=True)
    prefix = str(CFG['room_id']) + '_' + now.strftime('%Y-%m-%d_%H-%M-%S')
    pattern = directory / (prefix + '_part%03d.mkv')
    SESSION = prefix
    (directory / (prefix + '_info.json')).write_text(json.dumps({
        'room_id': CFG['room_id'],
        'display_name': CFG.get('display_name'),
        'title': room.get('title'),
        'started_recording_at': stamp(),
        'live_started_at': room.get('live_time'),
        'available_format': fmt.get('format_id'),
        'recording_policy': '记录从获取直播流开始的内容；没有回放时不能补录此前内容',
        'segment_seconds': CFG['segment_seconds'],
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    # 不转码，保留原流；MKV 分段可减少断网/异常关机影响范围。
    headers = 'User-Agent: ' + UA + '\r\nReferer: ' + str(CFG['room_url']) + '\r\n'
    tls_args = [] if CFG.get('ffmpeg_tls_verify', True) else ['-tls_verify', '0']
    args = [str(FFMPEG), '-hide_banner', '-loglevel', 'warning', '-n',
            '-rw_timeout', '20000000', '-reconnect', '1', '-reconnect_streamed', '1',
            '-reconnect_delay_max', '5', *tls_args, '-headers', headers, '-i', fmt['url'],
            '-map', '0:v:0?', '-map', '0:a:0?', '-c', 'copy',
            '-f', 'segment', '-segment_time', str(CFG['segment_seconds']),
            '-segment_format', 'matroska', '-reset_timestamps', '1', str(pattern)]
    # FFmpeg 错误日志不记录启动命令或签名 URL，只保留当前这一份并轮换上一份。
    if FFMPEG_LOG.exists() and FFMPEG_LOG.stat().st_size > 2_000_000:
        previous = STATE_DIR / 'ffmpeg-previous.log'
        if previous.exists():
            previous.unlink()
        FFMPEG_LOG.replace(previous)
    logging.info('开始录制 %s，格式 %s', room.get('title'), fmt.get('format_id'))
    last_bytes = 0
    last_growth = time.monotonic()
    low_disk = False
    reason = 'stream_ended_or_disconnected'
    with FFMPEG_LOG.open('ab') as errors:
        child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                 stderr=errors, creationflags=CREATE_NO_WINDOW)
        try:
            while child.poll() is None:
                files = list(directory.glob(prefix + '_part*.mkv'))
                total = sum(f.stat().st_size for f in files)
                if total > last_bytes:
                    last_bytes = total
                    last_growth = time.monotonic()
                free = shutil.disk_usage(OUTPUT).free / 1024 ** 3
                save_status('recording' if total else 'connecting', title=room.get('title'),
                            ffmpeg_pid=child.pid, recorded_bytes=total,
                            segment_count=len(files),
                            current_file=str(max(files, key=lambda x: x.stat().st_mtime))
                            if files else None,
                            free_gib=round(free, 2), format_id=fmt.get('format_id'))
                if PAUSED.exists():
                    reason = 'user_paused'
                    break
                if free < CFG['min_free_gib']:
                    low_disk = True
                    reason = 'low_disk'
                    break
                if time.monotonic() - last_growth > CFG['stall_seconds']:
                    reason = 'no_data_timeout'
                    break
                time.sleep(5)
        finally:
            stop_ffmpeg(child)
    files = list(directory.glob(prefix + '_part*.mkv'))
    total = sum(f.stat().st_size for f in files)
    logging.info('本段录制结束：%s，%s 字节，退出码 %s', reason, total, child.returncode)
    save_status('low_disk' if low_disk else 'reconnecting', last_reason=reason,
                last_recorded_bytes=total, last_segment_count=len(files),
                last_ffmpeg_exit=child.returncode)
    return low_disk


def run() -> None:
    ensure_state_dir()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    log_handler = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000,
                                      backupCount=2, encoding='utf-8')
    logging.basicConfig(level=logging.INFO, handlers=[log_handler],
                        format='%(asctime)s %(levelname)s %(message)s')
    lock = WORKER_LOCK.open('a+b')
    lock.seek(0)
    if not lock.read(1):
        lock.write(b'0')
        lock.flush()
    lock.seek(0)
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        return  # 已有录制守护进程，避免重复下载。
    logging.info('录制监测启动，直播间 %s', CFG['room_id'])
    # 不改全局电源设置。配置启用时，只在此进程存活期间阻止自动睡眠。
    if CFG.get('keep_awake'):
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000001)
    save_status('starting')
    try:
        while not PAUSED.exists():
            try:
                free = shutil.disk_usage(OUTPUT).free / 1024 ** 3
                if free < CFG['min_free_gib']:
                    save_status('low_disk', free_gib=round(free, 2))
                    if not wait(60):
                        break
                    continue
                room = room_info()
                if room.get('live_status') != 1:
                    save_status('waiting', title=room.get('title'),
                                live_status=room.get('live_status'),
                                next_check_seconds=CFG['poll_seconds'],
                                free_gib=round(free, 2))
                    if not wait(CFG['poll_seconds']):
                        break
                    continue
                record(room)
                if not wait(CFG['retry_seconds']):
                    break
            except Exception as exc:
                # 记录错误类别，避免完整第三方异常中可能包含的临时播放 URL。
                logging.error('录制检查出错：%s', type(exc).__name__)
                save_status('retrying', error_type=type(exc).__name__,
                            next_check_seconds=CFG['retry_seconds'])
                if not wait(CFG['retry_seconds']):
                    break
    finally:
        save_status('paused' if PAUSED.exists() else 'stopped')
        if CFG.get('keep_awake'):
            ctypes.windll.kernel32.SetThreadExecutionState(0x80000000)
        logging.info('录制监测已停止')
        lock.close()


def check() -> int:
    ensure_state_dir()
    result = {
        'config_path': str(CONFIG_PATH),
        'room_id': CFG.get('room_id'),
        'display_name': CFG.get('display_name'),
        'output': str(OUTPUT),
        'python': sys.version.split()[0],
        'ffmpeg': tool_version(FFMPEG, ['-version']),
        'yt_dlp': tool_version(YT_DLP, ['--version']),
    }
    try:
        room = room_info()
        result['room_title'] = room.get('title')
        result['live_status'] = room.get('live_status')
    except Exception as exc:
        result['room_error'] = type(exc).__name__
    print(json.dumps(result, ensure_ascii=False, indent=2))
    tools_ok = result['ffmpeg'].get('exists') and result['yt_dlp'].get('exists')
    return 0 if tools_ok else 2


def room_info_json() -> int:
    try:
        room = room_info()
        anchor = anchor_info()
        payload = {
            'room_id': CFG.get('room_id'),
            'title': room.get('title'),
            'live_status': room.get('live_status'),
            'anchor_name': anchor.get('uname'),
            'anchor_uid': anchor.get('uid'),
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({'error': type(exc).__name__, 'message': str(exc)[:300]},
                         ensure_ascii=False))
        return 3


def main() -> int:
    parser = argparse.ArgumentParser(description='B 站公开直播录制工具')
    parser.add_argument('--check', action='store_true', help='检查配置与依赖后退出')
    parser.add_argument('--room-info', action='store_true', help='查询直播间信息后退出')
    args = parser.parse_args()
    if args.room_info:
        return room_info_json()
    if args.check:
        return check()
    run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
