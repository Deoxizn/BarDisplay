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
// The built-in Omarchy bar (and any bar outside the watched dir) is never
// hot-reloaded, so after patching one the service confirms the restart to the
// user and runs `omarchy restart shell` (Omarchy's own restart, not
// Quickshell.reload(false), which on quickshell-git tears down the IPC handler
// registry in a way that can use-after-free and crash the shell).
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
  // | restart-pending | restarting | restart-needed
  property string supportState: "idle"
  property string supportDetail: ""
  property bool supportBusy: false
  // A system bar was patched; a shell restart is required (and scheduled)
  // before the running bar honors bar.monitors. Stops reconcile from
  // clobbering the restart states with a stale-bar verdict.
  property bool restartPending: false

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

  // ---- system-bar restart ----
  // User-owned bars live under the watched plugin dir, so Omarchy's watcher
  // re-creates them the moment the patch writes their QML. The built-in bar
  // (and any bar outside that dir) is not watched: it only re-reads its QML
  // when the whole shell restarts, so a freshly patched system bar stays
  // stale in the running shell until then.
  function isSystemBar() {
    var file = root.activeBarFileFor()
    if (file === "") return false
    var dir = root.shell && root.shell.pluginRegistry
      ? String(root.shell.pluginRegistry.pluginsDir || "") : ""
    if (dir === "") return false
    dir = dir.replace(/\/+$/, "") + "/"
    return file.indexOf(dir) !== 0
  }

  // Ground truth for the running bar: the patch adds `barMonitors` to the
  // bar root, so its presence means the live bar can honor per-display
  // visibility without a restart.
  function barHasSupport() {
    return root.shell && root.shell.bar && "barMonitors" in root.shell.bar
  }

  // The patch is on disk ("ok") but the running bar is stale — the shell was
  // never restarted after the file was written. Surface that and offer the
  // manual restart. Deferred until the bar itself has resolved.
  function reconcileStaleSystemBar() {
    if (root.restartPending) return
    if (!root.isSystemBar()) return
    if (root.supportState !== "ok") return
    if (!root.shell || !root.shell.bar) return
    if (root.barHasSupport()) return
    root.supportState = "restart-needed"
    root.supportDetail = "The bar is patched, but the shell needs a restart to apply per-display toggling."
  }

  // Confirm-then-restart: show the pending state (the panel renders it with
  // a Cancel option) for a few seconds, then restart via `omarchy restart
  // shell` — Omarchy's sanctioned, crash-free restart (Quickshell.reload is
  // deliberately avoided: it can use-after-free on quickshell-git).
  function scheduleRestart() {
    root.restartPending = true
    restartTimer.restart()
    // The pkexec dialog steals focus and closes the popup, so the pending
    // state alone is invisible. Toast the countdown (notify-send lands on
    // Omarchy's notification daemon) and tell the user where the Cancel is.
    notifyProc.command = ["notify-send", "-a", "BarDisplay",
      "Bar patched",
      "The shell will restart in 8 seconds to apply per-display toggling. Open the BarDisplay widget to cancel."]
    notifyProc.running = true
  }

  function restartShell() {
    if (root.restartPending && root.supportState === "restarting") return
    root.restartPending = true
    root.supportState = "restarting"
    root.supportDetail = "Restarting the shell to apply bar support\u2026"
    var omarchyPath = root.shell && root.shell.omarchyPath
      ? String(root.shell.omarchyPath) : ""
    var omarchyBin = omarchyPath !== "" ? omarchyPath + "/bin/omarchy" : "omarchy"
    restartProc.command = [
      "bash", "-c",
      "setsid \"$0\" restart shell >/dev/null 2>&1 &", omarchyBin
    ]
    restartProc.running = true
    restartWatchdog.restart()
  }

  function cancelRestart() {
    restartTimer.stop()
    restartWatchdog.stop()
    root.restartPending = false
    root.supportState = "restart-needed"
    root.supportDetail = "Restart cancelled. The bar patch takes effect after the next shell restart."
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
    // While a shell restart is pending, skip re-checks (e.g. the file watcher
    // firing when pkexec wrote the bar): the restart itself is what applies it.
    if (root.restartPending) return
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
    if (root.restartPending) return
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
        var detail = lines.length > 1 ? String(lines[1] || "").trim() : ""
        if (status === "patched" || status === "ok") {
          if (root.restartPending) {
            // A restart is already confirmed/scheduled. A re-run of the patch
            // check ("ok", e.g. from the file watcher after pkexec wrote the
            // bar) must not downgrade the pending state.
            if (root.supportState !== "restarting")
              root.supportDetail = root.supportDetail || detail
          } else if (root.isSystemBar() && !root.barHasSupport()) {
            // A system bar cannot be hot-reloaded, so a fresh patch only
            // takes effect after the shell restarts.
            if (status === "patched") {
              root.supportState = "restart-pending"
              root.supportDetail = "Bar patched. The shell will restart in 8 seconds to apply per-display toggling."
              root.scheduleRestart()
            } else {
              root.supportState = "ok"
              root.supportDetail = ""
              root.reconcileStaleSystemBar()
            }
          } else {
            root.supportState = "ok"
            root.supportDetail = ""
          }
        } else if (status === "needs-admin") {
          root.supportState = "needs-admin"
          root.supportDetail = detail
        } else if (status === "unsupported-bar") {
          root.supportState = "unsupported"
          root.supportDetail = ""
        } else {
          root.supportState = "error"
          root.supportDetail = detail
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

  // Pending restart countdown: gives the panel time to show the
  // "the shell will restart" confirmation (and a Cancel) before it happens.
  Timer {
    id: restartTimer
    interval: 8000
    onTriggered: {
      if (root.restartPending) root.restartShell()
    }
  }

  // If the restart never takes effect we are still alive when this fires.
  Timer {
    id: restartWatchdog
    interval: 10000
    onTriggered: {
      if (root.restartPending && root.supportState === "restarting") {
        root.supportState = "restart-needed"
        root.supportDetail = "The shell did not restart. Use the Restart button to try again."
      }
    }
  }

  Process {
    id: restartProc
    command: []
    // The restart runs detached (setsid), so it survives the shell being
    // killed and can launch the replacement. Nothing to read here.
  }

  Process {
    id: notifyProc
    command: []
    // Fires the `notify-send` toast for the pending-restart countdown.
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
    root.reconcileStaleSystemBar()
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
    function onBarChanged() {
      root.pushToBar()
      root.reconcileStaleSystemBar()
    }
  }

  Component.onCompleted: {
    root.refreshFromConfig()
    root.fetchMonitorInfo()
  }
}
