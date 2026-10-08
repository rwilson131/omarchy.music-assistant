import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import "MaApi.js" as MaApi
import "ConfigSchema.js" as ConfigSchema

Item {
  id: root

  property var shell: null

  // --------------------------------------------------------------- config
  property var config: ({})
  property string configError: ""
  property bool ready: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginId: "io.github.manologarciadev.music-assistant"
  readonly property string configPath: home + "/.config/omarchy/plugins/" + pluginId + "/config.json"

  // ---------------------------------------------------------------- state
  property var players: []
  property string activePlayerId: ""
  property var queue: []
  property int queuePosition: 0
  property int queueRevision: 0
  // From player_queues/get for the active player. The queue, not the player,
  // owns shuffle/repeat/crossfade/autoplay and the current index; items
  // responses never carried current_item_index, so the queue tab always
  // highlighted row 0 before.
  property var queueInfo: null
  property bool crossfadeEnabled: false
  property bool autoplayEnabled: false
  property bool dontStopTheMusicEnabled: false
  property string queueState: "idle"
  property real queueElapsedBase: 0
  property real queueElapsedAtMs: 0
  property bool currentFavorite: false
  // Bumped once a second while something plays so elapsed-time bindings
  // re-evaluate between the two-second polls.
  property int nowTick: 0
  property var searchResults: null
  property string searchQuery: ""
  property string lastError: ""
  property bool connected: false
  property int revision: 0

  // --------------------------------------------------------------- mpris
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var activeMprisPlayer: root.pickActiveMprisPlayer()

  function pickActiveMprisPlayer() {
    var oldest = null
    var oldestOrder = 0
    var playingProxy = null
    var proxyOrder = 0
    for (var i = 0; i < root.mprisPlayers.length; i++) {
      var p = root.mprisPlayers[i]
      if (!p || !p.isPlaying) continue
      var dbusName = String(p.dbusName || "").toLowerCase()
      var isProxy = dbusName.indexOf("playerctld") !== -1
      var order = i + 1000
      if (!isProxy && (!oldest || order < oldestOrder)) {
        oldest = p
        oldestOrder = order
      } else if (isProxy && (!playingProxy || order < proxyOrder)) {
        playingProxy = p
        proxyOrder = order
      }
    }
    return oldest || playingProxy || null
  }

  function mprisRoutingEnabled() {
    return root.config && root.config.mprisFallback !== false
  }
  property string preferredPlayerId: ""
  property var favorites: ({ tracks: [], albums: [], artists: [], playlists: [], radio: [] })
  property int favoritesRevision: 0
  property var _favTypes: []
  property int _favIndex: 0
  property var playlists: []
  property int playlistsRevision: 0
  property var recentItems: []
  property int recentRevision: 0

  readonly property int pollIntervalMs: {
    var v = config && config.pollIntervalMs ? config.pollIntervalMs : 2000
    return Math.max(500, v)
  }

  readonly property var activePlayer: {
    if (!players || players.length === 0) return null
    for (var i = 0; i < players.length; i++) {
      if (players[i].player_id === activePlayerId) return players[i]
    }
    return null
  }

  readonly property var activeMedia: {
    var p = activePlayer
    return p && p.current_media ? p.current_media : null
  }

  readonly property bool hasMedia: activeMedia !== null && (activeMedia.title || activeMedia.uri)

  readonly property bool isPlaying: MaApi.isPlaying(activePlayer)
  readonly property bool isPaused: MaApi.isPaused(activePlayer)
  readonly property int activeVolume: MaApi.volumePercent(activePlayer)
  readonly property string activeTitle: MaApi.trackTitle(activeMedia)
  readonly property string activeArtist: MaApi.trackArtist(activeMedia)
  readonly property string activeAlbum: MaApi.trackAlbum(activeMedia)
  readonly property string activeImageUrl: MaApi.trackImageUrl(activeMedia)
  // Seconds. PlayerMedia.duration / elapsed_time and PlayerQueue.elapsed_time
  // are all seconds in the 2.10 API; the old code fed them to a formatter
  // that expected milliseconds and showed 0:00 forever.
  readonly property int activeDuration: {
    if (activeMedia && typeof activeMedia.duration === "number" && activeMedia.duration > 0) return Math.round(activeMedia.duration)
    if (queueInfo && queueInfo.current_item && typeof queueInfo.current_item.duration === "number") return Math.round(queueInfo.current_item.duration)
    return 0
  }
  readonly property int activeElapsed: {
    var _t = nowTick
    if (!queueInfo) return activeMedia && activeMedia.elapsed_time ? Math.round(activeMedia.elapsed_time) : 0
    var e = queueElapsedBase
    if (queueState === "playing" && queueElapsedAtMs > 0) e += (Date.now() - queueElapsedAtMs) / 1000
    if (activeDuration > 0) e = Math.min(e, activeDuration)
    return Math.max(0, Math.round(e))
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.ready && root.queueState === "playing"
    onTriggered: root.nowTick = root.nowTick + 1
  }

  // ---------------------------------------------------------------- config loader

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: root.applyConfig(text())
    onLoadFailed: function(err) {
      root.configError = "config.json missing or unreadable"
      root.config = ({})
      root.ready = false
    }
  }

  Component.onCompleted: {
    if (configFile) configFile.reload()
    Qt.callLater(function() {
      installMediaKeysBindings()
    })
  }

  // --------------------------------------------------- media keys installer

  readonly property string mediaKeysMarkerBegin: "-- BEGIN music-assistant media-keys"
  readonly property string mediaKeysMarkerEnd: "-- END music-assistant media-keys"
  readonly property string ipcTarget: root.pluginId

  function mediaKeysBindingsBlock() {
    var qsBin = "/usr/bin/qs"
    var omarchyShell = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
    var ipcCmd = qsBin + " -p " + omarchyShell + " ipc call " + root.pluginId
    return [
      "",
      mediaKeysMarkerBegin,
      "hl.unbind(\"XF86AudioNext\")",
      "hl.unbind(\"XF86AudioPrev\")",
      "hl.unbind(\"XF86AudioPlay\")",
      "hl.unbind(\"XF86AudioPause\")",
      // The installed block also takes the volume keys. To route them to the
      // laptop while Music Assistant is idle instead, set installMediaKeys to
      // false and bind them to scripts/contextual-volume-control.
      "hl.unbind(\"XF86AudioRaiseVolume\")",
      "hl.unbind(\"XF86AudioLowerVolume\")",
      "hl.unbind(\"XF86AudioMute\")",
      "o.bind(\"XF86AudioNext\", \"Music next\", \"" + ipcCmd + " nextTrack\", { locked = true })",
      "o.bind(\"XF86AudioPrev\", \"Music previous\", \"" + ipcCmd + " previousTrack\", { locked = true })",
      "o.bind(\"XF86AudioPlay\", \"Music play/pause\", \"" + ipcCmd + " playPause\", { locked = true })",
      "o.bind(\"XF86AudioPause\", \"Music play/pause\", \"" + ipcCmd + " playPause\", { locked = true })",
      "o.bind(\"XF86AudioRaiseVolume\", \"Music volume up\", \"" + ipcCmd + " volumeUp\", { locked = true, repeating = true })",
      "o.bind(\"XF86AudioLowerVolume\", \"Music volume down\", \"" + ipcCmd + " volumeDown\", { locked = true, repeating = true })",
      "o.bind(\"XF86AudioMute\", \"Music mute\", \"" + ipcCmd + " toggleMute\", { locked = true })",
      mediaKeysMarkerEnd,
      ""
    ].join("\n")
  }

  function installMediaKeysBindings() {
    if (!root.ready) return
    if (root.config && root.config.installMediaKeys === false) return

    mediaKeysInstaller.running = true
  }

  readonly property string mediaKeysInstallScript: {
    var hyprConfig = Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    var block = root.mediaKeysBindingsBlock().replace(/'/g, "'\\''")
    return "set -e\n" +
      "F=\"" + hyprConfig + "\"\n" +
      "if [ ! -f \"$F\" ]; then exit 0; fi\n" +
      "if grep -qF -e '" + root.mediaKeysMarkerBegin + "' \"$F\"; then exit 0; fi\n" +
      "touch \"$F\"\n" +
      "if [ -s \"$F\" ] && [ -n \"$(tail -c 1 \"$F\")\" ]; then echo >> \"$F\"; fi\n" +
      "printf '%s\\n' '" + block + "' >> \"$F\"\n" +
      "hyprctl reload >/dev/null 2>&1 || true\n" +
      // Exit 42 = we just installed (caller shows first-run OSD)
      "exit 42\n"
  }

  Process {
    id: mediaKeysInstaller
    command: [Quickshell.env("SHELL") || "/bin/bash", "-c", root.mediaKeysInstallScript]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        console.log("[music-assistant] Media key bindings: nothing to do (already installed)")
      } else if (exitCode === 42) {
        console.log("[music-assistant] Media key bindings installed (first run)")
        root.showOsd(
          "Media keys enabled",
          "media-play",
          "XF86AudioPlay/Pause/Next/Prev now control Music Assistant. " +
          "Revert by removing the music-assistant media-keys block in ~/.config/hypr/bindings.lua."
        )
      } else {
        console.warn("[music-assistant] Failed to install media key bindings: exitCode=" + exitCode)
      }
    }
  }

  // --------------------------------------------------- config persistence

  Process {
    id: configSaver
    property string savePath: ""
    property string saveJson: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        console.log("[music-assistant] Config persisted to " + savePath)
      } else {
        console.warn("[music-assistant] Failed to persist config (exit=" + exitCode + ")")
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
    root.preferredPlayerId = result.config.preferredPlayerId || ""
    root.ready = result.error.length === 0
    root.configError = result.error
    if (root.ready) {
      root.startConnection()
      Qt.callLater(function() { root.installMediaKeysBindings() })
    } else {
      root.stopConnection()
      root.configError = result.error || "invalid config"
    }
  }

  // --------------------------------------------------------------- polling

  property bool pollingActive: false
  property bool pollInFlight: false
  property bool shuffleEnabled: false
  property string repeatMode: "off"
  property int elapsed: 0
  property int duration: 0
  property var _lastSuccessAt: 0

  Timer {
    id: pollTimer
    interval: root.config && root.config.pollIntervalMs ? root.config.pollIntervalMs : 2000
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

  function refreshIfStale(maxAgeMs) {
    if (!root.ready) return
    var age = Date.now() - (root._lastSuccessAt || 0)
    if (age < maxAgeMs) return
    root.refreshState()
  }

  function runMaRequest(proc, payload) {
    if (!payload) return
    proc.authToken = payload.token || ""
    proc.command = [Quickshell.env("SHELL") || "/bin/bash", "-c", payload.script]
    proc.running = true
  }

  function runFetchPlayers() {
    if (!root.ready) { root.pollInFlight = false; return }
    var payload = MaApi.buildArgs(root.config.url, root.config.token, "players/all", {}, "poll-players")
    root.runMaRequest(playersProc, payload)
  }

  function runFetchQueueInfo(playerId) {
    if (!root.ready || !playerId) { root.pollInFlight = false; return }
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "player_queues/get", { queue_id: playerId }, "poll-queue-info")
    root.runMaRequest(queueInfoProc, payload)
  }

  function runFetchQueue(playerId) {
    if (!root.ready || !playerId) { root.pollInFlight = false; return }
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "player_queues/items",
      { queue_id: playerId, limit: 200, offset: 0 },
      "poll-queue")
    root.runMaRequest(queueProc, payload)
  }

  Process {
    id: queueInfoProc
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(queueInfoProc.stdout.text || "{}"))
          root.applyQueueInfo(payload && payload.result !== undefined ? payload.result : payload)
        } catch (e) {
          root.lastError = "queue info parse: " + e.message
        }
        root.runFetchQueue(root.activePlayerId)
      }
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
      items: typeof q.items === "number" ? q.items : 0,
      current_index: typeof q.current_index === "number" ? q.current_index : 0,
      state: MaApi.boundedString(q.state, 20),
      current_item: cur ? {
        queue_item_id: MaApi.boundedString(cur.queue_item_id, 100),
        name: MaApi.boundedString(cur.name, 500),
        duration: typeof cur.duration === "number" ? cur.duration : 0,
        uri: MaApi.boundedString(cur.media_item ? cur.media_item.uri : "", 2048),
        media_type: MaApi.boundedString(cur.media_item ? cur.media_item.media_type : "", 50),
        favorite: !!(cur.media_item && cur.media_item.favorite === true)
      } : null,
      next_name: q.next_item && q.next_item.name ? MaApi.boundedString(q.next_item.name, 500) : ""
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

  Process {
    id: playersProc
    property string outputText: ""
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = playersProc.stdout.text
        try {
          var payload = JSON.parse(String(text || "{}"))
          root.applyPlayers(payload.result || payload)
        } catch (e) {
          root.lastError = "players parse: " + e.message
        }
        var chosen = root.pickNextActivePlayer()
        if (chosen && chosen !== root.activePlayerId) {
          root.activePlayerId = chosen
        }
        root.runFetchQueueInfo(root.activePlayerId)
      }
    }
    onExited: {
      if (root.pollInFlight && root.lastError === "") {
        // queue fetch will reset pollInFlight
      } else if (root.pollInFlight) {
        root.pollInFlight = false
      }
    }
  }

  Process {
    id: queueProc
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(queueProc.stdout.text || "{}"))
          root.applyQueue(payload.result || payload)
        } catch (e) {
          root.lastError = "queue parse: " + e.message
        }
        root.pollInFlight = false
      }
    }
  }

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
        shuffle_enabled: !!p.shuffle_enabled,
        repeat_mode: MaApi.boundedString(p.repeat_mode, 20),
        current_media: p.current_media || null,
        group_members: Array.isArray(p.group_members) ? MaApi.boundedArray(p.group_members, 32).map(function(g) { return MaApi.boundedString(g, 100) }) : [],
        can_group_with: Array.isArray(p.can_group_with) ? MaApi.boundedArray(p.can_group_with, 64).map(function(g) { return MaApi.boundedString(g, 100) }) : [],
        hide_in_ui: !!p.hide_in_ui,
        synced_to: MaApi.boundedString(p.synced_to, 100),
        active_group: MaApi.boundedString(p.active_group, 100),
        active_source: MaApi.boundedString(p.active_source, 200),
        type: MaApi.boundedString(p.type, 20),
        provider: MaApi.boundedString(p.provider, 100),
        group_volume: typeof p.group_volume === "number" ? Math.max(0, Math.min(100, p.group_volume)) : null,
        sleep_timer_expires_at: typeof p.sleep_timer_expires_at === "number" ? p.sleep_timer_expires_at : 0,
        power_control: MaApi.boundedString(p.power_control, 50),
        supported_features: Array.isArray(p.supported_features) ? MaApi.boundedArray(p.supported_features, 32).map(function(f) { return MaApi.boundedString(f, 50) }) : [],
        source_list: Array.isArray(p.source_list) ? MaApi.boundedArray(p.source_list, 16).map(function(src) {
          return { id: MaApi.boundedString(src && src.id, 100), name: MaApi.boundedString(src && src.name, 100), passive: !!(src && src.passive) }
        }) : []
      }
    })
    root.players = bounded
    root.revision = root.revision + 1
    root.connected = true
    root._lastSuccessAt = Date.now()
    root.lastError = ""
    root.updatePlayModeFromPlayer()
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

  function pickNextActivePlayer() {
    return MaApi.pickActivePlayerId(root.players, root.preferredPlayerId)
  }

  function refreshPlayersOnly() {
    if (!root.ready) return
    var payload = MaApi.buildArgs(root.config.url, root.config.token, "players/all", {}, "ws-players")
    root.runMaRequest(playersProc, payload)
  }

  function updatePlayModeFromPlayer() {
    // Shuffle and repeat live on the queue (see applyQueueInfo); nothing to
    // read from the player in 2.10.
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
    var payload = MaApi.buildPlayArgs(root.config.url, root.config.token, command, args)
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
      if (root.actionOnExited) root.actionOnExited(code, status)
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

  property var actionOnExited: null

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

  function actionForPlayer(playerId, command, args) {
    var pid = playerId || root.activePlayerId
    var a = args ? Object.assign({}, args) : {}
    a.queue_id = pid
    root.runAction(command, a)
  }

  function actionForSourceTarget(command, args) {
    root.runAction(command, args)
  }

  function playPause(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      var mp = root.activeMprisPlayer
      if (mp.isPlaying && mp.canPause) mp.pause()
      else if (mp.canPlay) mp.play()
      else if (mp.canTogglePlaying) mp.togglePlaying()
      return
    }
    if (!root.activePlayer && !playerId) return
    var pid = playerId || root.activePlayerId
    var isP = MaApi.isPlaying(root.playerById(pid))
    if (isP) {
      root.actionForPlayer(pid, "player_queues/pause")
    } else {
      root.actionForPlayer(pid, "player_queues/play")
    }
    root.showOsd(isP ? "Pause" : "Play", isP ? "media-pause" : "media-play",
      (MaApi.trackTitle(root.playerById(pid).current_media) || "Music Assistant"))
  }

  function next(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      if (root.activeMprisPlayer.canGoNext) root.activeMprisPlayer.next()
      return
    }
    root.actionForPlayer(playerId, "player_queues/next")
    root.showOsd("Next", "media-next", MaApi.trackTitle(root.playerById(playerId || root.activePlayerId).current_media))
  }

  function previous(playerId) {
    if (root.mprisRoutingEnabled() && root.activeMprisPlayer) {
      if (root.activeMprisPlayer.canGoPrevious) root.activeMprisPlayer.previous()
      return
    }
    root.actionForPlayer(playerId, "player_queues/previous")
    root.showOsd("Previous", "media-previous", MaApi.trackTitle(root.playerById(playerId || root.activePlayerId).current_media))
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
    // Fix: players/cmd/* commands take player_id. actionForPlayer() adds
    // queue_id instead, which Music Assistant rejected, so volume, mute and
    // power never reached the player.
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
    // player_id, not queue_id: see setVolume().
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

  function transferQueue(sourceId, targetId) {
    root.runAction("player_queues/transfer", {
      source_queue_id: sourceId || root.activePlayerId,
      target_queue_id: targetId,
      auto_play: true
    })
    root.preferredPlayerId = targetId
    root.activePlayerId = targetId
    if (root.config) {
      root.config.preferredPlayerId = targetId
      root.persistConfig()
    }
    root.refreshState()
  }

  function activatePlayer(playerId) {
    if (!root.playerById(playerId)) return
    root.preferredPlayerId = playerId
    root.activePlayerId = playerId
    if (root.config) {
      root.config.preferredPlayerId = playerId
      root.persistConfig()
    }
    root.refreshState()
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
    // The API parameter is item_id_or_index; queue_item_id was rejected.
    root.actionForPlayer(playerId, "player_queues/delete_item", { item_id_or_index: itemId })
    root.refreshState()
  }

  function clearQueue(playerId) {
    root.actionForPlayer(playerId, "player_queues/clear")
    root.refreshState()
  }

  function search(query, limit) {
    if (!query) return
    root.searchQuery = query
    var lim = limit || 20
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "music/search",
      { search_query: query, limit: lim, media_types: ["track", "album", "artist", "playlist", "radio", "podcast", "audiobook"] },
      // Uncached searches across every provider take 8-11 s on a Home
      // Assistant host; the default 10 s cap returned them as empty.
      "search-" + Date.now(), "30")
    root.runMaRequest(searchProc, payload)
  }

  function clearSearch() {
    root.searchResults = null
    root.searchQuery = ""
  }

  function _boundMediaItem(it) {
    return MaApi.mapMediaItem(it, root.config.url)
  }

  function _boundList(list, max) {
    return MaApi.boundedArray(Array.isArray(list) ? list : [], max).map(_boundMediaItem).filter(function(x) { return x !== null })
  }

  function _boundSearchResults(raw) {
    if (!raw || typeof raw !== "object") return null
    return {
      tracks: _boundList(raw.tracks, MaApi.MAX_SEARCH_TRACKS),
      albums: _boundList(raw.albums, MaApi.MAX_SEARCH_ALBUMS),
      artists: _boundList(raw.artists, MaApi.MAX_SEARCH_ARTISTS),
      playlists: _boundList(raw.playlists, MaApi.MAX_SEARCH_PLAYLISTS),
      radio: _boundList(raw.radio, MaApi.MAX_SEARCH_TRACKS),
      podcasts: _boundList(raw.podcasts, MaApi.MAX_SEARCH_ALBUMS),
      audiobooks: _boundList(raw.audiobooks, MaApi.MAX_SEARCH_ALBUMS)
    }
  }

  Process {
    id: searchProc
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(searchProc.stdout.text || "{}"))
          var bounded = _boundSearchResults(payload.result || payload)
          root.searchResults = bounded || root.searchResults
          root.searchRevision = root.searchRevision + 1
        } catch (e) {
          root.lastError = "search parse: " + e.message
        }
      }
    }
  }

  Process {
    id: favProc
    property string authToken: ""
    property string typeKey: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(favProc.stdout.text || "{}"))
          var list = payload.result || payload || []
          var bounded = MaApi.boundedArray(list, MaApi.MAX_FAVORITES_PER_TYPE).map(_boundMediaItem).filter(function(x) { return x !== null })
          var next = Object.assign({}, root.favorites)
          next[favProc.typeKey] = bounded
          root.favorites = next
          root.favoritesRevision = root.favoritesRevision + 1
        } catch (e) {
          root.lastError = "favorites parse: " + e.message
        }
        root._favFetchNext()
      }
    }
  }

  Process {
    id: playlistsProc
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(playlistsProc.stdout.text || "{}"))
          var list = Array.isArray(payload.result) ? payload.result : (Array.isArray(payload) ? payload : [])
          root.playlists = MaApi.boundedArray(list, MaApi.MAX_PLAYLISTS).map(_boundMediaItem).filter(function(x) { return x !== null })
          root.playlistsRevision = root.playlistsRevision + 1
        } catch (e) {
          root.lastError = "playlists parse: " + e.message
        }
      }
    }
  }

  Process {
    id: recentProc
    property string authToken: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var payload = JSON.parse(String(recentProc.stdout.text || "{}"))
          // The server answers with a bare list, not {result: [...]}.
          var list = Array.isArray(payload) ? payload : (Array.isArray(payload.result) ? payload.result : [])
          root.recentItems = MaApi.boundedArray(list, MaApi.MAX_RECENT_ITEMS).map(function(it) {
            var m = MaApi.mapMediaItem(it, root.config.url)
            if (!m) return null
            m.last_played = typeof it.last_played === "number" ? it.last_played : (typeof it.timestamp === "number" ? it.timestamp : null)
            return m
          }).filter(function(x) { return x !== null })
          root.recentRevision = root.recentRevision + 1
        } catch (e) {
          root.lastError = "recent parse: " + e.message
        }
      }
    }
  }

  Process {
    id: saveQueueProc
    property string authToken: ""
    property string phase: ""
    property string name: ""
    property string newPlaylistId: ""
    stdinEnabled: true
    onStarted: {
      if (authToken.length > 0) {
        write(authToken + "\n")
        authToken = ""
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (saveQueueProc.phase !== "create") {
          root.saveQueuePhase = ""
          root.saveQueueNewId = ""
          root.refreshPlaylists()
          return
        }
        try {
          var payload = JSON.parse(String(saveQueueProc.stdout.text || "{}"))
          var res = payload.result || payload
          var pid = res && res.item_id ? res.item_id : (res && res.uri ? res.uri.split("/").pop() : "")
          if (!pid) {
            root.saveQueuePhase = ""
            return
          }
          root.saveQueueNewId = pid
          var items = root.queue.map(function(it) { return it.uri || it.media_item_uri || "" }).filter(function(u) { return u.length > 0 })
          saveQueueProc.phase = "add"
          var payload2 = MaApi.buildArgs(root.config.url, root.config.token,
            "music/playlists/add_playlist_tracks", { playlist_id: pid, tracks: items },
            "save-q-add")
          saveQueueProc.authToken = payload2.token || ""
          saveQueueProc.command = [Quickshell.env("SHELL") || "/bin/bash", "-c", payload2.script]
          saveQueueProc.running = true
        } catch (e) {
          root.lastError = "save queue parse: " + e.message
          root.saveQueuePhase = ""
        }
      }
    }
  }

  property string saveQueuePhase: ""
  property string saveQueueNewId: ""

  property int searchRevision: 0

  // Seconds. player_queues/seek takes `position` in seconds; the old
  // position_ms argument was unknown to the server.
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

  function toggleShuffle(playerId) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    if (!p) return
    var next = !(p.shuffle_enabled === true)
    root.actionForPlayer(pid, "player_queues/shuffle", { shuffle_enabled: next })
    root.shuffleEnabled = next
  }

  function cycleRepeat(playerId) {
    var pid = playerId || root.activePlayerId
    var p = root.playerById(pid)
    var cur = p && p.repeat_mode ? String(p.repeat_mode) : "off"
    var next = cur === "off" ? "all" : (cur === "all" ? "one" : "off")
    root.actionForPlayer(pid, "player_queues/repeat", { repeat_mode: next })
    root.repeatMode = next
  }

  function power(playerId, on) {
    var pid = playerId || root.activePlayerId
    // player_id, not queue_id: see setVolume().
    root.runAction("players/cmd/power", { player_id: pid, powered: !!on })
  }

  function addFavorite(uri) {
    if (!uri) return
    root.actionForSourceTarget("music/favorites/add_item", { item: uri })
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

  function openWebUI() {
    var url = root.config.openWebUiPath && root.config.openWebUiPath.length > 0
      ? root.config.openWebUiPath : root.config.url
    // shell.summon() opens shell plugins by id, so summon("browser", url)
    // silently did nothing. Launch the default browser the way the shell's
    // Tailscale panel does; argv form, no shell, http(s) only.
    if (!/^https?:\/\//.test(String(url || ""))) return
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }

  function refreshFavorites() {
    if (!root.ready) return
    root._favTypes = ["tracks", "albums", "artists", "playlists", "radio"]
    root._favIndex = 0
    root._favFetchNext()
  }

  function _favFetchNext() {
    if (root._favIndex >= root._favTypes.length) return
    var t = root._favTypes[root._favIndex++]
    // Favorites are Music Assistant library items marked favorite. There is
    // no music/favorites/* API; query each media controller instead.
    var controller = t === "radio" ? "radios" : t
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "music/" + controller + "/library_items",
      { limit: 50, favorite: true }, "fav-" + t)
    favProc.typeKey = t
    root.runMaRequest(favProc, payload)
  }

  function refreshPlaylists() {
    if (!root.ready) return
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      // music/playlists/all is not a command in 2.10; library_items is.
      "music/playlists/library_items", { limit: 100 }, "playlists")
    root.runMaRequest(playlistsProc, payload)
  }

  function refreshRecent() {
    if (!root.ready) return
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "music/recently_played_items", { limit: root.config.recentLimit || 50 }, "recent")
    root.runMaRequest(recentProc, payload)
  }

  function saveQueueAsPlaylist(name) {
    if (!name || !root.queue || root.queue.length === 0) return
    // 2.10 has a native command for this; the old create-then-add dance sent
    // the wrong playlist id field and never populated the playlist.
    root.runAction("player_queues/save_as_playlist", { queue_id: root.activePlayerId, name: String(name) }, function() {
      root.refreshPlaylists()
    })
    root.showOsd("Saved", "playlist", "Queue saved as \"" + name + "\"")
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
        pollingState: root.pollingActive ? "active" : "stopped",
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

    // Volume keys. Bound either by the installed media-keys block or by
    // scripts/contextual-volume-control, which calls these over IPC only
    // while the active player is playing.
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
      root.toggleShuffle(root.activePlayerId)
      return "ok"
    }

    function cycleRepeat(): string {
      root.cycleRepeat(root.activePlayerId)
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