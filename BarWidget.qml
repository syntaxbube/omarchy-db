import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Palette.js" as Palette

// Bar entry point. Shows the next departure from the home station and owns
// the nested Panel.qml, which does the fetching and draws the board and the
// route search. Follows the shape of the built-in weather widget so shell
// summon / hide / toggle routing works on this widget's id.
//
// With the "Figma" palette the departure is drawn as the pill from the
// template (Waybar / SBB Module): dark surface, rail red icon, blue line,
// status dot. With "Theme" it is plain bar text like the built-in widgets.
BarWidget {
  id: root
  moduleName: "vvkycodevv.sbb"

  // nf-md-train
  readonly property string trainGlyph: "󰔬"

  readonly property var panelItem: panelLoader.item
  readonly property bool panelBroken: panelLoader.status === Loader.Error
  readonly property bool figma: panelItem ? panelItem.figma === true : setting("palette", "Figma") !== "Theme"
  readonly property bool pillMode: figma && !root.vertical

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function open() {
    if (panelItem) panelItem.open()
  }

  function close() {
    if (panelItem) panelItem.close()
  }

  function toggle() {
    if (panelItem) panelItem.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelItem) panelItem.closeForPopoutSwitch()
  }

  function refresh() {
    if (panelItem) panelItem.refresh()
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

  // ---- Pill content (Figma palette) ----------------------------------------

  readonly property var dep: panelItem ? panelItem.barDeparture : null
  readonly property string depStatus: dep ? Model.status(dep) : "none"
  readonly property bool compact: panelItem ? panelItem.compactBar === true : false
  // "Show in bar" off: only the train icon stays in the bar.
  readonly property bool showDeparture: panelItem ? panelItem.showInBar !== false : true
  readonly property bool offline: panelBroken || (panelItem && panelItem.boardError !== "" && !dep)

  readonly property color pillStatusColor: {
    if (offline) return Palette.red
    if (!dep) return Palette.muted
    if (depStatus === "cancelled") return Palette.red
    if (depStatus === "delayed") return Palette.amber
    return Palette.green
  }
  readonly property string pillStatusText: {
    if (panelBroken) return "error"
    if (offline) return "offline"
    if (!dep) return panelItem && panelItem.loaded ? "no trains" : "fetching…"
    return Model.barTail(dep, panelItem.nowSec)
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // In pill mode the label is drawn by the pill below; the button keeps
    // the click handling, tooltip and bar click-target registration.
    labelVisible: !root.pillMode
    hasVisualContent: true
    fixedWidth: root.pillMode ? pill.width + Style.space(8) : -1
    text: {
      if (root.pillMode) return ""
      var label = root.panelBroken ? "error" : (root.panelItem ? root.panelItem.label : "…")
      if (root.vertical || label === "" || !root.showDeparture) return root.trainGlyph
      return root.trainGlyph + "  " + label
    }
    // Theme mode: late or cancelled trains take the bar's alert colour.
    active: !root.pillMode && root.showDeparture && (root.panelBroken || (root.panelItem ? root.panelItem.barAlert === true : false))
    tooltipText: root.panelBroken
      ? "SBB: Panel.qml failed to load, see qs log"
      : (root.panelItem && !root.opened ? root.panelItem.tooltip : "")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton && root.panelItem) root.panelItem.openRouteSearch("", "")
      else root.toggle()
    }

    Rectangle {
      id: pill
      visible: root.pillMode
      anchors.centerIn: parent
      width: pillRow.implicitWidth + Style.space(8) + Style.space(root.showDeparture ? 10 : 8)
      height: Math.max(Style.space(18), Math.min(Style.space(26), root.barSize - Style.space(8)))
      radius: Style.space(6)
      color: Palette.surface
      border.width: 1
      border.color: root.opened ? Palette.blue : Palette.border

      Row {
        id: pillRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        // Icon / Train: rail red tile with a white train.
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          height: width
          radius: Style.space(4)
          color: Palette.rail

          Text {
            anchors.centerIn: parent
            text: root.trainGlyph
            textFormat: Text.PlainText
            color: "#ffffff"
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Line, e.g. IR 70
        Text {
          visible: root.showDeparture && root.dep !== null && !root.compact
          anchors.verticalCenter: parent.verticalCenter
          text: root.dep ? root.dep.line : ""
          textFormat: Text.PlainText
          color: Palette.blue
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        // → Luzern
        Text {
          visible: root.showDeparture && root.dep !== null && !root.compact
          anchors.verticalCenter: parent.verticalCenter
          text: root.dep ? "→ " + root.dep.to : ""
          textFormat: Text.PlainText
          color: Palette.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        // 16:42, struck through when cancelled
        Text {
          visible: root.showDeparture && root.dep !== null
          anchors.verticalCenter: parent.verticalCenter
          text: root.dep ? root.dep.time : ""
          textFormat: Text.PlainText
          color: root.depStatus === "cancelled" ? Palette.muted : Palette.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          font.strikeout: root.depStatus === "cancelled"
        }

        // Placeholder label while loading or offline
        Text {
          visible: root.showDeparture && root.dep === null
          anchors.verticalCenter: parent.verticalCenter
          text: "SBB"
          textFormat: Text.PlainText
          color: Palette.subtle
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Row {
          visible: root.showDeparture && root.pillStatusText !== ""
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            color: root.pillStatusColor
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.pillStatusText
            textFormat: Text.PlainText
            color: root.pillStatusColor
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.weight: Font.Medium
          }
        }
      }
    }
  }
}
