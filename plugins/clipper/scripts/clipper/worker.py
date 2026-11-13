"""Session ownership, editor launch, and clip export. Python 3.10+."""
import datetime
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = Path(tempfile.gettempdir()) / "mpv-clipper"
NO_CONSOLE = getattr(subprocess, "CREATE_NO_WINDOW", 0)
URI = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://")


class Cancelled(Exception):
    """The editor closed while its clip was encoding."""


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def sanitize(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .") or "clip"
    if re.fullmatch(r"(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", name, re.I):
        name = "_" + name
    return name[:100].rstrip(" .")


def timestamp(t):
    seconds, ms = divmod(round(max(0, t) * 1000), 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}-{minutes:02}-{seconds:02}.{ms:03}"


def absolute(path, cwd):
    return str((Path(cwd) / Path(path).expanduser()).resolve())


def resolve_paths(cfg):
    source = cfg["source"]
    cfg["remote"] = bool(URI.match(source))
    if not cfg["remote"] and not cfg["live"]:
        cfg["source"] = absolute(source, cfg["cwd"])
    cfg["output"] = absolute(cfg["output"], cfg["cwd"])
    for track in cfg["tracks"].values():
        path = track.get("external")
        if path and not URI.match(path):
            track["external"] = absolute(path, cfg["cwd"])
    cfg["mpv"] = find_tool("mpv", cfg["mpv"], parent_mpv(cfg["pid"]))
    cfg["ffmpeg"] = find_tool("ffmpeg", cfg["ffmpeg"])


def parent_mpv(pid):
    """Portable Windows installations often keep mpv.exe outside PATH."""
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return None
    try:
        buf, size = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
        if kernel.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            return str(Path(buf.value).with_name("mpv.exe"))
    finally:
        kernel.CloseHandle(handle)
    return None


def find_tool(name, *candidates):
    """A stale configured path falls back to the player's folder, then PATH."""
    # On Windows PATH lookup would otherwise pick the mpv.com console wrapper.
    options = [c for c in (*candidates, name + ".exe" if os.name == "nt" else None, name) if c]
    for candidate in options:
        found = shutil.which(candidate)
        if found:
            return found
    tried = ", ".join(dict.fromkeys(map(str, options)))
    raise RuntimeError(f"Cannot find {name} (tried {tried}).\n\n"
                       f"Install it, or set {name}=<full path> in script-opts/clipper.conf.")


def source_args(cfg):
    args = []
    if cfg["live"]:
        return args
    for key in ("user-agent", "referrer", "cookies-file", "ytdl-format"):
        if cfg.get(key) and cfg["remote"]:
            args.append(f"--{key}={cfg[key]}")
    if cfg["remote"] and cfg.get("cookies"):
        args.append("--cookies=yes")
    for field in cfg.get("http-header-fields") or []:
        if cfg["remote"]:
            args.append("--http-header-fields-append=" + field)
    for kind, flag in (("video", "vid"), ("audio", "aid")):
        track = cfg["tracks"].get(kind)
        if not track:
            args.append(f"--{flag}=no")
        elif track.get("external") and not cfg["remote"]:
            args.extend([f"--{kind}-file={track['external']}", f"--{flag}=auto"])
        else:
            args.append(f"--{flag}={track['id']}")
    return args


def output_base(cfg, edit):
    # A title typed in the editor replaces the source name in the filename.
    name = edit.get("title") or (cfg["title"] if cfg["remote"] or cfg["live"] else cfg["source_name"])
    date = datetime.datetime.strptime(cfg["date"], "%Y/%m/%d")
    directory = Path(cfg["output"]) / f"{date:%Y}" / f"{date:%m}" / f"{date:%d}"
    directory.mkdir(parents=True, exist_ok=True)
    return directory / f"{sanitize(name or 'clip')}_{timestamp(edit['source_start'])}"


def local_export(cfg, edit, media, dest):
    start, end = edit["a"], edit["b"]
    seek = ["-ss", f"{start:.6f}"]
    args = [cfg["ffmpeg"], "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *seek, "-i", str(media)]
    tracks = {} if cfg["live"] else cfg["tracks"]
    audio = tracks.get("audio", {})
    video = tracks.get("video", {})
    def mapping(track, kind):
        index = track.get("index")
        return f"0:{index}" if isinstance(index, int) and index >= 0 else f"0:{kind}:0"
    external_audio = edit["audio"] and audio.get("external")
    if external_audio:
        args.extend([*seek, "-i", external_audio])
    args.extend(["-map", mapping(video, "v")])
    if edit["audio"] and (cfg["live"] or audio):
        if external_audio:
            args.extend(["-map", "1:a:0"])
        else:
            args.extend(["-map", mapping(audio, "a") + "?"])
        args.extend(["-c:a", "aac", "-b:a", "192k"])
    else:
        args.append("-an")
    return [*args, "-t", f"{end-start:.6f}", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
            "-metadata", "comment=" + cfg["origin"], "-movflags", "+faststart", str(dest)]


def encode(args, length, report, editor):
    """Run the encoder, reporting progress and stopping when the editor closes."""
    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=log,
                                creationflags=NO_CONSOLE)
        encoded = [None]

        def drain():
            for line in proc.stdout:
                key, _, value = line.strip().partition(b"=")
                if key == b"out_time_us" and value.isdigit():
                    encoded[0] = int(value) / 1e6

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        try:
            while proc.poll() is None:
                if editor.poll() is not None:
                    raise Cancelled
                report(None if encoded[0] is None else min(1.0, encoded[0] / length))
                time.sleep(0.2)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            reader.join()
            proc.stdout.close()
        if proc.returncode:
            log.seek(max(0, log.tell() - 1600))
            raise RuntimeError(log.read().decode(errors="replace").strip() or "Encoder failed")


def export(cfg, edit, media, report, editor):
    a, b = edit["a"], edit["b"]
    if not all(math.isfinite(x) for x in (a, b, edit["source_start"])) or not 0 <= a < b:
        raise ValueError("Invalid clip range")
    base = output_base(cfg, edit)
    with tempfile.TemporaryDirectory(prefix=".clip-", dir=base.parent) as stage:
        dest = Path(stage) / "export.mp4"
        if (cfg["remote"] or cfg["tracks"].get("video", {}).get("external")) and not cfg["live"]:
            args = [cfg["mpv"], "--no-config", "--load-scripts=no", "--no-resume-playback",
                    "--sid=no", *source_args(cfg), f"--start={a:.6f}", f"--end={b:.6f}",
                    "--ovc=libx264", "--ovcopts=crf=18,preset=veryfast", "--oac=aac",
                    "--of=mp4", "--ofopts=movflags=+faststart", "--oset-metadata-append=comment=" + cfg["origin"],
                    f"--o={dest}"]
            if not edit["audio"]:
                args.append("--aid=no")
            args.extend(["--", str(media)])
        else:
            args = local_export(cfg, edit, media, dest)
            args[1:1] = ["-progress", "pipe:1", "-nostats"]
        encode(args, b - a, report, editor)
        if not dest.exists() or not dest.stat().st_size:
            raise RuntimeError("Encoder produced no clip")
        # O_EXCL reserves the final name across simultaneous saves. The encoded
        # file is moved within the same filesystem only after successful export.
        for n in range(10000):
            target = base.parent / (base.name + (f"_{n}" if n else "") + ".mp4")
            try:
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                continue
            os.close(fd)
            try:
                os.replace(dest, target)
            except OSError:
                target.unlink(missing_ok=True)
                raise
            return target
        raise FileExistsError("All clip names are in use")


def error_dialog(message):
    try:
        if os.name == "nt":
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, str(message), "mpv Clip", 0x10)
        else:
            from tkinter import messagebox
            messagebox.showerror("mpv Clip", str(message))
    except Exception:
        if sys.stderr:
            print(message, file=sys.stderr)


def align_capture(cfg, media):
    """Find where a cache dump really starts on the main player's timeline.

    mpv begins a dump on the keyframe at or before the requested time. Cached ranges start on a
    keyframe too, so with evenly spaced keyframes that start can be counted out from the range start.
    Uneven keyframes leave the requested time in place, which is right to within one keyframe interval.
    """
    probe = shutil.which(str(Path(cfg["ffmpeg"]).with_name("ffprobe"))) or shutil.which("ffprobe")
    if not probe or cfg.get("range_start") is None:
        return
    try:
        listing = subprocess.run([probe, "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags",
                                  "-of", "csv=p=0", str(media)], capture_output=True, text=True, timeout=60,
                                 creationflags=NO_CONSOLE).stdout
    except (OSError, subprocess.SubprocessError):
        return
    keys = []
    for row in listing.splitlines():
        fields = row.split(",")
        if len(fields) >= 2 and "K" in fields[1]:
            try:
                keys.append(float(fields[0]))
            except ValueError:
                pass
    if not keys:
        return
    gaps = [later - earlier for earlier, later in zip(keys, keys[1:])]
    behind = cfg["start"] - cfg["range_start"]
    if behind < 0.001:
        start = cfg["range_start"]
    elif gaps and max(gaps) - min(gaps) < 0.05:
        interval = sum(gaps) / len(gaps)
        start = cfg["range_start"] + interval * math.floor(behind / interval + 1e-3)
    else:
        return
    # The capture's clock starts at its first packet, which can be audio just ahead of the keyframe.
    cfg["start"] = start - keys[0]


def window_args(cfg):
    """Size the editor so the video fills its area above the 180-unit panel, without side bars."""
    width, height = cfg.get("dwidth"), cfg.get("dheight")
    fallback = ["--geometry=62%x78%", "--video-margin-ratio-bottom=0.25"]
    if not width or not height or os.name != "nt":
        return fallback
    import ctypes
    from ctypes import wintypes
    try:
        # Physical pixels, which is what mpv's geometry uses.
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except (AttributeError, OSError):
        pass
    area = wintypes.RECT()
    if not ctypes.windll.user32.SystemParametersInfoW(0x30, 0, ctypes.byref(area), 0):  # SPI_GETWORKAREA
        return fallback
    screen_w, screen_h = area.right - area.left, area.bottom - area.top
    aspect = width / height
    window_w = 0.62 * screen_w
    while True:
        video_h = window_w / aspect
        # Mirrors editor.lua: the panel is 180 units at scale min(w/960, h/640), clamped to 0.5-3.
        scale = 1.0
        for _ in range(12):
            scale = min(3.0, max(0.5, min(window_w / 960, (video_h + 180 * scale) / 640)))
        total_h = video_h + 180 * scale
        if total_h <= 0.85 * screen_h or window_w < 480:
            break
        window_w *= 0.95
    return [f"--geometry={round(window_w)}x{round(total_h)}", f"--video-margin-ratio-bottom={180 * scale / total_h:.4f}"]


def write_status(folder, value):
    staged = folder / "status.tmp"
    write_json(staged, value)
    for _ in range(40):
        try:
            os.replace(staged, folder / "status.json")
            return
        except PermissionError:
            # The editor is reading the previous status.
            time.sleep(0.05)


def edit_session(folder):
    cfg = read_json(folder / "session.json")
    resolve_paths(cfg)
    media = folder / "capture.mkv" if cfg["live"] else cfg["source"]
    if cfg.get("fetch") and media.exists():
        align_capture(cfg, media)
    if cfg.get("ring"):
        from live import snapshot
        media = snapshot(Path(cfg["ring"]), folder, cfg)
    # The clip's source as shown in the editor and stored in the file: a full path for local files.
    cfg["origin"] = cfg.get("origin") or str(cfg["source"])
    write_json(folder / "session.json", cfg)
    if cfg["live"] and (not media.exists() or media.stat().st_size < 512):
        raise RuntimeError("mpv could not retain this live range. Check the demuxer back cache.")
    request = folder / "export.json"
    args = [cfg["mpv"], "--no-config", "--load-scripts=no", "--no-resume-playback", "--no-save-position-on-quit",
            "--pause", "--keep-open=yes", "--force-window=yes", "--osc=no", "--sid=no",
            *window_args(cfg),
            f"--volume={min(100.0, max(0.0, float(cfg.get('volume') or 100))):g}",
            "--input-default-bindings=no", "--input-vo-keyboard=yes", "--input-cursor=yes",
            "--window-dragging=no", "--cursor-autohide=no", "--hwdec=auto-safe",
            "--title=Clip editor", "--osd-level=0", "--script=" + str(HERE / "editor.lua"),
            *(["--border=no"] if cfg.get("border") is False else []),
            *(["--title-bar=no"] if cfg.get("title_bar") is False else []),
            *source_args(cfg), "--", str(media)]
    env = dict(os.environ, MPV_CLIP_SESSION=str(folder))
    # The editor stays open during export and shows the status written here.
    editor = subprocess.Popen(args, env=env, creationflags=NO_CONSOLE)
    while editor.poll() is None:
        if not request.is_file():
            time.sleep(0.1)
            continue
        edit = read_json(request)
        request.unlink()
        # After fetching more of a stream, the editor works on a newer capture in this folder.
        current = edit.get("media")
        if current:
            if Path(current).name != current or not (folder / current).is_file():
                raise ValueError("Unknown clip media")
            media = folder / current

        def report(**state):
            write_status(folder, {"id": edit.get("id"), **state})

        report(state="encoding")
        try:
            target = export(cfg, edit, media, lambda done: report(state="encoding", progress=done), editor)
        except Cancelled:
            break
        except (ValueError, OSError, RuntimeError) as exc:
            report(state="error", message="Export failed: " + (str(exc).strip().splitlines() or ["unknown error"])[-1])
        else:
            report(state="done", path=str(target))
    if editor.returncode:
        raise RuntimeError(f"mpv editor exited with status {editor.returncode}. Check the source and mpv path.")


def main():
    action = sys.argv[1]
    if action == "prepare":
        ROOT.mkdir(mode=0o700, exist_ok=True)
        print(json.dumps(tempfile.mkdtemp(prefix="session-", dir=ROOT)))
        return
    folder = Path(sys.argv[2]).resolve()
    if folder.parent != ROOT.resolve() or not folder.name.startswith("session-"):
        raise ValueError("Unknown clip session")
    try:
        if action == "edit":
            edit_session(folder)
        elif action != "discard":
            raise ValueError("Unknown clip action")
    finally:
        shutil.rmtree(folder, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as problem:
        if sys.argv[1:2] == ["edit"]:
            error_dialog(problem)
        raise
