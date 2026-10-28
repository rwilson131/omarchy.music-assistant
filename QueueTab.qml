import QtQuick
import qs.Commons
import qs.Ui

// Queue playback, editing and playlist-save controls. Kept separate from
// BarWidget so queue behavior can evolve without expanding the popup shell.
Column {
  id: tab

  property var service: null
  property var bar: null
  property bool saveOpen: false
  readonly property bool serviceReady: service && service.ready

  spacing: Style.space(4)

  function openSave() {
    tab.saveOpen = true
    Qt.callLater(function() { queueSaveName.forceActiveFocus() })
  }

  Row {
    width: parent.width
    Text {
      text: "QUEUE (" + (tab.service ? tab.service.queue.length : 0) + ")"
      color: Qt.darker(tab.bar.foreground, 1.3)
      font.family: tab.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
    Item { width: Style.space(8); height: 1 }
    Button {
      text: "Save"
      tooltipText: "Save the queue as a playlist"
      foreground: tab.bar.foreground
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.spacing.controlPaddingY
      enabled: tab.serviceReady && tab.service.queue.length > 0
      opacity: enabled ? 1.0 : 0.4
      active: tab.saveOpen
      onClicked: tab.saveOpen ? (tab.saveOpen = false) : tab.openSave()
    }
    Button {
      text: "Clear"
      foreground: tab.bar.foreground
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.spacing.controlPaddingY
      enabled: tab.serviceReady && tab.service.queue.length > 0
      opacity: enabled ? 1.0 : 0.4
      onClicked: if (tab.service) tab.service.clearQueue(tab.service.activePlayerId)
    }
  }

  TextField {
    id: queueSaveName
    width: parent.width
    visible: tab.saveOpen
    placeholderText: "Playlist name, then Enter"
    foreground: tab.bar.foreground
    onAccepted: {
      if (tab.service && text.length > 0) tab.service.saveQueueAsPlaylist(text)
      text = ""
      tab.saveOpen = false
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) { tab.saveOpen = false; event.accepted = true }
    }
  }

  Repeater {
    model: tab.service ? tab.service.queue : []
    delegate: BorderSurface {
      id: queueRow
      required property var modelData
      required property int index
      readonly property bool isCurrent: tab.service && queueRow.index === tab.service.queuePosition
      width: parent.width
      height: queueInner.implicitHeight + Style.space(8)
      radius: Style.spacing.labelGap
      color: isCurrent
        ? Style.selectedFillFor(tab.bar.foreground, Color.accent)
        : "transparent"
      borderSpec: isCurrent
        ? Border.controlSpec("normal", tab.bar.foreground, Color.accent)
        : Border.none()

      Row {
        id: queueInner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: queueRow.borderLeft + Style.space(8)
        anchors.rightMargin: queueRow.borderRight + Style.space(8)
        spacing: Style.space(8)

        Text {
          text: queueRow.modelData.image_url ? "" : (queueRow.isCurrent ? "󰝚" : "")
          color: tab.bar.foreground
          font.family: tab.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          visible: !queueRow.modelData.image_url && queueRow.isCurrent
        }
        Image {
          source: queueRow.modelData.image_url || ""
          width: Style.space(28)
          height: Style.space(28)
          fillMode: Image.PreserveAspectCrop
          visible: source !== ""
          asynchronous: true
          anchors.verticalCenter: parent.verticalCenter
        }
        Column {
          width: parent.width - Style.space(58) - queueActions.width - Style.space(8)
          spacing: Style.space(1)
          anchors.verticalCenter: parent.verticalCenter
          Text {
            textFormat: Text.PlainText
            text: queueRow.modelData.name || queueRow.modelData.uri || "?"
            color: tab.bar.foreground
            font.family: tab.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: queueRow.isCurrent
            elide: Text.ElideRight
            width: parent.width
          }
          Text {
            textFormat: Text.PlainText
            text: queueRow.modelData.artist || queueRow.modelData.uri || ""
            color: Qt.darker(tab.bar.foreground, 1.4)
            font.family: tab.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          if (!tab.service) return
          if (mouse.button === Qt.RightButton) {
            tab.service.deleteQueueItem(tab.service.activePlayerId, queueRow.modelData.queue_item_id)
          } else {
            tab.service.playIndex(tab.service.activePlayerId, queueRow.index)
          }
        }
      }

      // Move up / down / to end / remove. After the MouseArea so the buttons
      // receive the click instead of the row handler.
      Row {
        id: queueActions
        spacing: 0
        anchors.right: parent.right
        anchors.rightMargin: queueRow.borderRight + Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        Button {
          iconText: "󰅃"
          tooltipText: "Move up"
          foreground: tab.bar.foreground
          iconSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(2)
          enabled: queueRow.index > 0
          opacity: enabled ? 1.0 : 0.3
          onClicked: if (tab.service) tab.service.moveQueueItem(queueRow.modelData.queue_item_id, -1)
        }
        Button {
          iconText: "󰅀"
          tooltipText: "Move down"
          foreground: tab.bar.foreground
          iconSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(2)
          enabled: tab.service && queueRow.index < tab.service.queue.length - 1
          opacity: enabled ? 1.0 : 0.3
          onClicked: if (tab.service) tab.service.moveQueueItem(queueRow.modelData.queue_item_id, 1)
        }
        Button {
          iconText: "󰘁"
          tooltipText: "Move to end"
          foreground: tab.bar.foreground
          iconSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(2)
          enabled: tab.service && queueRow.index < tab.service.queue.length - 1
          opacity: enabled ? 1.0 : 0.3
          onClicked: if (tab.service) tab.service.moveQueueItemEnd(queueRow.modelData.queue_item_id)
        }
        Button {
          iconText: "󰅖"
          tooltipText: "Remove from queue"
          foreground: tab.bar.foreground
          iconSize: Style.font.caption
          horizontalPadding: Style.space(3)
          verticalPadding: Style.space(2)
          onClicked: if (tab.service) tab.service.deleteQueueItem(tab.service.activePlayerId, queueRow.modelData.queue_item_id)
        }
      }
    }
  }

  Text {
    text: tab.service && tab.service.queue.length === 0 ? "Queue is empty." : ""
    color: Qt.darker(tab.bar.foreground, 1.4)
    font.family: tab.bar.fontFamily
    font.pixelSize: Style.font.caption
    width: parent.width
    wrapMode: Text.WordWrap
  }
}
