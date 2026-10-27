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
  // Optional service callbacks keep failures scoped to the operation that
  // produced them: an unrelated successful poll must not erase a Browse or
  // Search error. Arguments are (message, label, context) and (label, context).
  property var errorReporter: null
  property var successReporter: null
  // Distinguish a valid JSON null (no active queue) from a failed read.
  property bool replyValid: false
  property string errorText: ""

  readonly property bool busy: running

  function failureMessage(curlCode, httpStatus) {
    var operation = request.label || "request"
    if (curlCode === 28) return "Music Assistant " + operation + " timed out"
    if (curlCode === 63) return "Music Assistant " + operation + " response was too large"
    if (curlCode === 6 || curlCode === 7) return "Couldn't connect to Music Assistant (" + operation + ")"
    if (curlCode !== 0) return "Music Assistant " + operation + " failed [curl " + curlCode + "]"
    if (httpStatus === 401) return "Music Assistant authentication failed (" + operation + ") [HTTP 401]"
    if (httpStatus === 403) return "Music Assistant permission denied (" + operation + ") [HTTP 403]"
    if (httpStatus < 200 || httpStatus >= 300) return "Music Assistant " + operation + " failed [HTTP " + httpStatus + "]"
    return ""
  }

  function jsonErrorMessage(payload) {
    if (!payload || typeof payload !== "object" || Array.isArray(payload) || !payload.error) return ""
    var error = payload.error
    var detail = error && typeof error === "object" ? error.message : error
    detail = String(detail || "request rejected").replace(/\s+/g, " ")
    if (detail.length > 300) detail = detail.substring(0, 300) + "…"
    return "Music Assistant " + (request.label || "request") + ": " + detail
  }

  function reportFailure(message) {
    request.errorText = message
    console.warn("[music-assistant] " + message)
    if (typeof request.errorReporter === "function") request.errorReporter(message, request.label, request.context)
  }

  function reportSuccess() {
    request.errorText = ""
    if (typeof request.successReporter === "function") request.successReporter(request.label, request.context)
  }

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
      var raw = String(text || "")
      var curlCode = 0
      var httpStatus = 200
      var metadata = raw.match(/^__MA_HTTP__ ([0-9]+) ([0-9]{3})\n/)
      // Accept unprefixed output for synthetic tests and callers that construct
      // a custom payload; production MaApi requests always carry the prefix.
      if (metadata) {
        curlCode = Number(metadata[1])
        httpStatus = Number(metadata[2])
        raw = raw.substring(metadata[0].length)
      }

      var data = null
      var failure = request.failureMessage(curlCode, httpStatus)
      request.replyValid = false
      if (failure === "") {
        try {
          var payload = JSON.parse(raw)
          failure = request.jsonErrorMessage(payload)
          if (failure === "") {
            request.replyValid = true
            data = payload !== null && typeof payload === "object" && !Array.isArray(payload) && payload.result !== undefined
              ? payload.result : payload
          }
        } catch (e) {
          failure = "Music Assistant " + (request.label || "request") + " returned invalid data"
        }
      }
      if (request.requestGeneration !== request.connectionGeneration) return
      if (failure !== "") request.reportFailure(failure)
      else request.reportSuccess()
      // Existing consumers already treat null as failure and release loading or
      // poll state. Keep that cleanup path while reporting the richer error.
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
