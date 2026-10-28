import QtQuick
import qs.Commons
import qs.Ui

// Player selection, queue transfer and grouping controls. Kept separate from
// BarWidget so changes to multi-room behavior do not expand the popup shell.
Column {
  id: tab

  property var service: null
  property var bar: null
  property var activePlayer: null

  spacing: Style.space(4)

  function sortedPlayers() {
    if (!service) return []
    var _r = service.revision
    var active = service.activePlayerId
    var list = service.players.filter(function(player) { return !player.hide_in_ui })
    function rank(player) {
      if (player.player_id === active) return 0
      if (!player.available) return 4
      if (player.playback_state === "playing") return 1
      if (player.type === "group") return 3
      return 2
    }
    list.sort(function(a, b) {
      var ra = rank(a), rb = rank(b)
      if (ra !== rb) return ra - rb
      return String(a.name).localeCompare(String(b.name))
    })
    return list
  }

  PanelSectionHeader {
    foreground: tab.bar.foreground
    text: "PLAYERS (" + (tab.service ? tab.service.players.length : 0) + ")"
  }

  Repeater {
    model: tab.sortedPlayers()

    delegate: BorderSurface {
      id: playerRow
      required property var modelData
      readonly property var player: modelData
      readonly property bool isActive: tab.service && player.player_id === tab.service.activePlayerId
      readonly property bool available: player.available === true
      readonly property bool playingHere: player.playback_state === "playing"
      readonly property bool groupPlayer: player.group_members && player.group_members.length > 0
      readonly property string rowTitle: player.name + (groupPlayer ? " (" + player.group_members.length + ")" : "")
      readonly property string leaderName: {
        var lid = player.synced_to || player.active_group
        var leader = lid && tab.service ? tab.service.playerById(lid) : null
        return leader ? leader.name : ""
      }
      readonly property string rowDetail: {
        if (!available) return "unavailable"
        if (leaderName !== "") return "grouped with " + leaderName
        var media = player.current_media
        if (!media) return "idle"
        return (media.artist ? media.artist + " — " : "") + (media.title || media.uri || "")
      }
      readonly property string groupMode: {
        if (!tab.service || !available) return ""
        if (isActive) return groupPlayer ? "ungroup" : ""
        if (tab.service.isGroupedWithActive(player.player_id)) return "leave"
        if (tab.service.canGroupWithActive(player.player_id)) return "join"
        return ""
      }

      width: parent.width
      height: rowInner.implicitHeight + Style.space(10)
      radius: Style.spacing.labelGap
      color: isActive
        ? Style.selectedFillFor(tab.bar.foreground, Color.accent)
        : "transparent"
      borderSpec: isActive
        ? Border.controlSpec("normal", tab.bar.foreground, Color.accent)
        : Border.none()

      Row {
        id: rowInner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: playerRow.borderLeft + Style.space(8)
        anchors.rightMargin: playerRow.borderRight + Style.space(8)
        spacing: Style.space(8)

        Text {
          text: playingHere ? "󰏤" : (available ? "󰐊" : "󰂃")
          color: tab.bar.foreground
          font.family: tab.bar.fontFamily
          font.pixelSize: Style.font.body
          width: Style.space(18)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: available ? 1.0 : 0.5
        }

        Column {
          width: parent.width - Style.space(34) - (groupBtn.visible ? groupBtn.width + Style.space(8) : 0) - (moveBtn.visible ? moveBtn.width + Style.space(8) : 0)
          spacing: Style.space(1)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: playerRow.rowTitle
            color: tab.bar.foreground
            font.family: tab.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: playerRow.isActive
            elide: Text.ElideRight
            width: parent.width
          }
          Text {
            textFormat: Text.PlainText
            text: playerRow.rowDetail
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
          if (!tab.service || !playerRow.available) return
          if (mouse.button === Qt.RightButton) {
            tab.service.toggleMute(playerRow.player.player_id)
            return
          }
          if (!playerRow.isActive) tab.service.activatePlayer(playerRow.player.player_id)
        }
      }

      Button {
        id: moveBtn
        readonly property bool canMove: !playerRow.isActive && playerRow.available && tab.service && tab.service.queue.length > 0
        visible: canMove
        text: "Move here"
        tooltipText: "Move what " + (tab.activePlayer ? tab.activePlayer.name : "the active player") + " is playing to this player"
        foreground: tab.bar.foreground
        fontSize: Style.font.caption
        bordered: true
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(2)
        anchors.right: groupBtn.visible ? groupBtn.left : parent.right
        anchors.rightMargin: groupBtn.visible ? Style.space(4) : playerRow.borderRight + Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: if (tab.service) tab.service.transferQueue(tab.service.activePlayerId, playerRow.player.player_id)
      }

      Button {
        id: groupBtn
        visible: playerRow.groupMode !== ""
        text: playerRow.groupMode === "join" ? "Join" : (playerRow.groupMode === "leave" ? "Leave" : "Ungroup")
        tooltipText: playerRow.groupMode === "join" ? "Group with " + (tab.activePlayer ? tab.activePlayer.name : "the active player")
          : (playerRow.groupMode === "leave" ? "Leave the group" : "Dissolve the group")
        foreground: tab.bar.foreground
        fontSize: Style.font.caption
        bordered: true
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(2)
        anchors.right: parent.right
        anchors.rightMargin: playerRow.borderRight + Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: {
          if (!tab.service) return
          if (playerRow.groupMode === "join") tab.service.groupAdd(playerRow.player.player_id)
          else if (playerRow.groupMode === "leave") tab.service.groupRemove(playerRow.player.player_id)
          else tab.service.ungroup(playerRow.player.player_id)
        }
      }
    }
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Click a player to control it; nothing changes on the others. Move here carries the active player's queue over. Right-click mutes. Join / Leave group speakers with the active player."
    color: Qt.darker(tab.bar.foreground, 1.5)
    font.family: tab.bar.fontFamily
    font.pixelSize: Style.font.caption
  }
}
