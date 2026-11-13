# twitch-rewind

Rewind a live Twitch broadcast in mpv, past the live cache, back to the start. Open a channel as usual:

```text
mpv https://www.twitch.tv/<channel>
```

Seek back further than mpv has cached and the script switches to the broadcast's in-progress VOD at the matching moment. The `live` action returns to the live playlist. Normal playback and completed VODs still use mpv's built-in yt-dlp hook.

## Install

Copy `scripts/twitch-rewind` into `%APPDATA%\mpv\scripts\` (or run `py tools/install.py` from the repo root). Needs `yt-dlp` and `curl` on PATH. Options go in `script-opts/twitch-rewind.conf` (sample included).

## Use

Ordinary seeks work as before, including seekbar clicks and relative or percentage seeks. With the [ModernZ fork](../ModernZ) the live seekbar spans the whole broadcast and has a LIVE / skip-to-live button.

Optional `input.conf` bindings (none are installed):

```text
Alt+LEFT   script-binding twitch_rewind/back-1m
Ctrl+LEFT  script-binding twitch_rewind/back-5m
Alt+RIGHT  script-binding twitch_rewind/live
Alt+g      script-binding twitch_rewind/goto-prompt
```

Other bindings: `back-30s`, `back-15m`, `back-1h`. Messages: `script-message-to twitch_rewind <message>`

| Message | Effect |
|---|---|
| `back N` / `forward N` | Seek N seconds. Uses the live cache when possible, otherwise the VOD. |
| `goto TIME` | Go to broadcast time (`1:23:45`, `83m`, `1h2m3s` or seconds). |
| `live` | Return to the live playlist. |
| `toggle` | From live rewind 5 minutes; from VOD return to live. |

## Options

| Option | Default | Meaning |
|---|---|---|
| `ytdl_path`, `curl_path` | `yt-dlp`, `curl` | Executables |
| `quality` | `best` | `best`, `worst`, or a max height such as `720` |
| `prefetch` | `yes` | Resolve the VOD in the background while watching live |
| `auto_seek` | `yes` | Switch to the VOD on ordinary seeks outside the cache |
| `live_on_end` | `yes` | Return to live when the VOD snapshot ends |
| `calibrate` | `yes` | Measure the live-to-VOD time offset (needed for the whole-broadcast seekbar) |
| `pts_offset` | `63` | Fallback offset in seconds if calibration fails |
| `manage_cache`, `live_*`, `vod_*` | | Per-mode cache sizes; set `manage_cache=no` to leave mpv's cache settings alone |

## Notes

- A live `time-pos` is the stream's transport-stream PTS; the VOD starts at about 62 s of it. VOD time = live time − offset, measured from the VOD's first segment (about one frame accurate).
- mpv plays an in-progress VOD like a live stream, so the script fetches its playlist, marks it finished and plays that local copy. Segments are still streamed on demand. The copy is fixed at the time of the switch; rewind again for a newer one.
- `auto_seek` reads mpv's own "Run command: seek" debug log, since mpv has no pre-seek hook. The explicit messages above do not depend on that.
- Seeking to the very start of the VOD can be rejected by FFmpeg's HLS demuxer; the script detects that and re-seeks to 0.1 s.
- Other scripts can read `user-data/twitch` (`channel`, `mode`, `vod_id`, `date`, `title`, `can_live`, and `dvr_offset` while live) and ask for the VOD playlist with `script-message-to twitch_rewind snapshot <reply-script>`.
- If a `[live-stream]`-style auto-profile in your `mpv.conf` matches every `twitch.tv` URL, narrow it to channel URLs so it does not apply live cache settings to VODs.
- Requires a public current-broadcast VOD (no subscriber-only or disabled VODs). Twitch's GQL endpoint is undocumented and may change. Ads, encoder restarts or discontinuities can cause timing drift. Playlist switches are not gapless.
