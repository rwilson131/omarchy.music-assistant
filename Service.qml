import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import "MaApi.js" as MaApi
import "ConfigSchema.js" as ConfigSchema

// Music Assistant service: owns the connection, the polled state, every
// action, the media-key bindings and the IPC surface. The bar widget only
// renders what is here and calls the functions below.
//
// Transport is HTTP: each call is one curl run (see MaRequest.qml and
// MaApi.js); state is polled every pollIntervalMs as
// players/all -> player_queues/get -> player_queues/items.
Item {
  id: root

  // The shell root, injected by Omarchy; used for OSD summons.
  property var shell: null

  // --------------------------------------------------------------- config

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginId: "io.github.rwilson131.music-assistant"
  readonly property string pluginDir: home + "/.config/omarchy/plugins/" + pluginId
  readonly property string configPath: pluginDir + "/config.json"
  readonly property string ipcTarget: pluginId

  // Parsed config.json (see ConfigSchema.js), which keys the file actually
  // had, and whether it is usable.
  property var config: ({})
  property var configPresent: ({})
  property string configError: ""
  property bool ready: false
  property string preferredPlayerId: ""

  readonly property int pollIntervalMs: Math.max(500, config && config.pollIntervalMs ? config.pollIntervalMs : 2000)

  // ---------------------------------------------------------------- state
  // Replaced wholesale on each poll; the *Revision counters let bindings
  // that call functions re-evaluate.

  property bool connected: false
  property string lastError: ""
  property int revision: 0

  property var players: []
  property string activePlayerId: ""

  // The active player's queue: items from player_queues/items, and the
  // queue object from player_queues/get, which owns the current index,
  // shuffle/repeat/crossfade/autoplay and the elapsed time.
  property var queue: []
  property int queueRevision: 0
  property var queueInfo: null
  property int queuePosition: 0
  property string queueState: "idle"
  property bool shuffleEnabled: false
  property string repeatMode: "off"
  property bool crossfadeEnabled: false
  property bool autoplayEnabled: false
  property bool dontStopTheMusicEnabled: false
  property bool currentFavorite: false
  // Elapsed time as of the last poll, and when that was, so the progress
  // bar can advance locally between polls.
  property real queueElapsedBase: 0
  property real queueElapsedAtMs: 0
  // Bumped once a second while something plays so elapsed-time bindings
  // re-evaluate between polls.
  property int nowTick: 0

  property var searchResults: null
  property string searchQuery: ""
  property int searchRevision: 0
  property var favorites: ({ tracks: [], albums: [], artists: [], playlists: [], radio: [] })
  property int favoritesRevision: 0
  property var playlists: []
  property int playlistsRevision: 0
  property var recentItems: []
  property int recentRevision: 0

  // ------------------------------------------------------- derived state

  readonly property var activePlayer: {
    for (var i = 0; i < players.length; i++) {
      if (players[i].player_id === activePlayerId) return players[i]
    }
    return null
  }

  readonly property var activeMedia: activePlayer && activePlayer.current_media ? activePlayer.current_media : null
  readonly property bool hasMedia: activeMedia !== null && !!(activeMedia.title || activeMedia.uri)
  readonly property bool isPlaying: MaApi.isPlaying(activePlayer)
  readonly property bool isPaused: MaApi.isPaused(activePlayer)
  readonly property int activeVolume: MaApi.volumePercent(activePlayer)
  readonly property string activeTitle: MaApi.trackTitle(activeMedia)
  readonly property string activeArtist: MaApi.trackArtist(activeMedia)
  readonly property string activeAlbum: MaApi.trackAlbum(activeMedia)
  readonly property string activeImageUrl: MaApi.trackImageUrl(activeMedia)

  // Seconds; durations and elapsed times are seconds throughout the API.
  readonly property int activeDuration: {
    if (activeMedia && typeof activeMedia.duration === "number" && activeMedia.duration > 0) return Math.round(activeMedia.duration)
    if (queueInfo && queueInfo.current_item && typeof queueInfo.current_item.duration === "number") return Math.round(queueInfo.current_item.duration)
    return 0
  }

  readonly property int activeElapsed: {
    var _tick = nowTick
    if (!queueInfo) return activeMedia && activeMedia.elapsed_time ? Math.round(activeMedia.elapsed_time) : 0
    var e = queueElapsedBase
    if (queueState === "playing" && queueElapsedAtMs > 0) e += (Date.now() - queueElapsedAtMs) / 1000
    if (activeDuration > 0) e = Math.min(e, activeDuration)
    return Math.max(0, Math.round(e))
  }

  readonly property int sleepRemainingSeconds: {
    var _tick = nowTick
    var p = activePlayer
    if (!p || !p.sleep_timer_expires_at) return 0
    return Math.max(0, Math.round(p.sleep_timer_expires_at - Date.now() / 1000))
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.ready && root.queueState === "playing"
    onTriggered: root.nowTick = root.nowTick + 1
  }

  // --------------------------------------------------------------- mpris
  // With mprisFallback on, play/pause/next/previous go to a local player
  // (browser, Spotify) while one is playing, so the media keys do what the
  // user expects even when Music Assistant is idle.

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var activeMprisPlayer: {
    var proxy = null
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      if (!p || !p.isPlaying) continue
      // playerctld mirrors whichever player is active; prefer the real one.
      if (String(p.dbusName || "").toLowerCase().indexOf("playerctld") !== -1) { if (!proxy) proxy = p }
      else return p
    }
    return proxy
  }

  function mprisRoutingEnabled() {
    return root.config && root.config.mprisFallback !== false
  }

  // ---------------------------------------------------------------- config loader

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    // text() still holds the previous content when fileChanged fires, so a
    // save made by this plugin (persistConfig) was re-applied as the old
    // state. Reload; onLoaded applies the fresh text.
    onFileChanged: configFile.reload()
    onLoadFailed: function(err) {
      root.configError = "config.json missing or unreadable"
      root.config = ({})
      root.ready = false
      // A fresh install has no config.json yet; the watcher does not see a
      // file that appears later, so keep retrying until it loads.
      configRetry.start()
    }
  }

  Timer {
    id: configRetry
    interval: 3000
    repeat: true
    onTriggered: configFile.reload()
  }

  Component.onCompleted: {
    if (configFile) configFile.reload()
  }

  // --------------------------------------------------- media keys

  readonly property string mediaKeysMarkerBegin: "-- BEGIN music-assistant media-keys"
  readonly property string mediaKeysMarkerEnd: "-- END music-assistant media-keys"
  readonly property string hyprBindingsPath: home + "/.config/hypr/bindings.lua"

  // The switch in the popup header. Backed by config.json's installMediaKeys
  // so the file, the popup and the IPC call stay in step.
  readonly property bool mediaKeysEnabled: !!(root.config && root.config.installMediaKeys === true)

  // Play/pause/next/previous go straight to the plugin. The volume keys go
  // through scripts/contextual-volume-control, which sends them to Music
  // Assistant only while its active player is playing and otherwise keeps
  // Omarchy's local-audio behaviour. An older block is replaced on the next
  // enable because the installer compares the installed text with this.
  function mediaKeysBindingsBlock() {
    var qsBin = "/usr/bin/qs"
    var omarchyShell = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
    var ipcCmd = qsBin + " -p " + omarchyShell + " ipc call " + root.pluginId
    var volCmd = root.pluginDir + "/scripts/contextual-volume-control"
    return [
      "",
      mediaKeysMarkerBegin,
      "-- Installed by the Music Assistant plugin (Media keys switch in the popup).",
      "hl.unbind(\"XF86AudioNext\")",
      "hl.unbind(\"XF86AudioPrev\")",
      "hl.unbind(\"XF86AudioPlay\")",
      "hl.unbind(\"XF86AudioPause\")",
      "hl.unbind(\"XF86AudioRaiseVolume\")",
      "hl.unbind(\"XF86AudioLowerVolume\")",
      "hl.unbind(\"XF86AudioMute\")",
      "o.bind(\"XF86AudioNext\", \"Music next\", \"" + ipcCmd + " nextTrack\", { locked = true })",
      "o.bind(\"XF86AudioPrev\", \"Music previous\", \"" + ipcCmd + " previousTrack\", { locked = true })",
      "o.bind(\"XF86AudioPlay\", \"Music play/pause\", \"" + ipcCmd + " playPause\", { locked = true })",
      "o.bind(\"XF86AudioPause\", \"Music play/pause\", \"" + ipcCmd + " playPause\", { locked = true })",
      "-- Volume keys: Music Assistant while it is playing, otherwise local audio.",
      "o.bind(\"XF86AudioRaiseVolume\", \"Volume up\", \"" + volCmd + " raise\", { locked = true, repeating = true })",
      "o.bind(\"XF86AudioLowerVolume\", \"Volume down\", \"" + volCmd + " lower\", { locked = true, repeating = true })",
      "o.bind(\"XF86AudioMute\", \"Mute\", \"" + volCmd + " mute-toggle\", { locked = true })",
      mediaKeysMarkerEnd,
      ""
    ].join("\n")
  }

  // The two scripts edit the same file; run one at a time and replay the
  // last request made while one was in flight.
  property string mediaKeysPending: ""

  function installMediaKeysBindings() {
    if (!root.ready || !root.mediaKeysEnabled) return
    root.runMediaKeysScript("install")
  }

  function uninstallMediaKeysBindings() {
    root.runMediaKeysScript("uninstall")
  }

  function runMediaKeysScript(which) {
    if (mediaKeysInstaller.running || mediaKeysUninstaller.running) {
      root.mediaKeysPending = which
      return
    }
    if (which === "install") mediaKeysInstaller.running = true
    else mediaKeysUninstaller.running = true
  }

  function mediaKeysScriptDone() {
    var next = root.mediaKeysPending
    root.mediaKeysPending = ""
    if (next === "install" && root.mediaKeysEnabled) Qt.callLater(function() { root.runMediaKeysScript("install") })
    else if (next === "uninstall" && !root.mediaKeysEnabled) Qt.callLater(function() { root.runMediaKeysScript("uninstall") })
  }

  function setMediaKeysEnabled(on) {
    if (!root.ready || !root.config) return
    var next = !!on
    if (root.config.installMediaKeys === next) {
      if (next) installMediaKeysBindings()
      return
    }
    var cfg = Object.assign({}, root.config)
    cfg.installMediaKeys = next
    root.config = cfg
    root.persistConfig()
    if (next) installMediaKeysBindings()
    else uninstallMediaKeysBindings()
  }

  // awk programs for the scripts below: print the block, or everything but
  // the block, between the two markers (matched at line start).
  readonly property string mediaKeysAwkBlock: "index($0,b)==1{p=1} p{print} index($0,e)==1{p=0}"
  readonly property string mediaKeysAwkOutside: "index($0,b)==1{p=1} !p{print} index($0,e)==1{p=0}"

  function mediaKeysShellPrelude() {
    return "set -e\n" +
      "F='" + root.hyprBindingsPath.replace(/'/g, "'\\''") + "'\n" +
      "B='" + root.mediaKeysMarkerBegin + "'\n" +
      "E='" + root.mediaKeysMarkerEnd + "'\n"
  }

  // Exit 0 = already current, 42 = installed, 43 = replaced an older block.
  readonly property string mediaKeysInstallScript: {
    var block = root.mediaKeysBindingsBlock().replace(/'/g, "'\\''")
    return root.mediaKeysShellPrelude() +
      "if [ ! -f \"$F\" ]; then exit 0; fi\n" +
      "T=$(mktemp); C=$(mktemp); D=$(mktemp)\n" +
      "trap 'rm -f \"$T\" \"$C\" \"$D\"' EXIT\n" +
      "printf '%s\\n' '" + block + "' > \"$T\"\n" +
      "status=42\n" +
      "if grep -qF -e \"$B\" \"$F\"; then\n" +
      "  awk -v b=\"$B\" -v e=\"$E\" '" + root.mediaKeysAwkBlock + "' \"$F\" > \"$C\"\n" +
      "  awk -v b=\"$B\" -v e=\"$E\" '" + root.mediaKeysAwkBlock + "' \"$T\" > \"$D\"\n" +
      "  if cmp -s \"$C\" \"$D\"; then exit 0; fi\n" +
      "  awk -v b=\"$B\" -v e=\"$E\" '" + root.mediaKeysAwkOutside + "' \"$F\" > \"$F.tmp\" && mv -f \"$F.tmp\" \"$F\"\n" +
      "  status=43\n" +
      "fi\n" +
      "if [ -s \"$F\" ] && [ -n \"$(tail -c 1 \"$F\")\" ]; then echo >> \"$F\"; fi\n" +
      "cat \"$T\" >> \"$F\"\n" +
      "hyprctl reload >/dev/null 2>&1 || true\n" +
      "exit $status\n"
  }

  // Exit 0 = nothing to do, 44 = removed.
  readonly property string mediaKeysUninstallScript: root.mediaKeysShellPrelude() +
    "if [ ! -f \"$F\" ]; then exit 0; fi\n" +
    "grep -qF -e \"$B\" \"$F\" || exit 0\n" +
    "awk -v b=\"$B\" -v e=\"$E\" '" + root.mediaKeysAwkOutside + "' \"$F\" > \"$F.tmp\" && mv -f \"$F.tmp\" \"$F\"\n" +
    "hyprctl reload >/dev/null 2>&1 || true\n" +
    "exit 44\n"

  // Exit 0 = a block is present, 1 = not.
  readonly property string mediaKeysProbeScript: root.mediaKeysShellPrelude() +
    "[ -f \"$F\" ] && grep -qF -e \"$B\" \"$F\"\n"

  Process {
    id: mediaKeysInstaller
    command: [Quickshell.env("SHELL") || "/bin/bash", "-c", root.mediaKeysInstallScript]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        console.log("[music-assistant] Media key bindings: already current")
      } else if (exitCode === 42) {
        console.log("[music-assistant] Media key bindings installed")
        root.showOsd("Media keys on", "input-keyboard",
          "Play/pause, next and previous control Music Assistant; volume keys while it is playing")
      } else if (exitCode === 43) {
        console.log("[music-assistant] Media key bindings updated")
        root.showOsd("Media keys updated", "input-keyboard",
          "Volume keys now follow Music Assistant only while it is playing")
      } else {
        console.warn("[music-assistant] Failed to install media key bindings: exitCode=" + exitCode)
      }
      root.mediaKeysScriptDone()
    }
  }

  Process {
    id: mediaKeysUninstaller
    command: [Quickshell.env("SHELL") || "/bin/bash", "-c", root.mediaKeysUninstallScript]
    onExited: function(exitCode) {
      if (exitCode === 44) {
        console.log("[music-assistant] Media key bindings removed")
        root.showOsd("Media keys off", "input-keyboard", "Keyboard media keys returned to Omarchy")
      } else if (exitCode !== 0) {
        console.warn("[music-assistant] Failed to remove media key bindings: exitCode=" + exitCode)
      }
      root.mediaKeysScriptDone()
    }
  }

  // A block on disk means the keys are bound to this plugin, whatever the
  // config says: an upgrade from 1.0.x (no installMediaKeys key yet), or a
  // reinstall after a remove that left the block behind, pointing at a
  // folder that no longer exists. Turn the switch on so the state matches
  // and the block is rewritten for this install.
  Process {
    id: mediaKeysProbe
    command: [Quickshell.env("SHELL") || "/bin/bash", "-c", root.mediaKeysProbeScript]
    onExited: function(exitCode) {
      if (exitCode === 0 && root.ready && root.config && !root.mediaKeysEnabled)
        root.setMediaKeysEnabled(true)
    }
  }

  // --------------------------------------------------- config persistence

  Process {
    id: configSaver
    property string savePath: ""
    property string saveJson: ""
    // Setting running = true on a busy Process is a no-op, so a save
    // requested while one is in flight is replayed when it finishes.
    property bool pending: false
    onExited: function(exitCode) {
      if (exitCode === 0) {
        console.log("[music-assistant] Config persisted to " + savePath)
      } else {
        console.warn("[music-assistant] Failed to persist config (exit=" + exitCode + ")")
      }
      if (pending) {
        pending = false
        Qt.callLater(function() { root.persistConfig() })
      }
    }
  }

  function configSaveScript(path, json) {
    var safePath = path.replace(/'/g, "'\\''")
    var safeJson = json.replace(/'/g, "'\\''")
    // Defense against symlink pre-creation at a predictable path:
    //   1. mktemp creates a uniquely-named file in the same directory as
    //      the final config, with mode 0600 from the start (umask 077 +
    //      mktemp's default permissions). Same directory = atomic rename.
    //   2. Open the file with exec 3>"$T" *before* any other lookup of
    //      $T happens. The fd stays bound to the original inode even if
    //      a same-user attacker races to replace $T with a symlink.
    //   3. Write through fd 3 (printf >&3), close fd (exec 3>&-).
    //   4. mv -f: atomic rename(2) on Linux; replaces the destination
    //      atomically regardless of what the destination was (regular
    //      file, symlink, missing).
    //   5. chmod 600 the final file in case the destination already
    //      existed with broader perms.
    var lastSlash = path.lastIndexOf("/")
    var safeDir = (lastSlash >= 0 ? path.substring(0, lastSlash) : ".").replace(/'/g, "'\\''")
    return "set -e\n" +
      "umask 077\n" +
      "D='" + safeDir + "'\n" +
      "F='" + safePath + "'\n" +
      "T=$(mktemp -p \"$D\" ma-config.XXXXXXXXXX)\n" +
      "exec 3> \"$T\"\n" +
      "printf '%s\\n' '" + safeJson + "' >&3\n" +
      "exec 3>&-\n" +
      "chmod 600 \"$T\"\n" +
      "mv -f \"$T\" \"$F\"\n" +
      "chmod 600 \"$F\"\n"
  }

  function persistConfig() {
    if (!root.ready || !root.config) return
    if (configSaver.running) { configSaver.pending = true; return }
    var path = root.configPath
    var json = JSON.stringify(root.config, null, 2)
    configSaver.savePath = path
    configSaver.saveJson = json
    configSaver.command = [Quickshell.env("SHELL") || "/bin/bash", "-c",
      root.configSaveScript(path, json)]
    configSaver.running = true
  }

  function applyConfig(text) {
    var result = ConfigSchema.parse(text)
    root.config = result.config
    root.configPresent = result.present || ({})
    root.preferredPlayerId = result.config.preferredPlayerId || ""
    root.ready = result.error.length === 0
    root.configError = result.error
    if (root.ready) {
      configRetry.stop()
      root.startConnection()
      Qt.callLater(function() {
        root.installMediaKeysBindings()
        mediaKeysProbe.running = true
      })
    } else {
      root.stopConnection()
      root.configError = result.error || "invalid config"
    }
  }

  // --------------------------------------------------------------- polling

  property bool pollingActive: false
  property bool pollInFlight: false

  Timer {
    id: pollTimer
    interval: root.pollIntervalMs
    repeat: true
    running: root.ready
    triggeredOnStart: true
    onTriggered: root.refreshState()
  }

  function startConnection() {
    root.pollingActive = true
    pollTimer.restart()
  }

  function stopConnection() {
    pollTimer.stop()
    root.pollingActive = false
  }

  function refreshState() {
    if (!root.ready) return
    if (root.pollInFlight) return
    root.pollInFlight = true
    root.runFetchPlayers()
  }

  function api(command, args, messageId, maxTime) {
    return MaApi.buildArgs(root.config.url, root.config.token, command, args || {}, messageId, maxTime)
  }

  // Poll step 1 of 3.
  function runFetchPlayers() {
    if (!root.ready || !playersRequest.send(root.api("players/all", {}, "poll-players"))) root.pollInFlight = false
  }

  MaRequest {
    id: playersRequest
    label: "players"
    onFinished: function(data) {
      if (data === null) root.lastError = "players: bad reply"
      else root.applyPlayers(data)
      var chosen = MaApi.pickActivePlayerId(root.players, root.preferredPlayerId)
      if (chosen && chosen !== root.activePlayerId) root.activePlayerId = chosen
      // Step 2 of 3.
      if (!root.activePlayerId || !queueInfoRequest.send(root.api("player_queues/get", { queue_id: root.activePlayerId }, "poll-queue-info")))
        root.pollInFlight = false
    }
  }

  MaRequest {
    id: queueInfoRequest
    label: "queue info"
    onFinished: function(data) {
      root.applyQueueInfo(data)
      // Step 3 of 3.
      if (!root.activePlayerId || !queueRequest.send(root.api("player_queues/items", { queue_id: root.activePlayerId, limit: 200, offset: 0 }, "poll-queue")))
        root.pollInFlight = false
    }
  }

  MaRequest {
    id: queueRequest
    label: "queue"
    onFinished: function(data) {
      root.applyQueue(data)
      root.pollInFlight = false
    }
  }

  function applyQueueInfo(q) {
    if (!q || typeof q !== "object" || !q.queue_id) {
      root.queueInfo = null
      return
    }
    var cur = q.current_item && typeof q.current_item === "object" ? q.current_item : null
    root.queueInfo = {
      queue_id: MaApi.boundedString(q.queue_id, 100),
      current_index: typeof q.current_index === "number" ? q.current_index : 0,
      state: MaApi.boundedString(q.state, 20),
      current_item: cur ? {
        queue_item_id: MaApi.boundedString(cur.queue_item_id, 100),
        name: MaApi.boundedString(cur.name, 500),
        duration: typeof cur.duration === "number" ? cur.duration : 0,
        uri: MaApi.boundedString(cur.media_item ? cur.media_item.uri : "", 2048),
        media_type: MaApi.boundedString(cur.media_item ? cur.media_item.media_type : "", 50),
        favorite: !!(cur.media_item && cur.media_item.favorite === true)
      } : null
    }
    root.queuePosition = root.queueInfo.current_index
    root.queueState = root.queueInfo.state || "idle"
    root.shuffleEnabled = q.shuffle_enabled === true
    root.repeatMode = MaApi.boundedString(q.repeat_mode || "off", 20)
    root.crossfadeEnabled = q.crossfade_enabled === true
    root.autoplayEnabled = q.autoplay_enabled === true
    root.dontStopTheMusicEnabled = q.dont_stop_the_music_enabled === true
    root.currentFavorite = root.queueInfo.current_item ? root.queueInfo.current_item.favorite : false
    // elapsed_time is as of elapsed_time_last_updated (server epoch seconds).
    // Project it to now, assuming the clocks agree, and tick locally from here.
    var base = typeof q.elapsed_time === "number" ? q.elapsed_time : 0
    if (root.queueState === "playing" && typeof q.elapsed_time_last_updated === "number") {
      var drift = Date.now() / 1000 - q.elapsed_time_last_updated
      if (drift > 0 && drift < 3600) base += drift
    }
    root.queueElapsedBase = base
    root.queueElapsedAtMs = Date.now()
  }

  // Player records keep only what the popup and the IPC surface read.
  function applyPlayers(list) {
    if (!Array.isArray(list)) {
      root.lastError = "players/all returned non-list"
      return
    }
    var bounded = MaApi.boundedArray(list, MaApi.MAX_PLAYERS).map(function(p) {
      return {
        player_id: MaApi.boundedString(p.player_id, 100),
        name: MaApi.boundedString(p.name, 200),
        available: !!p.available,
        powered: p.powered === undefined ? true : !!p.powered,
        playback_state: MaApi.boundedString(p.playback_state, 20),
        volume_muted: !!p.volume_muted,
        volume_level: typeof p.volume_level === "number" ? Math.max(0, Math.min(100, p.volume_level)) : null,
        current_media: p.current_media || null,
        group_members: Array.isArray(p.group_members) ? MaApi.boundedArray(p.group_members, 32).map(function(g) { return MaApi.boundedString(g, 100) }) : [],
        can_group_with: Array.isArray(p.can_group_with) ? MaApi.boundedArray(p.can_group_with, 64).map(function(g) { return MaApi.boundedString(g, 100) }) : [],
        hide_in_ui: !!p.hide_in_ui,
        synced_to: MaApi.boundedString(p.synced_to, 100),
        active_group: MaApi.boundedString(p.active_group, 100),
        type: MaApi.boundedString(p.type, 20),
        provider: MaApi.boundedString(p.provider, 100),
        group_volume: typeof p.group_volume === "number" ? Math.max(0, Math.min(100, p.group_volume)) : null,
        sleep_timer_expires_at: typeof p.sleep_timer_expires_at === "number" ? p.sleep_timer_expires_at : 0
      }
    })
    root.players = bounded
    root.revision = root.revision + 1
    root.connected = true
    root.lastError = ""
  }

  function applyQueue(payload) {
    if (!payload) {
      root.queue = []
      root.queuePosition = 0
      return
    }
    var raw = Array.isArray(payload) ? payload : (payload.items || [])
    // QueueItem: name, duration, index, queue_item_id, image {path}, and the
    // full media_item underneath (uri, artists, album, favorite).
    var items = MaApi.boundedArray(raw, MaApi.MAX_QUEUE_ITEMS).map(function(it) {
      var mi = it.media_item && typeof it.media_item === "object" ? it.media_item : {}
      return {
        queue_item_id: MaApi.boundedString(it.queue_item_id || it.item_id, 100),
        index: typeof it.index === "number" ? it.index : null,
        uri: MaApi.boundedString(mi.uri || it.uri || it.media_item_uri, 2048),
        name: MaApi.boundedString(it.name || mi.name || it.title, 500),
        artist: MaApi.boundedString(MaApi.itemArtist(mi) || it.artist, 500),
        album: MaApi.boundedString(MaApi.itemAlbum(mi) || it.album, 500),
        image_url: MaApi.itemImageUrl(it, root.config.url),
        duration: typeof it.duration === "number" && it.duration >= 0 ? it.duration : 0,
        track_number: typeof mi.track_number === "number" ? mi.track_number : null,
        media_type: MaApi.boundedString(mi.media_type || it.media_type, 50),
        favorite: mi.favorite === true,
        available: it.available !== false
      }
    })
    root.queue = items
    root.queueRevision = root.queueRevision + 1
  }

  // ------------------------------------------------------------- helpers

  function playerById(id) {
    if (!players || !id) return null
    for (var i = 0; i < players.length; i++) {
      if (players[i].player_id === id) return players[i]
    }
    return null
  }

  function showOsd(actionLabel, iconName, message) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: iconName || "media",
      message: message || actionLabel
    }))
  }

  // ----------------------------------------------------------- action api

  // One action at a time goes through actionProc; setting running = true on a
  // busy Process does nothing, so later actions wait here instead of vanishing
  // (e.g. a volume change right behind an unmute, or held volume keys).
  property var pendingActions: []

  function runAction(command, args, onDone) {
    if (!root.ready) return
    if (actionProc.running) {
      // A new pick supersedes any pick still waiting: replaying every click
      // made while the server was slow sent the Sonos four play requests in
      // six seconds and wedged its session.
      if (command === "player_queues/play_media")
        root.pendingActions = root.pendingActions.filter(function(a) { return a.command !== "player_queues/play_media" })
      if (root.pendingActions.length < 20)
        root.pendingActions.push({ command: command, args: args, onDone: onDone })
      return
    }
    var payload = MaApi.buildActionArgs(root.config.url, root.config.token, command, args)
    actionProc.authToken = payload.token || ""
    actionProc.command = [Quickshell.env("SHELL") || "/bin/bash", "-c", payload.script]
    actionProc.onFinished = onDone || null
    actionProc.actionCommand = command
    actionProc.running = true
  }

  Process {
    id: actionProc
    property string authToken: ""
    property var onFinished: null
    property string actionCommand: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.reportActionStatus(actionProc.actionCommand, String(text || "").trim())
    }
    onExited: function(code, status) {
      // curl exit 28 = timed out. play_media keeps going on the server
      // (SiriusXM streams take ~20 s to start), so say so instead of failing.
      if (code === 28 && actionCommand === "player_queues/play_media")
        root.showOsd("Music Assistant", "media-play", "Starting… some stations take up to 20 seconds")
      else if (code !== 0)
        root.showOsd("Music Assistant", "dialog-warning", "Music Assistant didn't respond")
      if (typeof onFinished === "function") onFinished(code, status)
      // Start the next waiting action (see pendingActions) once this Process
      // has exited; starting it from here keeps them in the order sent.
      if (root.pendingActions.length > 0) {
        var next = root.pendingActions.shift()
        Qt.callLater(function() { root.runAction(next.command, next.args, next.onDone) })
      }
      // schedule a quick refresh so UI picks up the new state
      if (refreshTimer) refreshTimer.restart()
    }
  }

  // Actions print only the HTTP status. Anything but 200 means Music Assistant
  // rejected the command (e.g. a provider that is signed out cannot play its
  // stations); tell the user instead of silently doing nothing.
  function reportActionStatus(command, httpCode) {
    if (!httpCode || httpCode === "200" || httpCode === "000") return
    var what = command === "player_queues/play_media" ? "Couldn't play that"
      : "Command failed (" + command.split("/").pop() + ")"
    var hint = httpCode === "500" ? " — check the provider is signed in to Music Assistant" : ""
    root.showOsd("Music Assistant", "dialog-warning", what + hint + " [" + httpCode + "]")
  }

  Timer {
    id: refreshTimer
    interval: 250
    repeat: false
    onTriggered: root.refreshState()
  }

  // player_queues/* commands address the queue, whose id is the player's.
  // players/cmd/* commands take player_id instead and call runAction() directly.
  function actionForPlayer(playerId, command, args) {
    var pid = playerId || root.activePlayerId
    var a = args ? Object.assign({}, args) : {}
    a.queue_id = pid
    root.runAction(command, a)
  }

  function playPause(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      var mp = root.activeMprisPlayer
      if (mp.isPlaying && mp.canPause) mp.pause()
      else if (mp.canPlay) mp.play()
      else if (mp.canTogglePlaying) mp.togglePlaying()
      return
    }
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    if (!p) return
    var playing = MaApi.isPlaying(p)
    root.actionForPlayer(pid, playing ? "player_queues/pause" : "player_queues/play")
    root.showOsd(playing ? "Pause" : "Play", playing ? "media-pause" : "media-play",
      MaApi.trackTitle(p.current_media) || "Music Assistant")
  }

  function next(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      if (root.activeMprisPlayer.canGoNext) root.activeMprisPlayer.next()
      return
    }
    root.actionForPlayer(playerId, "player_queues/next")
    root.showOsd("Next", "media-next", root.activeTitle)
  }

  function previous(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      if (root.activeMprisPlayer.canGoPrevious) root.activeMprisPlayer.previous()
      return
    }
    root.actionForPlayer(playerId, "player_queues/previous")
    root.showOsd("Previous", "media-previous", root.activeTitle)
  }

  function play(playerId) {
    root.actionForPlayer(playerId, "player_queues/play")
  }

  function pause(playerId) {
    root.actionForPlayer(playerId, "player_queues/pause")
  }

  function setVolume(playerId, volumePercent) {
    var pid = playerId || root.activePlayerId
    var v = Math.max(0, Math.min(100, Math.round(volumePercent)))
    var p = root.playerById(pid)
    if (p && p.group_members && p.group_members.length > 0) {
      // A group leader: move the whole group, like the Music Assistant UI.
      root.runAction("players/cmd/group_volume", { player_id: pid, volume_level: v })
      return
    }
    root.runAction("players/cmd/volume_set", { player_id: pid, volume_level: v })
  }

  function adjustVolume(playerId, delta) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    if (!p) return
    // A volume key while muted only unmutes, at the level from before muting,
    // like system volume keys. Raising the hidden level would make the unmute
    // jump loud, and a volume_set sent right behind the unmute gets dropped.
    if (p.volume_muted) {
      root.setMutedLocal(pid, false)
      return
    }
    root.setVolumeLocal(pid, MaApi.volumePercent(p) + delta)
  }

  // Set an absolute level and record it locally, so repeated key presses or
  // a slider drag build on the new value instead of waiting for the next
  // two-second server poll. Setting a level while muted unmutes first, like
  // the system volume keys do; the action queue keeps the two in order.
  function setVolumeLocal(playerId, volumePercent) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    if (!p) return
    var target = Math.max(0, Math.min(100, Math.round(volumePercent)))
    if (p.volume_muted) root.setMutedLocal(pid, false)
    p.volume_level = target
    root.players = root.players.slice()
    root.setVolume(pid, target)
  }

  function setMuted(playerId, muted) {
    var pid = playerId || root.activePlayerId
    root.runAction("players/cmd/volume_mute", { player_id: pid, muted: !!muted })
  }

  // Like adjustVolume, record the new mute state locally so a second key
  // press before the next poll toggles from it instead of the stale state.
  function setMutedLocal(playerId, muted) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    if (p) {
      p.volume_muted = !!muted
      root.players = root.players.slice()
    }
    root.setMuted(pid, muted)
  }

  function toggleMute(playerId) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    root.setMutedLocal(pid, !(p && p.volume_muted))
  }

  // Make a player the active one and remember it in config.json so the
  // choice survives restarts.
  function activatePlayer(playerId) {
    if (!root.playerById(playerId)) return
    root.preferredPlayerId = playerId
    root.activePlayerId = playerId
    var cfg = Object.assign({}, root.config)
    cfg.preferredPlayerId = playerId
    root.config = cfg
    root.persistConfig()
    root.refreshState()
  }

  // Move the current queue to another player and make that one active.
  function transferQueue(sourceId, targetId) {
    root.runAction("player_queues/transfer", {
      source_queue_id: sourceId || root.activePlayerId,
      target_queue_id: targetId,
      auto_play: true
    })
    root.activatePlayer(targetId)
  }

  function playUri(playerId, uri) {
    if (!uri) return
    root.actionForPlayer(playerId, "player_queues/play_media", {
      media: uri,
      // "replace" clears the queue first. "play" inserts at the current spot and
      // keeps the rest, so after the pick ends the queue resumes whatever was
      // there, and an endless radio stream (SiriusXM) then plays forever.
      option: "replace"
    })
    root.refreshState()
  }

  function playIndex(playerId, index) {
    root.actionForPlayer(playerId, "player_queues/play_index", { index: index })
    root.refreshState()
  }

  function deleteQueueItem(playerId, itemId) {
    root.actionForPlayer(playerId, "player_queues/delete_item", { item_id_or_index: itemId })
    root.refreshState()
  }

  function clearQueue(playerId) {
    root.actionForPlayer(playerId, "player_queues/clear")
    root.refreshState()
  }

  function search(query) {
    if (!query) return
    root.searchQuery = query
    // Uncached searches across every provider can take 10 s; allow 30.
    searchRequest.send(root.api("music/search", {
      search_query: query,
      limit: root.config.searchLimit || 20,
      media_types: ["track", "album", "artist", "playlist", "radio", "podcast", "audiobook"]
    }, "search-" + Date.now(), "30"))
  }

  function clearSearch() {
    root.searchResults = null
    root.searchQuery = ""
  }

  function mapItems(list, max) {
    return MaApi.boundedArray(Array.isArray(list) ? list : [], max)
      .map(function(it) { return MaApi.mapMediaItem(it, root.config.url) })
      .filter(function(x) { return x !== null })
  }

  MaRequest {
    id: searchRequest
    label: "search"
    onFinished: function(data) {
      if (!data || typeof data !== "object") return
      root.searchResults = {
        tracks: root.mapItems(data.tracks, MaApi.MAX_SEARCH_TRACKS),
        albums: root.mapItems(data.albums, MaApi.MAX_SEARCH_ALBUMS),
        artists: root.mapItems(data.artists, MaApi.MAX_SEARCH_ARTISTS),
        playlists: root.mapItems(data.playlists, MaApi.MAX_SEARCH_PLAYLISTS),
        radio: root.mapItems(data.radio, MaApi.MAX_SEARCH_TRACKS),
        podcasts: root.mapItems(data.podcasts, MaApi.MAX_SEARCH_ALBUMS),
        audiobooks: root.mapItems(data.audiobooks, MaApi.MAX_SEARCH_ALBUMS)
      }
      root.searchRevision = root.searchRevision + 1
    }
  }

  // Favorites are library items flagged favorite, fetched per media
  // controller one after another (there is no single favorites listing).
  readonly property var favoriteTypes: ["tracks", "albums", "artists", "playlists", "radio"]

  function refreshFavorites() {
    if (!root.ready) return
    root.fetchFavorites(0)
  }

  function fetchFavorites(index) {
    if (index >= root.favoriteTypes.length) return
    var type = root.favoriteTypes[index]
    var controller = type === "radio" ? "radios" : type
    favoritesRequest.send(root.api("music/" + controller + "/library_items", { limit: 50, favorite: true }, "fav-" + type),
      { type: type, index: index })
  }

  MaRequest {
    id: favoritesRequest
    label: "favorites"
    onFinished: function(data, ctx) {
      var next = Object.assign({}, root.favorites)
      next[ctx.type] = root.mapItems(data, MaApi.MAX_FAVORITES_PER_TYPE)
      root.favorites = next
      root.favoritesRevision = root.favoritesRevision + 1
      root.fetchFavorites(ctx.index + 1)
    }
  }

  function refreshPlaylists() {
    if (!root.ready) return
    playlistsRequest.send(root.api("music/playlists/library_items", { limit: 100 }, "playlists"))
  }

  MaRequest {
    id: playlistsRequest
    label: "playlists"
    onFinished: function(data) {
      root.playlists = root.mapItems(data, MaApi.MAX_PLAYLISTS)
      root.playlistsRevision = root.playlistsRevision + 1
    }
  }

  function refreshRecent() {
    if (!root.ready) return
    recentRequest.send(root.api("music/recently_played_items", { limit: root.config.recentLimit || 50 }, "recent"))
  }

  MaRequest {
    id: recentRequest
    label: "recent"
    onFinished: function(data) {
      root.recentItems = MaApi.boundedArray(Array.isArray(data) ? data : [], MaApi.MAX_RECENT_ITEMS).map(function(it) {
        var m = MaApi.mapMediaItem(it, root.config.url)
        if (m) m.last_played = typeof it.last_played === "number" ? it.last_played : null
        return m
      }).filter(function(x) { return x !== null })
      root.recentRevision = root.recentRevision + 1
    }
  }

  // Seconds; player_queues/seek takes `position` in seconds.
  function seek(playerId, positionSeconds) {
    var pid = playerId || root.activePlayerId
    if (!pid) return
    var p = Math.max(0, Math.round(positionSeconds))
    root.actionForPlayer(pid, "player_queues/seek", { position: p })
    root.queueElapsedBase = p
    root.queueElapsedAtMs = Date.now()
  }

  function seekRelative(deltaSeconds) {
    root.seek(root.activePlayerId, root.activeElapsed + deltaSeconds)
  }

  // Shuffle and repeat are queue state (applyQueueInfo), so these act on
  // the active player's queue.
  function toggleShuffle() {
    if (!root.activePlayerId) return
    var next = !root.shuffleEnabled
    root.actionForPlayer(root.activePlayerId, "player_queues/shuffle", { shuffle_enabled: next })
    root.shuffleEnabled = next
  }

  function cycleRepeat() {
    if (!root.activePlayerId) return
    var next = root.repeatMode === "off" ? "all" : (root.repeatMode === "all" ? "one" : "off")
    root.actionForPlayer(root.activePlayerId, "player_queues/repeat", { repeat_mode: next })
    root.repeatMode = next
  }

  function power(playerId, on) {
    var pid = playerId || root.activePlayerId
    root.runAction("players/cmd/power", { player_id: pid, powered: !!on })
  }

  function addFavorite(uri) {
    if (!uri) return
    root.runAction("music/favorites/add_item", { item: uri })
    root.refreshFavorites()
  }

  // Takes a mapped library item (media_type + item_id); the API wants
  // media_type and library_item_id, not a uri.
  function removeFavorite(item) {
    if (!item || !item.media_type || !item.item_id) return
    root.runAction("music/favorites/remove_item", { media_type: item.media_type, library_item_id: item.item_id }, function() {
      root.refreshFavorites()
    })
  }

  function removeFavoriteByUri(uri) {
    var m = /^library:\/\/([a-z_]+)\/(\d+)$/.exec(String(uri || ""))
    if (!m) return
    root.removeFavorite({ media_type: m[1], item_id: m[2] })
  }

  function favoriteCurrent() {
    var pid = root.activePlayerId
    if (!pid || !root.hasMedia) return
    // Lets the server resolve the item, including the live track behind a
    // radio stream, instead of favoriting the station uri.
    root.runAction("players/add_currently_playing_to_favorites", { player_id: pid }, function() {
      root.refreshFavorites()
    })
    root.currentFavorite = true
    root.showOsd("Favorited", "favorite", root.activeTitle)
  }

  // Open the web UI (openWebUiPath, else the server url) in the default
  // browser; argv form, no shell, http(s) only.
  function openWebUI() {
    var url = root.config.openWebUiPath && root.config.openWebUiPath.length > 0
      ? root.config.openWebUiPath : root.config.url
    if (!/^https?:\/\//.test(String(url || ""))) return
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }

  function saveQueueAsPlaylist(name) {
    if (!name || !root.queue || root.queue.length === 0) return
    root.runAction("player_queues/save_as_playlist", { queue_id: root.activePlayerId, name: String(name) }, function() {
      root.refreshPlaylists()
    })
    root.showOsd("Saved", "playlist", "Queue saved as \"" + name + "\"")
  }

  // ------------------------------------------------------- queue options

  function stop(playerId) {
    root.actionForPlayer(playerId, "player_queues/stop")
    root.showOsd("Stop", "media-stop", root.activeTitle || "Music Assistant")
  }

  function skip(seconds) {
    if (!root.activePlayerId) return
    root.actionForPlayer(root.activePlayerId, "player_queues/skip", { seconds: Math.round(seconds) })
    root.queueElapsedBase = Math.max(0, root.activeElapsed + seconds)
    root.queueElapsedAtMs = Date.now()
  }

  function setCrossfade(on) {
    if (!root.activePlayerId) return
    root.actionForPlayer(root.activePlayerId, "player_queues/crossfade", { crossfade_enabled: !!on })
    root.crossfadeEnabled = !!on
  }

  function setAutoplay(on) {
    if (!root.activePlayerId) return
    root.actionForPlayer(root.activePlayerId, "player_queues/autoplay", { autoplay_enabled: !!on })
    root.autoplayEnabled = !!on
  }

  function setDontStopTheMusic(on) {
    if (!root.activePlayerId) return
    root.actionForPlayer(root.activePlayerId, "player_queues/dont_stop_the_music", { dont_stop_the_music_enabled: !!on })
    root.dontStopTheMusicEnabled = !!on
  }

  // Sleep timer on the active player; seconds <= 0 clears it.
  function setSleepTimer(seconds) {
    var pid = root.activePlayerId
    if (!pid) return
    if (seconds > 0) {
      root.runAction("players/sleep_timer/set", { player_id: pid, seconds: Math.round(seconds) })
      root.showOsd("Sleep timer", "media-pause", "Stops in " + Math.round(seconds / 60) + " min")
    } else {
      root.runAction("players/sleep_timer/clear", { player_id: pid })
      root.showOsd("Sleep timer", "media-pause", "Cleared")
    }
  }

  // ---------------------------------------------------------- queue edits

  function moveQueueItem(itemId, shift) {
    if (!itemId || !shift) return
    root.actionForPlayer(root.activePlayerId, "player_queues/move_item", { queue_item_id: itemId, pos_shift: shift })
  }

  function moveQueueItemEnd(itemId) {
    if (!itemId) return
    root.actionForPlayer(root.activePlayerId, "player_queues/move_item_end", { queue_item_id: itemId })
  }

  // option: "next" (after the current item) or "add" (end of the queue).
  function enqueue(uri, option, label) {
    if (!uri) return
    var opt = option === "next" ? "next" : "add"
    root.actionForPlayer(root.activePlayerId, "player_queues/play_media", { media: uri, option: opt })
    root.showOsd(opt === "next" ? "Playing next" : "Added to queue", "playlist", label || uri)
  }

  // ------------------------------------------------------------ grouping
  // Grouping is always relative to the active player: other players join
  // it or leave it. The server validates against can_group_with.

  function isGroupedWithActive(playerId) {
    var a = root.activePlayer
    if (!a || !playerId || playerId === a.player_id) return false
    if (a.group_members && a.group_members.indexOf(playerId) !== -1) return true
    var p = root.playerById(playerId)
    return !!p && (p.synced_to === a.player_id || p.active_group === a.player_id)
  }

  function canGroupWithActive(playerId) {
    var a = root.activePlayer
    return !!a && !!playerId && playerId !== a.player_id && Array.isArray(a.can_group_with) && a.can_group_with.indexOf(playerId) !== -1
  }

  function groupAdd(childId) {
    var target = root.activePlayerId
    if (!target || !childId || childId === target) return
    var child = root.playerById(childId)
    root.runAction("players/cmd/set_members", { target_player: target, player_ids_to_add: [childId] })
    root.showOsd("Grouped", "speaker", (child ? child.name : childId) + " joins " + (root.activePlayer ? root.activePlayer.name : "the group"))
  }

  function groupRemove(childId) {
    var target = root.activePlayerId
    if (!target || !childId) return
    var child = root.playerById(childId)
    root.runAction("players/cmd/set_members", { target_player: target, player_ids_to_remove: [childId] })
    root.showOsd("Ungrouped", "speaker", (child ? child.name : childId) + " leaves the group")
  }

  function ungroup(playerId) {
    var pid = playerId || root.activePlayerId
    if (!pid) return
    root.runAction("players/cmd/ungroup", { player_id: pid })
    root.showOsd("Ungrouped", "speaker", (root.playerById(pid) || {}).name || "")
  }

  // -------------------------------------------------------------- browse
  // music/browse walks the provider tree: no path lists the providers, a
  // folder's `path` lists its children (the first child ".." points back up
  // and is dropped; the popup keeps its own stack instead).

  property var browseItems: []
  property var browseStack: []
  property string browsePath: ""
  property string browseName: "Music Assistant"
  property bool browseLoading: false
  property int browseRevision: 0

  function browseRoot() {
    root.browseStack = []
    root.browse("", "Music Assistant")
  }

  function browse(path, name) {
    if (!root.ready) return
    root.browseLoading = true
    browseRequest.send(root.api("music/browse", path ? { path: path } : {}, "browse-" + Date.now(), "30"),
      { path: path || "", name: name || "Music Assistant" })
  }

  function browseInto(item) {
    if (!item) return
    var stack = root.browseStack.slice()
    stack.push({ path: root.browsePath, name: root.browseName })
    root.browseStack = stack
    root.browse(item.path || item.uri, item.name)
  }

  function browseBack() {
    if (root.browseStack.length === 0) return
    var stack = root.browseStack.slice()
    var prev = stack.pop()
    root.browseStack = stack
    root.browse(prev.path, prev.name)
  }

  MaRequest {
    id: browseRequest
    label: "browse"
    onFinished: function(data, ctx) {
      var list = Array.isArray(data) ? data : []
      root.browseItems = root.mapItems(list.filter(function(it) {
        return it && it.name !== ".." && !(it.media_type === "folder" && it.path === "root")
      }), MaApi.MAX_QUEUE_ITEMS)
      root.browsePath = ctx.path
      root.browseName = ctx.name
      root.browseRevision = root.browseRevision + 1
      root.browseLoading = false
    }
  }

  // ------------------------------------------------- collection drill-down
  // Tracks of a playlist, album or artist, shown inside the Lists tab with
  // a Back button.

  property var drillItems: []
  property var drillItem: null
  property bool drillLoading: false
  property int drillRevision: 0

  function openCollection(item) {
    if (!item || !item.item_id || !item.provider) return false
    var cmd = item.media_type === "playlist" ? "music/playlists/playlist_tracks"
      : item.media_type === "album" ? "music/albums/album_tracks"
      : item.media_type === "artist" ? "music/artists/artist_tracks"
      : ""
    if (!cmd) return false
    root.drillItem = item
    root.drillItems = []
    root.drillLoading = true
    drillRequest.send(root.api(cmd, { item_id: item.item_id, provider_instance_id_or_domain: item.provider }, "drill-" + Date.now(), "30"))
    return true
  }

  function closeCollection() {
    root.drillItem = null
    root.drillItems = []
    root.drillLoading = false
  }

  MaRequest {
    id: drillRequest
    label: "collection"
    onFinished: function(data) {
      root.drillItems = root.mapItems(data, MaApi.MAX_QUEUE_ITEMS)
      root.drillRevision = root.drillRevision + 1
      root.drillLoading = false
    }
  }

  // Add a track to one of the library's own playlists (provider "library").
  function addToPlaylist(playlistItem, uri, label) {
    if (!playlistItem || playlistItem.provider !== "library" || !uri) {
      root.showOsd("Music Assistant", "dialog-warning", "Only library playlists can be edited here")
      return
    }
    root.runAction("music/playlists/add_playlist_tracks", { db_playlist_id: playlistItem.item_id, uris: [uri] })
    root.showOsd("Added to playlist", "playlist", (label || "Track") + " → " + playlistItem.name)
  }

  function addCurrentToPlaylist(playlistItem) {
    var uri = root.queueInfo && root.queueInfo.current_item ? root.queueInfo.current_item.uri : (root.activeMedia ? root.activeMedia.uri : "")
    root.addToPlaylist(playlistItem, uri, root.activeTitle)
  }

  // ---------------------------------------------------------------- IPC

  IpcHandler {
    target: root.ipcTarget

    function status(): string {
      return JSON.stringify({
        ready: root.ready,
        connected: root.connected,
        lastError: root.lastError,
        configError: root.configError,
        activePlayerId: root.activePlayerId,
        activePlayerName: root.activePlayer ? root.activePlayer.name : "",
        isPlaying: root.isPlaying,
        title: root.activeTitle,
        artist: root.activeArtist,
        album: root.activeAlbum,
        imageUrl: root.activeImageUrl,
        volume: root.activeVolume,
        muted: root.activePlayer ? !!root.activePlayer.volume_muted : false,
        playerCount: root.players.length,
        queueLength: root.queue.length,
        shuffle: root.shuffleEnabled,
        repeat: root.repeatMode,
        elapsed: root.activeElapsed,
        duration: root.activeDuration,
        pollingActive: root.pollingActive,
        queueState: root.queueState,
        queueIndex: root.queuePosition,
        crossfade: root.crossfadeEnabled,
        autoplay: root.autoplayEnabled,
        currentFavorite: root.currentFavorite
      })
    }

    function playPause(): string {
      root.playPause()
      return "ok"
    }

    function nextTrack(): string {
      root.next()
      return "ok"
    }

    function previousTrack(): string {
      root.previous()
      return "ok"
    }

    function setVolumePct(percent: real): string {
      root.setVolume(root.activePlayerId, percent)
      return "ok"
    }

    // Called by scripts/contextual-volume-control while the active player
    // is playing.
    function volumeUp(): string {
      root.adjustVolume(root.activePlayerId, 5)
      return "ok"
    }

    function volumeDown(): string {
      root.adjustVolume(root.activePlayerId, -5)
      return "ok"
    }

    function toggleMute(): string {
      root.toggleMute(root.activePlayerId)
      return "ok"
    }

    function activatePlayerById(playerId: string): string {
      root.activatePlayer(playerId)
      return "ok"
    }

    function transferQueueTo(targetId: string): string {
      root.transferQueue(root.activePlayerId, targetId)
      return "ok"
    }

    function playUri(uri: string): string {
      root.playUri(root.activePlayerId, uri)
      return "ok"
    }

    function playUriOn(playerId: string, uri: string): string {
      root.playUri(playerId, uri)
      return "ok"
    }

    function search(q: string): string {
      root.search(q)
      return "ok"
    }

    function clearQueueNow(): string {
      root.clearQueue(root.activePlayerId)
      return "ok"
    }

    function refresh(): string {
      root.refreshState()
      return "ok"
    }

    function playersList(): string {
      var list = []
      for (var i = 0; i < root.players.length; i++) {
        var p = root.players[i]
        list.push({
          id: p.player_id,
          name: p.name,
          available: p.available,
          playing: p.playback_state === "playing",
          paused: p.playback_state === "paused",
          volume: MaApi.volumePercent(p),
          muted: !!p.volume_muted,
          title: MaApi.trackTitle(p.current_media),
          artist: MaApi.trackArtist(p.current_media),
          imageUrl: MaApi.trackImageUrl(p.current_media)
        })
      }
      return JSON.stringify(list)
    }

    function seek(positionSeconds: real): string {
      root.seek(root.activePlayerId, positionSeconds)
      return "ok"
    }

    function seekRelative(deltaSeconds: real): string {
      root.seekRelative(deltaSeconds)
      return "ok"
    }

    function toggleShuffle(): string {
      root.toggleShuffle()
      return "ok"
    }

    function cycleRepeat(): string {
      root.cycleRepeat()
      return "ok"
    }

    function power(action: string): string {
      root.power(root.activePlayerId, action === "on")
      return "ok"
    }

    function favoriteCurrent(): string {
      root.favoriteCurrent()
      return "ok"
    }

    function favoriteAdd(uri: string): string {
      root.addFavorite(uri)
      return "ok"
    }

    function favoriteRemove(uri: string): string {
      root.removeFavoriteByUri(uri)
      return "ok"
    }

    function saveQueue(name: string): string {
      root.saveQueueAsPlaylist(name)
      return "ok"
    }

    function openWebUI(): string {
      root.openWebUI()
      return "ok"
    }

    function refreshFavorites(): string {
      root.refreshFavorites()
      return "ok"
    }

    function refreshPlaylists(): string {
      root.refreshPlaylists()
      return "ok"
    }

    function refreshRecent(): string {
      root.refreshRecent()
      return "ok"
    }

    function stop(): string {
      root.stop(root.activePlayerId)
      return "ok"
    }

    // "on" / "off" install or remove the Hyprland media-key block; anything
    // else just reports the current state.
    function mediaKeys(action: string): string {
      if (action === "on") root.setMediaKeysEnabled(true)
      else if (action === "off") root.setMediaKeysEnabled(false)
      return root.mediaKeysEnabled ? "on" : "off"
    }

    function skipSeconds(seconds: real): string {
      root.skip(seconds)
      return "ok"
    }

    function toggleCrossfade(): string {
      root.setCrossfade(!root.crossfadeEnabled)
      return "ok"
    }

    function toggleAutoplay(): string {
      root.setAutoplay(!root.autoplayEnabled)
      return "ok"
    }

    // minutes <= 0 clears the timer.
    function sleepTimer(minutes: real): string {
      root.setSleepTimer(minutes * 60)
      return "ok"
    }

    function enqueueUri(uri: string, option: string): string {
      root.enqueue(uri, option, uri)
      return "ok"
    }

    function groupJoin(playerId: string): string {
      root.groupAdd(playerId)
      return "ok"
    }

    function groupLeave(playerId: string): string {
      root.groupRemove(playerId)
      return "ok"
    }

    function browse(path: string): string {
      if (path === "") root.browseRoot()
      else root.browse(path, path)
      return "ok"
    }

    function browseSnapshot(): string {
      return JSON.stringify({ path: root.browsePath, name: root.browseName, depth: root.browseStack.length, loading: root.browseLoading, count: root.browseItems.length, items: root.browseItems.slice(0, 5) })
    }

    // Counts plus the first row of every list, for scripts and debugging.
    function listsSnapshot(): string {
      function head(a) { return Array.isArray(a) && a.length > 0 ? a[0] : null }
      var fav = {}
      for (var k in root.favorites) fav[k] = { count: (root.favorites[k] || []).length, first: head(root.favorites[k]) }
      var sr = {}
      if (root.searchResults) for (var sk in root.searchResults) sr[sk] = { count: (root.searchResults[sk] || []).length, first: head(root.searchResults[sk]) }
      return JSON.stringify({
        queue: { count: root.queue.length, position: root.queuePosition, first: head(root.queue) },
        queueInfo: root.queueInfo,
        favorites: fav,
        playlists: { count: root.playlists.length, first: head(root.playlists) },
        recent: { count: root.recentItems.length, first: head(root.recentItems) },
        search: { query: root.searchQuery, results: sr }
      })
    }
  }
}