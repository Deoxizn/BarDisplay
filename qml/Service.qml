pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// BarDisplay service — owns which displays the bar appears on, persists that
// to shell.json (`bar.monitors`), and keeps the active bar able to honor it.
//
// The bar plugins themselves have no per-display toggle, so this service also
// runs scripts/ensure-bar-support.sh against the active bar's QML: idempotent,
// backed up, and self-healing after an update replaces the file (which wipes
// any previous support). When the support patch had to be applied the shell is
// reloaded once so the bar picks it up.
Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  readonly property int contractVersion: 1
  readonly property bool ready: true

  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir || "") : ""
  readonly property string supportScript: sourceDir + "/scripts/ensure-bar-support.sh"

  // ---- active bar ----
  readonly property string activeBarId: shell && shell.activeBarId
    ? String(shell.activeBarId) : ""
  readonly property var activeBarManifest: shell && shell.activeBarManifest
    ? shell.activeBarManifest : null
  readonly property string activeBarFile: activeBarManifest
      && activeBarManifest.__sourceDir
      && activeBarManifest.entryPoints
      && activeBarManifest.entryPoints.bar
    ? String(activeBarManifest.__sourceDir).replace(/\/+$/, "")
      + "/" + String(activeBarManifest.entryPoints.bar)
    : ""

  // ---- state ----
  // Monitors the bar should appear on. Empty list means "every display"
  // (the default), which also guarantees the bar can never be hidden on every
  // display at once, so the toggle UI always stays reachable.
  property var enabledMonitors: []
  // idle | patching | ok | needs-admin | error | unsupported
  property string supportState: "idle"
  property string supportDetail: ""
  property bool supportBusy: false
  property bool reloadScheduled: false

  // ---- monitor info ----
  // Per-monitor refresh rate in Hz, keyed by output name, from `hyprctl
  // monitors -j`. Replaced wholesale (new object) so widgets' bindings that
  // read this property are re-evaluated.
  property var refreshRates: ({})

  function fetchMonitorRates() {
    monitorProc.command = ["hyprctl", "monitors", "-j"]
    monitorProc.running = true
  }

  // ---- display helpers ----
  function displayNames() {
    var out = []
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var n = String(screens[i].name || "")
      if (n !== "") out.push(n)
    }
    return out
  }

  function isBarShown(name) {
    var key = String(name || "")
    if (key === "") return true
    var list = root.enabledMonitors
    if (!list || list.length === 0) return true
    return list.indexOf(key) >= 0
  }

  function hiddenCount() {
    var names = root.displayNames()
    var hidden = 0
    for (var i = 0; i < names.length; i++)
      if (!root.isBarShown(names[i])) hidden++
    return hidden
  }

  // ---- config ----
  function refreshFromConfig() {
    var config = shell && shell.barConfig && typeof shell.barConfig === "object"
      ? shell.barConfig : ({})
    var list = Array.isArray(config.monitors) ? config.monitors
      : (Array.isArray(config.barMonitors) ? config.barMonitors : [])
    var next = []
    for (var i = 0; i < list.length; i++) {
      var m = String(list[i] || "")
      if (m !== "" && next.indexOf(m) < 0) next.push(m)
    }
    root.enabledMonitors = next
  }

  function persist() {
    if (!shell || typeof shell.mutateShellConfig !== "function") return
    var list = root.enabledMonitors.slice()
    shell.mutateShellConfig(function(config) {
      if (!config || typeof config !== "object") return
      if (!config.bar || typeof config.bar !== "object") config.bar = {}
      config.bar.monitors = list
    })
  }

  function pushToBar() {
    if (shell && shell.bar && "barMonitors" in shell.bar)
      shell.bar.barMonitors = root.enabledMonitors
  }

  // ----
  function setMonitorShown(name, shown) {
    var key = String(name || "")
    if (key === "") return
    var names = root.enabledMonitors.slice()
    var wasShown = root.isBarShown(key)
    if (shown === wasShown) return
    if (shown) {
      var removeAt = names.indexOf(key)
      if (removeAt >= 0) names.splice(removeAt, 1)
    } else {
      var all = root.displayNames()
      for (var k = 0; k < all.length; k++)
        if (names.indexOf(all[k]) < 0) names.push(all[k])
      var offAt = names.indexOf(key)
      if (offAt >= 0) names.splice(offAt, 1)
    }
    root.enabledMonitors = names
    root.persist()
    root.pushToBar()
  }

  // ---- support patch ----
  function ensureSupport() {
    // The host assigns `shell` before `manifest`, so the source dir may not be
    // resolvable yet; onManifestChanged re-runs this.
    if (root.sourceDir === "") return
    if (root.activeBarFile === "") {
      root.supportState = "unsupported"
      return
    }
    if (root.supportBusy) return
    root.supportBusy = true
    root.supportState = "patching"
    patchProc.command = [root.supportScript, root.activeBarFile]
    patchProc.running = true
  }

  function runAdminPatch() {
    if (root.activeBarFile === "" || root.supportBusy) return
    root.supportBusy = true
    root.supportState = "patching"
    patchProc.command = ["pkexec", root.supportScript, root.activeBarFile]
    patchProc.running = true
  }

  function scheduleReload() {
    if (root.reloadScheduled) return
    root.reloadScheduled = true
    Qt.callLater(function() {
      root.reloadScheduled = false
      Quickshell.reload(false)
    })
  }

  Process {
    id: patchProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var status = lines.length > 0 ? String(lines[0] || "").trim() : ""
        root.supportDetail = lines.length > 1 ? String(lines[1] || "").trim() : ""
        if (status === "patched") {
          root.supportState = "ok"
          root.scheduleReload()
        } else if (status === "ok") {
          root.supportState = "ok"
        } else if (status === "needs-admin") {
          root.supportState = "needs-admin"
        } else if (status === "unsupported-bar") {
          root.supportState = "unsupported"
        } else {
          root.supportState = "error"
        }
      }
    }
    onExited: {
      root.supportBusy = false
      root.pushToBar()
    }
  }

  // Quickshell's Process only warns on start failure (no signal), so a
  // watchdog keeps the service from wedging in the "patching" state if the
  // script never runs.
  Timer {
    id: patchWatchdog
    interval: 10000
    running: root.supportBusy
    onTriggered: {
      root.supportBusy = false
      if (root.supportState === "patching") root.supportState = "error"
    }
  }

  // Self-healing: if the active bar file is replaced on disk (an update that
  // wiped the support patch), re-apply it.
  FileView {
    id: barFileWatch
    path: root.activeBarFile
    watchChanges: true
    printErrors: false
    onFileChanged: Qt.callLater(root.ensureSupport)
  }

  onActiveBarFileChanged: {
    barFileWatch.path = root.activeBarFile
    root.ensureSupport()
    root.pushToBar()
  }

  onManifestChanged: root.ensureSupport()

  onShellChanged: {
    root.refreshFromConfig()
    root.ensureSupport()
    root.pushToBar()
  }

  Process {
    id: monitorProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rates = ({})
        try {
          var arr = JSON.parse(String(text || ""))
          if (Array.isArray(arr)) {
            for (var i = 0; i < arr.length; i++) {
              var m = arr[i]
              var name = String(m && m.name || "")
              var hz = m ? Number(m.refreshRate) || 0 : 0
              if (name !== "" && hz > 0) rates[name] = hz
            }
          }
        } catch (error) {
          rates = ({})
        }
        root.refreshRates = rates
      }
    }
  }

  Connections {
    target: shell
    function onBarChanged() { root.pushToBar() }
  }

  Component.onCompleted: {
    root.refreshFromConfig()
    root.fetchMonitorRates()
  }
}
