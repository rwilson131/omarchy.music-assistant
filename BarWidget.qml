import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "MaApi.js" as MaApi

BarWidget {
  id: root
  moduleName: "io.github.manologarciadev.music-assistant"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("io.github.manologarciadev.music-assistant") : null
  readonly property bool serviceReady: service && service.ready
  readonly property bool serviceConnected: service && service.connected

  readonly property var activePlayer: service && service.activePlayer ? service.activePlayer : null
  readonly property var media: service && service.activeMedia ? service.activeMedia : null
  readonly property bool hasMedia: service ? service.hasMedia : false
  readonly property bool isPlaying: service ? service.isPlaying : false
  readonly property string playIcon: isPlaying ? "󰏤" : "󰐊"
  readonly property string title: service ? service.activeTitle : ""
  readonly property string artist: service ? service.activeArtist : ""
  readonly property string album: service ? service.activeAlbum : ""
  readonly property string imageUrl: service ? service.activeImageUrl : ""
  readonly property int volume: service ? service.activeVolume : 100
  readonly property int duration: service ? service.activeDuration : 0
  readonly property int elapsed: service ? service.activeElapsed : 0
  readonly property int revision: service ? service.revision : 0

  // Active popup section: "now", "players", "queue", "search"
  property string popupSection: "now"
  property bool popupOpen: false

  onPopupSectionChanged: {
    if (popupSection !== "search") searchFilter = "all"
    activatePopupSection()
  }

  function close() { popupOpen = false }
  function openSection(s) { popupSection = s; popupOpen = true }

  // Fix: switching tabs while the popup was already open did nothing, because
  // the per-section focus and refresh only ran from onOpenChanged. Run it from
  // both places so the search field gets focus and the favorites, playlists
  // and recent lists reload whichever way the section was reached.
  function activatePopupSection() {
    if (!popupOpen || !service) return
    if (popupSection === "search") {
      // Run after the popup FocusScope receives focus so it cannot steal
      // focus back from the text field.
      Qt.callLater(function() { searchInput.forceActiveFocus() })
    } else if (popupSection === "favorites") {
      service.refreshFavorites()
    } else if (popupSection === "playlists") {
      service.refreshPlaylists()
    } else if (popupSection === "recent") {
      service.refreshRecent()
    }
  }

  property real maxLabelWidth: 180
  property real popupWidth: 380
  property string searchFilter: "all"
  property string favFilter: "tracks"

  readonly property bool shouldShow: service && (service.ready || service.configError)
  visible: shouldShow
  implicitWidth: visible ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      text: root.playIcon
      color: root.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    Item {
      id: scrollClip
      width: Math.min(root.maxLabelWidth, labelText.implicitWidth)
      height: glyph.height
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical

      Text {
        id: labelText
        text: root.serviceReady
          ? (root.title ? (root.title + (root.artist ? "  ·  " + root.artist : "")) : (root.hasMedia ? "" : "Nothing playing"))
          : "Music Assistant: setup"
        color: root.serviceReady
          ? root.bar.barForeground
          : Qt.darker(root.bar.barForeground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight

        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          id: scrollAnim
          running: labelText.needsScroll && !root.popupOpen && !root.bar.vertical
          loops: Animation.Infinite
          duration: Math.max(6000, labelText.implicitWidth * 25)
          from: scrollClip.width
          to: -labelText.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.serviceReady ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.serviceReady) return
      if (mouse.button === Qt.MiddleButton) {
        root.service.next()
      } else if (mouse.button === Qt.RightButton) {
        root.popupOpen = !root.popupOpen
        root.popupSection = "now"
      } else {
        root.service.playPause()
      }
    }
    onWheel: function(wheel) {
      if (!root.serviceReady) return
      if (wheel.angleDelta.y > 0) root.service.previous()
      else if (wheel.angleDelta.y < 0) root.service.next()
    }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      root.serviceReady
        ? (root.title ? (root.title + (root.artist ? " — " + root.artist : "")) : "Music Assistant")
        : "")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // -------------------------------------------------- popup

  // KeyboardPanel rather than PopupCard: PopupCard is an xdg-popup of the
  // bar, and the bar never takes keyboard focus, so nothing typed ever
  // reached the search field (or the Tab / Ctrl+N / Space shortcuts).
  // KeyboardPanel is the shell's layer-shell popup that primes keyboard
  // focus on open; its API matches what this widget used from PopupCard.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: popupFocus
    contentWidth: popup.fittedContentWidth(Style.space(root.popupWidth))
    contentHeight: popup.fittedContentHeight(hero.implicitHeight + Style.space(21) + Math.max(sidebar.implicitHeight, 320), 620)

    onOpenChanged: {
      if (open && root.service && typeof root.service.refreshState === "function") {
        root.service.refreshState()
      }
      if (open) Qt.callLater(function() {
        popupFocus.forceActiveFocus()
        root.activatePopupSection()
      })
    }

    FocusScope {
      id: popupFocus
      anchors.fill: parent
      focus: root.popupOpen

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.popupOpen = false
          event.accepted = true
        } else if (event.modifiers === Qt.ControlModifier) {
          var tabs = ["now", "players", "queue", "search", "favorites", "playlists", "recent"]
          var n = parseInt(event.text)
          if (!isNaN(n) && n >= 1 && n <= tabs.length) {
            root.popupSection = tabs[n - 1]
            event.accepted = true
          }
        } else if (event.key === Qt.Key_Tab) {
          var tabs2 = ["now", "players", "queue", "search", "favorites", "playlists", "recent"]
          var idx = tabs2.indexOf(root.popupSection)
          if (event.modifiers === Qt.ShiftModifier) idx = (idx - 1 + tabs2.length) % tabs2.length
          else idx = (idx + 1) % tabs2.length
          root.popupSection = tabs2[idx]
          event.accepted = true
        } else if (event.key === Qt.Key_Space && root.popupSection === "now" && root.service) {
          root.service.playPause()
          event.accepted = true
        }
      }

      // Header in the style of the shell's own panels (see Tailscale):
      // glyph, title, and a status line for the active player.
      PanelHero {
        id: hero
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Music Assistant"
        meta: !root.serviceReady ? "Not configured"
          : !root.serviceConnected ? "Connecting…"
          : root.activePlayer
            ? (root.activePlayer.name || "Player") + (root.isPlaying ? " · Playing" : (root.hasMedia ? " · Paused" : " · Idle"))
            : "No player selected"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        iconOpacity: root.serviceConnected ? 1.0 : 0.5
        iconComponent: Component {
          MaIcon {
            iconSize: Style.font.display
            color: root.bar.foreground
          }
        }
      }

      PanelSeparator {
        id: heroRule
        anchors.top: hero.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        foreground: root.bar.foreground
      }

      Row {
        id: popupRow
        height: 320
        anchors.top: heroRule.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        Column {
          id: sidebar
          width: Style.space(48)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          spacing: Style.space(4)
  
          Repeater {
            // Nerd Font Material Design glyphs. The originals were stale
            // codepoints that rendered as Facebook, a flask, fast-forward,
            // "123" and two calendars in current Nerd Fonts.
            model: [
              { id: "now", icon: "󰝚", label: "Now" },
              { id: "players", icon: "󰓃", label: "Players" },
              { id: "queue", icon: "󰐐", label: "Queue" },
              { id: "search", icon: "󰍉", label: "Search" },
              { id: "favorites", icon: "󰋑", label: "Favs" },
              { id: "playlists", icon: "󰲸", label: "Lists" },
              { id: "recent", icon: "󰋚", label: "Recent" }
            ]
            delegate: TabIcon {
              required property var modelData
              icon: modelData.icon
              label: modelData.label
              labelId: modelData.id
              active: root.popupSection === modelData.id
              bar: root.bar
              onClicked: root.popupSection = modelData.id
            }
          }
        }
  
        Item {
          id: popupColumn
          width: parent.width - Style.space(56)
          height: parent.height
          clip: true

          ScrollView {
            id: contentFlick
            anchors.fill: parent
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            // Themed scrollbar parked in the card's right padding, beside the
            // content instead of on top of it, so row borders stay visible.
            // It is parented to the popup FocusScope because popupColumn clips.
            ScrollBar.vertical: ThemedScrollBar {
              id: contentScrollBar
              parent: popupFocus
              bar: root.bar
              x: popupColumn.x + popupColumn.width + Style.space(2)
              y: popupColumn.y
              height: popupColumn.height
            }

            // Only let the flickable grab wheel and drag input while there is
            // something to scroll, as the shell's own panels do.
            Binding {
              target: contentFlick.contentItem
              property: "interactive"
              value: contentColumn.implicitHeight > contentFlick.height
            }

            Column {
              id: contentColumn
              width: contentFlick.availableWidth
              spacing: Style.space(10)

                  // Connection status banner
              BorderSurface {
                width: parent.width
                visible: !root.serviceReady || !root.serviceConnected
                radius: Style.spacing.labelGap
                color: Style.selectedFillFor(root.bar.foreground, Color.accent)
                borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
                padding: Style.space(8)
  
                Text {
                  anchors.fill: parent
                  wrapMode: Text.WordWrap
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  text: root.serviceReady
                    ? ("Connecting to Music Assistant…")
                    : ("Music Assistant not configured.\n" + (root.service && root.service.configError ? root.service.configError : ""))
                }
              }
  
              // ------------------ Now section
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.popupSection === "now"
  
                PlayerControls {
                  width: parent.width
                  bar: root.bar
                  activePlayer: root.service ? root.service.activePlayer : null
                  activeMedia: root.media
                  imageUrl: root.imageUrl
                  title: root.title
                  artist: root.artist
                  album: root.album
                  volume: root.volume
                  muted: root.service && root.service.activePlayer ? !!root.service.activePlayer.volume_muted : false
                  elapsed: root.elapsed
                  duration: root.duration
                  isPlaying: root.isPlaying
                  shuffleEnabled: root.service ? root.service.shuffleEnabled : false
                  repeatMode: root.service ? root.service.repeatMode : "off"
                  onPlayPause: if (root.service) root.service.playPause()
                  onNext: if (root.service) root.service.next()
                  onPrevious: if (root.service) root.service.previous()
                  onSeek: function(ms) { if (root.service) root.service.seek(root.service.activePlayerId, ms) }
                  onToggleShuffle: if (root.service) root.service.toggleShuffle()
                  onCycleRepeat: if (root.service) root.service.cycleRepeat()
                  onFavoriteCurrent: if (root.service) root.service.favoriteCurrent()
                  onOpenWebUI: if (root.service) root.service.openWebUI()
                  onChangeVolume: function(percent) { if (root.service) root.service.setVolumeLocal(root.service.activePlayerId, percent) }
                  onToggleMute: if (root.service) root.service.toggleMute(root.service.activePlayerId)
                }
              }
  
              // ------------------ Players section
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.popupSection === "players"
  
                PanelSectionHeader {
                  foreground: root.bar.foreground
                  text: "PLAYERS (" + (root.service ? root.service.players.length : 0) + ")"
                }
  
                Repeater {
                  model: root.service ? root.service.players : []
  
                  delegate: BorderSurface {
                    id: playerRow
                    required property var modelData
                    readonly property var player: modelData
                    readonly property bool isActive: root.service && player.player_id === root.service.activePlayerId
                    readonly property bool available: player.available === true
                    readonly property bool playingHere: player.playback_state === "playing"
                    readonly property bool groupPlayer: player.group_members && player.group_members.length > 1
                    readonly property int vol: MaApi.volumePercent(player)
                    readonly property string rowTitle: player.name + (groupPlayer ? " (" + player.group_members.length + " players)" : "")
                    readonly property string rowDetail: {
                      var m = player.current_media
                      if (!m) return available ? (player.synced_to ? "synced" : "idle") : "unavailable"
                      return (m.artist ? m.artist + " — " : "") + (m.title || m.uri || "")
                    }
  
                    width: parent.width
                    height: rowInner.implicitHeight + Style.space(10)
                    radius: Style.spacing.labelGap
                    color: isActive
                      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                      : "transparent"
                    borderSpec: isActive
                      ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
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
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        width: Style.space(18)
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: available ? 1.0 : 0.5
                      }
  
                      Column {
                        width: parent.width - Style.space(34)
                        spacing: Style.space(1)
                        anchors.verticalCenter: parent.verticalCenter
  
                        Text {
                          text: playerRow.rowTitle
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: playerRow.isActive
                          elide: Text.ElideRight
                          width: parent.width
                        }
                        Text {
                          text: playerRow.rowDetail
                          color: Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
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
                        if (!root.service || !playerRow.available) return
                        if (mouse.button === Qt.RightButton) {
                          root.service.toggleMute(playerRow.player.player_id)
                          return
                        }
                        if (playerRow.isActive) return
                        if (root.service.queue && root.service.queue.length > 0) {
                          root.service.transferQueue(root.service.activePlayerId, playerRow.player.player_id)
                        } else {
                          root.service.activatePlayer(playerRow.player.player_id)
                        }
                      }
                    }
                  }
                }
              }
  
              // ------------------ Queue section
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.popupSection === "queue"
  
                Row {
                  width: parent.width
                  Text {
                    text: "QUEUE (" + (root.service ? root.service.queue.length : 0) + ")"
                    color: Qt.darker(root.bar.foreground, 1.3)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Item { width: 1; height: 1 }
                  Button {
                    text: "Clear"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    enabled: root.serviceReady && root.service && root.service.queue.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    onClicked: if (root.service) root.service.clearQueue(root.service.activePlayerId)
                  }
                }
  
                Repeater {
                  model: root.service ? root.service.queue : []
                  delegate: BorderSurface {
                    id: queueRow
                    required property var modelData
                    required property int index
                    readonly property bool isCurrent: root.service && queueRow.index === root.service.queuePosition
                    width: parent.width
                    height: queueInner.implicitHeight + Style.space(8)
                    radius: Style.spacing.labelGap
                    color: isCurrent
                      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                      : "transparent"
                    borderSpec: isCurrent
                      ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
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
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
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
                        width: parent.width - Style.space(58)
                        spacing: Style.space(1)
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                          text: queueRow.modelData.name || queueRow.modelData.title || queueRow.modelData.uri || "?"
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: queueRow.isCurrent
                          elide: Text.ElideRight
                          width: parent.width
                        }
                        Text {
                          text: queueRow.modelData.artist || queueRow.modelData.uri || ""
                          color: Qt.darker(root.bar.foreground, 1.4)
                          font.family: root.bar.fontFamily
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
                        if (!root.service) return
                        if (mouse.button === Qt.RightButton) {
                          root.service.deleteQueueItem(root.service.activePlayerId, queueRow.modelData.queue_item_id || queueRow.modelData.item_id)
                        } else {
                          root.service.playIndex(root.service.activePlayerId, queueRow.index)
                        }
                      }
                    }
                  }
                }
  
                Text {
                  text: root.service && root.service.queue.length === 0 ? "Queue is empty." : ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                }
              }
  
              // ------------------ Search section
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.popupSection === "search"
  
                TextField {
                  id: searchInput
                  width: parent.width
                  placeholderText: "Search Music Assistant…"
                  onAccepted: if (root.service && text.length > 0) root.service.search(text)
                  foreground: root.bar.foreground
                  focus: root.popupSection === "search" && root.popupOpen
                  activeFocusOnTab: true
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.popupOpen = false
                      event.accepted = true
                    }
                  }
                }
  
                Row {
                  width: parent.width
                  Button {
                    text: "Search"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    enabled: searchInput.text.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    onClicked: if (root.service) root.service.search(searchInput.text)
                  }
                  Item { width: 1; height: 1 }
                  Button {
                    text: "Clear"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    enabled: root.service && root.service.searchResults !== null
                    opacity: enabled ? 1.0 : 0.4
                    onClicked: {
                      searchInput.text = ""
                      if (root.service) root.service.clearSearch()
                      root.searchFilter = "all"
                    }
                  }
                }
  
                // Filter chips
                Row {
                  width: parent.width
                  spacing: Style.space(4)
  
                  Repeater {
                    model: {
                      if (!root.service || !root.service.searchResults) return []
                      var r = root.service.searchResults
                      return [
                        { id: "all", label: "All", count: (r.tracks ? r.tracks.length : 0) + (r.albums ? r.albums.length : 0) + (r.artists ? r.artists.length : 0) + (r.playlists ? r.playlists.length : 0) },
                        { id: "track", label: "Songs", count: r.tracks ? r.tracks.length : 0 },
                        { id: "album", label: "Albums", count: r.albums ? r.albums.length : 0 },
                        { id: "artist", label: "Artists", count: r.artists ? r.artists.length : 0 },
                        { id: "playlist", label: "Playlists", count: r.playlists ? r.playlists.length : 0 }
                      ]
                    }
  
                    delegate: BorderSurface {
                      required property var modelData
                      readonly property bool active: root.searchFilter === modelData.id
                      width: (parent.width - Style.space(16)) / 5
                      height: Style.space(26)
                      radius: Style.cornerRadius
                      color: active
                        ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                        : Style.normalFillFor(root.bar.foreground, Color.accent)
                      borderSpec: active
                        ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
                        : Border.controlSpec("normal", Qt.darker(root.bar.foreground, 1.4), Color.accent)
                      visible: modelData.count > 0
  
                      Row {
                        anchors.centerIn: parent
                        spacing: Style.space(3)
                        Text {
                          text: modelData.label
                          color: root.bar.foreground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: parent.parent.active
                          anchors.verticalCenter: parent.verticalCenter
                        }
                        Rectangle {
                          visible: modelData.count > 0
                          anchors.verticalCenter: parent.verticalCenter
                          radius: 6
                          color: parent.parent.active ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                          implicitWidth: countLbl.implicitWidth + Style.space(6)
                          implicitHeight: countLbl.implicitHeight + 2
                          Text {
                            id: countLbl
                            anchors.centerIn: parent
                            text: modelData.count
                            color: parent.parent.parent.parent.parent.active
                              ? Color.popups.background
                              : root.bar.foreground
                            font.family: root.bar.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }
  
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.searchFilter = modelData.id
                      }
                    }
                  }
                }
  
                Component {
                  id: trackRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || modelData.title || "?"
                    subtitle: (modelData.artists ? modelData.artists.map(function(a){return a.name}).join(", ") : "") + (modelData.album ? " — " + (modelData.album.name || "") : "")
                    type: MaApi.mediaTypeLabel(modelData.media_type || "track")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "track")) ? root.service.searchResults.tracks : []
                  delegate: trackRowDelegate
                }
  
                Component {
                  id: albumRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || "?"
                    subtitle: modelData.artists ? modelData.artists.map(function(a){return a.name}).join(", ") : ""
                    type: MaApi.mediaTypeLabel(modelData.media_type || "album")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "album")) ? root.service.searchResults.albums : []
                  delegate: albumRowDelegate
                }
  
                Component {
                  id: playlistRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || "?"
                    subtitle: (modelData.owner ? modelData.owner + " · " : "") + (modelData.track_count !== undefined ? modelData.track_count + " tracks" : "playlist")
                    type: MaApi.mediaTypeLabel(modelData.media_type || "playlist")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "playlist")) ? root.service.searchResults.playlists : []
                  delegate: playlistRowDelegate
                }
  
                Component {
                  id: artistRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    title: modelData.name || "?"
                    subtitle: ""
                    type: MaApi.mediaTypeLabel(modelData.media_type || "artist")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "artist")) ? root.service.searchResults.artists : []
                  delegate: artistRowDelegate
                }
  
                Text {
                  width: parent.width
                  text: {
                    if (!root.service) return ""
                    var r = root.service.searchResults
                    if (!r) return root.service.searchQuery ? "Searching…" : "Type a query and press Enter."
                    var total = (r.tracks ? r.tracks.length : 0) + (r.albums ? r.albums.length : 0) + (r.artists ? r.artists.length : 0) + (r.playlists ? r.playlists.length : 0)
                    return total === 0 ? "No results." : ""
                  }
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
  
              // ------------------ Favorites section
              Column {
                id: favoritesTab
                width: parent.width
                spacing: Style.space(4)
                visible: root.popupSection === "favorites"
  
                Row {
                  width: parent.width
                  spacing: Style.space(4)
  
                  Repeater {
                    model: [
                      { id: "tracks", label: "Tracks" },
                      { id: "albums", label: "Albums" },
                      { id: "artists", label: "Artists" },
                      { id: "playlists", label: "Playlists" },
                      { id: "radio", label: "Radio" }
                    ]
                    delegate: BorderSurface {
                      required property var modelData
                      readonly property bool active: root.favFilter === modelData.id
                      width: (parent.width - Style.space(16)) / 5
                      height: Style.space(26)
                      radius: Style.cornerRadius
                      color: active
                        ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                        : Style.normalFillFor(root.bar.foreground, Color.accent)
                      borderSpec: active
                        ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
                        : Border.controlSpec("normal", Qt.darker(root.bar.foreground, 1.4), Color.accent)
  
                      Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: parent.active
                      }
  
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.favFilter = modelData.id
                      }
                    }
                  }
                }
  
                Component {
                  id: favRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || modelData.title || "?"
                    subtitle: (modelData.artist || "") + (modelData.duration ? " · " + Math.floor(modelData.duration / 60) + " min" : "")
                    showTypeBadge: false
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) {
                      if (root.service) root.service.removeFavorite(modelData.uri)
                    }
                  }
                }
  
                Repeater {
                  model: root.service && root.service.favorites ? root.service.favorites[root.favFilter] || [] : []
                  delegate: favRowDelegate
                }
  
                Text {
                  visible: !root.service || !root.service.favorites || !(root.service.favorites[root.favFilter] || []).length
                  width: parent.width
                  text: root.service ? "No " + root.favFilter + " favorites yet." : "Loading…"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
  
              // ------------------ Playlists section
              Column {
                id: playlistsTab
                width: parent.width
                spacing: Style.space(4)
                visible: root.popupSection === "playlists"
  
                Component {
                  id: playlistDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || (modelData.metadata && modelData.metadata.image_url) || ""
                    title: modelData.name || "?"
                    subtitle: (modelData.owner ? modelData.owner + " · " : "") + (modelData.track_count !== undefined ? modelData.track_count + " tracks" : "playlist")
                    showTypeBadge: false
                    showSourceBadge: true
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: root.service ? root.service.playlists : []
                  delegate: playlistDelegate
                }
  
                Text {
                  visible: !root.service || !root.service.playlists || root.service.playlists.length === 0
                  width: parent.width
                  text: root.service ? "No playlists found." : "Loading…"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
  
              // ------------------ Recent section
              Column {
                id: recentTab
                width: parent.width
                spacing: Style.space(4)
                visible: root.popupSection === "recent"
  
                Component {
                  id: recentDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || modelData.title || "?"
                    subtitle: MaApi.formatRelativeTime(modelData.last_played || modelData.timestamp)
                    showTypeBadge: true
                    showSourceBadge: true
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                  }
                }
  
                Repeater {
                  model: root.service ? root.service.recentItems : []
                  delegate: recentDelegate
                }
  
                Text {
                  visible: !root.service || !root.service.recentItems || root.service.recentItems.length === 0
                  width: parent.width
                  text: root.service ? "No recent items." : "Loading…"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
    }
  }
}
}

