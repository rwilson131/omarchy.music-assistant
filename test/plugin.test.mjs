import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { test } from "node:test"
import vm from "node:vm"

const root = new URL("../", import.meta.url)

async function text(path) {
  return readFile(new URL(path, root), "utf8")
}

async function qmlLibrary(path) {
  const source = (await text(path)).replace(/^\.pragma library\s*$/m, "")
  const context = vm.createContext({})
  vm.runInContext(source, context, { filename: path })
  return context
}

function occurrences(source, fragment) {
  return source.split(fragment).length - 1
}

test("configuration preserves explicit booleans and validates required values", async () => {
  const schema = await qmlLibrary("ConfigSchema.js")
  const parsed = schema.parse(JSON.stringify({
    url: "http://music-assistant.test:8095",
    token: "secret",
    pollIntervalMs: 750,
    searchLimit: 12,
    recentLimit: 25,
    showSourceBadge: false,
    installMediaKeys: false,
    mprisFallback: false,
  }))

  assert.equal(parsed.error, "")
  assert.equal(parsed.config.showSourceBadge, false)
  assert.equal(parsed.config.installMediaKeys, false)
  assert.equal(parsed.config.mprisFallback, false)
  assert.equal(parsed.config.pollIntervalMs, 750)
  assert.match(schema.parse("{").error, /^JSON parse:/)
  assert.equal(schema.parse(JSON.stringify({ url: "x", token: "y", pollIntervalMs: 499 })).error,
    "pollIntervalMs too low (min 500)")
  assert.equal(schema.parse(JSON.stringify({ token: "y" })).error, "missing url")
  assert.equal(schema.parse(JSON.stringify({ url: "x" })).error, "missing token")
})

test("API requests keep bearer tokens out of argv and cap responses", async () => {
  const api = await qmlLibrary("MaApi.js")
  const token = "token-that-must-not-enter-argv"
  const payload = api.buildArgs("https://music.example", token, "players/all", {}, "test", "17")

  assert.equal(payload.token, token)
  assert.equal(payload.script.includes(token), false)
  assert.match(payload.script, /IFS= read -r token/)
  assert.match(payload.script, /Authorization: Bearer \$\{token\}/)
  assert.match(payload.script, /--max-filesize 8388608/)
  assert.match(payload.script, /--max-time 17/)
  assert.match(payload.script, /mktemp -t ma-auth\.XXXXXX/)
  assert.match(payload.script, /trap 'rm -f "\$F"' EXIT/)
})

test("server-provided image URLs are restricted to HTTP(S)", async () => {
  const api = await qmlLibrary("MaApi.js")

  assert.equal(api.safeImageUrl("https://example.test/cover.png", 2048), "https://example.test/cover.png")
  assert.equal(api.safeImageUrl("http://example.test/cover.png", 2048), "http://example.test/cover.png")
  assert.equal(api.safeImageUrl("file:///etc/passwd", 2048), "")
  assert.equal(api.safeImageUrl("data:image/png;base64,AAAA", 2048), "")
  assert.equal(api.safeImageUrl("javascript:alert(1)", 2048), "")
})

test("media mapping bounds fields and proxies provider-relative artwork", async () => {
  const api = await qmlLibrary("MaApi.js")
  const mapped = api.mapMediaItem({
    uri: "library://track/42",
    item_id: "42",
    provider: "library",
    name: "Track",
    media_type: "track",
    artists: [{ name: "Artist" }],
    album: { name: "Album" },
    image: { path: "covers/42.jpg", provider: "library" },
    provider_mappings: Array.from({ length: 12 }, (_, i) => ({
      provider_domain: `provider-${i}`,
      provider_instance: `instance-${i}`,
    })),
  }, "http://music.example:8095")

  assert.equal(mapped.artist, "Artist")
  assert.equal(mapped.album, "Album")
  assert.equal(mapped.provider_mappings.length, 8)
  assert.match(mapped.image_url, /^http:\/\/music\.example:8095\/imageproxy\?path=covers%2F42\.jpg/)
})

test("play-now coalesces while enqueue actions remain distinct", async () => {
  const api = await qmlLibrary("MaApi.js")

  assert.equal(api.isQueueReplacingPlay("player_queues/play_media", { option: "replace" }), true)
  assert.equal(api.isQueueReplacingPlay("player_queues/play_media", { option: "next" }), false)
  assert.equal(api.isQueueReplacingPlay("player_queues/play_media", { option: "add" }), false)
  assert.equal(api.isQueueReplacingPlay("player_queues/next", {}), false)
  assert.equal(api.isPlayCommand("player_queues/play_media"), true)
  assert.equal(api.isPlayCommand("players/cmd/volume_set"), false)
})

test("QML source retains media-key file safety guards", async () => {
  const service = await text("Service.qml")

  assert.match(service, /grep -cFx -- \\"\$B\\" \\"\$F\\"/)
  assert.match(service, /BEGIN_COUNT.*END_COUNT.*BEGIN_COUNT.*-gt 1/)
  assert.match(service, /return 45/)
  assert.match(service, /mktemp -p \\"\$DIR\\" \\"\$BASE\.bak\.music-assistant\./)
  assert.match(service, /chmod --reference=\\"\$F\\" \\"\$edited\\"/)
  assert.match(service, /mv -f -- \\"\$edited\\" \\"\$F\\"/)
  assert.equal(service.includes('> \\"$F.tmp\\"'), false)
})

test("QML source retains disconnect, latest-request and badge guards", async () => {
  const [service, request, widget] = await Promise.all([
    text("Service.qml"),
    text("MaRequest.qml"),
    text("BarWidget.qml"),
  ])

  assert.match(service, /function applyPlayers\(list\)[\s\S]*!Array\.isArray\(list\)[\s\S]*root\.connected = false[\s\S]*return false/)
  assert.match(service, /if \(!root\.applyPlayers\(data\)\)[\s\S]*root\.pollInFlight = false[\s\S]*return/)
  assert.match(service, /MaApi\.isQueueReplacingPlay\(command, args\)/)
  assert.match(service, /ctx\.generation !== root\.searchGeneration/)
  assert.match(service, /ctx\.generation !== root\.browseGeneration/)
  assert.match(service, /ctx\.generation !== root\.drillGeneration/)

  assert.match(request, /property var pendingPayload: null/)
  assert.match(request, /if \(running\)[\s\S]*request\.pendingPayload = payload/)
  assert.match(request, /onExited:[\s\S]*Qt\.callLater\(function\(\) \{ request\.send\(payload, ctx\) \}\)/)

  assert.equal(occurrences(widget, "SearchResultRow {"), 6)
  assert.equal(occurrences(widget, "showSourceBadge: root.sourceBadgesEnabled"), 6)
  assert.equal(widget.includes("showSourceBadge: true"), false)
})

test("manifest, preview and third-party notices remain publication-ready", async () => {
  const manifest = JSON.parse(await text("manifest.json"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.id, "io.github.rwilson131.music-assistant")
  assert.deepEqual([...manifest.kinds].sort(), ["bar-widget", "service"])

  const png = await readFile(new URL("preview.png", root))
  assert.equal(png.subarray(1, 4).toString(), "PNG")
  assert.equal(png.readUInt32BE(16), 607)
  assert.equal(png.readUInt32BE(20), 748)
  const chunkTypes = []
  for (let offset = 8; offset + 12 <= png.length;) {
    const length = png.readUInt32BE(offset)
    chunkTypes.push(png.subarray(offset + 4, offset + 8).toString("ascii"))
    offset += 12 + length
  }
  for (const metadataChunk of ["eXIf", "iTXt", "tEXt", "zTXt"])
    assert.equal(chunkTypes.includes(metadataChunk), false, `${metadataChunk} metadata must be stripped`)

  const [readme, notices, apache] = await Promise.all([
    text("README.md"), text("THIRD_PARTY_NOTICES.md"), text("LICENSES/Apache-2.0.txt"),
  ])
  assert.match(readme, /^## Requirements$/m)
  assert.match(readme, /^## Removal$/m)
  assert.match(readme, /omarchy plugin remove io\.github\.rwilson131\.music-assistant/)
  assert.match(notices, /e3a8d7b19a6d5f46b8262e0ca202a26dc85a3aec/)
  assert.match(apache, /^\s*Apache License\s*$/m)
  assert.match(apache, /Version 2\.0, January 2004/)
})
