import assert from "node:assert/strict"
import { test } from "node:test"
import { mkdtemp, copyFile, writeFile, rm, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"

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
      {reply:null,expected:null}
    ]
    const payloads = cases.map(c=>({token:"dummy",body:"{}",script:"read -r token; read -r body; printf '%s' '"+JSON.stringify(c.reply)+"'"}))
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
   index++;
   if(index===payloads.length) {console.log("PASS_QML_ARRAY_CALLBACKS");Qt.quit();return;}
   request.send(payloads[index],{index:index});
  }
 }
 Component.onCompleted: request.send(payloads[0],{index:0})
 Timer {interval:8000;running:true;onTriggered:{console.log("FAIL_TIMEOUT");Qt.quit();}}
}
`)
    const env = {...process.env,QT_QPA_PLATFORM:"offscreen"};delete env.WAYLAND_DISPLAY
    const result=spawnSync("quickshell",["-p",dir],{env,encoding:"utf8",timeout:12000})
    assert.equal(result.status,0,result.stderr)
    assert.match(result.stdout+result.stderr,/PASS_QML_ARRAY_CALLBACKS/)
    assert.doesNotMatch(result.stdout+result.stderr,/FAIL_|ERROR/)
  } finally {await rm(dir,{recursive:true,force:true})}
})

test("all MaRequest consumers use the JS callback rather than a var signal",async()=>{
 const service=await readFile(new URL("../Service.qml",import.meta.url),"utf8")
 assert.equal((service.match(/onResult: function\(data/g)||[]).length,11)
 assert.doesNotMatch(service,/onFinished: function\(data/)
})
