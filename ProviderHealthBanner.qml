import QtQuick
import qs.Commons
import qs.Ui

// Persistent provider-auth/status warning shared by every popup tab.
BorderSurface {
  id: root

  property var service: null
  property var bar: null

  width: parent ? parent.width : 0
  visible: !!service && service.providerHealthSummary !== ""
  implicitHeight: visible ? warningText.implicitHeight + Style.space(16) : 0
  radius: Style.spacing.labelGap
  color: Style.selectedFillFor(bar ? bar.foreground : "white", Color.urgent)
  borderSpec: Border.controlSpec("normal", bar ? bar.urgent : Color.urgent, Color.urgent)
  padding: Style.space(8)

  Text {
    id: warningText
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.service ? root.service.providerHealthSummary + "  ·  Open Music Assistant" : ""
    color: root.bar ? root.bar.urgent : Color.urgent
    font.family: root.bar ? root.bar.fontFamily : "sans-serif"
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    wrapMode: Text.WordWrap
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: if (root.service) root.service.openWebUI()
  }
}
