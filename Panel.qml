import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Vivobook Control: one bar icon, one panel. Every action shells out to
// bin/vivobook-ctl so keybindings, the menu and this panel share one code path.
Panel {
  id: root
  moduleName: "io.github.leandrooricchio.vivobook"
  ipcTarget: "vivobook"
  // manageIpc: false so this panel owns the IpcHandler and can add methods.
  manageIpc: false

  readonly property string ctl: Qt.resolvedUrl("bin/vivobook-ctl").toString().replace(/^file:\/\//, "")
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/vivobook/config.json"
  readonly property bool showKbdLevel: String(setting("showKbdLevelInBar", "false")) === "true"

  property var st: ({})
  property bool loaded: false
  property var queue: []

  // Keyboard cursor: section id, row within section, column within a group row.
  property bool cursorActive: false
  property string focusSection: ""
  property int focusRow: 0
  property int focusCol: 0
  readonly property var sectionList: Model.sections(st)

  readonly property var caps: Model.get(st, "caps", {})
  readonly property int kbdLevel: Model.get(st, "kbd.level", 0)
  readonly property int kbdMax: Model.get(st, "kbd.max", 3)
  readonly property var rgb: Model.get(st, "rgb", {})
  readonly property var profile: Model.get(st, "profile", {})
  readonly property var charge: Model.get(st, "charge", {})
  readonly property var copilot: Model.get(st, "copilot", {})
  readonly property var gestures: Model.get(st, "gestures", {})
  readonly property var edge: Model.get(st, "edge", {})
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)

  // ---------------------------------------------------------------- data

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Serialize writes: one vivobook-ctl at a time, refresh after the last one.
  function run(args) {
    var q = root.queue.slice()
    q.push(args)
    root.queue = q
    pump()
  }

  function pump() {
    if (actionProc.running || !root.queue.length) return
    var q = root.queue.slice()
    var next = q.shift()
    root.queue = q
    actionProc.command = [root.ctl].concat(next).concat(["--no-osd"])
    actionProc.running = true
  }

  function runWithOsd(args) {
    osdProc.command = [root.ctl].concat(args)
    osdProc.running = true
  }

  // ---------------------------------------------------------------- actions

  function setKbd(level) { run(["kbd", "set", String(Math.max(0, Math.min(root.kbdMax, Math.round(level))))]) }
  function setColor(hex) { run(["rgb", "set", String(hex)]) }
  function setEffect(mode) { run(mode === "auto" ? ["rgb", "auto"] : ["rgb", "effect", String(mode)]) }
  function setProfile(p) { run(["profile", "set", String(p)]) }
  function setCharge(limit) { run(["charge", "set", String(limit)]) }
  function setCopilot(preset) { run(["copilot", "set", String(preset)]) }
  function setCopilotCommand(cmd) { if (cmd && cmd.trim().length) run(["copilot", "set", "custom", "--command", cmd.trim()]) }
  function setGesture(key, value) { run(["gestures", "set", String(key), String(value)]) }
  function toggleGesture(key) { setGesture(key, root.gestures[key] ? "off" : "on") }
  function toggleEdge() { run(["edge", root.edge.daemon === "active" ? "disable" : "enable"]) }
  function copySetupCommand() {
    copyProc.command = ["bash", "-c", "printf %s \"$1\" | wl-copy", "_", String(Model.get(root.st, "setupCommand", ""))]
    copyProc.running = true
  }

  // ---------------------------------------------------------------- cursor

  function ensureCursor() {
    var list = root.sectionList
    if (!list.length) return
    if (!Model.sectionById(list, root.focusSection)) {
      root.focusSection = list[0].id
      root.focusRow = 0
      root.focusCol = 0
    }
  }

  function currentRow() {
    var s = Model.sectionById(root.sectionList, root.focusSection)
    if (!s) return null
    return s.rows[Math.max(0, Math.min(s.rows.length - 1, root.focusRow))] || null
  }

  function moveCursor(delta) {
    ensureCursor()
    var r = Model.moveCursor(root.sectionList, root.focusSection, root.focusRow, root.focusCol, delta)
    root.focusSection = r.section
    root.focusRow = r.row
    root.focusCol = r.col
    syncColToValue()
  }

  // Land the column on the currently selected chip of a group row.
  function syncColToValue() {
    var row = currentRow()
    if (!row || row.kind !== "group") { root.focusCol = 0; return }
    var idx = 0
    switch (root.focusSection) {
      case "swatches": idx = Model.indexOf(root.rgb.presets, String(root.rgb.color || "").toUpperCase()); break
      case "effect": idx = Model.indexOf(root.rgb.modes, root.rgb.mode); break
      case "profile": idx = Model.indexOf(root.profile.choices, root.profile.platform); break
      case "charge": idx = Model.indexOf(root.charge.limits, root.charge.limit); break
      case "gestures": idx = Model.indexOf(root.gestures.actions, root.gestures[row.key]); break
    }
    root.focusCol = Model.clampCol(row, idx < 0 ? 0 : idx)
  }

  function moveCursorH(delta) {
    var row = currentRow()
    if (!row) return
    if (row.kind === "slider") { setKbd(root.kbdLevel + delta); return }
    if (row.kind === "group") { root.focusCol = Model.clampCol(row, root.focusCol + delta); return }
    if (row.kind === "dropdown") {
      var values = (root.copilot.presets || []).map(function(p) { return p.value })
      var next = Model.cycle(values, root.copilot.action, delta)
      if (next !== "custom") setCopilot(next)
    }
  }

  function activateCursor() {
    var row = currentRow()
    if (!row) return
    switch (root.focusSection) {
      case "swatches": setColor(root.rgb.presets[root.focusCol]); break
      case "effect": setEffect(root.rgb.modes[root.focusCol]); break
      case "profile": setProfile(root.profile.choices[root.focusCol]); break
      case "charge": setCharge(root.charge.limits[root.focusCol]); break
      case "copilot": copilotDropdown.toggle(); break
      case "gestures":
        if (row.kind === "toggle") toggleGesture(row.key)
        else setGesture(row.key, root.gestures.actions[root.focusCol])
        break
      case "edge": toggleEdge(); break
      case "setup": copySetupCommand(); break
    }
  }

  function hoverCursor(section, row, col) {
    root.cursorActive = true
    root.focusSection = section
    root.focusRow = row
    root.focusCol = col
  }

  function cursorOn(section, row, col) {
    return root.cursorActive && root.focusSection === section && root.focusRow === row
      && (col === undefined || root.focusCol === col)
  }

  // ---------------------------------------------------------------- lifecycle

  onOpenedChanged: {
    if (opened) { refresh(); root.cursorActive = false }
  }
  Component.onCompleted: refresh()

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Keybindings and the menu also write config.json; pick those up live.
  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: configDebounce.restart()
  }
  Timer { id: configDebounce; interval: 200; repeat: false; onTriggered: root.refresh() }

  Process {
    id: statusProc
    command: [root.ctl, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (Object.keys(parsed).length) { root.st = parsed; root.loaded = true }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function() {
      if (root.queue.length) root.pump()
      else root.refresh()
    }
  }

  Process {
    id: osdProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.refresh()
  }
  Process { id: copyProc }

  IpcHandler {
    target: "vivobook"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function kbdUp(): void { root.runWithOsd(["kbd", "up"]) }
    function kbdDown(): void { root.runWithOsd(["kbd", "down"]) }
    function kbdCycle(): void { root.runWithOsd(["kbd", "cycle"]) }
    function rgbNext(): void { root.runWithOsd(["rgb", "next"]) }
    function rgbEffect(mode: string): void { root.runWithOsd(mode === "auto" ? ["rgb", "auto"] : ["rgb", "effect", mode]) }
    function profileCycle(): void { root.runWithOsd(["profile", "cycle"]) }
    function chargeCycle(): void { root.runWithOsd(["charge", "cycle"]) }
    function edgeToggle(): void { root.runWithOsd(["edge", "toggle"]) }
    function status(): string { return JSON.stringify(root.st) }
  }

  // Equal-width chip row (ButtonGroup lets chips size to content and overflow).
  component Segmented: Row {
    id: seg
    property var options: []
    property string value: ""
    property int cursorIndex: -1
    property real fontSize: Style.font.bodySmall
    property real iconSize: Style.font.body
    signal changed(string value)
    signal hovered(int index, bool isHovered)
    spacing: Style.space(6)
    readonly property real cellWidth: options.length ? (width - spacing * (options.length - 1)) / options.length : 0
    Repeater {
      model: seg.options
      Button {
        required property var modelData
        required property int index
        width: seg.cellWidth
        text: String(modelData.label !== undefined ? modelData.label : modelData)
        iconText: modelData.icon ? String(modelData.icon) : ""
        iconSize: seg.iconSize
        fontSize: seg.fontSize
        foreground: root.fg
        fontFamily: root.ff
        horizontalPadding: Style.space(4)
        verticalPadding: Style.spacing.controlPaddingY
        bordered: true
        selected: String(modelData.value !== undefined ? modelData.value : modelData) === seg.value
        hasCursor: seg.cursorIndex === index
        onClicked: seg.changed(String(modelData.value !== undefined ? modelData.value : modelData))
        onHovered: function(h) { seg.hovered(index, h) }
      }
    }
  }

  // ---------------------------------------------------------------- bar button

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property int wheelAccumulator: 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showKbdLevel && !vertical ? "󰌌 " + root.kbdLevel : "󰌌"
    slotSize: Style.bar.iconSlot * (root.showKbdLevel && !vertical ? 1.6 : 1)
    tooltipText: "Vivobook Control"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.runWithOsd(["kbd", "cycle"])
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.runWithOsd(["kbd", wheel.steps > 0 ? "up" : "down"])
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: customField.activeFocus || copilotDropdown.popupOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); root.syncColToValue(); return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            foreground: root.fg
            fontFamily: root.ff
            title: Model.get(root.st, "model", "Vivobook")
            meta: (Model.profileLabel(root.profile.platform) + " · " + Model.tempText(root.profile.cpuC)).toUpperCase()
            detail: root.loaded ? "" : "Loading…"
            iconComponent: Component {
              Text {
                text: "󰌌"
                color: root.fg
                font.family: root.ff
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Keyboard ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.caps.kbd === true

            Item {
              width: parent.width
              implicitHeight: Math.max(kbdHeader.implicitHeight, kbdValue.implicitHeight)
              PanelSectionHeader { id: kbdHeader; text: "KEYBOARD LIGHT"; foreground: root.fg; fontFamily: root.ff; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: kbdValue
                text: (kbdSlider.dragging ? Math.round(kbdSlider.liveValue) : root.kbdLevel) + " / " + root.kbdMax
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              width: parent.width
              height: kbdSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorOn("kbd", 0)
              foreground: root.fg
              outline: true
              PanelSlider {
                id: kbdSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.kbdMax
                step: 1
                integer: true
                tickCount: root.kbdMax + 1
                value: root.kbdLevel
                onReleased: function(v) { root.setKbd(v) }
              }
              HoverHandler { onHoveredChanged: if (hovered) root.hoverCursor("kbd", 0, 0) }
            }

            // Color swatches
            Item {
              width: parent.width
              implicitHeight: Math.max(rgbHeader.implicitHeight, rgbValue.implicitHeight)
              visible: root.caps.rgbDevice === true
              PanelSectionHeader { id: rgbHeader; text: "RGB COLOR"; foreground: root.fg; fontFamily: root.ff; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: rgbValue
                text: root.caps.rgb ? ("#" + String(root.rgb.color || "") + (root.rgb.daemon === "active" ? "" : " · daemon off")) : "locked · run setup"
                color: root.caps.rgb ? root.dim : Color.urgent
                font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: swatchRow
              width: parent.width
              spacing: Style.space(6)
              visible: root.caps.rgbDevice === true
              opacity: root.caps.rgb ? 1 : 0.45
              readonly property var presets: root.rgb.presets || []
              readonly property real cell: presets.length ? (width - spacing * (presets.length - 1)) / presets.length : 0
              Repeater {
                model: swatchRow.presets
                Rectangle {
                  required property var modelData
                  required property int index
                  readonly property bool active: String(modelData).toUpperCase() === String(root.rgb.color || "").toUpperCase()
                  readonly property bool hot: root.cursorOn("swatches", 0, index) || swatchMouse.containsMouse
                  width: swatchRow.cell
                  height: Style.space(26)
                  radius: Style.cornerRadius > 0 ? Style.space(6) : 0
                  color: "#" + modelData
                  border.width: active ? 2 : (hot ? Style.hoverBorderWidth : 0)
                  border.color: active ? root.fg : Style.hoverBorderFor(root.fg, Color.accent)
                  Text {
                    anchors.centerIn: parent
                    visible: parent.active
                    text: "󰄬"
                    color: Qt.hsla(0, 0, 0, 0.7)
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: swatchMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.caps.rgb === true
                    onEntered: root.hoverCursor("swatches", 0, index)
                    onClicked: root.setColor(modelData)
                  }
                }
              }
            }

            Segmented {
              width: parent.width
              visible: root.caps.rgbDevice === true
              enabled: root.caps.rgb === true
              opacity: enabled ? 1 : 0.45
              fontSize: Style.font.caption
              options: (root.rgb.modes || []).map(function(m) { return { value: m, label: m === "breathing" ? "Breathe" : m.charAt(0).toUpperCase() + m.slice(1), icon: Model.rgbModeGlyph(m) } })
              value: String(root.rgb.mode || "")
              cursorIndex: root.cursorOn("effect", 0) ? root.focusCol : -1
              onChanged: function(v) { root.setEffect(v) }
              onHovered: function(i, h) { if (h) root.hoverCursor("effect", 0, i) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg; visible: root.caps.profile === true }

          // ---------- Performance ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.caps.profile === true

            Item {
              width: parent.width
              implicitHeight: Math.max(perfHeader.implicitHeight, perfValue.implicitHeight)
              PanelSectionHeader { id: perfHeader; text: "PERFORMANCE"; foreground: root.fg; fontFamily: root.ff; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: perfValue
                text: "CPU " + Model.tempText(root.profile.cpuC) + " · FAN " + Model.fanText(root.profile.fans)
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Segmented {
              width: parent.width
              options: (root.profile.choices || []).map(function(p) { return { value: p, label: Model.profileLabel(p), icon: Model.profileGlyph(p) } })
              value: String(root.profile.platform || "")
              cursorIndex: root.cursorOn("profile", 0) ? root.focusCol : -1
              onChanged: function(v) { root.setProfile(v) }
              onHovered: function(i, h) { if (h) root.hoverCursor("profile", 0, i) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg; visible: root.caps.chargeDevice === true }

          // ---------- Battery ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.caps.chargeDevice === true

            Item {
              width: parent.width
              implicitHeight: Math.max(batHeader.implicitHeight, batValue.implicitHeight)
              PanelSectionHeader { id: batHeader; text: "CHARGE LIMIT"; foreground: root.fg; fontFamily: root.ff; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: batValue
                text: root.caps.charge ? Model.batteryText(root.charge) : "locked · run setup"
                color: root.caps.charge ? root.dim : Color.urgent
                font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Segmented {
              width: parent.width
              enabled: root.caps.charge === true
              opacity: enabled ? 1 : 0.45
              options: (root.charge.limits || []).map(function(l) { return { value: String(l), label: l + "%", icon: l >= 100 ? "󰁹" : (l >= 80 ? "󰂁" : "󰁾") } })
              value: String(root.charge.limit || "")
              cursorIndex: root.cursorOn("charge", 0) ? root.focusCol : -1
              onChanged: function(v) { root.setCharge(v) }
              onHovered: function(i, h) { if (h) root.hoverCursor("charge", 0, i) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Copilot key ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(cpHeader.implicitHeight, cpValue.implicitHeight)
              PanelSectionHeader { id: cpHeader; text: "COPILOT KEY"; foreground: root.fg; fontFamily: root.ff; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Text {
                id: cpValue
                text: String(root.copilot.resolved || "—")
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth, parent.width * 0.6)
                anchors.right: parent.right; anchors.rightMargin: Style.space(6); anchors.verticalCenter: parent.verticalCenter
              }
            }

            Dropdown {
              id: copilotDropdown
              width: parent.width
              showLabel: false
              foreground: root.fg
              fontFamily: root.ff
              options: root.copilot.presets || []
              value: String(root.copilot.action || "agent-pick")
              hasCursor: root.cursorOn("copilot", 0)
              onChanged: function(v) {
                if (v === "custom") { customField.forceActiveFocus(); return }
                root.setCopilot(v)
              }
              onHovered: function(h) { if (h) root.hoverCursor("copilot", 0, 0) }
            }

            TextField {
              id: customField
              width: parent.width
              visible: String(root.copilot.action) === "custom" || activeFocus
              foreground: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
              placeholderText: "Command to run, e.g. omarchy-launch-browser"
              text: String(root.copilot.action) === "custom" ? String(root.copilot.command || "") : ""
              onAccepted: { root.setCopilotCommand(text); keyCatcher.forceActiveFocus() }
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Touchpad gestures ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "TOUCHPAD GESTURES"; foreground: root.fg; fontFamily: root.ff }

            Repeater {
              model: [
                { key: "workspace3", label: "3-finger swipe ↔", description: "Switch workspace" },
                { key: "move4", label: "4-finger swipe ↔", description: "Move window to next / previous workspace" },
                { key: "pinchFloat", label: "Pinch", description: "Toggle floating for the focused window" }
              ]
              Toggle {
                required property var modelData
                required property int index
                width: parent.width
                label: modelData.label
                description: modelData.description
                checked: root.gestures[modelData.key] === true
                hasCursor: root.cursorOn("gestures", index)
                foreground: root.fg
                fontFamily: root.ff
                onClicked: root.toggleGesture(modelData.key)
                onHovered: function(h) { if (h) root.hoverCursor("gestures", index, 0) }
              }
            }

            Repeater {
              model: [
                { key: "up3", label: "3-finger swipe ↑", row: 3 },
                { key: "down3", label: "3-finger swipe ↓", row: 4 }
              ]
              Item {
                required property var modelData
                width: parent.width
                implicitHeight: swipeGroup.implicitHeight
                Text {
                  id: swipeLabel
                  text: modelData.label
                  width: Style.space(120)
                  color: root.fg; font.family: root.ff; font.pixelSize: Style.font.bodySmall
                  anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                }
                Segmented {
                  id: swipeGroup
                  anchors.left: swipeLabel.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  fontSize: Style.font.caption
                  options: (root.gestures.actions || []).map(function(a) { return { value: a, label: Model.actionLabel(a) } })
                  value: String(root.gestures[modelData.key] || "none")
                  cursorIndex: root.cursorOn("gestures", modelData.row) ? root.focusCol : -1
                  onChanged: function(v) { root.setGesture(modelData.key, v) }
                  onHovered: function(i, h) { if (h) root.hoverCursor("gestures", modelData.row, i) }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ---------- Edge gestures ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "EDGE SLIDES"; foreground: root.fg; fontFamily: root.ff }

            Toggle {
              readonly property bool ready: root.caps.uinput === true && root.caps.touchpad === true && root.caps.evdev === true
              width: parent.width
              label: "ASUS edge gestures"
              description: ready
                ? "Right edge: brightness · Left edge: volume · Top edge: back / forward"
                : "Locked · run setup to enable the touchpad edge daemon"
              checked: root.edge.daemon === "active"
              enabled: ready
              opacity: ready ? 1 : 0.45
              hasCursor: root.cursorOn("edge", 0)
              foreground: root.fg
              fontFamily: root.ff
              onClicked: root.toggleEdge()
              onHovered: function(h) { if (h) root.hoverCursor("edge", 0, 0) }
            }
          }

          // ---------- Setup footer ----------
          BorderSurface {
            width: parent.width
            visible: root.loaded && root.caps.setupDone !== true
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.10)
            borderSpec: Border.flat(Util.alpha(Color.urgent, 0.6), Math.max(1, Style.normalBorderWidth))
            implicitHeight: setupColumn.implicitHeight + Style.space(24)

            Column {
              id: setupColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "One-time setup unlocks keyboard RGB, the charge limit and edge gestures."
                wrapMode: Text.WordWrap
                color: root.fg; font.family: root.ff; font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                text: String(Model.get(root.st, "setupCommand", ""))
                elide: Text.ElideMiddle
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
              Button {
                text: "Copy command"
                iconText: "󰆏"
                bordered: true
                foreground: root.fg
                fontFamily: root.ff
                fontSize: Style.font.bodySmall
                hasCursor: root.cursorOn("setup", 0)
                onClicked: root.copySetupCommand()
                onHovered: function(h) { if (h) root.hoverCursor("setup", 0, 0) }
              }
            }
          }
        }
      }
    }
  }
}
