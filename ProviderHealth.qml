import QtQuick
import "MaApi.js" as MaApi

// Polls only the non-secret provider status fields needed by the popup. Keeping
// this outside Service.qml prevents provider setup data from entering the main
// player model and gives provider health its own slow polling cadence.
Item {
  id: root

  property bool ready: false
  property int connectionGeneration: 0
  property string serverUrl: ""
  property string token: ""
  property var providers: []
  property string requestError: ""

  readonly property var problems: root.problemProviders()
  readonly property string summary: root.problemSummary()

  onConnectionGenerationChanged: {
    root.providers = []
    root.requestError = ""
    request.clearPending()
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.ready
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  function refresh() {
    if (!root.ready || !root.serverUrl || !root.token || request.busy) return false
    return request.send(MaApi.buildArgs(root.serverUrl, root.token, "config/providers", {}, "provider-health"),
      { connectionGeneration: root.connectionGeneration })
  }

  function mapProviders(data) {
    if (!Array.isArray(data)) {
      root.requestError = "Provider status unavailable"
      return
    }
    root.requestError = ""
    root.providers = MaApi.boundedArray(data, 128).map(function(provider) {
      var lastError = provider && provider.last_error
      return {
        domain: MaApi.boundedString(provider && provider.domain, 100),
        instance_id: MaApi.boundedString(provider && provider.instance_id, 100),
        name: MaApi.boundedString(provider && (provider.name || provider.default_name || provider.domain), 200),
        enabled: !!(provider && provider.enabled),
        status: MaApi.boundedString(provider && provider.status, 50),
        error: MaApi.boundedString(lastError && (lastError.message || lastError), 500)
      }
    })
  }

  function providerProblem(provider) {
    if (!provider || !provider.enabled) return false
    if (provider.status === "loaded" || provider.status === "loading" || provider.status === "disabled") return false
    return provider.status === "auth_required" || provider.status === "error"
      || provider.status === "unavailable" || provider.error !== ""
  }

  function problemProviders() {
    return root.providers.filter(function(provider) { return root.providerProblem(provider) })
  }

  function problemText(provider) {
    if (!provider) return "Provider needs attention"
    if (provider.status === "auth_required") return "Sign-in required"
    if (provider.error) return provider.error
    if (provider.status) return provider.status.replace(/_/g, " ")
    return "Provider needs attention"
  }

  function problemSummary() {
    var list = root.problems
    if (!list || list.length === 0) return ""
    if (list.length === 1) return list[0].name + ": " + root.problemText(list[0])
    return list.length + " providers need attention"
  }

  MaRequest {
    id: request
    connectionGeneration: root.connectionGeneration
    label: "providers"
    onResult: function(data, ctx) {
      if (!root.ready || !ctx || ctx.connectionGeneration !== root.connectionGeneration) return
      root.mapProviders(data)
    }
  }
}
