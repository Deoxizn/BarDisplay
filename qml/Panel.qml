pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// BarDisplay widget + popup. Root is a qs.Ui.Panel (the bar button lives on
// it, plus the per-display toggle popup), so the Shibumi host treats it as a
// single mounted widget whose popup it can host.
//
// The KeyboardPanel MUST be a direct child of this root (not buried in a
// Loader or inner Item): the Shibumi host's compatibility adapter scans the
// mounted widget's `data` for it, then re-anchors the card to the visible bar
// edge and re-sizes it to the real content height. Otherwise the panel derives
// its offset from the screen-sized bar window and lands at the bottom of the
// screen collapsed to the 120px safety minimum.
Panel {
  id: root
  moduleName: "dev.deoxizn.bardisplay"
  ipcTarget: ""
  manageIpc: false

  readonly property string serviceId: "dev.deoxizn.bardisplay"
  readonly property var service: bar && bar.shell
    && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(serviceId) : null

  // Theming: Shibumi VisualTokens when present, otherwise the stock host
  // adapter, otherwise the theme singletons.
  HostTokens {
    id: hostTokens
    bar: root.bar
  }

  readonly property var tokens: bar && "visualTokens" in bar && bar.visualTokens
    ? bar.visualTokens : hostTokens

  readonly property color contentForeground: tokens && tokens.ink
    ? tokens.ink : (bar ? bar.foreground : Color.foreground)
  readonly property color contentBackground: tokens && tokens.paper
    ? tokens.paper : (bar ? bar.background : Color.background)
  readonly property string contentFontFamily: tokens && tokens.fontFamily
    ? tokens.fontFamily : (bar ? bar.fontFamily : Style.font.family)
  readonly property int labelSize: tokens ? tokens.labelSize : Style.font.body
  readonly property int captionSize: tokens ? tokens.captionSize : Style.font.caption
  readonly property int iconSize: tokens ? tokens.iconSize : Style.space(15)

  // ---- bar button state ----
  readonly property int totalDisplays: Quickshell.screens.length
  readonly property int hiddenDisplays: root.service ? root.service.hiddenCount() : 0
  readonly property int shownDisplays: root.totalDisplays - root.hiddenDisplays

  readonly property string glyph: "󰍹"
  readonly property string labelText: root.hiddenDisplays > 0
    ? root.shownDisplays + "/" + root.totalDisplays : ""
  readonly property string tooltipText: root.hiddenDisplays > 0
    ? "Bar hidden on " + root.hiddenDisplays
      + (root.hiddenDisplays === 1 ? " display" : " displays")
      + " \u2014 click to change"
    : "Bar on every display \u2014 click to change"

  function displayDescription(screen) {
    var parts = []
    if (screen && Number(screen.width) > 0 && Number(screen.height) > 0)
      parts.push(screen.width + "\u00d7" + screen.height)
    var hz = screen ? Math.round(Number(screen.refreshRate) || 0) : 0
    if (hz > 0) parts.push(hz + " Hz")
    if (screen && String(screen.name || "") === String(root.primaryName))
      parts.push("primary")
    return parts.join("  \u00b7  ")
  }

  readonly property string primaryName: Hyprland.focusedMonitor
    ? String(Hyprland.focusedMonitor.name || "") : ""

  // Plain JS objects so Repeater delegates get a working `modelData`
  // (Quickshell.screens is a C++ object model and does not provide it).
  // The `service.monitorInfo` property access keeps this re-computed when the
  // service's hyprctl scan replaces the map. Width/height are the physical
  // pixels from hyprctl (Quickshell's screen width/height are logical pixels
  // divided by the monitor scale, e.g. 3840x2160 at scale 1.333 would report
  // as 2880x1620), falling back to the logical size if the scan is pending.
  readonly property var displayModel: {
    var out = []
    var screens = Quickshell.screens
    var info = root.service && root.service.monitorInfo
      ? root.service.monitorInfo : ({})
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      var name = String(s.name || "")
      var mi = info[name] || ({})
      out.push({
        name: name,
        width: Number(mi.width) || Number(s.width),
        height: Number(mi.height) || Number(s.height),
        refreshRate: Number(mi.refreshRate) || 0
      })
    }
    return out
  }

  readonly property int screenCount: root.displayModel.length
  readonly property bool supportMatters: root.service
    && root.service.supportState !== "ok"
    && root.service.supportState !== "unsupported"
  readonly property bool showStatus: root.service
    && root.service.supportState !== "ok"

  readonly property string statusText: {
    var st = root.service ? root.service.supportState : "idle"
    if (st === "needs-admin") return "The bar needs a one-time admin grant for per-display toggling."
    if (st === "error") return "Could not update the bar. " + (root.service ? root.service.supportDetail : "")
    if (st === "unsupported") return "This bar cannot be toggled per display."
    if (st === "patching") return "Checking bar support\u2026"
    return "Bar support active"
  }

  readonly property real rowHeight: Style.space(54)
  readonly property real rowSpacing: rowHeight + Style.space(2)
  readonly property real headerHeight: Style.space(34)
  readonly property real statusHeight: Style.space(62)

  readonly property real estimatedHeight: root.headerHeight
    + root.screenCount * root.rowSpacing
    + (root.showStatus ? root.statusHeight : Style.space(8))

  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  WidgetButton {
    id: pill
    anchors.fill: parent
    bar: root.bar
    text: root.glyph + (root.labelText !== "" ? " " + root.labelText : "")
    tooltipText: root.tooltipText
    active: root.hiddenDisplays > 0
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(root.estimatedHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "d" || t === "D") root.close()
      }
    }

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: column.width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: column
        width: Math.max(scroll.width, Style.space(300))
        spacing: Style.space(2)

        // ---- Header ----
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: "BAR DISPLAY"
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: root.captionSize
            font.letterSpacing: 1
            renderType: Text.NativeRendering
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: root.screenCount + (root.screenCount === 1 ? " display" : " displays")
            color: Qt.darker(root.contentForeground, 1.9)
            font.family: root.contentFontFamily
            font.pixelSize: root.captionSize
            renderType: Text.NativeRendering
          }
        }

        // ---- Per-display toggles ----
        Repeater {
          model: root.displayModel

          delegate: Toggle {
            required property var modelData
            width: column.width
            label: modelData.name
            description: root.displayDescription(modelData)
            checked: root.service ? root.service.isBarShown(modelData.name) : true
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: {
              if (root.service)
                root.service.setMonitorShown(modelData.name, !root.service.isBarShown(modelData.name))
            }
          }
        }

        // ---- Support status ----
        Item {
          width: parent.width
          height: root.statusHeight
          visible: root.showStatus

          Rectangle {
            anchors.fill: parent
            anchors.topMargin: Style.space(6)
            radius: Style.cornerRadius
            color: Style.controlFill(false, false, root.contentForeground, Color.accent)
          }

          Text {
            anchors.left: parent.left
            anchors.right: adminButton.visible ? adminButton.left : parent.right
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: root.captionSize
            wrapMode: Text.WordWrap
          }

          Button {
            id: adminButton
            visible: root.service && root.service.supportState === "needs-admin"
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: "Apply"
            foreground: root.contentForeground
            accent: Color.accent
            fontFamily: root.contentFontFamily
            onClicked: {
              if (root.service) root.service.runAdminPatch()
            }
          }
        }
      }
    }
  }
}
