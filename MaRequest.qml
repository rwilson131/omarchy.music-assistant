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
// A send() while a request is in flight is ignored, like Process itself.
Process {
  id: request

  // Free-form context handed back with the result, so one component can
  // serve a sequence of related calls (favorites per media type).
  property var context: ({})
  property string authToken: ""
  // Short label for error messages, e.g. "players".
  property string label: "request"

  // data is the parsed reply (unwrapped), or null when it was not JSON.
  signal finished(var data, var context)

  readonly property bool busy: running

  function send(payload, ctx) {
    if (!payload || running) return false
    request.context = ctx || ({})
    request.authToken = payload.token || ""
    request.command = [Quickshell.env("SHELL") || "/bin/bash", "-c", payload.script]
    request.running = true
    return true
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
}
