#!/usr/bin/env python3
"""Build a zip to share. Extract it into an mpv config folder (%APPDATA%\\mpv) and restart mpv.

    py tools/package.py                         # dist/twitch-rewind-clipper-<date>.zip
    py tools/package.py --material-font PATH    # where to take Material-Design-Iconic-Font.ttf from

The zip holds the same files tools/install.py installs, plus the Material icon font the patched
ModernZ uses for play/pause (taken from your mpv fonts folder), sample configs with a .example suffix
so nothing of the friend's is overwritten, and an INSTALL text.
"""
import argparse
import datetime
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import install  # noqa: E402

INSTALL_TEXT = """\
twitch-rewind + clipper + ModernZ (patched) for mpv
===================================================

Install
  1. Close mpv.
  2. Extract this zip into your mpv config folder, so that "scripts" and "fonts" merge with the ones there.
       Windows:  %APPDATA%\\mpv      (portable install: the portable_config folder)
       Linux:    ~/.config/mpv
     Your own modernz.lua is replaced. Keep a copy if you changed it: scripts/modernz.lua is a
     patched fork (Clip button, LIVE button, whole-broadcast seekbar).
  3. Start mpv.

What you need on PATH
  - mpv 0.38 or newer
  - yt-dlp                       (mpv's ytdl support opens twitch.tv links)
  - curl                         (ships with Windows 10/11)
  - ffmpeg and ffprobe           (clipper cuts and exports with them)
  - Python 3                     (clipper; on Windows the "py" launcher. If it is not "python", set
                                  python=py in script-opts/clipper.conf)

Using it
  - mpv https://www.twitch.tv/<channel>
    The seekbar spans the whole broadcast. Click left of the live part to jump into the VOD; the red LIVE
    button returns to the live stream.
  - Ctrl+G, or the scissors button in the OSC, opens the clip editor on the last 30 s with 60 s loaded.

Optional configuration (copy a .example file from script-opts/ and remove the ".example")
  - script-opts/clipper.conf        output folder, clip length, how much footage is loaded
  - script-opts/twitch-rewind.conf  cache sizes, quality, yt-dlp/curl paths

Notes
  - mpv.conf: ModernZ replaces mpv's built-in OSC, so it needs "osc=no" (without it you get two on-screen
    controllers). Add that line if your mpv.conf does not have it.
  - mpv.conf: if you have a profile that matches every twitch.tv URL (for example with force-seekable=no),
    limit it to channel URLs. See scripts/twitch-rewind/README.md ("Compatibility notes").
  - The play/pause icon uses fonts/Material-Design-Iconic-Font.ttf, the clip icon uses Segoe Fluent Icons
    (Windows 11). On other systems the clip icon may be missing.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=install.ROOT / "dist", help="output folder (default: %(default)s)")
    parser.add_argument("--material-font", type=Path, default=install.default_target() / "fonts" / "Material-Design-Iconic-Font.ttf",
                        help="Material-Design-Iconic-Font.ttf to include (default: %(default)s)")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now()
    zip_path = args.out / f"twitch-rewind-clipper-{stamp:%Y-%m-%d}.zip"
    try:
        zip_path.open("ab").close()   # fails while another program (for example 7-Zip) has the old zip open
    except PermissionError:
        zip_path = args.out / f"twitch-rewind-clipper-{stamp:%Y-%m-%d-%H%M%S}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for src, rel in install.collect():
            z.write(src, rel)
        for src, name in install.sample_configs():
            z.write(src, f"script-opts/{name}.example")
        if args.material_font.is_file():
            z.write(args.material_font, "fonts/Material-Design-Iconic-Font.ttf")
        else:
            print(f"warning: {args.material_font} not found; the play/pause icon will be missing", file=sys.stderr)
        z.writestr("INSTALL-twitch-rewind-clipper.txt", INSTALL_TEXT)
    print(f"{zip_path} ({zip_path.stat().st_size / 1048576:.1f} MiB)")


if __name__ == "__main__":
    main()
