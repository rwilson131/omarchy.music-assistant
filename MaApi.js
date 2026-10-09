.pragma library

var counter = 0

// Producer-side response cap. curl errors out with exit 63 when the server
// returns more than this many bytes. Generous for a real Music Assistant
// payload (a typical /players/all response is < 50 KB) but small enough
// that a malicious or malfunctioning server cannot exhaust shell memory.
var MAX_RESPONSE_BYTES = 8 * 1024 * 1024

// Client-side budgets. Applied AFTER parsing JSON, before assigning to
// QML models, so a single oversized array cannot blow up a Repeater.
var MAX_PLAYERS = 64
var MAX_QUEUE_ITEMS = 2000
var MAX_SEARCH_TRACKS = 50
var MAX_SEARCH_ALBUMS = 50
var MAX_SEARCH_ARTISTS = 50
var MAX_SEARCH_PLAYLISTS = 50
var MAX_FAVORITES_PER_TYPE = 100
var MAX_PLAYLISTS = 100
var MAX_RECENT_ITEMS = 50

function truncate(s, maxLen) {
  if (s === null || s === undefined) return s
  var str = String(s)
  if (str.length <= maxLen) return str
  return str.substring(0, maxLen) + "…"
}

function boundedArray(arr, maxLen) {
  if (!Array.isArray(arr)) return []
  if (arr.length <= maxLen) return arr
  return arr.slice(0, maxLen)
}

function boundedString(v, maxLen) {
  if (v === null || v === undefined) return ""
  return truncate(String(v), maxLen)
}

// Whitelist allowed URL schemes for image (and other fetched) URLs sourced
// from the Music Assistant server. Rejects file://, javascript:, data:, etc.
// so a compromised or buggy MA cannot trick QML's Image type into reading
// arbitrary local files.
function safeImageUrl(v, maxLen) {
  if (v === null || v === undefined) return ""
  var str = String(v).trim()
  if (str.length === 0) return ""
  var lower = str.toLowerCase()
  if (lower.indexOf("http://") !== 0 && lower.indexOf("https://") !== 0) return ""
  return truncate(str, maxLen)
}

// Bash script that reads the bearer token from stdin, writes it to a
// 0600-mode temp file, runs curl with the Authorization header sourced
// from that file (-H @file), and removes the file on exit. The token
// never appears in any process's argv, only on stdin (which is not
// visible via /proc/PID/cmdline). The --max-filesize flag caps the
// response body so a malicious or malfunctioning server cannot exhaust
// shell memory.
function _buildCurlScript(url, bodyJson, maxTime, includeOutput) {
  var escapedUrl = url.replace(/'/g, "'\\''")
  var escapedBody = bodyJson.replace(/'/g, "'\\''")
  return "set -e\n" +
    "F=$(mktemp -t ma-auth.XXXXXX)\n" +
    "chmod 600 \"$F\"\n" +
    "trap 'rm -f \"$F\"' EXIT\n" +
    "IFS= read -r token\n" +
    "printf '%s' \"Authorization: Bearer ${token}\" > \"$F\"\n" +
    "curl -sS --max-time " + maxTime + " --max-filesize " + MAX_RESPONSE_BYTES + " -X POST " +
    "-H 'Content-Type: application/json' -H '@'\"$F\" " +
    // Without the body, print only the HTTP status so callers can report
    // failures (Music Assistant answers errors with a non-200 status).
    // The elapsed time lets the service tell a stuck stream slot (the server
    // waits 15 s before answering 500) from an immediate rejection.
    (includeOutput ? "" : "-o /dev/null -w '%{http_code} %{time_total}' ") +
    "'" + escapedUrl + "/api' " +
    "-d '" + escapedBody + "'\n"
}

// Script + token for a command whose reply the caller wants. maxTime (seconds,
// default 10) is the curl cap; search and browse pass 30.
function buildArgs(url, token, command, args, messageId, maxTime) {
  var body = {
    message_id: messageId !== undefined ? messageId : "omarchy-" + (counter++),
    command: command,
    args: args || {}
  }
  // Return an object so the caller can pipe the token over stdin instead of
  // passing it as an argv element.
  return {
    script: _buildCurlScript(url, JSON.stringify(body), maxTime || "10", true),
    token: token
  }
}

// Commands that start or move playback. They get a longer curl cap so the
// server's 15 s stream-slot wait can finish and report, instead of curl giving
// up at 8 s and the plugin never learning why the play failed.
var PLAY_COMMANDS = ["player_queues/play_media", "player_queues/play", "player_queues/resume",
  "player_queues/play_index", "player_queues/next", "player_queues/previous"]
function isPlayCommand(command) { return PLAY_COMMANDS.indexOf(command) !== -1 }

// Only a play-now selection replaces the queue and may supersede older pending
// media picks. "next" and "add" are distinct enqueue requests and must remain.
function isQueueReplacingPlay(command, args) {
  return command === "player_queues/play_media" && !!args && args.option === "replace"
}

// Drop only older play-now selections before appending a newer one. Enqueue
// requests share the play_media command, so filtering by command alone would
// silently discard distinct "next" and "add" actions.
function withoutQueueReplacingPlays(actions) {
  if (!Array.isArray(actions)) return []
  return actions.filter(function(action) {
    return !action || !isQueueReplacingPlay(action.command, action.args)
  })
}

// Script + token for an action; the reply is the HTTP status and elapsed seconds.
function buildActionArgs(url, token, command, args, messageId, maxTime) {
  var body = {
    message_id: messageId !== undefined ? messageId : "omarchy-play-" + (counter++),
    command: command,
    args: args || {}
  }
  return {
    script: _buildCurlScript(url, JSON.stringify(body), maxTime || "8", false),
    token: token
  }
}

function isPlaying(player) {
  if (!player) return false
  return player.playback_state === "playing"
}

function isPaused(player) {
  return player && player.playback_state === "paused"
}

function volumePercent(player) {
  if (!player) return 100
  // A group leader shows and sets the group volume, as the MA UI does.
  if (player.group_members && player.group_members.length > 0 && typeof player.group_volume === "number")
    return Math.round(player.group_volume)
  if (player.volume_level === undefined || player.volume_level === null) return 100
  return Math.round(player.volume_level)
}

function trackTitle(media) {
  return (media && media.title) ? media.title : ""
}

function trackArtist(media) {
  if (!media) return ""
  if (media.artist) return media.artist
  return ""
}

function trackAlbum(media) {
  return (media && media.album) ? media.album : ""
}

function trackImageUrl(media) {
  if (!media || !media.image_url) return ""
  return safeImageUrl(media.image_url, 2048)
}

function pickActivePlayerId(players, preferredId) {
  if (!players || players.length === 0) return ""
  if (preferredId) {
    for (var i = 0; i < players.length; i++) {
      if (players[i].player_id === preferredId && players[i].available) return players[i].player_id
    }
  }
  for (var j = 0; j < players.length; j++) {
    var p = players[j]
    if (!p.available || p.hide_in_ui) continue
    if (p.playback_state === "playing") return p.player_id
  }
  for (var k = 0; k < players.length; k++) {
    var pp = players[k]
    if (pp.available && !pp.hide_in_ui) return pp.player_id
  }
  return players[0].player_id
}

function providerLabel(slug) {
  if (!slug) return ""
  var s = String(slug).toLowerCase()
  var dashIdx = s.indexOf("--")
  if (dashIdx !== -1) s = s.substring(0, dashIdx)
  var map = {
    tidal: "Tidal",
    apple_music: "Apple Music",
    spotify: "Spotify",
    youtube_music: "YouTube Music",
    qobuz: "Qobuz",
    deezer: "Deezer",
    soundcloud: "SoundCloud",
    pandora: "Pandora",
    tunein: "TuneIn",
    radio_browser: "Radio Browser",
    radio_paradise: "Radio Paradise",
    soma_fm: "SomaFM",
    nts: "NTS",
    phishin: "Phish.in",
    nugs: "Nugs.net",
    podcast_index: "Podcast Index",
    audible: "Audible",
    audiobookshelf: "Audiobookshelf",
    filesystem: "Local Files",
    builtin: "Built-in",
    library: "Library",
    siriusxm: "SiriusXM",
    vban: "VBAN",
    snapcast: "Snapcast",
    chromecast: "Chromecast",
    dlna: "DLNA",
    airplay: "AirPlay"
  }
  return map[s] || s
}

function providerDomain(item) {
  if (!item) return ""
  if (item.provider_mappings && item.provider_mappings.length > 0 && item.provider_mappings[0].provider_domain)
    return item.provider_mappings[0].provider_domain
  return item.provider || ""
}

function providerBase(value) {
  if (value === null || value === undefined) return ""
  return String(value).toLowerCase().split("--")[0]
}

// The timed 500 signature has only been confirmed for Pandora. Return the
// exact provider instance to reload only when the item has a Pandora mapping.
function pandoraProvider(item) {
  if (!item || !Array.isArray(item.provider_mappings)) return null
  var mappings = boundedArray(item.provider_mappings, 8)
  for (var i = 0; i < mappings.length; i++) {
    var mapping = mappings[i]
    if (!mapping || !mapping.provider_instance) continue
    var domain = providerBase(mapping.provider_domain || mapping.provider_instance)
    if (domain === "pandora") {
      var instance = String(mapping.provider_instance)
      // Never reload a truncated or otherwise ambiguous provider identifier.
      if (instance.length === 0 || instance.length > 100) return null
      return { instance: instance, domain: "pandora", name: "Pandora" }
    }
  }
  return null
}

function providerValueMatches(value, instance, domain) {
  if (value === null || value === undefined || String(value).length === 0) return false
  var candidate = String(value).toLowerCase()
  return candidate === String(instance || "").toLowerCase() || providerBase(candidate) === providerBase(domain)
}

// Tri-state queue evidence for a fail-closed provider reload. A playing queue
// without provider metadata is "unknown", not evidence that the slot is free.
function queueProviderUse(queue, targetQueueId, instance, domain) {
  if (!queue || typeof queue !== "object") return "unknown"
  if (String(queue.queue_id || "") === String(targetQueueId || "")) return "skip"
  if (queue.state !== "playing") return "clear"
  var item = queue.current_item
  if (!item || typeof item !== "object") return "unknown"
  var evidence = []
  function addEvidence(value) {
    var base = providerBase(value)
    // Library/builtin identify the catalog wrapper, not the streaming backend,
    // so they cannot prove that a playing queue is unrelated to Pandora.
    if (base && base !== "library" && base !== "builtin") evidence.push(value)
  }
  var details = item.streamdetails
  if (details && details.provider) addEvidence(details.provider)
  var media = item.media_item
  if (media && media.provider) addEvidence(media.provider)
  var mappings = media && Array.isArray(media.provider_mappings) ? boundedArray(media.provider_mappings, 8) : []
  for (var i = 0; i < mappings.length; i++) {
    if (!mappings[i]) continue
    if (mappings[i].provider_instance) addEvidence(mappings[i].provider_instance)
    if (mappings[i].provider_domain) addEvidence(mappings[i].provider_domain)
  }
  if (evidence.length === 0) return "unknown"
  for (var j = 0; j < evidence.length; j++)
    if (providerValueMatches(evidence[j], instance, domain)) return "busy"
  return "clear"
}

function mediaTypeLabel(t) {
  if (!t) return ""
  var map = {
    track: "Track",
    album: "Album",
    playlist: "Playlist",
    artist: "Artist",
    radio: "Radio",
    podcast: "Podcast",
    podcast_episode: "Episode",
    audiobook: "Audiobook",
    folder: "Folder",
    genre: "Genre"
  }
  return map[t] || t
}

// ---------------------------------------------------------------------------
// Media item helpers for the Music Assistant 2.10 wire format. Items carry
// `artists` (a list of objects), `album` (an object), `image` (an object
// whose `path` may be provider-relative) and `metadata.images`; these
// flatten them into the strings the rows render.

function itemArtist(it) {
  if (!it) return ""
  if (Array.isArray(it.artists) && it.artists.length > 0)
    return it.artists.map(function(a) { return a && a.name ? String(a.name) : "" }).filter(function(x) { return x }).join(", ")
  if (typeof it.artist === "string") return it.artist
  if (Array.isArray(it.authors) && it.authors.length > 0) return it.authors.join(", ")
  if (it.publisher) return String(it.publisher)
  if (it.owner) return String(it.owner)
  return ""
}

function itemAlbum(it) {
  if (!it) return ""
  if (it.album && typeof it.album === "object") return it.album.name ? String(it.album.name) : ""
  if (typeof it.album === "string") return it.album
  return ""
}

function itemImage(it) {
  if (!it) return null
  if (it.image && typeof it.image === "object" && it.image.path) return it.image
  if (it.metadata && Array.isArray(it.metadata.images) && it.metadata.images.length > 0) {
    for (var i = 0; i < it.metadata.images.length; i++) {
      var im = it.metadata.images[i]
      if (im && im.type === "thumb" && im.path) return im
    }
    if (it.metadata.images[0] && it.metadata.images[0].path) return it.metadata.images[0]
  }
  if (it.media_item) return itemImage(it.media_item)
  if (typeof it.image_url === "string" && it.image_url) return { path: it.image_url, provider: "url", remotely_accessible: true }
  return null
}

// Absolute http(s) image URL for an item, or "". A provider-relative path
// (local files, some streaming providers) goes through the server's image
// proxy, which is how the Music Assistant web UI loads them too.
function itemImageUrl(it, serverUrl) {
  var im = itemImage(it)
  if (!im || !im.path) return ""
  var path = String(im.path)
  if (/^https?:\/\//i.test(path)) return safeImageUrl(path, 2048)
  if (!serverUrl) return ""
  // The built-in provider's bundled images (logo.png) are not proxyable.
  if (im.provider === "builtin") return ""
  return safeImageUrl(serverUrl + "/imageproxy?path=" + encodeURIComponent(path)
    + "&provider=" + encodeURIComponent(im.provider || "") + "&size=128", 2048)
}

// "Artist — Album" style second line for a list row.
function itemSubtitle(it) {
  if (!it) return ""
  var parts = []
  if (it.artist) parts.push(it.artist)
  if (it.album) parts.push(it.album)
  var s = parts.join(" — ")
  if (it.year) s += (s ? " · " : "") + it.year
  if (it.total_episodes) s += (s ? " · " : "") + it.total_episodes + " episodes"
  return s
}

// One bounded, flat record for every list in the popup (search, favorites,
// playlists, recent, browse, queue). Keeps only what the rows render plus
// what actions need (uri, item_id, provider, media_type, path).
function mapMediaItem(it, serverUrl) {
  if (!it || typeof it !== "object") return null
  var pm = Array.isArray(it.provider_mappings) ? boundedArray(it.provider_mappings, 8).map(function(m) {
    return {
      provider_domain: boundedString(m && m.provider_domain, 100),
      provider_instance: boundedString(m && m.provider_instance, 100)
    }
  }) : []
  return {
    uri: boundedString(it.uri || it.media_item_uri, 2048),
    item_id: boundedString(it.item_id, 200),
    provider: boundedString(it.provider, 100),
    name: boundedString(it.name || it.title, 500),
    title: boundedString(it.name || it.title, 500),
    artist: boundedString(itemArtist(it), 500),
    album: boundedString(itemAlbum(it), 500),
    image_url: itemImageUrl(it, serverUrl),
    duration: typeof it.duration === "number" && it.duration >= 0 ? it.duration : 0,
    track_number: typeof it.track_number === "number" ? it.track_number : null,
    media_type: boundedString(it.media_type, 50),
    favorite: it.favorite === true,
    is_playable: it.is_playable !== false,
    path: boundedString(it.path, 1024),
    owner: boundedString(it.owner, 200),
    year: typeof it.year === "number" ? it.year : null,
    total_episodes: typeof it.total_episodes === "number" ? it.total_episodes : null,
    provider_mappings: pm
  }
}

function formatRelativeTime(epochSeconds) {
  if (!epochSeconds || epochSeconds <= 0) return ""
  var now = Math.floor(Date.now() / 1000)
  var delta = now - epochSeconds
  if (delta < 60) return delta + "s ago"
  if (delta < 3600) return Math.floor(delta / 60) + " min ago"
  if (delta < 86400) return Math.floor(delta / 3600) + " h ago"
  if (delta < 604800) return Math.floor(delta / 86400) + " d ago"
  return new Date(epochSeconds * 1000).toLocaleDateString()
}
