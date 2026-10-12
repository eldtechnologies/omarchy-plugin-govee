import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Govee popup.
//
// The panel never touches the network. `eld-govee` finds the lights, drives
// them (LAN first, the Govee cloud for the rest), and writes state.json; the
// panel watches that file and runs the helper for every change.
//
// Commands run one at a time from a queue. A newer command for the same light
// and setting replaces one still waiting, so dragging a slider or spinning the
// wheel sends the final value, not every step on the way: the Govee cloud
// allows 10,000 requests a day.
Panel {
  id: root
  moduleName: "com.eldtechnologies.govee"
  manageIpc: false

  property Item anchorItem: null
  property var hostWidget: null

  readonly property string home: Quickshell.env("HOME")
  // A relative XDG_STATE_HOME is invalid by the spec; the helper ignores it too.
  readonly property string stateHome: String(Quickshell.env("XDG_STATE_HOME") || "").charAt(0) === "/"
                                      ? Quickshell.env("XDG_STATE_HOME") : home + "/.local/state"
  readonly property string statePath: stateHome + "/eld-govee/state.json"
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace("file://", ""))
  readonly property string cli: pluginDir + "bin/eld-govee"

  // Version and release notes come from manifest.json alone.
  property string pluginVersion: ""
  property string homepage: ""
  readonly property string releaseUrl: homepage !== "" && pluginVersion !== ""
                                       ? homepage + "/releases/tag/v" + pluginVersion : ""

  FileView {
    path: root.pluginDir + "manifest.json"
    printErrors: false
    // An update rewrites the manifest under a running shell.
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        root.pluginVersion = manifest.version || ""
        root.homepage = String(manifest.homepage || "").replace(/\/+$/, "")
      } catch (error) { }
    }
  }

  // ---- settings ------------------------------------------------------

  readonly property string refreshPreset: {
    var value = setting("refresh", "balanced")
    return ["fast", "balanced", "efficient"].indexOf(value) >= 0 ? value : "balanced"
  }
  // While closed: how often to look, and how old cloud readings may get.
  // LAN lights are read every time for free; only cloud lights cost requests.
  readonly property int backgroundSeconds: refreshPreset === "fast" ? 30
                                           : refreshPreset === "efficient" ? 300 : 60
  readonly property int backgroundCloudAge: refreshPreset === "fast" ? 300
                                            : refreshPreset === "efficient" ? 3600 : 900
  readonly property bool showHidden: setting("showHidden", false) === true

  // ---- state ---------------------------------------------------------

  property var state: ({})
  // Optimistic values per device id, shown until the helper catches up.
  property var overrides: ({})
  // Follow-theme switches by target, likewise.
  property var followOverrides: ({})
  readonly property bool demo: state && state.demo === true
  readonly property string themeColor: state && state.theme ? (state.theme.color || "") : ""

  readonly property bool configured: state && state.configured === true
  readonly property bool hasCloud: state && state.cloud === true
  readonly property var allDevices: {
    var list = state && state.devices ? state.devices : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var device = list[i]
      var extra = root.overrides[device.id]
      if (extra) {
        device = Object.assign({}, device)
        for (var key in extra) device[key] = extra[key]
      }
      out.push(device)
    }
    return out
  }
  readonly property var devices: allDevices.filter(function(d) { return root.showHidden || !d.hidden })
  readonly property var visibleDevices: allDevices.filter(function(d) { return !d.hidden })
  readonly property var groups: {
    var list = state && state.groups ? state.groups : []
    return list.map(function(group) {
      var members = root.allDevices.filter(function(d) { return group.members.indexOf(d.id) >= 0 })
      var on = members.filter(function(d) { return d.power === true })
      var levels = on.filter(function(d) { return typeof d.brightness === "number" })
                     .map(function(d) { return d.brightness })
      return Object.assign({}, group, {
        power: on.length > 0,
        onCount: on.length,
        brightness: levels.length ? Math.round(levels.reduce(function(a, b) { return a + b }, 0) / levels.length)
                                  : group.brightness
      })
    })
  }
  readonly property int onCount: visibleDevices.filter(function(d) { return d.power === true && d.online !== false }).length
  readonly property bool anyOn: onCount > 0
  readonly property string errorText: state && state.error && state.error.message ? state.error.message : ""
  property string flash: ""

  readonly property string barTooltip: {
    if (!configured) return "Govee — not set up yet"
    if (visibleDevices.length === 0) return "Govee — no lights found"
    var lines = [onCount + " of " + visibleDevices.length + " on"]
    for (var i = 0; i < visibleDevices.length; i++) {
      var d = visibleDevices[i]
      lines.push((d.online === false ? "! " : d.power ? "● " : "○ ") + d.name
                 + (d.online === false ? " offline"
                    : d.power && typeof d.brightness === "number" ? "  " + d.brightness + "%" : ""))
    }
    return lines.join("\n")
  }

  function applyState(text) {
    if (!text || text.trim() === "") return
    try {
      root.state = JSON.parse(text)
      if (!cmdProcess.running && root.queue.length === 0) {
        root.overrides = ({})
        root.followOverrides = ({})
      }
    } catch (error) { }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.state = ({})
  }

  // ---- commands ------------------------------------------------------

  property var queue: []

  // Commands that replace an older one still waiting for the same target.
  readonly property var coalescing: ({ "on": "power", "off": "power", "toggle": "power",
                                       "brightness": "brightness", "color": "look",
                                       "temp": "look", "scene": "look" })

  function run(args) {
    var kind = root.coalescing[args[0]]
    var next = root.queue
    if (kind) {
      next = next.filter(function(other) {
        return !(root.coalescing[other[0]] === kind && other[1] === args[1])
      })
    }
    next.push(args)
    root.queue = next
    pump()
  }

  // "--" before names and targets: a light or group called "-h" is a name,
  // not an option. theme and group take a subcommand first.
  function helperArgs(args) {
    var split = (args[0] === "theme" || args[0] === "group") ? 2 : 1
    return args.length > split ? args.slice(0, split).concat(["--"], args.slice(split)) : args
  }

  function pump() {
    if (cmdProcess.running || root.queue.length === 0) return
    cmdProcess.command = [root.cli].concat(helperArgs(root.queue[0]))
    root.queue = root.queue.slice(1)
    cmdProcess.running = true
    cmdWatchdog.restart()  // each queued command gets its own time
  }

  function helperError(text, fallback) {
    var message = String(text || "").trim().replace(/^eld-govee: /, "")
    return message !== "" ? message.split("\n")[0] : fallback
  }

  Process {
    id: cmdProcess
    running: false
    stderr: StdioCollector { id: cmdErr }
    onExited: function(exitCode) {
      // Errors from the network land in state.json; this catches the rest
      // (an unsupported action, say) without showing either twice.
      if (exitCode !== 0) {
        var message = root.helperError(cmdErr.text, "command failed")
        if (message !== root.errorText) {
          root.flash = message
          flashTimer.restart()
        }
      }
      if (root.queue.length === 0) {
        root.overrides = ({})
        root.followOverrides = ({})
        stateFile.reload()
      }
      // Start the next one once this exit has fully settled.
      Qt.callLater(root.pump)
    }
  }

  Timer {
    id: flashTimer
    interval: 6000
    onTriggered: root.flash = ""
  }

  function targetDevices(target) {
    if (target === "all") return root.visibleDevices
    for (var g = 0; g < root.groups.length; g++)
      if (root.groups[g].name === target)
        return root.allDevices.filter(function(d) { return root.groups[g].members.indexOf(d.id) >= 0 })
    return root.allDevices.filter(function(d) { return d.id === target })
  }

  function override(target, fields) {
    var next = Object.assign({}, root.overrides)
    var list = targetDevices(target)
    for (var i = 0; i < list.length; i++)
      next[list[i].id] = Object.assign({}, next[list[i].id] || {}, fields)
    root.overrides = next
  }

  function setPower(target, on) {
    override(target, { power: on })
    run([on ? "on" : "off", target])
  }

  function toggleLight(target) {
    var on = targetDevices(target).some(function(d) { return d.power === true })
    setPower(target, !on)
  }

  function setBrightness(target, level) {
    level = Math.max(1, Math.min(100, Math.round(level)))
    override(target, { brightness: level, power: true })
    run(["brightness", target, String(level)])
  }

  function nudgeBrightness(target, delta) {
    var list = targetDevices(target).filter(function(d) { return d.power === true })
    if (list.length === 0) return
    var current = list[0].brightness || 50
    setBrightness(target, current + delta)
  }

  function setColor(target, hex) {
    override(target, { color: hex, mode: "color", power: true })
    run(["color", target, hex])
  }

  function follows(target, stored) {
    return target in root.followOverrides ? root.followOverrides[target] : stored === true
  }

  // The helper installs or removes the Omarchy theme-set hook, and recolours
  // the lights that are on.
  function setFollow(target, follow) {
    var next = Object.assign({}, root.followOverrides)
    next[target] = follow
    root.followOverrides = next
    run(["theme", follow ? "follow" : "unfollow", target])
  }

  function setTemp(target, kelvin) {
    kelvin = Math.round(kelvin / 100) * 100
    override(target, { colorTemp: kelvin, mode: "temp", power: true })
    run(["temp", target, String(kelvin)])
  }

  // An empty name goes back to the Govee (or model) name.
  function renameLight(device, field) {
    var name = field.text.trim()
    if (name !== device.name) {
      if (name !== "") override(device.id, { name: name })
      run(["rename", device.id, name])
    }
    keyCatcher.forceActiveFocus()
  }

  function setScene(target, name) {
    override(target, { mode: "scene", power: true })
    run(["scene", target, name])
  }

  // Lights that are on, for the bar's scroll wheel.
  function nudgeLitBrightness(delta) {
    var lit = root.visibleDevices.filter(function(d) {
      return d.power === true && d.online !== false && d.supports && d.supports.brightness
    })
    for (var i = 0; i < lit.length; i++) nudgeBrightness(lit[i].id, delta)
  }

  function reloadState(maxAge) {
    if (pollProcess.running) return
    pollProcess.command = [root.cli, "poll", "--max-age", String(maxAge === undefined ? 60 : maxAge)]
    pollProcess.running = true
  }

  Process {
    id: pollProcess
    running: false
    onExited: stateFile.reload()
  }

  // A helper that hangs (a dead network, a server that never finishes) must
  // not stall the panel: stop any run that takes far longer than it should.
  property string confirmForget: ""
  Timer {
    id: forgetTimer
    interval: 4000
    onTriggered: root.confirmForget = ""
  }

  Watchdog { id: cmdWatchdog; process: cmdProcess; seconds: 60 }
  Watchdog { process: pollProcess; seconds: 60 }
  Watchdog { process: sceneProcess; seconds: 60 }
  Watchdog { process: setupSave; seconds: 90 }

  Component.onCompleted: reloadState(root.backgroundCloudAge)

  Timer {
    interval: (root.opened ? 15 : root.backgroundSeconds) * 1000
    repeat: true
    running: root.configured
    onTriggered: root.reloadState(root.opened ? 60 : root.backgroundCloudAge)
  }

  // ---- scenes --------------------------------------------------------

  property var sceneLists: ({})
  property string sceneLoading: ""

  function loadScenes(target) {
    if (root.sceneLists[target] !== undefined || sceneProcess.running) return
    root.sceneLoading = target
    sceneProcess.target = target
    sceneProcess.command = [root.cli, "scenes", "--json", "--", target]
    sceneProcess.running = true
  }

  Process {
    id: sceneProcess
    property string target: ""
    running: false
    stdout: StdioCollector { id: sceneOut }
    stderr: StdioCollector { id: sceneErr }
    onExited: function(exitCode) {
      var next = Object.assign({}, root.sceneLists)
      try {
        next[target] = exitCode === 0 ? JSON.parse(sceneOut.text).map(function(s) {
          return { value: s.name, label: s.name + (s.kind === "diy" ? "  (DIY)" : s.kind === "snapshot" ? "  (snapshot)" : "") }
        }) : []
      } catch (error) {
        next[target] = []
      }
      root.sceneLists = next
      root.sceneLoading = ""
      if (exitCode !== 0) {
        root.flash = root.helperError(sceneErr.text, "could not load scenes")
        flashTimer.restart()
      }
    }
  }

  // ---- expansion, selection and the group editor ----------------------

  // "d:<id>" or "g:<name>": the row showing colour, white and scene controls.
  property string expanded: ""
  property int selectedIndex: 0
  property bool keyboardUsed: false
  // A text field in a row has focus: letters are typing, not shortcuts.
  property bool typing: false
  readonly property var rows: {
    var out = []
    for (var g = 0; g < root.groups.length; g++) out.push({ key: "g:" + root.groups[g].name, target: root.groups[g].name })
    for (var d = 0; d < root.devices.length; d++) out.push({ key: "d:" + root.devices[d].id, target: root.devices[d].id })
    return out
  }

  function expand(key, target) {
    root.expanded = root.expanded === key ? "" : key
    if (root.expanded !== "" && root.hasCloud) root.loadScenes(target)
  }

  property bool editing: false
  property string editingName: ""
  property var editorMembers: []

  function openEditor(group) {
    root.editingName = group ? group.name : ""
    root.editorMembers = group ? group.members.slice() : []
    groupNameField.text = root.editingName
    root.editing = true
    Qt.callLater(function() { groupNameField.forceActiveFocus() })
  }

  function closeEditor() {
    root.editing = false
    keyCatcher.forceActiveFocus()
  }

  function toggleMember(id) {
    var next = root.editorMembers.slice()
    var at = next.indexOf(id)
    if (at >= 0) next.splice(at, 1)
    else next.push(id)
    root.editorMembers = next
  }

  function saveGroup() {
    var name = groupNameField.text.trim()
    if (name === "" || root.editorMembers.length === 0) return
    if (root.editingName !== "" && root.editingName.toLowerCase() !== name.toLowerCase())
      run(["group", "remove", root.editingName])
    run(["group", "set", name].concat(root.editorMembers))
    root.closeEditor()
  }

  function deleteGroup() {
    if (root.editingName !== "") run(["group", "remove", root.editingName])
    root.closeEditor()
  }

  // ---- setup ---------------------------------------------------------

  property string setupBusy: ""
  property string setupError: ""
  property string setupDone: ""
  property bool changingKey: false
  readonly property bool settingUp: !root.configured || root.changingKey

  function connect(lanOnly) {
    if (setupSave.running) return
    var key = keyField.text.trim()
    if (!lanOnly && key === "") {
      root.setupError = "Paste the API key, or choose LAN only"
      return
    }
    root.setupError = ""
    root.setupBusy = lanOnly ? "Looking for lights on the network…" : "Checking the key with Govee…"
    setupSave.secret = lanOnly ? "" : key
    keyField.text = ""
    setupSave.command = lanOnly ? [root.cli, "setup-save", "--lan-only"] : [root.cli, "setup-save"]
    setupSave.running = true
  }

  // The key goes to the helper on stdin, never as an argument, and the field
  // is cleared as soon as it is sent.
  Process {
    id: setupSave
    property string secret: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: saveOut }
    stderr: StdioCollector { id: saveErr }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    // Also when it never started, which may not report an exit.
    onRunningChanged: if (!running) {
      secret = ""
      Qt.callLater(function() { if (!setupSave.running) root.setupBusy = "" })
    }
    onExited: function(exitCode) {
      root.setupBusy = ""
      if (exitCode !== 0) {
        root.setupError = root.helperError(saveErr.text, "Setup failed")
        return
      }
      try {
        var result = JSON.parse(saveOut.text)
        root.setupDone = result.devices + (result.devices === 1 ? " light" : " lights") + " found"
          + (result.keyStore === "keyring" ? " · key stored in your keyring"
             : result.keyStore === "file" ? " · key stored in your config file" : " · LAN only")
      } catch (error) {
        root.setupDone = "Connected"
      }
      setupDoneTimer.restart()
      root.changingKey = false
      stateFile.reload()
    }
  }

  Timer {
    id: setupDoneTimer
    interval: 8000
    onTriggered: root.setupDone = ""
  }

  onOpenedChanged: {
    if (opened) {
      root.reloadState(30)
      if (root.selectedIndex >= root.rows.length) root.selectedIndex = 0
    } else {
      root.expanded = ""
      root.keyboardUsed = false
      root.typing = false
      root.changingKey = false
      root.setupError = ""
      keyField.text = ""
      if (root.editing) root.closeEditor()
    }
  }

  // ---- look ----------------------------------------------------------

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Util.alpha(foreground, 0.05)

  readonly property var swatches: ["#ff0000", "#ff7a00", "#ffd000", "#00ff40", "#00e5ff",
                                   "#0040ff", "#8a2be2", "#ff2d95", "#ffffff"]

  // Approximate colour of white light at a temperature (Tanner Helland).
  function kelvinColor(kelvin) {
    var t = kelvin / 100
    var r = t <= 66 ? 255 : 329.698727446 * Math.pow(t - 60, -0.1332047592)
    var g = t <= 66 ? 99.4708025861 * Math.log(t) - 161.1195681661
                    : 288.1221695283 * Math.pow(t - 60, -0.0755148492)
    var b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307
    function c(v) { return Math.max(0, Math.min(255, v)) / 255 }
    return Qt.rgba(c(r), c(g), c(b), 1)
  }

  function lightColor(device) {
    if (!device || device.power !== true || device.online === false) return Util.alpha(root.foreground, 0.15)
    if (device.mode === "temp" && device.colorTemp) return kelvinColor(device.colorTemp)
    if (device.mode === "color" && device.color) return device.color
    return Color.accent
  }

  function describe(device) {
    if (device.online === false) return "offline"
    var parts = []
    if (device.power === true) {
      if (typeof device.brightness === "number" && device.supports.brightness) parts.push(device.brightness + "%")
      if (device.mode === "temp" && device.colorTemp) parts.push(device.colorTemp + "K")
      else if (device.mode === "scene") parts.push("scene")
    } else if (device.power === false) {
      parts.push("off")
    }
    parts.push(device.lan ? "LAN" : "cloud")
    if (device.hidden) parts.push("hidden")
    // Still called by its model number: point at the rename field.
    if (!device.cloud && device.name.indexOf(device.sku + " ") === 0) parts.push("click to rename")
    return parts.join(" · ")
  }

  component ActionButton: Button {
    property string label: ""
    property bool outlined: false
    signal triggered()

    text: label
    bordered: outlined
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.4
    onClicked: if (enabled) triggered()
  }

  component Watchdog: Timer {
    property var process: null
    property int seconds: 60
    interval: seconds * 1000
    running: process !== null && process.running
    onTriggered: if (process) process.running = false
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  component LinkText: Text {
    signal activated()
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkMouse.containsMouse
    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.activated()
    }
  }

  // A rainbow strip: click or drag to pick a saturated colour.
  component HueStrip: Item {
    id: strip
    signal picked(string hex)
    implicitHeight: Style.space(20)

    function colorAt(x) {
      return String(Qt.hsva(Math.max(0, Math.min(0.999, x / width)), 1, 1, 1))
    }

    Rectangle {
      anchors.fill: parent
      radius: Math.min(Style.cornerRadius, height / 2)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: "#ff0000" }
        GradientStop { position: 0.17; color: "#ffff00" }
        GradientStop { position: 0.33; color: "#00ff00" }
        GradientStop { position: 0.5; color: "#00ffff" }
        GradientStop { position: 0.67; color: "#0000ff" }
        GradientStop { position: 0.83; color: "#ff00ff" }
        GradientStop { position: 1.0; color: "#ff0000" }
      }
    }

    Rectangle {
      id: marker
      visible: hueMouse.pressed
      width: Style.space(4)
      height: parent.height + Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      x: Math.max(0, Math.min(parent.width - width, hueMouse.mouseX - width / 2))
      color: root.foreground
      radius: width / 2
    }

    MouseArea {
      id: hueMouse
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onReleased: function(mouse) { strip.picked(strip.colorAt(mouse.x)) }
    }
  }

  // Colour, white and scene controls for a light or a group.
  component LookControls: Column {
    id: look
    property string target: ""
    property var supports: ({})
    property var tempRange: [2000, 9000]
    property int colorTemp: 0
    property bool follows: false
    spacing: Style.space(8)

    Flow {
      visible: look.supports.color === true
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: root.swatches
        Rectangle {
          required property string modelData
          width: Style.space(26)
          height: width
          radius: width / 2
          color: modelData
          border.width: swatchMouse.containsMouse ? Math.max(1, Style.space(2)) : 1
          border.color: swatchMouse.containsMouse ? root.foreground : Util.alpha(root.foreground, 0.25)
          MouseArea {
            id: swatchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setColor(look.target, parent.modelData)
          }
        }
      }
    }

    HueStrip {
      visible: look.supports.color === true
      width: parent.width
      onPicked: function(hex) { root.setColor(look.target, hex) }
    }

    Row {
      visible: look.supports.temp === true
      width: parent.width
      spacing: Style.space(8)
      Caption {
        id: warmLabel
        text: "Warm"
        wrapMode: Text.NoWrap
        anchors.verticalCenter: parent.verticalCenter
      }
      PanelSlider {
        bar: root.bar
        width: parent.width - warmLabel.width - coolLabel.width - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        minimum: look.tempRange[0]
        maximum: look.tempRange[1]
        step: 100
        integer: true
        value: look.colorTemp > 0 ? look.colorTemp : Math.round((look.tempRange[0] + look.tempRange[1]) / 2)
        fillColor: root.kelvinColor(liveValue)
        onReleased: function(value) { root.setTemp(look.target, value) }
      }
      Caption {
        id: coolLabel
        text: "Cool"
        wrapMode: Text.NoWrap
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    SearchableDropdown {
      visible: look.supports.scenes === true && root.hasCloud
      width: parent.width
      showLabel: false
      triggerLabel: root.sceneLoading === look.target ? "Loading scenes…"
                    : (root.sceneLists[look.target] || []).length ? "Scene…" : "No scenes"
      placeholderText: "Search scenes..."
      fontFamily: root.fontFamily
      options: root.sceneLists[look.target] || []
      onChanged: function(value) { if (value !== "") root.setScene(look.target, value) }
    }

    // The Omarchy theme's colour: the dot applies it once, the switch keeps
    // it in step with every theme change.
    Item {
      visible: look.supports.color === true && root.themeColor !== ""
      width: parent.width
      height: Math.max(themeText.implicitHeight, followSwitch.implicitHeight)

      Rectangle {
        id: themeDot
        width: Style.space(26)
        height: width
        radius: width / 2
        color: root.themeColor
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        border.width: themeMouse.containsMouse ? Math.max(1, Style.space(2)) : 1
        border.color: themeMouse.containsMouse ? root.foreground : Util.alpha(root.foreground, 0.25)
        MouseArea {
          id: themeMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setColor(look.target, root.themeColor)
        }
      }

      Column {
        id: themeText
        anchors.left: themeDot.right
        anchors.leftMargin: Style.space(10)
        anchors.right: followSwitch.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Follow theme"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Caption {
          width: parent.width
          text: "Changes colour with your Omarchy theme"
          font.pixelSize: Style.font.caption
        }
      }

      ToggleSwitch {
        id: followSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        checked: root.follows(look.target, look.follows)
        foreground: root.foreground
        cursorRing: false
        onToggled: root.setFollow(look.target, !root.follows(look.target, look.follows))
      }
    }
  }

  // One light or group: a dot in its current colour, name, state, switch,
  // and a brightness slider while it is on.
  component LightRow: Rectangle {
    id: row
    property string key: ""
    property string target: ""
    property string title: ""
    property string subtitle: ""
    property color dot: "transparent"
    property bool isOn: false
    property bool online: true
    property bool hasBrightness: false
    property int brightness: 100
    property bool selected: false
    property bool isExpanded: false
    property bool expandable: false
    default property alias extra: extraColumn.data

    width: parent ? parent.width : 0
    height: rowColumn.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: row.selected ? Util.alpha(root.foreground, 0.09) : root.surface
    border.width: row.selected && root.keyboardUsed ? Math.max(1, Style.space(2)) : 0
    border.color: Color.accent
    opacity: row.online ? 1 : 0.5

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      Item {
        width: parent.width
        height: Math.max(titleColumn.implicitHeight, powerSwitch.implicitHeight)

        Rectangle {
          id: dotItem
          width: Style.space(14)
          height: width
          radius: width / 2
          color: row.dot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.2)
        }

        Column {
          id: titleColumn
          anchors.left: dotItem.right
          anchors.leftMargin: Style.space(10)
          anchors.right: powerSwitch.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: row.title
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: row.subtitle + (row.expandable ? (row.isExpanded ? "  ▴" : "  ▾") : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        MouseArea {
          anchors.left: parent.left
          anchors.right: powerSwitch.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          cursorShape: row.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (row.expandable) root.expand(row.key, row.target)
        }

        ToggleSwitch {
          id: powerSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: row.isOn
          foreground: root.foreground
          cursorRing: false
          onToggled: root.setPower(row.target, !row.isOn)
        }
      }

      PanelSlider {
        visible: row.hasBrightness && row.isOn && row.online
        width: parent.width
        bar: root.bar
        minimum: 1
        maximum: 100
        step: 5
        integer: true
        value: row.brightness
        onReleased: function(value) { root.setBrightness(row.target, value) }
      }

      Column {
        id: extraColumn
        visible: row.isExpanded
        width: parent.width
        spacing: Style.space(8)
        topPadding: Style.space(4)
      }
    }
  }

  readonly property int cardWidth: Style.space(440)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.cardWidth)
    contentHeight: panel.fittedContentHeight(
      headerRow.implicitHeight + Style.space(10) + content.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingUp || root.editing || root.typing

      onCloseRequested: {
        if (root.expanded !== "") root.expanded = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.rows.length === 0) return
        root.keyboardUsed = true
        if (dy !== 0)
          root.selectedIndex = Math.max(0, Math.min(root.rows.length - 1, root.selectedIndex + dy))
        else if (dx !== 0)
          root.nudgeBrightness(root.rows[root.selectedIndex].target, dx * 10)
      }
      onActivateRequested: {
        if (root.rows.length > 0) root.toggleLight(root.rows[root.selectedIndex].target)
      }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        var row = root.rows[root.selectedIndex]
        if (key === "a") root.setPower("all", !root.anyOn)
        else if (key === "e" && row) root.expand(row.key, row.target)
        else if (key === "r") root.reloadState(0)
      }

      Column {
        id: panelBody
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- header ----
        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width - headerActions.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "GOVEE" + (root.configured && root.visibleDevices.length
                             ? "  ·  " + root.onCount + "/" + root.visibleDevices.length + " ON" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            id: headerActions
            spacing: Style.space(6)

            ActionButton {
              visible: root.configured && !root.settingUp && root.visibleDevices.length > 0
              label: "All on"
              outlined: true
              onTriggered: root.setPower("all", true)
            }
            ActionButton {
              visible: root.configured && !root.settingUp && root.visibleDevices.length > 0
              label: "All off"
              outlined: true
              onTriggered: root.setPower("all", false)
            }
          }
        }

        Flickable {
          id: bodyScroll
          width: parent.width
          height: parent.height - headerRow.height - panelBody.spacing
          contentHeight: content.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: content
            width: bodyScroll.width
            spacing: Style.space(8)

            Caption {
              visible: root.setupDone !== ""
              width: parent.width
              text: root.setupDone
            }

            // ---- errors ----
            Rectangle {
              visible: root.errorText !== "" || root.flash !== ""
              width: parent.width
              height: visible ? errorRow.implicitHeight + Style.space(16) : 0
              radius: Style.cornerRadius
              color: Util.alpha(root.urgent, 0.12)

              Row {
                id: errorRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                Caption {
                  width: parent.width - dismissButton.width - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.flash !== "" ? root.flash : root.errorText
                  color: root.urgent
                }
                ActionButton {
                  id: dismissButton
                  label: "Dismiss"
                  outlined: true
                  onTriggered: {
                    root.flash = ""
                    if (root.errorText !== "") root.run(["dismiss"])
                  }
                }
              }
            }

            Caption {
              visible: root.configured && !root.settingUp && (root.state.cloudError || "") !== ""
              width: parent.width
              text: "Govee cloud: " + (root.state.cloudError || "")
              color: root.urgent
            }

            Caption {
              visible: root.configured && !root.settingUp && (root.state.lanError || "") !== ""
              width: parent.width
              text: "Local network: " + (root.state.lanError || "")
              color: root.urgent
            }

            // The most common reason nothing shows up on the LAN.
            Rectangle {
              visible: root.configured && !root.settingUp && (root.state.lanHint || "") !== ""
              width: parent.width
              height: visible ? hintColumn.implicitHeight + Style.space(16) : 0
              radius: Style.cornerRadius
              color: root.surface

              Column {
                id: hintColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(6)

                Caption {
                  width: parent.width
                  text: "No light answered on the local network. Your firewall drops their "
                      + "replies; to control lights locally (faster, no cloud), run:"
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  text: root.state.lanHint || ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ActionButton {
                  label: "Copy command"
                  outlined: true
                  onTriggered: Quickshell.execDetached(["wl-copy", "--", root.state.lanHint || ""])
                }
                Caption {
                  width: parent.width
                  text: "The rule stays until you remove it, and lets that whole subnet reach this "
                      + "port. Also turn on LAN Control for each light in the Govee app."
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---- setup ----
            Rectangle {
              visible: root.settingUp
              width: parent.width
              height: visible ? setupColumn.implicitHeight + Style.space(24) : 0
              radius: Style.cornerRadius
              color: root.surface

              Column {
                id: setupColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.changingKey ? "Change the Govee API key" : "Connect your Govee lights"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Caption {
                  width: parent.width
                  text: "Lights with LAN Control turned on work locally without a key. For every "
                      + "other light, and for names and scenes, paste a Govee API key: Govee Home "
                      + "app → Profile → Settings → Apply for API Key. It arrives by email.\n\n"
                      + "The key is kept in your keyring (or a file only you can read)."
                }
                TextField {
                  id: keyField
                  width: parent.width
                  password: true
                  placeholderText: "API key (paste with Super+V)"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onAccepted: root.connect(false)
                  Keys.onEscapePressed: {
                    if (root.changingKey) root.changingKey = false
                    else root.close()
                  }
                }
                Caption {
                  visible: root.setupError !== "" || root.setupBusy !== ""
                  width: parent.width
                  text: root.setupError !== "" ? root.setupError : root.setupBusy
                  color: root.setupError !== "" ? root.urgent : root.dim
                }
                Row {
                  spacing: Style.space(6)
                  ActionButton {
                    label: "Connect"
                    enabled: !setupSave.running
                    onTriggered: root.connect(false)
                  }
                  ActionButton {
                    visible: !root.changingKey
                    label: "LAN only"
                    outlined: true
                    enabled: !setupSave.running
                    onTriggered: root.connect(true)
                  }
                  ActionButton {
                    visible: root.changingKey
                    label: "Cancel"
                    outlined: true
                    enabled: !setupSave.running
                    onTriggered: {
                      keyField.text = ""
                      root.setupError = ""
                      root.changingKey = false
                    }
                  }
                }
              }
            }

            // ---- group editor ----
            Rectangle {
              visible: root.editing
              width: parent.width
              height: visible ? editorColumn.implicitHeight + Style.space(24) : 0
              radius: Style.cornerRadius
              color: root.surface

              Column {
                id: editorColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.editingName !== "" ? "Edit group" : "New group"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                TextField {
                  id: groupNameField
                  width: parent.width
                  placeholderText: "Name, e.g. Office"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  onAccepted: root.saveGroup()
                  Keys.onEscapePressed: root.closeEditor()
                }
                Repeater {
                  model: root.allDevices
                  Item {
                    required property var modelData
                    width: editorColumn.width
                    height: memberSwitch.implicitHeight
                    Text {
                      anchors.left: parent.left
                      anchors.right: memberSwitch.left
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: parent.modelData.name
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                    ToggleSwitch {
                      id: memberSwitch
                      anchors.right: parent.right
                      checked: root.editorMembers.indexOf(parent.modelData.id) >= 0
                      foreground: root.foreground
                      cursorRing: false
                      onToggled: root.toggleMember(parent.modelData.id)
                    }
                  }
                }
                Row {
                  spacing: Style.space(6)
                  ActionButton {
                    label: "Save"
                    enabled: groupNameField.text.trim() !== "" && root.editorMembers.length > 0
                    onTriggered: root.saveGroup()
                  }
                  ActionButton {
                    label: "Cancel"
                    outlined: true
                    onTriggered: root.closeEditor()
                  }
                  ActionButton {
                    visible: root.editingName !== ""
                    label: "Delete group"
                    outlined: true
                    onTriggered: root.deleteGroup()
                  }
                }
              }
            }

            Caption {
              visible: root.configured && !root.settingUp && root.devices.length === 0
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.hasCloud ? "No lights on this Govee account yet."
                                  : "No lights answered on the network. Turn on LAN Control "
                                    + "for each light in the Govee Home app."
            }

            // ---- groups ----
            PanelSectionHeader {
              visible: root.configured && !root.settingUp && !root.editing && root.groups.length > 0
              text: "GROUPS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.configured && !root.settingUp && !root.editing ? root.groups : []

              LightRow {
                id: groupRow
                required property var modelData
                required property int index
                key: "g:" + modelData.name
                target: modelData.name
                title: modelData.name
                subtitle: modelData.onCount + " of " + modelData.members.length + " on"
                          + (modelData.power && typeof modelData.brightness === "number"
                             ? " · " + modelData.brightness + "%" : "")
                dot: modelData.power ? Color.accent : Util.alpha(root.foreground, 0.15)
                isOn: modelData.power
                hasBrightness: modelData.supports.brightness === true
                brightness: modelData.brightness || 100
                selected: root.selectedIndex === index
                expandable: true
                isExpanded: root.expanded === key

                LookControls {
                  width: parent.width
                  target: groupRow.target
                  supports: groupRow.modelData.supports
                  follows: groupRow.modelData.followsTheme === true
                }
                ActionButton {
                  label: "Edit group"
                  outlined: true
                  onTriggered: root.openEditor(groupRow.modelData)
                }
              }
            }

            // ---- lights ----
            PanelSectionHeader {
              visible: root.configured && !root.settingUp && !root.editing && root.devices.length > 0
              text: "LIGHTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.configured && !root.settingUp && !root.editing ? root.devices : []

              LightRow {
                id: deviceRow
                required property var modelData
                required property int index
                key: "d:" + modelData.id
                target: modelData.id
                title: modelData.name
                subtitle: root.describe(modelData)
                dot: root.lightColor(modelData)
                isOn: modelData.power === true
                online: modelData.online !== false
                hasBrightness: modelData.supports.brightness === true
                brightness: typeof modelData.brightness === "number" ? modelData.brightness : 100
                selected: root.selectedIndex === index + root.groups.length
                expandable: true
                isExpanded: root.expanded === key

                LookControls {
                  width: parent.width
                  target: deviceRow.target
                  supports: deviceRow.modelData.supports
                  tempRange: deviceRow.modelData.tempRange || [2000, 9000]
                  colorTemp: deviceRow.modelData.mode === "temp" ? (deviceRow.modelData.colorTemp || 0) : 0
                  follows: deviceRow.modelData.followsTheme === true
                }
                // LAN-only lights only know their model number; let them
                // have a real name. Enter or Save stores it, Esc puts it back.
                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Caption {
                    id: nameLabel
                    text: "Name"
                    wrapMode: Text.NoWrap
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  TextField {
                    id: nameField
                    width: parent.width - nameLabel.width - saveName.width - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: deviceRow.modelData.name
                    placeholderText: "e.g. Floor lamp"
                    foreground: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    onActiveFocusChanged: root.typing = activeFocus
                    onAccepted: root.renameLight(deviceRow.modelData, nameField)
                    Keys.onEscapePressed: {
                      text = deviceRow.modelData.name
                      keyCatcher.forceActiveFocus()
                    }
                  }
                  ActionButton {
                    id: saveName
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Save"
                    enabled: nameField.text.trim() !== deviceRow.modelData.name
                    onTriggered: root.renameLight(deviceRow.modelData, nameField)
                  }
                }
                Row {
                  spacing: Style.space(6)
                  ActionButton {
                    label: deviceRow.modelData.hidden ? "Unhide" : "Hide"
                    outlined: true
                    onTriggered: root.run([deviceRow.modelData.hidden ? "unhide" : "hide", deviceRow.target])
                  }
                  // A LAN-only light that is gone, or was never real. A second
                  // click confirms: a light that is only unplugged comes back.
                  ActionButton {
                    visible: deviceRow.modelData.cloud !== true && deviceRow.modelData.online === false
                    label: root.confirmForget === deviceRow.target ? "Click again to forget" : "Forget"
                    outlined: true
                    onTriggered: {
                      if (root.confirmForget === deviceRow.target) {
                        root.confirmForget = ""
                        root.run(["forget", deviceRow.target])
                      } else {
                        root.confirmForget = deviceRow.target
                        forgetTimer.restart()
                      }
                    }
                  }
                  Caption {
                    anchors.verticalCenter: parent.verticalCenter
                    text: deviceRow.modelData.sku + (deviceRow.modelData.lan ? " · LAN Control" : " · cloud only")
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // ---- footer ----
            Item {
              visible: root.configured && !root.settingUp
              width: parent.width
              height: Style.space(4)
            }

            Row {
              visible: root.configured && !root.settingUp && !root.editing
              width: parent.width
              spacing: Style.space(14)

              LinkText {
                text: "New group"
                visible: root.allDevices.length > 1
                onActivated: root.openEditor(null)
              }
              LinkText {
                text: "Leave demo"
                visible: root.demo
                onActivated: root.run(["demo", "off"])
              }
              LinkText {
                text: root.hasCloud ? "Change API key" : "Add API key"
                visible: !root.demo
                onActivated: {
                  root.changingKey = true
                  Qt.callLater(function() { keyField.forceActiveFocus() })
                }
              }
              LinkText {
                text: "Refresh"
                onActivated: root.reloadState(0)
              }
            }

            Caption {
              visible: root.configured && !root.settingUp
              width: parent.width
              font.pixelSize: Style.font.caption
              text: (root.demo ? "Demo mode: made-up lights  ·  " : "")
                  + (root.hasCloud && !root.demo && root.state.usage
                     ? root.state.usage.today + " of " + root.state.usage.limit + " cloud requests today  ·  " : "")
                  + "↑↓ select · Enter switch · ←→ dim · E colours · A all"
            }

            LinkText {
              visible: root.pluginVersion !== ""
              text: "Govee plugin " + root.pluginVersion
              onActivated: if (root.releaseUrl !== "") Qt.openUrlExternally(root.releaseUrl)
            }
          }
        }
      }
    }
  }
}
