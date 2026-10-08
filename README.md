# Music Assistant plugin for Omarchy

Talks to a [Music Assistant](https://music-assistant.io/) server over its
JSON-RPC API and exposes a bar widget plus OSD actions, keybindings, and CLI
control.

## Setup

```sh
omarchy plugin add https://github.com/manologarciadev/music-assistant.git --enable
```

1. In Music Assistant go to **Settings → Profile** and create a long-lived
   access token.
2. Copy `config.example.json` to `config.json` in this same directory and
   edit `url` and `token`:
   ```json
   {
     "url": "http://192.168.1.1:8095",
     "token": "eyJhbGciOi...",
     "pollIntervalMs": 2000,
     "preferredPlayerId": ""
   }
   ```
   After saving, restrict permissions since the token grants admin access:

   ```bash
   chmod 600 config.json
   ```
3. The plugin is auto-discovered. Either restart the shell
   (`omarchy restart shell`) or save `~/.config/omarchy/shell.json` after
   adding the widget.

## Features

- Live now-playing in the bar with auto-scrolling label
- Popup with 8 tabs: Now, Players, Queue, Search, Browse, Favorites, Playlists, Recent
- Queue options (crossfade, autoplay, don't stop the music), sleep timer, stop
- Speaker grouping (join / leave / ungroup with the active player), group volume
- Queue reordering and save-as-playlist; playlist drill-down; play-next / add-to-queue on every row
- Transport: play/pause, next/previous, seek (click progress bar)
- Shuffle and repeat (off / all / one) toggles
- Per-player volume slider with mute toggle
- Transfer queue between players with single click
- Search across tracks, albums, artists, playlists, and radio
- Favorites: browse and play liked items, right-click to remove
- Playlists: list user playlists, click to play
- Recent: browse recently played items with relative timestamps
- "Save queue as playlist" from the Queue tab
- HTTP polling for live state (2s default interval)
- IPC handlers for all actions (see table below)

## Bar widget

Add to the bar layout in `~/.config/omarchy/shell.json`:

```jsonc
{
  "id": "io.github.manologarciadev.music-assistant",
  "section": "right"   // or "left" / "center"
}
```

- Left-click: play / pause the active player
- Middle-click: next track
- Right-click: open popup
- Wheel: previous / next
- Right-click popup tabs:
  - **Now** — now-playing card, transport, volume slider
  - **Players** — every MA player; click to transfer the current queue,
    right-click to toggle mute
  - **Queue** — current queue with click-to-play and right-click-to-remove
  - **Search** — text search across tracks/albums/artists/playlists, click
    a result to play it on the active player
  - **Favorites** — browse and play liked items; right-click to remove
  - **Playlists** — list user playlists; click to play
  - **Recent** — recently played items with relative timestamps

## IPC

The service registers an `IpcHandler` under `target: "io.github.manologarciadev.music-assistant"` so
other shell components (or external scripts) can call it:

### Transport

| Method | Description |
|--------|-------------|
| `status` | JSON snapshot of the active player and connection state |
| `playPause`, `nextTrack`, `previousTrack` | Transport on active player |
| `seek(positionMs)` | Seek to absolute position in current track |
| `seekRelative(deltaMs)` | Seek relative to current position |

### Players

| Method | Description |
|--------|-------------|
| `setVolumePct(percent)` | Set volume 0–100 |
| `power(action)` | `"on"` or `"off"` for the active player |
| `activatePlayerById(playerId)` | Switch active player without transferring queue |
| `transferQueueTo(targetId)` | Transfer the queue from the active player to another |
| `playersList()` | JSON list of every player with playback state |

### Queue & search

| Method | Description |
|--------|-------------|
| `playUri(uri)` / `playUriOn(playerId, uri)` | Play a MA URI |
| `search(query)` | Run a search; results appear in the Search tab |
| `clearQueueNow()` | Clear the active player's queue |
| `saveQueue(name)` | Save current queue as a new playlist |

### Playback mode

| Method | Description |
|--------|-------------|
| `toggleShuffle()` | Toggle shuffle on the active player |
| `cycleRepeat()` | Cycle repeat off → all → one |

### Favorites & library

| Method | Description |
|--------|-------------|
| `favoriteCurrent()` | Add/remove the current track to/from favorites |
| `favoriteAdd(uri)` / `favoriteRemove(uri)` | Add/remove a URI to/from favorites |
| `refreshFavorites()` | Force-refresh favorites from MA |
| `refreshPlaylists()` | Force-refresh playlists from MA |
| `refreshRecent()` | Force-refresh recent items from MA |

### Misc

| Method | Description |
|--------|-------------|
| `refresh()` | Force an immediate state refresh |
| `openWebUI()` | Open the MA web UI in the default browser |

Example keybinding in `~/.config/hypr/bindings.lua`:

```lua
local function ma_playpause()
  Quickshell.exec("qs", "ipc", "call", "io.github.manologarciadev.music-assistant", "playPause")
end

local function ma_next()
  Quickshell.exec("qs", "ipc", "call", "io.github.manologarciadev.music-assistant", "nextTrack")
end
```

## API commands used

- `players/all` — list of players with current state
- `player_queues/get`, `player_queues/items` — queue state and listing for the active player
- `players/cmd/volume_set`, `players/cmd/volume_mute`, `players/cmd/power`
- `player_queues/play`, `pause`, `next`, `previous`, `seek`, `shuffle`, `repeat`,
  `play_index`, `delete_item`, `clear`, `transfer`, `play_media`, `save_as_playlist`
- `music/search`, `music/<type>/library_items` (favorites, playlists), `music/recently_played_items`
- `music/favorites/add_item`, `music/favorites/remove_item`, `players/add_currently_playing_to_favorites`
- `player_queues/stop`, `skip`, `crossfade`, `autoplay`, `dont_stop_the_music`, `move_item`, `move_item_end`
- `players/sleep_timer/get|set|clear`, `players/cmd/select_source`, `players/cmd/group_volume`
- `players/cmd/set_members`, `players/cmd/ungroup`
- `music/browse`, `music/playlists/playlist_tracks`, `music/albums/album_tracks`, `music/artists/artist_tracks`, `music/playlists/add_playlist_tracks`

See https://music-assistant.io/api/ for full API docs.

## Keyboard shortcuts

When the popup is open:

| Key | Action |
|-----|--------|
| `Escape` | Close popup |
| `Ctrl+1` … `Ctrl+8` | Jump to sidebar tab (Now, Players, Queue, Search, Browse, Favorites, Playlists, Recent) |
| `Tab` / `Shift+Tab` | Cycle tabs |
| `Space` | Play/pause (Now tab) |
| `↑` / `↓` | Move focus in lists |
| `Enter` | Activate focused item |
| `Delete` | Remove focused item (queue, favorites) |

## Media keys

On first successful config load, the plugin auto-installs Hyprland bindings for `XF86AudioPlay`, `XF86AudioPause`, `XF86AudioNext`, and `XF86AudioPrev` so your keyboard media keys control Music Assistant instead of Omarchy's default MPRIS routing.

The block is appended to `~/.config/hypr/bindings.lua` between unique markers (`-- BEGIN music-assistant media-keys` / `-- END music-assistant media-keys`), is fully idempotent (won't duplicate), and runs `hyprctl reload` to activate. Look for `[music-assistant] Media key bindings installed (idempotent)` in the shell log.

### Opt-out

Add to your `config.json` to disable auto-installation:

```json
{ "installMediaKeys": false }
```

### Manual uninstall

Delete the block between the markers in `~/.config/hypr/bindings.lua` and run `hyprctl reload`.

## Security

### Threat model

This plugin runs unsandboxed as part of the user's Omarchy shell process. It assumes:

- **Local user is trusted.** Any local process can call IPC methods
  (`qs ipc call io.github.manologarciadev.music-assistant playPause`,
  etc.) and trigger Media Assistant actions. There is no authentication
  on the IPC surface. If untrusted local code can run as your user,
  this plugin's actions are not isolated from it.

- **MA server is semi-trusted.** The plugin talks to a Music Assistant
  server URL configured by the user. All responses are validated:
  - Strings are length-bounded (≤500 chars) and `image_url` is
    scheme-whitelisted to `http://`/`https://`.
  - Arrays are size-bounded per collection (≤64 players, ≤2000 queue
    items, ≤50 search hits, etc.).
  - Response body is capped at 8 MB at the transport (`curl
    --max-filesize`).

### What this plugin will not do

- Run any code from the MA server (`JavaScript` URLs in `image_url` are
  dropped).
- Read local files via QML's `Image` type from a compromised MA
  (`file://` URLs are dropped).
- Leak the bearer token into any process's argv or `/proc/PID/cmdline`
  — the token reaches curl via stdin → a 0600-mode temp file → `-H
  @file`, never via `-H "Authorization: ..."` on the command line.

### File permissions

`config.json` is written with `umask 077` and `chmod 600` so the
bearer token is owner-readable only. If you have an existing install
from before this fix, run once:

```sh
chmod 600 ~/.config/omarchy/plugins/io.github.manologarciadev.music-assistant/config.json
```

## Credits

The Music Assistant mark in the popup header (`MaIcon.qml`) is drawn from the path in
[music-assistant/frontend](https://github.com/music-assistant/frontend) `public/favicon.svg`, Apache-2.0.
Music Assistant is a project of the Open Home Foundation; this plugin is not affiliated with it.
