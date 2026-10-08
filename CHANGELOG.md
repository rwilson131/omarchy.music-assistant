# Changelog

All notable changes to this plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.4] - 2026-10-08

### Added
- `Ctrl+S` on the Queue tab opens the save-as-playlist name field. The Save button and the shortcut share one focus path.

### Fixed
- Save queue as playlist: the "Saved" overlay fired before the server answered and the playlist list refreshed before the server's background task had created the playlist, so a failed save looked successful and a successful one did not show up. The overlay now follows a 200 reply and the list refreshes over the next seven seconds. Non-200 action replies are logged.

## [1.1.3] - 2026-10-08

### Fixed
- Shift+Tab now cycles tabs backwards; it was treated as Tab because the handler only recognised Qt's Backtab form, and the compositor delivers Tab with the Shift modifier instead.
- Ctrl+1 … Ctrl+8 match the key code rather than the key event's text, which is not reliable with Control held. All popup shortcuts in the README (Escape, Ctrl+N, Tab / Shift+Tab, Space, Enter) were verified by driving the open popup with a virtual keyboard.

## [1.1.2] - 2026-10-07

### Fixed
- Shuffle and repeat buttons toggled from stale player fields the 2.10 API no longer sends, so they could send the wrong state; they now toggle from the queue state shown in the popup.
- `searchLimit` in `config.json` is honoured; search always asked for 20 results.
- Shuffle and repeat are disabled (with a tooltip) while the active queue is dynamic (smart shuffle, "don't stop the music", artist radio): the server answers those changes with HTTP 500 on such queues. The failure overlay no longer suggests a provider sign-in problem for commands other than playback.

### Changed
- Internal cleanup for publication: one `MaRequest` component replaces nine copy-pasted request processes in the service; one row delegate serves all seven search result types; favorites filters reuse the shared chip; dead properties, unused player fields and historical "fix" comments removed; files documented at the top. No user-visible change beyond the fixes above.

## [1.1.1] - 2026-10-07

### Added
- **Media keys switch** at the top right of the popup (also `mediaKeys on|off` over IPC). On writes the marked block to `~/.config/hypr/bindings.lua` and reloads Hyprland; Off removes it. The state is `installMediaKeys` in `config.json`, now **off by default** for new installs: the plugin no longer edits Hyprland config on first run.
- The installed block routes the volume keys through `scripts/contextual-volume-control` in the plugin folder, so they drive Music Assistant only while its active player is playing and otherwise keep Omarchy's local audio behaviour. An older block from 1.0.x is replaced on the next enable; an upgrade with the old block installed turns the switch On so it matches.

### Fixed
- A `config.json` created after the plugin loaded is picked up within a few seconds; it used to need a shell restart (the file watcher never saw the file appear).
- The media-key installer ran twice on every config load.
- Settings the plugin saves itself (the media keys switch, the preferred player) no longer snap back: the config watcher re-applied its cached, pre-save text whenever the file changed. It now reloads the file. Saves made while one is still being written are queued instead of dropped, and the install/remove scripts run one at a time.

## [1.1.0] - 2026-10-07

First release of the rwilson131 fork. The original plugin by manologarciadev
(v1.0.5) has been unmaintained since 2026-08; this release audits every call
against Music Assistant 2.10.5 and adds the features below.

### Added
- **Browse tab**: walks the server's provider tree (`music/browse`) with Back, a filter box for long folders (SiriusXM lists 459 channels) and play / play-next / add on items.
- **Queue options** on the Now tab: Crossfade, Autoplay and Don't-stop-the-music toggles, a sleep timer chip (15 → 30 → 60 → 90 min → off, shows minutes left) and Stop.
- **Grouping** on the Players tab: Join / Leave group speakers with the active player, Ungroup on the active leader (`players/cmd/set_members`, `ungroup`). Rows show "grouped with …"; the list is sorted active → playing → idle → groups → unavailable and hides players hidden in the MA UI. The volume slider moves the group volume when the active player leads a group.
- **Queue editing**: move up / down / to end and remove buttons per row; Save asks for a name and uses `player_queues/save_as_playlist`.
- **Lists drill-down**: click a playlist to see its tracks with Play all; right-click a library playlist to add the playing track to it; middle-click queues it. Albums and artists open the same way from the service.
- **Enqueue everywhere**: right-click plays next, middle-click adds to the end, on search, browse, recent, favorites (middle only) and drill-down rows.
- IPC: `stop`, `skipSeconds`, `toggleCrossfade`, `toggleAutoplay`, `sleepTimer(minutes)`, `enqueueUri(uri, option)`, `groupJoin`, `groupLeave`, `browse(path)`, `browseSnapshot`, `listsSnapshot`.

### Changed
- Popup header with the Music Assistant mark (drawn from the project's favicon path in the theme colour), title, and a status line (active player and playing/paused/idle, or the connection state), in the style of the shell's own panels.
- Popup scrollbar is drawn with the shell's theme tokens (`ThemedScrollBar.qml`): a thin pill in the popup foreground colour, accent while dragged, parked in the card padding beside the content. It only appears when a tab actually overflows; the stock Qt bar was a flat gray track that stayed on screen even when nothing could scroll. The flickable also only grabs wheel/drag input while there is something to scroll.
- Tab icons use current Nerd Font Material Design codepoints (music, speaker, playlist-play, magnify, heart, playlist-music, history). The old codepoints rendered as Facebook, a flask, fast-forward, "123" and two calendars.

### Fixed
- Data layer brought in line with the Music Assistant 2.10 API. Rows in Favorites, Lists, Recent, Search and Queue now show artist, album and artwork (items carry `artists[]`, `album{}` and `image{path}` / `metadata.images`, not flat strings; provider-relative artwork goes through the server's image proxy). Playlists use `music/playlists/library_items` (`music/playlists/all` is not a command, so the Lists tab was always empty). Recent handles the bare-list response.
- Queue state comes from `player_queues/get`: the current item is highlighted correctly (items responses never carried an index), shuffle/repeat reflect the queue, and crossfade/autoplay state is read.
- Progress bar and times are in seconds (the API's unit); they showed 0:00 before. Elapsed time ticks locally between polls, live streams show "live" instead of 0:00, and seek sends `position` in seconds (the old `position_ms` was unknown to the server).
- Removing a favorite sends `media_type` + `library_item_id` as the API requires; deleting a queue item sends `item_id_or_index`; favoriting the current track uses `players/add_currently_playing_to_favorites` so the live track behind a radio stream is favorited, and the heart reflects the current item's favorite flag.
- Search covers radio, podcasts and audiobooks too, with filter chips for each; "Save queue as playlist" uses the native `player_queues/save_as_playlist`.
- The globe button on the Now tab now opens the Music Assistant web UI in the default browser (`omarchy-launch-browser`); it previously called the shell's plugin summon with "browser", which is not a plugin, and did nothing.
- The favorite button's off state drew a battery-with-bluetooth glyph (stale codepoint); it is now a heart outline.
- Typing in the Search field (and the popup's Tab / Ctrl+1–7 / Space shortcuts) now works. The popup was a `PopupCard`, an xdg-popup of the bar window, which never takes keyboard focus; it is now a `KeyboardPanel`, the shell's layer-shell popup that primes keyboard focus when it opens.
- Picks replace the queue (`option: "replace"`) instead of inserting before whatever was queued, so a radio station no longer takes over after a track ends.
- Actions sent while another is in flight are queued and run in order instead of being silently dropped (quick second key press, volume right after unmute, held volume keys).
- Search uses a 30 s curl timeout; cold searches across all providers took 8–11 s and showed nothing.
- Rejected actions show an OSD with the HTTP status instead of failing silently.
- Volume key presses update the plugin's local player state so repeated presses build on each other; a press while muted only unmutes.
- Search field focus, favorites, and player-row controls.

### Added
- Volume slider, mute button, and percent readout in the Now section (send on release, wheel steps by 5, right-click mutes).
- `scripts/contextual-volume-control`: install to `~/.local/bin` and bind the XF86 volume keys to it with `installMediaKeys: false`. Volume keys go to Music Assistant only while its active player is playing, with an OSD naming the player; otherwise they keep Omarchy's local-audio behaviour.

## [1.0.5] - 2026-08-28

### Security
- `configSaveScript()` no longer uses a PID-predicted temp path (`$F.tmp.$$`) which a same-user process could pre-create as a symlink to redirect the token write. The fix:
  - `mktemp -p "$D" ma-config.XXXXXXXXXX` creates an unpredictable 0600-mode regular file in the same directory as the final config (so `mv` stays atomic).
  - `exec 3> "$T"` opens the file descriptor before any later path lookup; `printf >&3` writes through the fd, so an attacker racing to replace `$T` with a symlink after `mktemp` cannot redirect the write.
  - `mv -f "$T" "$F"` is `rename(2)`, atomic on Linux regardless of what `$F` was.
  - `chmod 600` on the final file in case `$F` pre-existed with broader perms.

## [1.0.4] - 2026-08-27

### Security / UX
- Media-key installer now reports first-run via Omarchy's OSD: when bindings were just installed (exit code 42 from the install script), a notification explains what changed and how to revert. Subsequent plugin loads no longer show the OSD because the marker is already present.
- Image URLs from the MA server are now scheme-whitelisted to `http://` and `https://` via `MaApi.safeImageUrl()`. `file://`, `javascript:`, `data:`, and other schemes are dropped to empty string, so a compromised or buggy MA cannot trick QML `Image` into reading local files or executing scripts.

## [1.0.3] - 2026-08-27

### Security
- `config.json` is now written with `umask 077` and `chmod 600`, so the file containing the MA bearer token is owner-readable only (was 0644, world-readable). Existing installs: run `chmod 600 ~/.config/omarchy/plugins/io.github.rwilson131.music-assistant/config.json` once.

## [1.0.2] - 2026-08-27

### Security
- Bound Music Assistant responses to prevent shell-memory exhaustion from a malicious or malfunctioning server (fixes marketplace review finding). Three defense layers:
  - **Producer cap**: curl `--max-filesize 8388608` (8 MB) errors out with exit 63 if the server returns more.
  - **Model budgets** (in `MaApi.js`): `MAX_PLAYERS=64`, `MAX_QUEUE_ITEMS=2000`, `MAX_SEARCH_*=50`, `MAX_FAVORITES_PER_TYPE=100`, `MAX_PLAYLISTS=100`, `MAX_RECENT_ITEMS=50`.
  - **Field bounds** (in `Service.qml`): every assigned QML model maps raw server data through `boundedArray()` / `boundedString()` with `MAX_STRING_LENGTH=500`, so a single oversized item cannot blow up a Repeater.
- Net effect: a single oversized array or string is sliced / truncated before any QML binding sees it.

## [1.0.1] - 2026-08-27

### Security
- Pass MA bearer token via stdin instead of curl `-H` argv (fixes marketplace review finding `BEARER-TOKEN-IN-PROCESS-ARGV`). The token now lives in a 0600-mode `mktemp` file for the duration of one bash invocation only, and never appears in any process's `argv` or `/proc/PID/cmdline`.

## [1.0.0] - 2026-08-26

### Added
- Initial release
- Now-playing display with cover art and progress bar in the bar widget
- Transport controls: play/pause, next, previous, seek (relative and absolute)
- Volume, shuffle, repeat, favorite toggle
- Player selector with queue transfer and right-click mute
- Search across tracks, albums, artists, playlists with type filters
- Favorites tab with filter chips (tracks/albums/artists/playlists/radio)
- Playlists tab with click-to-play
- Recent tab with relative timestamps
- Save queue as playlist from Queue tab
- Auto-install Hyprland media key bindings (`XF86AudioPlay/Pause/Next/Prev`) on first load with markers and idempotency
- Smart media key routing: MPRIS active player first (YouTube, Spotify, etc.), Music Assistant fallback when no other player is active
- Persistent `preferredPlayerId` across shell restarts (saved to `config.json` on player activation)
- IPC handlers for 20+ actions (`status`, `playPause`, `seek`, `setVolumePct`, `toggleShuffle`, `cycleRepeat`, `activatePlayerById`, `playUri`, `playUriOn`, `search`, `clearQueueNow`, `refresh`, `playersList`, `seek`, `seekRelative`, `power`, `favoriteCurrent`, `favoriteAdd`, `favoriteRemove`, `saveQueue`, `openWebUI`, `refreshFavorites`, `refreshPlaylists`, `refreshRecent`)
- Keyboard navigation in popup (`Ctrl+1..7` for tabs, `Tab`/`Shift+Tab` to cycle, `Escape` to close, `Space` play/pause, arrow keys in lists, `Enter` activate, `Delete` remove)
- Configurable polling interval (`pollIntervalMs`), search limit, recent limit, badge display, web UI path, media key install, and MPRIS fallback
- HTTP polling for live state with 2-second default interval

### Notes
- Plugin id: `io.github.rwilson131.music-assistant`
- License: MIT
- Tested on Quickshell-git, Omarchy (Quattro)