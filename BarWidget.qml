import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry for Govee lights.
//
// A bulb, lit while any light is on. Click for the panel, middle-click to
// switch everything, scroll to dim or brighten the lights that are on.
BarWidget {
  id: root
  moduleName: "com.eldtechnologies.govee"

  readonly property bool configured: panelLoader.item ? panelLoader.item.configured : false
  readonly property bool anyOn: panelLoader.item ? panelLoader.item.anyOn : false

  // nf-md-lightbulb / nf-md-lightbulb_outline
  readonly property string iconOn: "󰌵"
  readonly property string iconOff: "󰌶"

  // Shape contract for Bar.findPanelWidget popout routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function toggle() { togglePanel() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function refresh() { if (panelLoader.item) panelLoader.item.reloadState(0) }

  function middleClick() {
    var item = panelLoader.item
    if (!item || !item.configured) return
    var mode = root.setting("middleClick", "toggle-all")
    if (mode === "toggle-all") item.setPower("all", !item.anyOn)
    else if (mode === "off-all") item.setPower("all", false)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "com.eldtechnologies.govee"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // Wheel steps are summed and sent once the wheel rests, so a fast spin is
  // one command per light rather than one per notch.
  property int pendingScroll: 0

  Timer {
    id: scrollTimer
    interval: 350
    onTriggered: {
      if (root.pendingScroll !== 0 && panelLoader.item)
        panelLoader.item.nudgeLitBrightness(root.pendingScroll)
      root.pendingScroll = 0
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: !root.configured ? root.iconOff + "  setup" : root.anyOn ? root.iconOn : root.iconOff
    labelVisible: true
    hasVisualContent: text !== ""
    horizontalMargin: 9.625
    verticalPadding: 8.75

    active: root.anyOn
    useActiveColor: true

    tooltipText: panelLoader.item ? panelLoader.item.barTooltip : "Govee"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
      else if (buttonCode === Qt.MiddleButton) root.middleClick()
      else if (buttonCode === Qt.RightButton) root.refresh()
    }

    onWheelMoved: function(delta) {
      var step = Number(root.setting("scrollStep", 10))
      if (!(step > 0) || !root.anyOn || delta === 0) return
      root.pendingScroll += delta > 0 ? step : -step
      scrollTimer.restart()
    }
  }
}
