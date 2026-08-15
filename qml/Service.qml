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
// any previous support). User-owned bars live under ~/.config/omarchy/plugins,
// so Omarchy's plugin watcher re-creates the bar automatically when the patch
// writes its QML — the bar picks the support up with no shell reload needed.
// (Quickshell.reload(false) is deliberately avoided: on quickshell-git it tears
// down the IPC handler registry in a way that can use-after-free and crash the
// shell.)
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

  // The host wires `shell`, `manifest`, ... synchronously right after the
  // component is created, and QML defers re-evaluating bindings that read
  // nested members of a `property var` (like `manifest.__sourceDir`) until
  // after those change handlers run. So the readonly bindings above can read
  // stale ("") inside onShellChanged/onManifestChanged/ensureSupport and make
  // the self-heal bail before it ever patches the bar. Compute the values
  // fresh from the objects themselves at call time instead of trusting the
  // bindings.
  function sourceDirFor() {
    var m = root.manifest || null
    return m && m.__sourceDir ? String(m.__sourceDir) : ""
  }

  function activeBarFileFor() {
    var m = root.shell && root.shell.activeBarManifest ? root.shell.activeBarManifest : null
    if (!m || !m.__sourceDir || !m.entryPoints || !m.entryPoints.bar) return ""
    return String(m.__sourceDir).replace(/\/+$/, "")
      + "/" + String(m.entryPoints.bar)
  }

  function supportScriptFor(sourceDir) {
    return String(sourceDir || "") + "/scripts/ensure-bar-support.sh"
  }

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

  // ---- monitor info ----
  // Per-monitor physical resolution and refresh rate in Hz, keyed by output
  // name, from `hyprctl monitors -j`. Quickshell screens report logical
  // (scaled) pixels, so the physical width/height come from hyprctl instead.
  // Replaced wholesale (new object) so widgets' bindings that read this
  // property are re-evaluated.
  property var monitorInfo: ({})

  function fetchMonitorInfo() {
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
    var srcDir = root.sourceDirFor()
    var barFile = root.activeBarFileFor()
    if (srcDir === "") return
    if (barFile === "") {
      // Only when the active bar itself has resolved can we call it
      // unsupported; early in host wiring it may simply not be resolved yet.
      if (root.shell && root.shell.activeBarId) root.supportState = "unsupported"
      return
    }
    if (root.supportBusy) return
    root.supportBusy = true
    root.supportState = "patching"
    patchProc.command = [root.supportScriptFor(srcDir), barFile]
    patchProc.running = true
  }

  function runAdminPatch() {
    var srcDir = root.sourceDirFor()
    var barFile = root.activeBarFileFor()
    if (barFile === "" || root.supportBusy) return
    root.supportBusy = true
    root.supportState = "patching"
    patchProc.command = ["pkexec", root.supportScriptFor(srcDir), barFile]
    patchProc.running = true
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
    barFileWatch.path = root.activeBarFileFor()
    root.ensureSupport()
    root.pushToBar()
  }

  onManifestChanged: {
    barFileWatch.path = root.activeBarFileFor()
    root.ensureSupport()
  }

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
        var info = ({})
        try {
          var arr = JSON.parse(String(text || ""))
          if (Array.isArray(arr)) {
            for (var i = 0; i < arr.length; i++) {
              var m = arr[i]
              var name = String(m && m.name || "")
              if (name === "") continue
              info[name] = {
                width: m ? Number(m.width) || 0 : 0,
                height: m ? Number(m.height) || 0 : 0,
                refreshRate: m ? Number(m.refreshRate) || 0 : 0
              }
            }
          }
        } catch (error) {
          info = ({})
        }
        root.monitorInfo = info
      }
    }
  }

  Connections {
    target: shell
    function onBarChanged() { root.pushToBar() }
  }

  Component.onCompleted: {
    root.refreshFromConfig()
    root.fetchMonitorInfo()
  }
}
