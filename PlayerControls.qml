import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Item {
  id: root

  property QtObject bar: null
  property var activePlayer: null
  property var activeMedia: null
  property string imageUrl: ""
  property string title: ""
  property string artist: ""
  property string album: ""
  property int volume: 100
  // Volume control for the Now section: the bar widget feeds the active
  // player's mute state in and acts on these two signals.
  property bool muted: false
  property int elapsed: 0
  property int duration: 0
  property bool isPlaying: false
  property bool shuffleEnabled: false
  property string repeatMode: "off"
  // Shuffle and repeat cannot be changed on a server-filled (dynamic) queue.
  property bool dynamicQueue: false
  property bool isFavorite: false
  property bool autoplayEnabled: false
  property int sleepRemainingSeconds: 0

  signal playPause()
  signal next()
  signal previous()
  signal seek(real positionSeconds)
  signal toggleShuffle()
  signal cycleRepeat()
  signal favoriteCurrent()
  signal toggleAutoplay()
  signal cycleSleepTimer()
  signal openWebUI()
  signal changeVolume(real percent)
  signal toggleMute()

  implicitWidth: Style.space(360)
  implicitHeight: column.implicitHeight

  // Seconds in, m:ss (or h:mm:ss) out.
  function formatTime(seconds) {
    if (!seconds || seconds < 0) return "0:00"
    var s = Math.floor(seconds)
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var sec = s % 60
    var mm = h > 0 && m < 10 ? "0" + m : String(m)
    return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" : "") + sec
  }

  Column {
    id: column
    anchors.fill: parent
    spacing: Style.space(6)

    BorderSurface {
      width: Style.space(112)
      height: Style.space(112)
      anchors.horizontalCenter: parent.horizontalCenter
      radius: Style.spacing.labelGap
      color: Style.normalFillFor(root.bar.foreground, Color.accent)
      borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

      Image {
        id: artwork
        anchors.fill: parent
        anchors.margins: Style.space(2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: root.imageUrl
        visible: source !== "" && status !== Image.Error
      }

      Text {
        anchors.centerIn: parent
        visible: !root.imageUrl || artwork.status === Image.Error
        text: "󰝚"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.displayLarge
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: root.title || "Nothing playing"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        text: root.artist + (root.artist && root.album ? " · " : "") + root.album
        color: Qt.darker(root.bar.foreground, 1.35)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        width: parent.width
        visible: text !== ""
      }
    }

    // Primary transport stays visually dominant and easy to target.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(6)

      Button {
        iconText: "󰒮"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.previous()
      }
      Button {
        iconText: root.isPlaying ? "󰏤" : "󰐊"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.panelGap
        verticalPadding: Style.spacing.controlPaddingY
        iconSize: Style.font.iconLarge
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.playPause()
      }
      Button {
        iconText: "󰒭"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.next()
      }
    }

    Column {
      width: parent.width
      spacing: Style.space(2)

      PanelSlider {
        id: progressSlider
        width: parent.width
        minimum: 0
        maximum: root.duration > 0 ? root.duration : 1
        value: root.elapsed
        bar: root.bar
        enabled: root.duration > 0
        // Explicit handler parameter: Qt 6 warns about injected signal
        // parameters.
        onMoved: function(value) { root.seek(value) }
      }

      Item {
        width: parent.width
        height: elapsedText.implicitHeight
        Text {
          id: elapsedText
          anchors.left: parent.left
          text: formatTime(root.elapsed)
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          // A live stream has no duration; show "live" instead of 0:00.
          text: root.duration > 0 ? formatTime(root.duration) : (root.isPlaying ? "live" : "")
          color: Qt.darker(root.bar.foreground, 1.3)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Volume for the active player. The slider sends on release (and on
    // wheel) rather than on every drag step so a drag is one request, not
    // twenty. Right-click on the track or the speaker button toggles mute.
    Row {
      id: volumeRow
      width: parent.width
      spacing: Style.space(6)

      Button {
        id: muteButton
        iconText: root.muted || root.volume === 0 ? "󰝟" : "󰕾"
        foreground: root.muted ? Qt.darker(root.bar.foreground, 1.3) : root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.toggleMute()
      }

      PanelSlider {
        id: volumeSlider
        width: parent.width - muteButton.width - volumeText.width - volumeRow.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        minimum: 0
        maximum: 100
        step: 5
        integer: true
        value: root.volume
        bar: root.bar
        enabled: root.activePlayer !== null
        opacity: root.muted ? 0.5 : 1.0
        onReleased: function(value) { root.changeVolume(value) }
        onRightClicked: root.toggleMute()
      }

      Text {
        id: volumeText
        text: Math.round(volumeSlider.liveValue) + "%"
        color: Qt.darker(root.bar.foreground, 1.3)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        width: Style.space(34)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Secondary playback actions sit at the bottom of the Now tab.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(4)

      Button {
        iconText: root.shuffleEnabled ? "󰒟" : "󰒞"
        tooltipText: root.dynamicQueue ? "Shuffle is fixed on a dynamic queue" : (root.shuffleEnabled ? "Shuffle on" : "Shuffle off")
        foreground: root.shuffleEnabled ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null && !root.dynamicQueue
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.toggleShuffle()
      }
      Button {
        iconText: root.repeatMode === "one" ? "󰑘" : (root.repeatMode === "all" ? "󰑖" : "󰑗")
        tooltipText: root.dynamicQueue ? "Repeat is fixed on a dynamic queue" : "Repeat: " + root.repeatMode
        foreground: root.repeatMode !== "off" ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null && !root.dynamicQueue
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.cycleRepeat()
      }
      Button {
        iconText: "󰁪"
        tooltipText: root.autoplayEnabled ? "Autoplay on" : "Autoplay off"
        foreground: root.autoplayEnabled ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.toggleAutoplay()
      }
      Button {
        // Heart (favorited) / heart outline.
        iconText: root.isFavorite ? "󰋑" : "󰋕"
        tooltipText: root.isFavorite ? "Remove favorite" : "Add favorite"
        foreground: root.isFavorite ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.favoriteCurrent()
      }
      Button {
        iconText: "󰒲"
        tooltipText: root.sleepRemainingSeconds > 0
          ? "Sleep timer: " + Math.ceil(root.sleepRemainingSeconds / 60) + " min"
          : "Sleep timer: off"
        foreground: root.sleepRemainingSeconds > 0 ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.3)
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.cycleSleepTimer()
      }
      Button {
        iconText: "󰖟"
        tooltipText: "Open Music Assistant"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        enabled: root.activePlayer !== null
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.openWebUI()
      }
    }
  }
}
