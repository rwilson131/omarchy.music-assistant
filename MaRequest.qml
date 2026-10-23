import QtQuick
import Quickshell
import Quickshell.Io

// One request to the Music Assistant JSON API, run through curl by the
// script MaApi.buildArgs() produces. The bearer token and JSON body travel
// over stdin (never argv); the reply is parsed and unwrapped from {result: ...} when
// the server wraps it, since some commands answer with a bare list.
//
//   MaRequest { id: req; onResult: function(data, ctx) { ... } }
//   req.send(MaApi.buildArgs(url, token, "players/all", {}), { any: "context" })
//
// A send() while a request is in flight retains the latest request and starts
// it when the current process exits. Intermediate duplicates are superseded.
Process {
  id: request

  // Free-form context handed back with the result, so one component can
  // serve a sequence of related calls (favorites per media type).
  property int connectionGeneration: 0
  property int requestGeneration: 0
  property int pendingGeneration: 0
  onConnectionGenerationChanged: clearPending()

  property var context: ({})
  property string authToken: ""
  property string requestBody: ""
  property var pendingPayload: null
  property var pendingContext: ({})
  // Short label for error messages, e.g. "players".
  property string label: "request"

  // Direct JS callback: Qt 6.12 marshals arrays passed through a QML var
  // signal into sequence objects for which Array.isArray() is false (including
  // nested lists). Keep parsed JSON in JS instead of weakening array validation.
  // Arguments: parsed reply (unwrapped, or null), then request context.
  property var onResult: null
  // Distinguish a valid JSON null (no active queue) from a failed read.
  property bool replyValid: false

  readonly property bool busy: running

  function send(payload, ctx) {
    if (!payload) return false
    if (running) {
      request.pendingGeneration = request.connectionGeneration
      request.pendingPayload = payload
      request.pendingContext = ctx || ({})
      return true
    }
    request.requestGeneration = request.connectionGeneration
    request.context = ctx || ({})
    request.authToken = payload.token || ""
    request.requestBody = payload.body || ""
    request.command = [Quickshell.env("SHELL") || "/bin/bash", "-c", payload.script]
    request.running = true
    return true
  }

  function clearPending() {
    request.pendingPayload = null
    request.pendingContext = ({})
  }

  stdinEnabled: true
  onStarted: {
    if (authToken.length > 0 && requestBody.length > 0) {
      write(authToken + "\n" + requestBody + "\n")
      authToken = ""
      requestBody = ""
    }
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      var data = null
      request.replyValid = false
      try {
        var payload = JSON.parse(String(text || ""))
        request.replyValid = true
        data = payload !== null && typeof payload === "object" && !Array.isArray(payload) && payload.result !== undefined
          ? payload.result : payload
      } catch (e) {
        console.warn("[music-assistant] " + request.label + ": reply is not JSON: " + e.message)
      }
      if (request.requestGeneration !== request.connectionGeneration) return
      if (typeof request.onResult === "function") request.onResult(data, request.context)
    }
  }

  onExited: {
    if (request.pendingPayload === null) return
    var payload = request.pendingPayload
    var ctx = request.pendingContext
    var generation = request.pendingGeneration
    request.clearPending()
    Qt.callLater(function() {
      if (generation === request.connectionGeneration) request.send(payload, ctx)
    })
  }
}
