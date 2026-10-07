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
  readonly property int activeDuration: activeMedia && activeMedia.duration ? activeMedia.duration : 0
  readonly property int activeElapsed: activeMedia && activeMedia.elapsed_time ? activeMedia.elapsed_time : 0

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

  function runFetchQueue(playerId) {
    if (!root.ready || !playerId) { root.pollInFlight = false; return }
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "player_queues/items",
      { queue_id: playerId, limit: 200, offset: 0 },
      "poll-queue")
    root.runMaRequest(queueProc, payload)
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
        root.runFetchQueue(root.activePlayerId)
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
        group_members: Array.isArray(p.group_members) ? MaApi.boundedArray(p.group_members, 16).map(function(g) { return MaApi.boundedString(g, 100) }) : [],
        hide_in_ui: !!p.hide_in_ui,
        synced_to: MaApi.boundedString(p.synced_to, 100)
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
    var items = MaApi.boundedArray(raw, MaApi.MAX_QUEUE_ITEMS).map(function(it) {
      return {
        queue_item_id: MaApi.boundedString(it.queue_item_id || it.item_id, 100),
        uri: MaApi.boundedString(it.uri || it.media_item_uri, 2048),
        name: MaApi.boundedString(it.name || it.title, 500),
        artist: MaApi.boundedString(it.artist, 500),
        album: MaApi.boundedString(it.album, 500),
        image_url: MaApi.safeImageUrl(it.image_url || it.image, 2048),
        duration: typeof it.duration === "number" && it.duration >= 0 ? it.duration : 0,
        track_number: typeof it.track_number === "number" ? it.track_number : null,
        media_type: MaApi.boundedString(it.media_type, 50)
      }
    })
    var pos = (payload && payload.current_item_index !== undefined) ? payload.current_item_index
      : (payload && payload.current_index !== undefined) ? payload.current_index
      : 0
    root.queue = items
    root.queuePosition = pos || 0
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
    var p = root.activePlayer
    if (!p) return
    if (p.shuffle_enabled !== undefined) root.shuffleEnabled = !!p.shuffle_enabled
    if (p.repeat_mode !== undefined) root.repeatMode = String(p.repeat_mode)
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
    root.actionForPlayer(playerId, "player_queues/delete_item", { queue_item_id: itemId })
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
      { search_query: query, limit: lim, media_types: ["track", "album", "artist", "playlist"] },
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
    if (!it) return null
    return {
      uri: MaApi.boundedString(it.uri || it.media_item_uri, 2048),
      name: MaApi.boundedString(it.name || it.title, 500),
      title: MaApi.boundedString(it.title || it.name, 500),
      artist: MaApi.boundedString(it.artist, 500),
      album: MaApi.boundedString(it.album, 500),
      image_url: MaApi.safeImageUrl(it.image_url || it.image || it.imageUrl, 2048),
      duration: typeof it.duration === "number" && it.duration >= 0 ? it.duration : 0,
      track_number: typeof it.track_number === "number" ? it.track_number : null,
      media_type: MaApi.boundedString(it.media_type, 50)
    }
  }

  function _boundSearchResults(raw) {
    if (!raw || typeof raw !== "object") return null
    return {
      tracks: MaApi.boundedArray(raw.tracks || [], MaApi.MAX_SEARCH_TRACKS).map(_boundMediaItem),
      albums: MaApi.boundedArray(raw.albums || [], MaApi.MAX_SEARCH_ALBUMS).map(_boundMediaItem),
      artists: MaApi.boundedArray(raw.artists || [], MaApi.MAX_SEARCH_ARTISTS).map(function(a) {
        return {
          uri: MaApi.boundedString(a.uri, 2048),
          name: MaApi.boundedString(a.name, 500),
          image_url: MaApi.safeImageUrl(a.image_url || a.image, 2048)
        }
      }),
      playlists: MaApi.boundedArray(raw.playlists || [], MaApi.MAX_SEARCH_PLAYLISTS).map(_boundMediaItem)
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
          var list = Array.isArray(payload.result) ? payload.result : []
          root.recentItems = MaApi.boundedArray(list, MaApi.MAX_RECENT_ITEMS).map(function(it) {
            return {
              uri: MaApi.boundedString(it.uri, 2048),
              name: MaApi.boundedString(it.name || it.title, 500),
              artist: MaApi.boundedString(it.artist, 500),
              album: MaApi.boundedString(it.album, 500),
              image_url: MaApi.safeImageUrl(it.image_url, 2048),
              last_played: MaApi.boundedString(it.last_played, 50),
              timestamp: typeof it.timestamp === "number" ? it.timestamp : null
            }
          })
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

  function seek(playerId, positionMs) {
    var pid = playerId || root.activePlayerId
    if (!pid) return
    var p = Math.max(0, Math.round(positionMs))
    root.actionForPlayer(pid, "player_queues/seek", { position_ms: p })
  }

  function seekRelative(deltaMs) {
    var cur = root.activeMedia ? (root.activeMedia.elapsed_time || 0) : 0
    root.seek(root.activePlayerId, cur + deltaMs)
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
    root.runAction("players/cmd/power", { player_id: pid, powered: !!on })
  }

  function addFavorite(uri) {
    if (!uri) return
    root.actionForSourceTarget("music/favorites/add_item", { item: uri })
    root.refreshFavorites()
  }

  function removeFavorite(uri) {
    if (!uri) return
    root.actionForSourceTarget("music/favorites/remove_item", { item: uri })
    root.refreshFavorites()
  }

  function favoriteCurrent() {
    var m = root.activeMedia
    if (!m || !m.uri) return
    root.addFavorite(m.uri)
    root.showOsd("Favorited", "favorite", MaApi.trackTitle(m))
  }

  function openWebUI() {
    if (!shell) return
    var url = root.config.openWebUiPath && root.config.openWebUiPath.length > 0
      ? root.config.openWebUiPath : root.config.url
    shell.summon("browser", url)
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
      "music/playlists/all", { limit: 100 }, "playlists")
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
    var payload = MaApi.buildArgs(root.config.url, root.config.token,
      "music/playlists/create_playlist", { name: name }, "save-q-create")
    root.saveQueuePhase = "create"
    saveQueueProc.phase = "create"
    saveQueueProc.name = name
    root.runMaRequest(saveQueueProc, payload)
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
        pollingActive: root.pollingActive
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

    function seek(positionMs: real): string {
      root.seek(root.activePlayerId, positionMs)
      return "ok"
    }

    function seekRelative(deltaMs: real): string {
      root.seekRelative(deltaMs)
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
      root.removeFavorite(uri)
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
  }
}