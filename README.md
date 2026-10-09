# Music Assistant plugin for Omarchy

[![Plugin checks](https://github.com/rwilson131/omarchy.music-assistant/actions/workflows/plugin-checks.yml/badge.svg)](https://github.com/rwilson131/omarchy.music-assistant/actions/workflows/plugin-checks.yml)

Control a [Music Assistant](https://music-assistant.io/) server from the
Omarchy bar: now playing with transport and volume, every player with
grouping, the queue, search, a library browser, favorites, playlists and
recently played. Talks to the server over its JSON API and also exposes an
IPC surface for keybindings and scripts.

This is the [rwilson131](https://github.com/rwilson131/omarchy.music-assistant)
fork of the plugin originally written by
[manologarciadev](https://github.com/manologarciadev/omarchy.music-assistant).
See [Credits](#credits). Tested against Music Assistant 2.10.5 and Omarchy 4.0.

## Requirements

- Omarchy 4 with the Quattro shell and its `qs` IPC client.
- A reachable Music Assistant server (tested with 2.10.5).
- A long-lived Music Assistant access token; the token grants administrator
  access to that server.
- `bash` and `curl` for API requests. The optional contextual volume-key
  helper also uses `jq`. These commands are included in a normal Omarchy
  installation.
- Hyprland is required only for the optional Media Keys integration.

## Setup

```sh
omarchy plugin add https://github.com/rwilson131/omarchy.music-assistant.git --enable
```

1. In Music Assistant go to **Settings → Profile** and create a long-lived
   access token.
2. Copy `config.example.json` to `config.json` in the plugin directory
   (`~/.config/omarchy/plugins/io.github.rwilson131.music-assistant/`)
   and set `url` and `token`. The token grants admin access, so:
   ```sh
   chmod 600 config.json
   ```
3. Add the widget to the bar (see below). The plugin picks the config up
   within a few seconds; `omarchy restart shell` is not needed.

If `omarchy plugin add --enable` ends with "omarchy-shell is not responding",
the shell was still busy loading the plugin when the CLI gave up. The plugin
is installed; enable it with:

```sh
omarchy plugin enable io.github.rwilson131.music-assistant right
```

### Config keys

| Key | Default | Meaning |
|-----|---------|---------|
| `url` | — | Server URL, e.g. `http://192.168.1.52:8095` |
| `token` | — | Long-lived access token |
| `preferredPlayerId` | `""` | Player to control by default; updated when you pick one in the popup |
| `pollIntervalMs` | `2000` | State poll interval |
| `searchLimit` | `20` | Results per media type |
| `recentLimit` | `50` | Items in the Recent tab |
| `showSourceBadge` | `true` | Provider badge on list rows |
| `openWebUiPath` | `""` | URL the globe button opens; defaults to `url` |
| `installMediaKeys` | `false` | Keyboard media keys (see below); the switch in the popup header writes this |
| `mprisFallback` | `true` | Route play/pause/next to a playing MPRIS player (browser, Spotify) instead of Music Assistant |

## Bar widget

Add to the bar layout in `~/.config/omarchy/shell.json`:

```jsonc
{ "id": "io.github.rwilson131.music-assistant", "section": "right" }
```

In the bar: left-click play/pause, middle-click next, right-click opens the
popup, wheel skips previous/next. The label scrolls when the title is long.

## The popup

A header shows the active player and its state. Eight tabs down the side:

| Tab | What it does |
|-----|--------------|
| **Now** | Album artwork when Music Assistant provides it, with a music-note fallback when it does not; title, transport (previous, play/pause, next, shuffle, repeat, favorite, web UI), progress bar (click to seek), volume slider and mute. Chips for Crossfade, Autoplay, Don't stop the music, a sleep timer (click cycles 15 → 30 → 60 → 90 min → off) and Stop. |
| **Players** | Every player, sorted active → playing → idle → groups → unavailable. Click makes a player active and moves the queue to it; right-click mutes. **Join** groups a speaker with the active player, **Leave** removes it, **Ungroup** dissolves the active player's group. The volume slider moves the group when the active player leads one. |
| **Queue** | Click plays an item, right-click removes it. Per-row buttons move it up, down, to the end, or remove it. **Save** (or `Ctrl+S`) asks for a name and saves the queue as a new library playlist, which appears in Lists a few seconds later; **Clear** empties it. |
| **Search** | Searches tracks, albums, artists, playlists, radio, podcasts and audiobooks, with a filter chip per type. |
| **Browse** | Walks the server's providers and folders (SiriusXM channels, Pandora stations, local files, …). Folders open, items play. A filter box appears for long folders. |
| **Favorites** | Favorited tracks, albums, artists, playlists and radio. Right-click removes a favorite. |
| **Lists** | Library playlists. Click opens the playlist's tracks with **Play all**; right-click adds the playing track to a library playlist. |
| **Recent** | Recently played items with when they were played. |

On every list row, **click plays now**, **right-click plays next** and
**middle-click adds to the end of the queue** (favorites use right-click to
remove instead). Album, artist and playlist rows play the whole collection.

### Keyboard

| Key | Action |
|-----|--------|
| `Escape` | Close the popup |
| `Ctrl+1` … `Ctrl+8` | Jump to a tab in sidebar order |
| `Tab` / `Shift+Tab` | Next / previous tab |
| `Space` | Play/pause on the Now tab |
| `Ctrl+S` | Queue tab: name the queue and save it as a playlist |
| `Enter` | Run the search / save the playlist name |

## IPC

The service registers an `IpcHandler` under
`target: "io.github.rwilson131.music-assistant"`:

```sh
omarchy-shell io.github.rwilson131.music-assistant playPause
```

| Method | Description |
|--------|-------------|
| `status` | JSON snapshot: player, track, volume, queue state, crossfade/autoplay, favorite |
| `playPause`, `nextTrack`, `previousTrack`, `stop` | Transport on the active player |
| `mediaKeys(on\|off\|status)` | Install / remove the Hyprland media-key block; returns the state |
| `seek(seconds)`, `seekRelative(seconds)`, `skipSeconds(seconds)` | Position |
| `setVolumePct(percent)`, `volumeUp`, `volumeDown`, `toggleMute` | Volume (steps of 5) |
| `power(action)` | `"on"` or `"off"` |
| `activatePlayerById(playerId)`, `transferQueueTo(targetId)` | Change the active player |
| `groupJoin(playerId)`, `groupLeave(playerId)` | Group a speaker with / remove it from the active player |
| `playersList` | JSON list of every player with its state |
| `playUri(uri)`, `playUriOn(playerId, uri)`, `enqueueUri(uri, option)` | Play a Music Assistant URI; option `next` or `add` |
| `search(query)` | Run a search; results show in the Search tab |
| `browse(path)` | Open a browse path (`""` for the root) |
| `clearQueueNow`, `saveQueue(name)` | Queue |
| `toggleShuffle`, `cycleRepeat`, `toggleCrossfade`, `toggleAutoplay` | Playback modes |
| `sleepTimer(minutes)` | Sleep timer; `0` clears it |
| `favoriteCurrent`, `favoriteAdd(uri)`, `favoriteRemove(uri)` | Favorites (`favoriteRemove` takes a `library://` uri) |
| `refresh`, `refreshFavorites`, `refreshPlaylists`, `refreshRecent` | Force a reload |
| `openWebUI` | Open the Music Assistant web UI in the default browser |
| `listsSnapshot`, `browseSnapshot` | JSON counts and first rows of the lists, for scripts and debugging |

## Pandora stream recovery

Pandora permits one concurrent stream per account. If Music Assistant leaves
that stream slot stuck, a playback request waits about 15 seconds and then
returns HTTP 500. For that specific signature, the plugin confirms that the
requested item has a Pandora provider mapping and checks every other Music
Assistant queue. It reloads only that Pandora provider instance and retries
once when all queue evidence shows the slot is unused. It does not reload when
another room is using Pandora, when a queue cannot be classified, or when
lookup data is missing or malformed. Recovery is limited to one attempt per
minute.

Provider reload temporarily reinitializes the Pandora integration in Music
Assistant. Other providers are never reloaded automatically.

## Media keys

Off by default. Turn it on with the **Media keys** switch at the top right of
the popup, or with `omarchy-shell io.github.rwilson131.music-assistant mediaKeys on`.

On, the plugin appends a marked block to `~/.config/hypr/bindings.lua`
(between `-- BEGIN music-assistant media-keys` and `-- END …`) and reloads
Hyprland:

- `XF86AudioPlay/Pause/Next/Prev` control Music Assistant's active player.
- `XF86AudioRaiseVolume/LowerVolume/Mute` go through
  `scripts/contextual-volume-control`: to Music Assistant in steps of 5 while
  its active player is playing, with an on-screen display naming the player,
  otherwise to Omarchy's normal local-audio volume. A volume key while muted
  only unmutes. If the shell or the plugin is down the keys keep local
  behaviour.
- Hold **Alt** while pressing **Volume Up/Down** to use Omarchy's existing
  precise local-volume bindings (1% steps), even while the ordinary volume
  keys are controlling Music Assistant. This is useful for a YouTube video or
  other audio playing locally in Chromium. It adjusts the complete local audio
  output, not Chromium alone. Omarchy does not provide a corresponding
  **Alt+Mute** binding. These Alt bindings belong to Omarchy and are not
  installed or removed by this plugin.

Off removes the block and reloads. The state is `installMediaKeys` in
`config.json`, so you can also set it there. A legacy block already on disk at
startup is detected but never adopted, updated, removed, or used to change the
stored setting automatically. The plugin reports it and leaves the file
untouched. Explicitly turn **Media keys** on (or run `mediaKeys on`) to adopt
and update it, or run `mediaKeys off` to remove it.

Before every successful install, update, or removal, the plugin keeps a
`bindings.lua.bak.music-assistant.*` rollback copy beside `bindings.lua` and
replaces the file atomically without changing its permissions. If the marker
block is incomplete, duplicated, or reversed, the plugin leaves the file
untouched and reports the problem instead of guessing what to remove.

Turn the switch off before `omarchy plugin remove` if you want the keys back
with Omarchy; removing the plugin does not edit `bindings.lua`.

## Removal

1. While the plugin is still configured, turn **Media keys** off in the popup,
   or run:
   ```sh
   omarchy-shell io.github.rwilson131.music-assistant mediaKeys off
   ```
2. Confirm the normal Omarchy media keys work, then remove the plugin:
   ```sh
   omarchy plugin remove io.github.rwilson131.music-assistant
   ```
3. Revoke the plugin's long-lived token in Music Assistant if nothing else
   uses it.

If the plugin was removed before Media Keys was turned off, open
`~/.config/hypr/bindings.lua`, remove the complete block from
`-- BEGIN music-assistant media-keys` through
`-- END music-assistant media-keys` (including both markers), and run
`hyprctl reload`. Inspect the adjacent `bindings.lua.bak.music-assistant.*`
files before restoring one; each is a point-in-time rollback copy and a newer
one may itself contain the marked block.

## Security

The plugin runs unsandboxed inside the Omarchy shell. It assumes the local
user is trusted (the IPC surface has no authentication) and treats the
server as semi-trusted:

- Strings from the server are length-bounded and arrays size-bounded
  (64 players, 2000 queue items, 50 search hits per type, …).
- Image URLs must be `http://` or `https://`; provider-relative artwork is
  fetched through the server's image proxy. `file://`, `data:` and
  `javascript:` are dropped.
- The response body is capped at 8 MB (`curl --max-filesize`).
- The bearer token never appears in a command line: it reaches curl over
  stdin and a 0600 temp file (`-H @file`).
- `config.json` is written with mode 600.

## API commands used

`players/all`, `players/get`, `players/cmd/*` (volume_set, volume_mute,
group_volume, power, set_members, ungroup, select_source),
`players/sleep_timer/*`, `players/add_currently_playing_to_favorites`,
`player_queues/get`, `player_queues/items`, `player_queues/*` (play, pause,
stop, next, previous, seek, skip, shuffle, repeat, crossfade, autoplay,
dont_stop_the_music, play_index, play_media, delete_item, move_item,
move_item_end, clear, transfer, save_as_playlist), `music/search`,
`music/browse`, `music/recently_played_items`, `music/<type>/library_items`,
`music/playlists/playlist_tracks`, `music/playlists/add_playlist_tracks`,
`music/albums/album_tracks`, `music/artists/artist_tracks`,
`music/favorites/add_item`, `music/favorites/remove_item`, `music/item_by_uri`,
`player_queues/all`, `config/providers/reload` (Pandora recovery only).

See https://music-assistant.io/api/ for the full API.

## Development

Run the dependency-free headless regression suite before publishing changes:

```sh
./test/run
```

It exercises the QML JavaScript libraries with Node's built-in test runner,
checks the shell helper and JSON files, enforces safety-critical QML source
invariants, and runs `omarchy plugin validate` when Omarchy is available. It
does not start Quickshell or touch the compositor. GitHub Actions runs the
same command on every push and pull request.

Files under the plugin directory hot-reload on save, with one catch:
`Service.qml` reloads as a service while the bar widget keeps its reference
to the old one, which leaves the popup unresponsive, and `BarWidget.qml`
changes are not picked up at all. Run `omarchy restart shell` after editing
either. QML errors appear in `journalctl --user -t omarchy-shell`.

## Credits

- Original plugin: [manologarciadev/omarchy.music-assistant](https://github.com/manologarciadev/omarchy.music-assistant),
  MIT. This fork keeps that license; see `LICENSE`.
- The Music Assistant mark in the popup header (`MaIcon.qml`) is adapted from
  [music-assistant/frontend](https://github.com/music-assistant/frontend)
  `public/favicon.svg`, Apache-2.0. Its exact source commit, modifications,
  license copy, and trademark disclaimer are recorded in
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

The plugin is distributed under the [MIT License](LICENSE). Third-party
material remains under its identified license; see
[Third-party notices](THIRD_PARTY_NOTICES.md) and the files under
[`LICENSES/`](LICENSES/).
