"""Watch a direct live input in mpv and retain a bounded history on disk."""
import argparse
import csv
from dataclasses import dataclass
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

NAME = re.compile(r"part-[0-9]{9,}\.ts")


@dataclass(frozen=True)
class Segment:
    path: Path
    start: float
    end: float


def segments(root):
    try:
        raw = (root / "segments.csv").read_bytes()
    except FileNotFoundError:
        return []
    # Ignore a final partially written line while FFmpeg is appending.
    lines = raw[:raw.rfind(b"\n") + 1].decode("ascii").splitlines()
    result = []
    for row in csv.reader(lines):
        if len(row) == 3 and NAME.fullmatch(row[0]):
            result.append(Segment(root / row[0], float(row[1]), float(row[2])))
    return result


def snapshot(root, folder, cfg):
    """Pin closed segments using hard links. The editor never follows the live edge."""
    anchor = cfg["anchor"]
    cutoff = max(0, anchor - cfg["history"])
    chosen = None
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        rows = [r for r in segments(root) if r.end > cutoff and r.start <= anchor]
        if rows and rows[-1].end >= anchor:
            chosen = rows
            break
        time.sleep(0.15)
    if not chosen:
        raise RuntimeError("The live recorder has no complete segment at this playback position.")
    pinned = []
    for row in chosen:
        dest = folder / row.path.name
        try:
            os.link(row.path, dest)
        except FileNotFoundError:
            if pinned:
                raise RuntimeError("The live recorder expired part of this range.")
            continue
        except OSError:
            shutil.copyfile(row.path, dest)
        pinned.append((row, dest))
    if not pinned or pinned[0][0].start >= anchor:
        raise RuntimeError("This moment is outside the retained live history.")
    # The FFmpeg tee outputs carry matching continuous MPEG-TS timestamps.
    # Binary concatenation preserves timestamps and A/V sync across segment joins.
    media = folder / "capture.ts"
    with media.open("wb") as out:
        for _, part in pinned:
            with part.open("rb") as src:
                shutil.copyfileobj(src, out, 1024 * 1024)
            part.unlink()
    cfg["start"] = pinned[0][0].start
    return media


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Direct FFmpeg-readable stream URL")
    parser.add_argument("--mpv", default="mpv")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--name", default="Live stream")
    parser.add_argument("--history", type=int, default=300, metavar="SECONDS")
    opts = parser.parse_args()
    if opts.history < 1:
        parser.error("--history must be positive")
    with tempfile.TemporaryDirectory(prefix="mpv-live-ring-") as tmp:
        root = Path(tmp)
        tee = ("[f=segment:segment_time=2:segment_list=segments.csv:segment_list_size="
               + str(max(120, opts.history + 60))
               + ":segment_list_type=csv:segment_format=mpegts:segment_format_options=mpegts_copyts=1]part-%09d.ts"
                 "|[f=mpegts:mpegts_copyts=1]pipe:1")
        with subprocess.Popen([opts.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
                               "-i", opts.url, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
                               "-f", "tee", tee], cwd=root, stdout=subprocess.PIPE) as recorder:
            viewer = None
            try:
                viewer = subprocess.Popen([opts.mpv, "--rebase-start-time=yes", "--demuxer-lavf-format=mpegts",
                                           "--force-media-title=" + opts.name, "--", "-"], stdin=recorder.stdout,
                                          env=dict(os.environ, MPV_CLIP_RING=tmp, MPV_CLIP_HISTORY=str(opts.history)))
                recorder.stdout.close()
                while viewer.poll() is None:
                    rows = segments(root)
                    if rows:
                        keep_from = rows[-1].end - opts.history - 8
                        for row in rows:
                            if row.end < keep_from:
                                row.path.unlink(missing_ok=True)
                    time.sleep(0.75)
                return viewer.returncode
            finally:
                if viewer and viewer.poll() is None:
                    viewer.terminate()
                    viewer.wait()
                if recorder.poll() is None:
                    recorder.terminate()
                    recorder.wait()


if __name__ == "__main__":
    sys.exit(main())
