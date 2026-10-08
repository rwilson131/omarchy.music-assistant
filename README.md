# Music Assistant plugin for Omarchy

Control a [Music Assistant](https://music-assistant.io/) server from the
Omarchy bar: now playing with transport and volume, every player with
grouping, the queue, search, a library browser, favorites, playlists and
recently played. Talks to the server over its JSON API and also exposes an
IPC surface for keybindings and scripts.

This is the [rwilson131](https://github.com/rwilson131/omarchy.music-assistant)
fork of the plugin originally written by
[manologarciadev](https://github.com/manologarciadev/omarchy.music-assistant).
See [Credits](#credits). Tested against Music Assistant 2.10.5 and Omarchy 4.0.

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
| **Now** | Artwork, title, transport (previous, play/pause, next, shuffle, repeat, favorite, web UI), progress bar (click to seek), volume slider and mute. Chips for Crossfade, Autoplay, Don't stop the music, a sleep timer (click cycles 15 → 30 → 60 → 90 min → off) and Stop. |
| **Players** | Every player, sorted active → playing → idle → groups → unavailable. Click makes a player active and moves the queue to it; right-click mutes. **Join** groups a speaker with the active player, **Leave** removes it, **Ungroup** dissolves the active player's group. The volume slider moves the group when the active player leads one. |
| **Queue** | Click plays an item, right-click removes it. Per-row buttons move it up, down, to the end, or remove it. **Save** names the queue as a new playlist; **Clear** empties it. |
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

Off removes the block and reloads. The state is `installMediaKeys` in
`config.json`, so you can also set it there. Upgrading from 1.0.x with the
old block installed turns the switch on and updates the block.

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
`music/favorites/add_item`, `music/favorites/remove_item`.

See https://music-assistant.io/api/ for the full API.

## Development

Files under the plugin directory hot-reload on save, with one catch:
`Service.qml` reloads as a service while the bar widget keeps its reference
to the old one, which leaves the popup unresponsive, and `BarWidget.qml`
changes are not picked up at all. Run `omarchy restart shell` after editing
either. QML errors appear in `journalctl --user -t omarchy-shell`.

## Credits

- Original plugin: [manologarciadev/omarchy.music-assistant](https://github.com/manologarciadev/omarchy.music-assistant),
  MIT. This fork keeps that license; see `LICENSE`.
- The Music Assistant mark in the popup header (`MaIcon.qml`) is drawn from
  the path in [music-assistant/frontend](https://github.com/music-assistant/frontend)
  `public/favicon.svg`, Apache-2.0. Music Assistant is a project of the Open
  Home Foundation; this plugin is not affiliated with it.
