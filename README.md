# twitch-rewind + clipper for mpv

Three mpv scripts that work together for watching and clipping Twitch broadcasts:

- **[twitch-rewind](plugins/twitch-rewind/README.md)**: open `mpv https://www.twitch.tv/<channel>` and rewind through the *whole* broadcast, not just mpv's short live cache. Seeking left of the live cache switches to the broadcast's VOD playlist; one action returns to the live playlist.
- **[clipper](plugins/clipper/README.md)**: press Ctrl+G to open a second mpv window with a trim bar, frame-accurate start/end fields and a Save button. Works for local files, live streams and Twitch VODs; exports H.264/AAC MP4s.
- **[ModernZ fork](plugins/ModernZ)**: the [ModernZ](https://github.com/Samillion/ModernZ) OSC with a Clip button, a LIVE / skip-to-live button and a seekbar that spans the whole broadcast while watching live.

The scripts also work separately. twitch-rewind and clipper run under any OSC; the whole-broadcast seekbar and the Clip and LIVE buttons need the ModernZ fork.

## Requirements

- mpv 0.38 or newer (developed on Windows 10/11)
- `yt-dlp` and `curl` on PATH
- `ffmpeg` and `ffprobe` on PATH (clipper)
- Python 3 (clipper; on Windows the `py` launcher)
- `osc=no` in `mpv.conf` if you use the ModernZ fork

## Install

Download `twitch-rewind-clipper-<version>.zip` from the [releases page](../../releases) and extract it into your mpv config folder (`%APPDATA%\mpv` on Windows, `~/.config/mpv` on Linux), or from a checkout:

```text
py tools/install.py             # copy the scripts into %APPDATA%\mpv (use --target for another folder)
py tools/package.py             # build dist/twitch-rewind-clipper-<date>.zip (the release workflow runs this)
```

`install.py` never overwrites your `mpv.conf` or `script-opts`; a differing `modernz.lua` is kept as `modernz.lua.bak`. If you used the earlier names (`twitch-dvr`, `clip-window`) it moves those folders to `backup-<name>-<date>/`, renames their config files and lists `input.conf` lines that need the new names. The zip ships `.example` configs and an install note.

## Layout

Each plugin mirrors the mpv config folder it installs into:

```text
plugins/twitch-rewind/   scripts/twitch-rewind/  script-opts/twitch-rewind.conf  README.md
plugins/clipper/         scripts/clipper/        script-opts/clipper.conf        README.md  docs/
plugins/ModernZ/         ModernZ with the Twitch/Clip changes (upstream layout; see below)
tools/                   install.py, package.py, check_zip.py
assets/                  Material Design Iconic Font (+ its OFL license), used by the ModernZ fork
.github/workflows/       release.yml: checks and builds the zip on every push and pull request; a `v*` tag also publishes it as a release
```

`git diff d93e5b3 -- plugins/ModernZ` lists every change made to ModernZ; that commit is the unmodified upstream copy.

## Notes

- Twitch's public GQL endpoint and client ID are undocumented and can change. VODs must be public; there is no access-control bypass.

## License

twitch-rewind and clipper are released under the [WTFPL](LICENSE). The ModernZ fork stays under its upstream LGPL-2.1 (`plugins/ModernZ/LICENSE`). The bundled Material Design Iconic Font is under the SIL OFL 1.1 (`assets/OFL.txt`). Each is shipped with its license in the zip.
