.pragma library

var DEFAULTS = {
  url: "",
  token: "",
  preferredPlayerId: "",
  pollIntervalMs: 2000,
  searchLimit: 20,
  recentLimit: 50,
  showSourceBadge: true,
  openWebUiPath: "",
  installMediaKeys: false,
  mprisFallback: true
}

var INTEGER_KEYS = {
  pollIntervalMs: true,
  searchLimit: true,
  recentLimit: true
}

var BOOL_KEYS = {
  showSourceBadge: true,
  installMediaKeys: true,
  mprisFallback: true
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v)
}

function coerce(raw, key) {
  if (raw === undefined || raw === null) return DEFAULTS[key]
  if (BOOL_KEYS[key]) return !!raw
  if (INTEGER_KEYS[key]) {
    var n = parseInt(raw, 10)
    return isNaN(n) ? DEFAULTS[key] : n
  }
  return String(raw)
}

function parse(text) {
  var parsed = {}
  try {
    if (text && String(text).trim().length > 0) {
      parsed = JSON.parse(String(text))
    }
  } catch (e) {
    return { config: Object.assign({}, DEFAULTS), error: "JSON parse: " + e.message }
  }
  if (!isPlainObject(parsed)) {
    return { config: Object.assign({}, DEFAULTS), error: "config root must be object" }
  }
  var merged = Object.assign({}, DEFAULTS)
  var present = {}
  for (var k in DEFAULTS) {
    if (parsed[k] !== undefined) { merged[k] = coerce(parsed[k], k); present[k] = true }
  }
  for (var k2 in parsed) {
    if (!(k2 in DEFAULTS)) merged[k2] = parsed[k2]
  }
  var error = ""
  if (!merged.url || String(merged.url).length === 0) error = "missing url"
  else if (!merged.token || String(merged.token).length === 0) error = "missing token"
  else if (merged.pollIntervalMs < 500) error = "pollIntervalMs too low (min 500)"
  return { config: merged, error: error, present: present }
}
