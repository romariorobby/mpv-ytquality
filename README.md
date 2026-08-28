# ytquality

Native mpv quality selector for [yt-dlp](https://github.com/yt-dlp/yt-dlp).

Opens the currently playing video's quality list right inside mpv — no external
menus, no separate pickers. Written in pure Lua using mpv's built-in console
`mp.input.select` API.

## Features

- Open a formatted quality list for the current yt-dlp stream (height from
  144p to 8K, plus **Auto**).
- Automatically highlights and pre-selects the active quality (applied
  `ytdl-format` string → current video height → Auto).
- Select and instantly reload the stream at the new quality; playback
  position is restored.
- Per-URL format caching (skip the yt-dlp fetch on re-open) with an option to
  always refresh.
- Auto-close timeout; safe cancellation of in-flight yt-dlp requests.

## Requirements

- mpv **>= 0.39** (`mp.input.select`)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) in `PATH`, or set `yt_dlp`

## Installation

```sh
curl -fsSL --create-dirs https://raw.githubusercontent.com/romariorobby/ytquality/main/ytquality.lua -o ~/.config/mpv/scripts/ytquality.lua
```

## Usage

Press **`g` then `y`** (a chord) to toggle the quality menu, navigate with
the arrow keys (or `Ctrl+p` / `Ctrl+n`), and press `Enter` to switch.

Override or disable the binding from `~/.config/mpv/input.conf`:

```conf
g-y ignore
F3 script-binding ytquality/toggle
```

Script messages are also registered:

```conf
ctrl+q script-message-to ytquality toggle
```

## Configuration

Create `~/.config/mpv/script-opts/ytquality.conf`:

```conf
# yt-dlp executable or absolute path.
yt_dlp=yt-dlp

# Maximum number of quality levels listed.
max_qualities=20

# Re-run yt-dlp on every open instead of using the per-URL cache.
refresh_formats=no

# Auto-close the menu after N seconds; 0 disables the timeout.
timeout=12
```

```conf
# set default video (mpv.conf)
ytdl-format=bestvideo*[height<=480]+bestaudio/best
```
## Note

The auto-close timeout counts from when the menu is shown, not from when the
yt-dlp metadata fetch starts.
