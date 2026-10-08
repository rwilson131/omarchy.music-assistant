import QtQuick
import Quickshell
import Quickshell.Io

// One request to the Music Assistant JSON API, run through curl by the
// script MaApi.buildArgs() produces. The bearer token travels over stdin
// (never argv); the reply is parsed and unwrapped from {result: ...} when
// the server wraps it, since some commands answer with a bare list.
//
//   MaRequest { id: req; onFinished: function(data, ctx) { ... } }
//   req.send(MaApi.buildArgs(url, token, "players/all", {}), { any: "context" })
//
// A send() while a request is in flight retains the latest request and starts
// it when the current process exits. Intermediate duplicates are superseded.
Process {
  id: request

  // Free-form context handed back with the result, so one component can
  // serve a sequence of related calls (favorites per media type).
  property var context: ({})
  property string authToken: ""
  property var pendingPayload: null
  property var pendingContext: ({})
  // Short label for error messages, e.g. "players".
  property string label: "request"

  // data is the parsed reply (unwrapped), or null when it was not JSON.
  signal finished(var data, var context)

  readonly property bool busy: running

  function send(payload, ctx) {
    if (!payload) return false
    if (running) {
      request.pendingPayload = payload
      request.pendingContext = ctx || ({})
      return true
    }
    request.context = ctx || ({})
    request.authToken = payload.token || ""
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
    if (authToken.length > 0) {
      write(authToken + "\n")
      authToken = ""
    }
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      var data = null
      try {
        var payload = JSON.parse(String(text || "null"))
        data = payload !== null && typeof payload === "object" && !Array.isArray(payload) && payload.result !== undefined
          ? payload.result : payload
      } catch (e) {
        console.warn("[music-assistant] " + request.label + ": reply is not JSON: " + e.message)
      }
      request.finished(data, request.context)
    }
  }

  onExited: {
    if (request.pendingPayload === null) return
    var payload = request.pendingPayload
    var ctx = request.pendingContext
    request.clearPending()
    Qt.callLater(function() { request.send(payload, ctx) })
  }
}
