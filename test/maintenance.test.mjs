import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import vm from 'node:vm'

const service = await readFile(new URL('../Service.qml', import.meta.url), 'utf8')
const apiSource = (await readFile(new URL('../MaApi.js', import.meta.url), 'utf8')).replace(/^\.pragma library\s*$/m, '')
const schemaSource = (await readFile(new URL('../ConfigSchema.js', import.meta.url), 'utf8')).replace(/^\.pragma library\s*$/m, '')
function serviceFixture() {
  const MaApi = vm.createContext({}), ConfigSchema = vm.createContext({})
  vm.runInContext(apiSource, MaApi); vm.runInContext(schemaSource, ConfigSchema)
  const calls = [], requests = [], later = []
  let now = 100000
  const root = {players: [], activePlayerId: 'child', selectionGeneration: 0, connectionGeneration: 0,
    ready: true, connected: true, queue: [], queueInfo: null, queueRevision: 0, revision: 0,
    config: {url: 'https://music.example', token: 'synthetic'}, pendingActions: [], currentAction: null,
    actionSequence: 0, pendingVolumes: {}, volumeSequence: 0, playersPollSequence: 0,
    searchGeneration: 0, browseGeneration: 0, drillGeneration: 0, favoriteTypes: ['tracks'],
    healInProgress: false, healRetry: false, lastHealAt: 0}
  const noop = () => {}
  const context = vm.createContext({root, MaApi, ConfigSchema, Qt: {callLater: f => later.push(f)},
    Quickshell: {env: () => '/bin/bash'}, Date: {now: () => now}, console: {warn: noop},
    pollTimer: {restart: noop, stop: noop}, configRetry: {stop: noop}, mediaKeysProbe: {},
    refreshTimer: {restart() {root.refreshes = (root.refreshes || 0) + 1}}, playlistsRefreshTimer: {restart: noop}})
  const ids = [...service.matchAll(/    id: (\w+)\n    connectionGeneration:/g)].map(m => m[1])
  for (const id of ids) context[id] = {replyValid: true, send(payload, ctx) {requests.push({id, payload, ctx}); return true}, clearPending: noop}
  const actionProc = {running: false}
  Object.defineProperty(actionProc, 'running', {get() {return this._running || false}, set(value) {
    assert.ok(!value || !this._running, 'production scheduler must not start a busy process')
    this._running = value
    if (value) {const payload = JSON.parse(this.requestBody); calls.push({...payload, onDone: root.currentAction.onDone})}
  }})
  context.actionProc = actionProc
  for (const key of ['actionContext', 'actionCommand', 'actionArgs', 'httpCode'])
    Object.defineProperty(context, key, {get: () => actionProc[key]})
  Object.defineProperty(context, 'players', {get: () => root.players})
  for (const match of service.matchAll(/^  function (\w+)\([^\n]*\) \{[\s\S]*?^  }/gm)) {
    vm.runInContext(match[0], context); root[match[1]] = context[match[1]]
  }
  // Only UI, disk persistence and periodic polling are isolated. Action queuing,
  // ownership resolution, payload construction and process completion stay real.
  root.showOsd = root.persistConfig = root.refreshState = root.installMediaKeysBindings = noop
  root.mprisRoutingEnabled = () => false
  const selectionChanged = vm.runInContext('(function(){' + service.match(/  onActivePlayerIdChanged: \{([\s\S]*?)\n  }/)[1] + '})', context)
  let selected = root.activePlayerId
  Object.defineProperty(root, 'activePlayerId', {get: () => selected, set(value) {
    if (value !== selected) {selected = value; selectionChanged()}
  }})
  function flush() {while (later.length) later.shift()()}
  function reply(id, data, ctx = requests.findLast(r => r.id === id)?.ctx) {
    const block = service.slice(service.indexOf('    id: ' + id)).split('\n  }')[0]
    const callback = block.match(/onResult: (function\(data(?:, ctx)?\) \{[\s\S]*\n    })/)
    assert.ok(callback, id)
    vm.runInContext('(' + callback[1] + ')', context)(data, ctx)
    flush()
  }
  const actionBlock = service.slice(service.indexOf('    id: actionProc'), service.indexOf('  // Actions print only'))
  const exit = vm.runInContext('(' + actionBlock.match(/onExited: (function\(code, status\) \{[\s\S]*?\n    })/)[1] + ')', context)
  function complete(code = 0, http = '200') {
    assert.equal(actionProc.running, true, 'an action must actually have started')
    actionProc.running = false; actionProc.httpCode = http; exit(code, 0); flush()
  }
  return {root, calls, requests, reply, MaApi, context, complete, flush, actionProc, advance: ms => {now += ms}}
}

const group = () => [{player_id:'child', available:true, group_members:['speaker'], group_volume:40, volume_level:25},
  {player_id:'speaker', available:true, group_members:[], volume_level:30}]

test('play-now and delayed queue edits share production transport ordering', () => {
  const {root, calls, requests, reply, complete} = serviceFixture()
  root.playUri('child', 'library://track/a'); root.stop('child')
  assert.deepEqual(calls.map(c => c.command), ['player_queues/play_media'])
  complete(); assert.equal(calls.at(-1).command, 'players/cmd/stop'); complete()
  root.clearQueue('child'); root.playUri('child', 'library://track/b'); root.stop('child')
  assert.equal(requests.at(-1).payload.body.includes('get_active_queue'), true)
  assert.equal(calls.length, 2, 'lookup reserves the action slot')
  reply('queueActionRequest', {queue_id:'leader'})
  assert.equal(calls.at(-1).command, 'player_queues/clear'); complete()
  assert.equal(calls.at(-1).command, 'player_queues/play_media'); complete()
  assert.equal(calls.at(-1).command, 'players/cmd/stop')
})

test('explicit child play destination differs from enqueue/edit/transfer owner', () => {
  const {root, calls, requests, reply, complete} = serviceFixture()
  root.players = [{player_id:'child', synced_to:'leader'}, {player_id:'leader'}, {player_id:'other'}]
  root.playUri('child', 'library://track/a')
  assert.equal(requests.length, 0); assert.equal(calls[0].args.queue_id, 'child'); complete()
  root.enqueue('library://track/b', 'add'); reply('queueActionRequest', {queue_id:'leader'})
  assert.equal(calls.at(-1).args.queue_id, 'leader'); complete()
  root.transferQueue('child', 'other'); reply('queueActionRequest', {queue_id:'leader'})
  assert.equal(calls.at(-1).args.source_queue_id, 'leader')
  assert.equal(calls.at(-1).args.target_queue_id, 'other')
  assert.equal(root.activePlayerId, 'other')
})

test('pending replaces and volumes coalesce while enqueues and retained callbacks survive', () => {
  const {root, calls, reply, complete} = serviceFixture()
  root.stop('child')
  root.playUri('child', 'library://old'); root.enqueue('library://one', 'add')
  root.playUri('child', 'library://latest'); root.enqueue('library://two', 'next')
  let finished = 0
  root.runAction('players/cmd/volume_set', {player_id:'child', volume_level:45})
  root.runAction('players/cmd/volume_set', {player_id:'child', volume_level:50}, () => finished++)
  root.runAction('players/cmd/volume_set', {player_id:'other', volume_level:25})
  complete(); reply('queueActionRequest', {queue_id:'leader'}); complete(); complete()
  reply('queueActionRequest', {queue_id:'leader'}); complete(); complete(); complete()
  assert.deepEqual(calls.filter(c => c.command === 'player_queues/play_media').map(c => c.args.media),
    ['library://one', 'library://latest', 'library://two'])
  assert.deepEqual(calls.filter(c => c.command === 'players/cmd/volume_set').map(c => c.args.volume_level), [50,25])
  assert.equal(finished, 1)
})

test('valid config replacement drops old lookups, polls and running action callbacks', () => {
  const {root, requests, calls, reply, complete, flush} = serviceFixture()
  root.clearQueue('child'); const old = requests.at(-1)
  root.runFetchPlayers(); const oldPlayers = requests.at(-1)
  root.applyConfig(JSON.stringify({url:'https://new.example', token:'new-synthetic'})); flush()
  assert.equal(root.ready, true)
  reply('queueActionRequest', {queue_id:'old-leader'}, old.ctx)
  reply('playersRequest', group(), oldPlayers.ctx)
  assert.equal(calls.length, 0); assert.equal(root.connected, false); assert.equal(root.players.length, 0)
  let completed = 0
  root.runAction('players/cmd/stop', {player_id:'child'}, () => completed++)
  root.runAction('players/cmd/play', {player_id:'child'})
  root.applyConfig(JSON.stringify({url:'https://third.example', token:'third-synthetic'})); flush()
  root.stop('other'); complete()
  assert.equal(completed, 0)
  assert.deepEqual(calls.map(c => c.command), ['players/cmd/stop','players/cmd/stop'])
  assert.equal(calls.at(-1).args.player_id, 'other')
})

test('disconnect/reconnect and selection changes reject stale snapshots before applying state', () => {
  const {root, requests, calls, reply} = serviceFixture()
  root.runFetchPlayers(); const old = requests.at(-1)
  root.stopConnection(); root.ready = false
  reply('playersRequest', group(), old.ctx)
  assert.equal(root.connected, false); assert.equal(root.queueInfo, null); assert.equal(root.players.length, 0)
  root.ready = true; root.startConnection(); root.runFetchPlayers(); const fresh = requests.at(-1)
  reply('playersRequest', group(), fresh.ctx); const info = requests.at(-1)
  root.selectionGeneration++; root.activePlayerId = 'speaker'
  reply('queueInfoRequest', {queue_id:'old-leader'}, info.ctx)
  assert.equal(root.queueInfo, null)
  root.clearQueue('child'); const lookup = requests.at(-1)
  root.selectionGeneration++; reply('queueActionRequest', {queue_id:'old-leader'}, lookup.ctx)
  assert.equal(calls.length, 0)
  reply('playersRequest', group(), old.ctx)
  assert.equal(root.activePlayerId, 'speaker')
})

test('stale library and provider recovery results cannot mutate a replacement connection', () => {
  const {root, calls, reply, complete} = serviceFixture()
  const old = {connectionGeneration:0, generation:0, command:'player_queues/play_media', args:{queue_id:'child'},
    type:'tracks', index:0, query:'old', instance:'pandora-test', domain:'pandora'}
  root.stopConnection(); root.ready = true
  for (const id of ['searchRequest','favoritesRequest','playlistsRequest','recentRequest','browseRequest','drillRequest','healLookup','healQueues'])
    reply(id, [], old)
  assert.equal(calls.length, 0); assert.equal(root.playlists.length, 0); assert.equal(root.healInProgress, false)
  root.runAction('config/providers/reload', {instance_id:'synthetic'}, () => root.playUri('child','library://old'))
  root.stopConnection()
  complete()
  assert.equal(calls.length, 1, 'old retry callback is never invoked')
})

test('provider recovery captures the original connection before lookup and reload completion', () => {
  const {root, requests, reply, complete, calls} = serviceFixture()
  assert.equal(root.tryStreamSlotHeal('player_queues/play_media', {queue_id:'child', media:'pandora://synthetic'}), true)
  const lookup = requests.at(-1)
  reply('healLookup', {provider_mappings:[{provider_instance:'pandora-synthetic',provider_domain:'pandora'}]}, lookup.ctx)
  const queues = requests.at(-1)
  reply('healQueues', [], queues.ctx)
  assert.equal(calls[0].command, 'config/providers/reload')
  root.applyConfig(JSON.stringify({url:'https://replacement.example', token:'synthetic-replacement'}))
  complete()
  assert.equal(calls.length, 1)
  root.healInProgress = true
  reply('healLookup', null, lookup.ctx)
  assert.equal(root.healInProgress, true, 'old recovery cannot clear newer recovery state')
})

test('pre-command polls cannot erase accumulating group or speaker volume targets', () => {
  const {root, calls, requests, reply, complete} = serviceFixture()
  root.players = group(); root.runFetchPlayers(); const old = requests.at(-1)
  root.adjustVolume('child', 5)
  reply('playersRequest', group(), old.ctx)
  root.adjustVolume('child', 5)
  assert.equal(root.players[0].group_volume, 50); assert.equal(root.players[0].volume_level, 25)
  complete(); assert.equal(calls.at(-1).args.volume_level, 50)
  root.runFetchPlayers(); const inFlight = requests.at(-1); complete()
  reply('playersRequest', group(), inFlight.ctx)
  assert.equal(root.players[0].group_volume, 50, 'poll started before completion stays stale')
  root.runFetchPlayers(); reply('playersRequest', group().map(p => ({...p, group_volume:38})))
  assert.equal(root.players[0].group_volume, 38, 'fresh server value reconciles even when different')
  assert.deepEqual(calls.slice(0,2).map(c => c.args.volume_level), [45,50])
  root.adjustVolume('speaker', 5); complete()
  assert.equal(calls.at(-1).args.volume_level, 35)
})

test('volume failure, expiry, clamp and mute preserve reconciliation and individual levels', () => {
  const {root, requests, reply, complete, advance} = serviceFixture()
  root.players = group(); root.adjustVolume('child', 5)
  root.runFetchPlayers(); const stale = requests.at(-1); complete(1, '500')
  assert.equal(root.refreshes, 1)
  reply('playersRequest', group(), stale.ctx); assert.equal(root.players[0].group_volume, 45)
  root.runFetchPlayers(); reply('playersRequest', group()); assert.equal(root.players[0].group_volume, 40)
  root.setVolumeLocal('child', 110); assert.equal(root.players[0].group_volume,100)
  advance(10001); root.runFetchPlayers(); reply('playersRequest', group())
  assert.equal(root.players[0].group_volume,40); complete()
  root.players[1].volume_muted = true; root.adjustVolume('speaker', 5)
  assert.equal(root.players[1].volume_level,30); assert.equal(root.players[1].volume_muted,false)
})

test('null/error queue lookups release the scheduler without inventing an owner', () => {
  const {root, calls, reply} = serviceFixture()
  root.clearQueue('child'); root.stop('child'); reply('queueActionRequest', null)
  assert.deepEqual(calls.map(c => c.command), ['players/cmd/stop'])
})

test('all queue edits preserve resolved ownership and save callbacks with the production scheduler', () => {
  const {root, calls, reply, complete} = serviceFixture()
  root.queue = [{queue_item_id:'one'}]
  const actions = [() => root.playIndex('child',2), () => root.toggleShuffle(), () => root.cycleRepeat(),
    () => root.setCrossfade(true), () => root.setAutoplay(true), () => root.setDontStopTheMusic(true),
    () => root.moveQueueItem('one',1), () => root.moveQueueItemEnd('one'), () => root.skip(10),
    () => root.saveQueueAsPlaylist('Synthetic playlist'), () => root.deleteQueueItem('child','one')]
  for (const action of actions) {action(); reply('queueActionRequest', {queue_id:'leader'}); complete()}
  assert.equal(calls.length, actions.length)
  for (const call of calls) assert.equal(call.args.queue_id, 'leader', call.command)
  assert.equal(typeof calls[9].onDone, 'function')
})

test('individual volume reconciles after actual action completion', () => {
  const {root, reply, complete} = serviceFixture()
  root.players = group(); root.adjustVolume('speaker',5); complete()
  root.runFetchPlayers(); reply('playersRequest', group())
  assert.equal(root.players[1].volume_level,30)
  assert.equal(root.pendingVolumes.speaker, undefined)
})

test('late action status cannot attach provider recovery to a new selection', () => {
  const {root, actionProc, requests} = serviceFixture()
  root.playUri('child','pandora://synthetic')
  root.selectionGeneration++
  root.reportActionStatus('player_queues/play_media','500',15,actionProc.actionArgs,actionProc.actionContext)
  assert.equal(requests.length,0)
})

test('transport remains player-directed and serialized for external sources', () => {
  const {root, calls, complete} = serviceFixture()
  root.players = [{player_id:'child', playback_state:'playing'}]
  root.playPause('child'); root.next('child'); root.previous('child'); root.play('child')
  root.pause('child'); root.stop('child'); root.seek('child',12)
  for (let i=0; i<7; i++) complete()
  assert.deepEqual(calls.map(c => c.command), ['pause','next','previous','play','pause','stop','seek'].map(c => 'players/cmd/'+c))
  assert.ok(calls.every(c => c.args.player_id === 'child'))
})

test('player transport keeps the production 25-second playback cap', () => {
  for (const method of ['play', 'next', 'previous', 'playPause']) {
    const {root, calls, actionProc, MaApi} = serviceFixture()
    root.players = [{player_id:'other', playback_state:'paused'}]
    root[method]('other')
    assert.equal(calls[0].args.player_id, 'other')
    assert.equal(MaApi.isPlayCommand(calls[0].command), true)
    assert.match(actionProc.command[2], /--max-time 25\b/)
  }
  const {root, actionProc} = serviceFixture()
  root.pause('other')
  assert.match(actionProc.command[2], /--max-time 8\b/)
})

test('slow player recovery uses its explicit target URI, retry and conservative queue evidence', () => {
  for (const busy of [false, true]) {
    const {root, calls, requests, actionProc, reply, complete} = serviceFixture()
    root.players = [{player_id:'other', current_media:{uri:'pandora://requested'}}]
    root.queueInfo = {queue_id:'child', current_item:{uri:'pandora://unrelated-selected'}}
    root.play('other')
    root.reportActionStatus('players/cmd/play','500',15,actionProc.actionArgs,actionProc.actionContext)
    const lookup = requests.at(-1)
    assert.ok(lookup, 'slow player failures retain guarded provider recovery')
    assert.equal(JSON.parse(lookup.payload.body).args.uri, 'pandora://requested')
    assert.equal(lookup.ctx.args.player_id, 'other')
    complete(0, '500')
    reply('healLookup', {provider_mappings:[{provider_instance:'pandora-synthetic',provider_domain:'pandora'}]}, lookup.ctx)
    const queues = requests.at(-1)
    reply('healQueues', busy ? [{queue_id:'child',state:'playing',current_item:{streamdetails:{provider:'pandora-synthetic'}}}] : [], queues.ctx)
    if (busy) {
      assert.equal(calls.length, 1, 'a different playing room prevents provider reload')
    } else {
      assert.equal(calls[1].command, 'config/providers/reload')
      complete()
      assert.equal(calls[2].command, 'players/cmd/play')
      assert.equal(calls[2].args.player_id, 'other', 'retry never substitutes the selected player')
    }
  }
  const {root, requests, actionProc} = serviceFixture()
  root.queueInfo = {queue_id:'child', current_item:{uri:'pandora://unrelated-selected'}}
  root.play('other')
  root.reportActionStatus('players/cmd/play','500',15,actionProc.actionArgs,actionProc.actionContext)
  assert.equal(requests.length, 0, 'missing target metadata must not recover an unrelated selected item')
})

test('canonical artwork accepts serialized IDs and safe direct URLs without leaking config', () => {
  const {MaApi: api} = serviceFixture()
  const id = 'a'.repeat(64)
  for (const provider of ['builtin', 'filesystem--one', 'library']) {
    const image = {path: 'covers/one.jpg', provider, proxy_id: id}
    const url = api.itemImageUrl({image}, 'https://music.example/')
    assert.equal(url, 'https://music.example/imageproxy/' + id + '?size=160')
    // Stable server metadata/constants.py rejects arbitrary thumbnail sizes.
    assert.ok([0, 80, 160, 256, 512, 1024].includes(Number(new URL(url).searchParams.get('size'))))
    assert.equal(api.mapMediaItem({metadata: {images: [{...image, type: 'thumb'}]}}, 'https://music.example').image_url,
      'https://music.example/imageproxy/' + id + '?size=160')
  }
  for (const proxy_id of [undefined, '', '../x', 'a'.repeat(63), id + '?token=x', {}, 'g'.repeat(64)])
    assert.equal(api.itemImageUrl({image: {path: 'relative', proxy_id}}, 'https://music.example'), '')
  for (const path of ['file:///tmp/cover', 'javascript:bad', 'data:image/png,abc'])
    assert.equal(api.itemImageUrl({image: {path}}, 'https://music.example'), '')
  assert.equal(api.itemImageUrl({image: {path: 'https://covers.example/one.jpg'}}, ''), 'https://covers.example/one.jpg')
  for (const base of ['file:///tmp', 'https://user:secret@music.example', 'https://music.example?token=secret'])
    assert.equal(api.itemImageUrl({image: {path: 'relative', proxy_id: id}}, base), '')
  assert.equal(api.itemImageUrl({}, 'https://music.example'), '')
})

test('actual MaRequest parser distinguishes JSON null, errors, arrays and failed reads', async () => {
  const source = await readFile(new URL('../MaRequest.qml', import.meta.url), 'utf8')
  const body = source.match(/    onStreamFinished: \{([\s\S]*?)\n    }/)[1]
  for (const [text, valid, expected] of [['null', true, null], ['', false, null], ['invalid', false, null],
    ['{"error":{"message":"rejected"}}', true, {error:{message:'rejected'}}],
    ['{"result":[]}', true, []]]) {
    let actual
    const request = {onResult(data) {actual = data}, context:{}}
    const context = vm.createContext({text, request, console:{warn() {}}})
    vm.runInContext('(function() {' + body + '})()', context)
    assert.equal(request.replyValid, valid)
    assert.equal(JSON.stringify(actual), JSON.stringify(expected))
    if (Array.isArray(expected)) assert.equal(Array.isArray(actual), true)
  }
})

test('MaRequest rejects old results and deferred pending sends after generation changes', async () => {
  const source = await readFile(new URL('../MaRequest.qml', import.meta.url), 'utf8')
  const later = [], starts = []
  const request = {connectionGeneration:0, requestGeneration:0, pendingGeneration:0,
    pendingPayload:null, pendingContext:{}, running:false, onResult() {throw Error('stale result applied')}}
  const context = vm.createContext({request, Qt:{callLater:f=>later.push(f)},
    Quickshell:{env:()=>'/bin/bash'}, text:'[]', console:{warn(){}}})
  Object.defineProperty(context, 'running', {get:()=>request.running})
  for (const name of ['send','clearPending']) {
    const fn = source.match(new RegExp('  function '+name+'\\([^\\n]*\\) \\{[\\s\\S]*?\\n  }'))[0]
    vm.runInContext(fn,context); request[name]=context[name]
  }
  const originalSend=request.send
  request.send=(...args)=>{starts.push(args);return originalSend(...args)}
  const payload={token:'synthetic',body:'{}',script:'synthetic-no-execution'}
  request.send(payload,{id:'running'});request.running=true
  request.send(payload,{id:'pending'})
  request.running=false
  const exit=source.match(/  onExited: \{([\s\S]*?)\n  }\n}/)[1]
  vm.runInContext('(function(){'+exit+'})()',context)
  request.connectionGeneration++
  request.clearPending()
  later.shift()()
  assert.equal(starts.length,2,'captured pending payload must not be resent after reconnect')
  const parse=source.match(/    onStreamFinished: \{([\s\S]*?)\n    }/)[1]
  vm.runInContext('(function(){'+parse+'})()',context)
  assert.equal(request.requestGeneration,0,'request snapshot stays attached to original dispatch')
})
