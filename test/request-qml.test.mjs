import assert from "node:assert/strict"
import { test } from "node:test"
import { mkdtemp, copyFile, writeFile, rm, readFile, mkdir } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

async function isolatedEnvironment(dir) {
  const runtime = join(dir, 'runtime')
  await mkdir(runtime, {mode:0o700})
  const env = {...process.env, QT_QPA_PLATFORM:'offscreen', XDG_RUNTIME_DIR:runtime,
    XDG_CACHE_HOME:join(dir, 'cache'), XDG_STATE_HOME:join(dir, 'state'),
    DBUS_SESSION_BUS_ADDRESS:'unix:path=' + join(dir, 'no-session-bus')}
  delete env.WAYLAND_DISPLAY
  delete env.DISPLAY
  return env
}

const available = spawnSync("quickshell", ["--version"], {encoding:"utf8"}).status === 0

test("MaRequest preserves JS arrays across callback and queued requests in real QML", {skip: !available}, async () => {
  const dir = await mkdtemp(join(tmpdir(), "ma-request-test-"))
  try {
    await copyFile(new URL("../MaRequest.qml", import.meta.url), join(dir,"MaRequest.qml"))
    const cases = [
      {reply:[{player_id:"test",group_members:["child"]}], expected:[{player_id:"test",group_members:["child"]}]},
      {reply:{result:[{player_id:"wrapped",group_members:[]}]},expected:[{player_id:"wrapped",group_members:[]}]},
      {reply:{result:{items:[{name:"nested"}]}},expected:{items:[{name:"nested"}]}},
      {reply:{error:{message:"rejected"}},expected:{error:{message:"rejected"}}},
      {reply:null,expected:null},
      {reply:undefined,expected:null}
    ]
    const payloads = cases.map(c=>({token:"dummy",body:"{}",script:"read -r token; read -r body; printf '%s' '"+(c.reply === undefined ? "" : JSON.stringify(c.reply))+"'"}))
    await writeFile(join(dir,"shell.qml"), `import QtQuick
import Quickshell
Scope {
 property int index: 0
 property var expected: ${JSON.stringify(cases.map(c=>c.expected))}
 property var payloads: ${JSON.stringify(payloads)}
 MaRequest {
  id: request
  onResult: function(data, ctx) {
   if (JSON.stringify(data)!==JSON.stringify(expected[index]) || ctx.index!==index) {console.log("FAIL_VALUE");Qt.quit();return;}
   if(index<2 && (!Array.isArray(data)||!Array.isArray(data[0].group_members))) {console.log("FAIL_ARRAY");Qt.quit();return;}
   if(index===2 && !Array.isArray(data.items)) {console.log("FAIL_NESTED");Qt.quit();return;}
   if(index===3 && Array.isArray(data)) {console.log("FAIL_ERROR");Qt.quit();return;}
   if(request.replyValid !== (index < payloads.length-1)) {console.log("FAIL_REPLY_VALID");Qt.quit();return;}
   index++;
   if(index===payloads.length) {console.log("PASS_QML_ARRAY_CALLBACKS");Qt.quit();return;}
   request.send(payloads[index],{index:index});
  }
 }
 Component.onCompleted: request.send(payloads[0],{index:0})
 Timer {interval:8000;running:true;onTriggered:{console.log("FAIL_TIMEOUT");Qt.quit();}}
}
`)
    const env = await isolatedEnvironment(dir)
    const result=spawnSync("quickshell",["-p",dir],{env,encoding:"utf8",timeout:12000})
    assert.equal(result.status,0,result.stderr)
    assert.match(result.stdout+result.stderr,/PASS_QML_ARRAY_CALLBACKS/)
    assert.doesNotMatch(result.stdout+result.stderr,/FAIL_|ERROR/)
  } finally {await rm(dir,{recursive:true,force:true})}
})

test("all MaRequest consumers use the JS callback rather than a var signal",async()=>{
 const service=await readFile(new URL("../Service.qml",import.meta.url),"utf8")
 assert.equal((service.match(/onResult: function\(data/g)||[]).length,12)
 assert.doesNotMatch(service,/onFinished: function\(data/)
})

test("PlayerControls artwork fallback follows real QML Image.Error and recovery", {skip: !available}, async () => {
  const dir = await mkdtemp(join(tmpdir(), "ma-artwork-test-"))
  try {
    const controls = await readFile(new URL('../PlayerControls.qml', import.meta.url), 'utf8')
    // Run the production Image and fallback Text together. Only theme geometry
    // is substituted; source, status and visibility bindings remain unchanged.
    const artwork = controls.slice(controls.indexOf('        Image {'), controls.indexOf('\n      }\n\n      Column {'))
      .replace(/Style\.space\(2\)/g, '2').replace('Style.font.displayLarge', '24')
    await writeFile(join(dir, 'cover.svg'), '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>')
    await writeFile(join(dir, 'shell.qml'), `import QtQuick
import Quickshell
Scope {
 Item {
  id: root
  width: 64; height: 64
  property string imageUrl: ""
  property var bar: ({foreground:"white",fontFamily:"sans-serif"})
  property int phase: 0
  ${artwork}
  Timer {
   interval: 25; repeat: true; running: true
   onTriggered: {
    var fallback = root.children[1]
    if(root.phase===0) {
     if(!fallback.visible) {console.log("FAIL_EMPTY");Qt.quit();return;}
     root.phase=1;root.imageUrl=Qt.resolvedUrl("missing.svg");
    } else if(root.phase===1 && artwork.status===Image.Error) {
     if(!fallback.visible || artwork.visible) {console.log("FAIL_ERROR_FALLBACK");Qt.quit();return;}
     root.phase=2;root.imageUrl=Qt.resolvedUrl("cover.svg");
    } else if(root.phase===2 && artwork.status===Image.Ready) {
     if(fallback.visible || !artwork.visible) {console.log("FAIL_RECOVERY");Qt.quit();return;}
     console.log("PASS_QML_ARTWORK");Qt.quit();
    }
   }
  }
 }
 Timer {interval:5000;running:true;onTriggered:{console.log("FAIL_TIMEOUT");Qt.quit();}}
}`)
    const env = await isolatedEnvironment(dir)
    const result = spawnSync('quickshell', ['-p', dir], {env, encoding:'utf8', timeout:8000})
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout + result.stderr, /PASS_QML_ARTWORK/)
    assert.doesNotMatch(result.stdout + result.stderr, /FAIL_|ERROR/)
  } finally { await rm(dir, {recursive:true, force:true}) }
})
