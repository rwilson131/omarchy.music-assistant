import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root

  property var model: []
  property Component delegateComponent: null
  property QtObject bar: null
  property string emptyText: "Empty"
  property int itemHeight: 48

  signal activated(int index)
  signal removeRequested(int index)
  signal contextMenu(int index, var mouse)

  implicitHeight: listView.contentHeight
  implicitWidth: parent ? parent.width : 0

  ListView {
    id: listView
    anchors.fill: parent
    clip: true
    model: root.model
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds

    delegate: Loader {
      width: listView.width
      sourceComponent: root.delegateComponent
      property var modelData: model.modelData
      property int index: model.index

      onLoaded: {
        if (item) {
          item.modelData = model.modelData
          item.index = model.index
        }
      }
    }

    // The list is sized to its content and scrolled by the popup's outer
    // ScrollView, so it carries no scrollbar of its own.

    Text {
      anchors.centerIn: parent
      visible: listView.count === 0
      text: root.emptyText
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Up) {
        listView.currentIndex = Math.max(0, listView.currentIndex - 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        listView.currentIndex = Math.min(listView.count - 1, listView.currentIndex + 1)
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (listView.currentIndex >= 0) {
          root.activated(listView.currentIndex)
          event.accepted = true
        }
      } else if (event.key === Qt.Key_Delete) {
        if (listView.currentIndex >= 0) {
          root.removeRequested(listView.currentIndex)
          event.accepted = true
        }
      }
    }
  }
}
