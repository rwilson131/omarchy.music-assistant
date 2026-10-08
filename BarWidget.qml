import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "MaApi.js" as MaApi

BarWidget {
  id: root
  moduleName: "io.github.rwilson131.music-assistant"

  readonly property var service: bar && bar.shell ? bar.shell.firstPartyServiceFor("io.github.rwilson131.music-assistant") : null
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

  // Active popup section: "now", "players", "queue", "search", "browse",
  // "favorites", "playlists", "recent"
  property string popupSection: "now"
  property bool popupOpen: false
  property bool queueSaveOpen: false
  property string browseFilter: ""

  readonly property var tabOrder: ["now", "players", "queue", "search", "browse", "favorites", "playlists", "recent"]

  // Players tab order: active, playing, idle, groups, unavailable; hidden
  // players stay hidden as in the MA UI.
  function sortedPlayers() {
    if (!service) return []
    var _r = service.revision
    var active = service.activePlayerId
    var list = service.players.filter(function(p) { return !p.hide_in_ui })
    function rank(p) {
      if (p.player_id === active) return 0
      if (!p.available) return 4
      if (p.playback_state === "playing") return 1
      if (p.type === "group") return 3
      return 2
    }
    list.sort(function(a, b) {
      var ra = rank(a), rb = rank(b)
      if (ra !== rb) return ra - rb
      return String(a.name).localeCompare(String(b.name))
    })
    return list
  }

  function filteredBrowseItems() {
    if (!service) return []
    var _r = service.browseRevision
    var items = service.browseItems
    var f = browseFilter.trim().toLowerCase()
    if (f.length > 0) items = items.filter(function(it) { return String(it.name || "").toLowerCase().indexOf(f) !== -1 })
    return items.slice(0, 200)
  }

  // Small toggle/action chip used for queue options and native sources.
  component Chip: BorderSurface {
    id: chip
    property string label: ""
    property string icon: ""
    property bool active: false
    signal clicked()

    width: chipInner.implicitWidth + Style.space(12)
    height: Style.space(24)
    radius: Style.cornerRadius
    opacity: enabled ? 1.0 : 0.4
    color: active
      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
      : Style.normalFillFor(root.bar.foreground, Color.accent)
    borderSpec: active
      ? Border.controlSpec("normal", root.bar.foreground, Color.accent)
      : Border.controlSpec("normal", Qt.darker(root.bar.foreground, 1.4), Color.accent)

    Row {
      id: chipInner
      anchors.centerIn: parent
      spacing: Style.space(4)
      Text {
        visible: chip.icon !== ""
        text: chip.icon
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: chip.label
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: chip.active
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  onPopupSectionChanged: {
    if (popupSection !== "search") searchFilter = "all"
    if (popupSection !== "playlists" && popupSection !== "favorites" && service && service.drillItem) service.closeCollection()
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
    } else if (popupSection === "browse") {
      if (service.browseItems.length === 0 && !service.browseLoading) service.browseRoot()
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
    contentHeight: popup.fittedContentHeight(hero.implicitHeight + Style.space(21) + Math.max(sidebar.implicitHeight, 380), 680)

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
          var tabs = root.tabOrder
          var n = parseInt(event.text)
          if (!isNaN(n) && n >= 1 && n <= tabs.length) {
            root.popupSection = tabs[n - 1]
            event.accepted = true
          }
        } else if (event.key === Qt.Key_Tab) {
          var tabs2 = root.tabOrder
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
        // Media keys switch, top right like the shell's own panels. On
        // installs a marked block in ~/.config/hypr/bindings.lua binding
        // play/pause/next/previous to the plugin and the volume keys to the
        // contextual script; Off removes it. See Service.mediaKeysBindingsBlock.
        trailingControl: Component {
          Row {
            spacing: Style.space(6)
            Text {
              text: "Media keys"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            ToggleSwitch {
              id: keysSwitch
              checked: root.service ? root.service.mediaKeysEnabled : false
              interactive: root.serviceReady
              foreground: root.bar.foreground
              anchors.verticalCenter: parent.verticalCenter
              onToggled: if (root.service) root.service.setMediaKeysEnabled(!root.service.mediaKeysEnabled)
              PanelToolTip {
                visible: keysSwitch.containsMouse
                text: "Keyboard play/pause, next and previous control Music Assistant; volume keys only while it is playing"
              }
            }
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
        height: 380
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
              { id: "browse", icon: "󰉋", label: "Browse" },
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
                  isFavorite: root.service ? root.service.currentFavorite : false
                  onPlayPause: if (root.service) root.service.playPause()
                  onNext: if (root.service) root.service.next()
                  onPrevious: if (root.service) root.service.previous()
                  onSeek: function(seconds) { if (root.service) root.service.seek(root.service.activePlayerId, seconds) }
                  onToggleShuffle: if (root.service) root.service.toggleShuffle()
                  onCycleRepeat: if (root.service) root.service.cycleRepeat()
                  onFavoriteCurrent: if (root.service) root.service.favoriteCurrent()
                  onOpenWebUI: if (root.service) root.service.openWebUI()
                  onChangeVolume: function(percent) { if (root.service) root.service.setVolumeLocal(root.service.activePlayerId, percent) }
                  onToggleMute: if (root.service) root.service.toggleMute(root.service.activePlayerId)
                }

                // Queue options (player_queues/crossfade, autoplay,
                // dont_stop_the_music), the sleep timer and stop.
                Flow {
                  width: parent.width
                  spacing: Style.space(4)
                  visible: root.serviceReady && root.service && root.service.activePlayer !== null

                  Chip {
                    label: "Crossfade"
                    active: root.service ? root.service.crossfadeEnabled : false
                    onClicked: root.service.setCrossfade(!active)
                  }
                  Chip {
                    label: "Autoplay"
                    active: root.service ? root.service.autoplayEnabled : false
                    onClicked: root.service.setAutoplay(!active)
                  }
                  Chip {
                    label: "Don't stop"
                    active: root.service ? root.service.dontStopTheMusicEnabled : false
                    onClicked: root.service.setDontStopTheMusic(!active)
                  }
                  Chip {
                    icon: "󰒲"
                    label: root.service && root.service.sleepRemainingSeconds > 0
                      ? Math.ceil(root.service.sleepRemainingSeconds / 60) + " min"
                      : "Sleep"
                    active: root.service ? root.service.sleepRemainingSeconds > 0 : false
                    // Cycles 15 → 30 → 60 → 90 min → off.
                    onClicked: {
                      var r = root.service.sleepRemainingSeconds
                      var next = r <= 0 ? 15 : (r <= 15 * 60 ? 30 : (r <= 30 * 60 ? 60 : (r <= 60 * 60 ? 90 : 0)))
                      root.service.setSleepTimer(next * 60)
                    }
                  }
                  Chip {
                    icon: "󰓛"
                    label: "Stop"
                    enabled: root.isPlaying || (root.service && root.service.isPaused)
                    onClicked: root.service.stop(root.service.activePlayerId)
                  }
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
                  model: root.sortedPlayers()

                  delegate: BorderSurface {
                    id: playerRow
                    required property var modelData
                    readonly property var player: modelData
                    readonly property bool isActive: root.service && player.player_id === root.service.activePlayerId
                    readonly property bool available: player.available === true
                    readonly property bool playingHere: player.playback_state === "playing"
                    readonly property bool groupPlayer: player.group_members && player.group_members.length > 0
                    readonly property int vol: MaApi.volumePercent(player)
                    readonly property string rowTitle: player.name + (groupPlayer ? " (" + player.group_members.length + ")" : "")
                    readonly property string leaderName: {
                      var lid = player.synced_to || player.active_group
                      var l = lid && root.service ? root.service.playerById(lid) : null
                      return l ? l.name : ""
                    }
                    readonly property string rowDetail: {
                      if (!available) return "unavailable"
                      if (leaderName !== "") return "grouped with " + leaderName
                      var m = player.current_media
                      if (!m) return "idle"
                      return (m.artist ? m.artist + " — " : "") + (m.title || m.uri || "")
                    }
                    // Grouping relative to the active player.
                    readonly property string groupMode: {
                      if (!root.service || !available) return ""
                      if (isActive) return groupPlayer ? "ungroup" : ""
                      if (root.service.isGroupedWithActive(player.player_id)) return "leave"
                      if (root.service.canGroupWithActive(player.player_id)) return "join"
                      return ""
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
                        width: parent.width - Style.space(34) - (groupBtn.visible ? groupBtn.width + Style.space(8) : 0)
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

                    // Join / Leave / Ungroup. Declared after the row's MouseArea
                    // so it receives the click.
                    Button {
                      id: groupBtn
                      visible: playerRow.groupMode !== ""
                      text: playerRow.groupMode === "join" ? "Join" : (playerRow.groupMode === "leave" ? "Leave" : "Ungroup")
                      tooltipText: playerRow.groupMode === "join" ? "Group with " + (root.activePlayer ? root.activePlayer.name : "the active player")
                        : (playerRow.groupMode === "leave" ? "Leave the group" : "Dissolve the group")
                      foreground: root.bar.foreground
                      fontSize: Style.font.caption
                      bordered: true
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(2)
                      anchors.right: parent.right
                      anchors.rightMargin: playerRow.borderRight + Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: {
                        if (!root.service) return
                        if (playerRow.groupMode === "join") root.service.groupAdd(playerRow.player.player_id)
                        else if (playerRow.groupMode === "leave") root.service.groupRemove(playerRow.player.player_id)
                        else root.service.ungroup(playerRow.player.player_id)
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Click a player to make it active (moves the queue). Right-click mutes. Join / Leave group speakers with the active player."
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
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
                  Item { width: Style.space(8); height: 1 }
                  Button {
                    text: "Save"
                    tooltipText: "Save the queue as a playlist"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    enabled: root.serviceReady && root.service && root.service.queue.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    active: root.queueSaveOpen
                    onClicked: {
                      root.queueSaveOpen = !root.queueSaveOpen
                      if (root.queueSaveOpen) Qt.callLater(function() { queueSaveName.forceActiveFocus() })
                    }
                  }
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

                TextField {
                  id: queueSaveName
                  width: parent.width
                  visible: root.queueSaveOpen
                  placeholderText: "Playlist name, then Enter"
                  foreground: root.bar.foreground
                  onAccepted: {
                    if (root.service && text.length > 0) root.service.saveQueueAsPlaylist(text)
                    text = ""
                    root.queueSaveOpen = false
                  }
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.queueSaveOpen = false; event.accepted = true }
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
                        width: parent.width - Style.space(58) - queueActions.width - Style.space(8)
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

                    // Move up / down / to end / remove. After the MouseArea so
                    // the buttons get the click.
                    Row {
                      id: queueActions
                      spacing: 0
                      anchors.right: parent.right
                      anchors.rightMargin: queueRow.borderRight + Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      Button {
                        iconText: "󰅃"
                        tooltipText: "Move up"
                        foreground: root.bar.foreground
                        iconSize: Style.font.caption
                        horizontalPadding: Style.space(3)
                        verticalPadding: Style.space(2)
                        enabled: queueRow.index > 0
                        opacity: enabled ? 1.0 : 0.3
                        onClicked: if (root.service) root.service.moveQueueItem(queueRow.modelData.queue_item_id, -1)
                      }
                      Button {
                        iconText: "󰅀"
                        tooltipText: "Move down"
                        foreground: root.bar.foreground
                        iconSize: Style.font.caption
                        horizontalPadding: Style.space(3)
                        verticalPadding: Style.space(2)
                        enabled: root.service && queueRow.index < root.service.queue.length - 1
                        opacity: enabled ? 1.0 : 0.3
                        onClicked: if (root.service) root.service.moveQueueItem(queueRow.modelData.queue_item_id, 1)
                      }
                      Button {
                        iconText: "󰘁"
                        tooltipText: "Move to end"
                        foreground: root.bar.foreground
                        iconSize: Style.font.caption
                        horizontalPadding: Style.space(3)
                        verticalPadding: Style.space(2)
                        enabled: root.service && queueRow.index < root.service.queue.length - 1
                        opacity: enabled ? 1.0 : 0.3
                        onClicked: if (root.service) root.service.moveQueueItemEnd(queueRow.modelData.queue_item_id)
                      }
                      Button {
                        iconText: "󰅖"
                        tooltipText: "Remove from queue"
                        foreground: root.bar.foreground
                        iconSize: Style.font.caption
                        horizontalPadding: Style.space(3)
                        verticalPadding: Style.space(2)
                        onClicked: if (root.service) root.service.deleteQueueItem(root.service.activePlayerId, queueRow.modelData.queue_item_id)
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
                  wrapMode: Text.WordWrap
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
                Flow {
                  width: parent.width
                  spacing: Style.space(4)
  
                  Repeater {
                    model: {
                      if (!root.service || !root.service.searchResults) return []
                      var r = root.service.searchResults
                      function n(k) { return r[k] ? r[k].length : 0 }
                      return [
                        { id: "all", label: "All", count: n("tracks") + n("albums") + n("artists") + n("playlists") + n("radio") + n("podcasts") + n("audiobooks") },
                        { id: "track", label: "Songs", count: n("tracks") },
                        { id: "album", label: "Albums", count: n("albums") },
                        { id: "artist", label: "Artists", count: n("artists") },
                        { id: "playlist", label: "Lists", count: n("playlists") },
                        { id: "radio", label: "Radio", count: n("radio") },
                        { id: "podcast", label: "Pods", count: n("podcasts") },
                        { id: "audiobook", label: "Books", count: n("audiobooks") }
                      ]
                    }
  
                    delegate: BorderSurface {
                      required property var modelData
                      readonly property bool active: root.searchFilter === modelData.id
                      width: chipRow.implicitWidth + Style.space(12)
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
                        id: chipRow
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
                    subtitle: (modelData.artist || "") + (modelData.album ? " — " + modelData.album : "")
                    type: MaApi.mediaTypeLabel(modelData.media_type || "track")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
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
                    subtitle: (modelData.artist || "") + (modelData.year ? " · " + modelData.year : "")
                    type: MaApi.mediaTypeLabel(modelData.media_type || "album")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
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
                    subtitle: modelData.owner || ""
                    type: MaApi.mediaTypeLabel(modelData.media_type || "playlist")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
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
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || "?"
                    subtitle: ""
                    type: MaApi.mediaTypeLabel(modelData.media_type || "artist")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }
  
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "artist")) ? root.service.searchResults.artists : []
                  delegate: artistRowDelegate
                }

                Component {
                  id: mediaRowDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || "?"
                    subtitle: (modelData.artist || "") + (modelData.total_episodes ? " · " + modelData.total_episodes + " episodes" : "")
                    type: MaApi.mediaTypeLabel(modelData.media_type || "")
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }

                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "radio")) ? root.service.searchResults.radio : []
                  delegate: mediaRowDelegate
                }
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "podcast")) ? root.service.searchResults.podcasts : []
                  delegate: mediaRowDelegate
                }
                Repeater {
                  model: (root.service && root.service.searchResults && (root.searchFilter === "all" || root.searchFilter === "audiobook")) ? root.service.searchResults.audiobooks : []
                  delegate: mediaRowDelegate
                }
  
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: {
                    if (!root.service) return ""
                    var r = root.service.searchResults
                    if (!r) return root.service.searchQuery ? "Searching…" : "Type a query and press Enter. Click plays, right-click plays next, middle-click adds to the queue."
                    var total = 0
                    for (var k in r) if (Array.isArray(r[k])) total += r[k].length
                    return total === 0 ? "No results." : ""
                  }
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
  
              // ------------------ Browse section
              Column {
                id: browseTab
                width: parent.width
                spacing: Style.space(6)
                visible: root.popupSection === "browse"

                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Button {
                    id: browseBackBtn
                    iconText: "󰁍"
                    tooltipText: "Back"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    enabled: root.service && root.service.browseStack.length > 0
                    opacity: enabled ? 1.0 : 0.4
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: { root.browseFilter = ""; browseFilterInput.text = ""; root.service.browseBack() }
                  }
                  Text {
                    width: parent.width - browseBackBtn.width - Style.space(6)
                    text: root.service ? (root.service.browseName || "Music Assistant") + (root.service.browseLoading ? "  …" : "") : ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideMiddle
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                TextField {
                  id: browseFilterInput
                  width: parent.width
                  visible: root.service && root.service.browseItems.length > 12
                  placeholderText: "Filter " + (root.service ? root.service.browseItems.length : 0) + " items…"
                  foreground: root.bar.foreground
                  onTextChanged: root.browseFilter = text
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { root.popupOpen = false; event.accepted = true }
                  }
                }

                Component {
                  id: browseDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    readonly property bool folder: modelData.media_type === "folder"
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: (folder ? "󰉋  " : "") + (modelData.name || "?")
                    subtitle: folder ? "" : (modelData.artist || "") + (modelData.album ? " — " + modelData.album : "")
                    showTypeBadge: !folder
                    type: MaApi.mediaTypeLabel(modelData.media_type || "")
                    source: folder ? "" : MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: {
                      if (!root.service) return
                      if (folder) { root.browseFilter = ""; browseFilterInput.text = ""; root.service.browseInto(modelData) }
                      else if (modelData.is_playable) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    }
                    onContextMenu: function(mouse) { if (root.service && !folder) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service && !folder) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }

                Repeater {
                  model: root.filteredBrowseItems()
                  delegate: browseDelegate
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: {
                    if (!root.service) return ""
                    if (root.service.browseLoading && root.service.browseItems.length === 0) return "Loading…"
                    var n = root.service.browseItems.length
                    if (n === 0) return "Nothing here."
                    var shown = root.filteredBrowseItems().length
                    return shown < n ? "Showing " + shown + " of " + n + ". Type to filter." : ""
                  }
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  visible: text !== ""
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
                    subtitle: (modelData.artist || "") + (modelData.album ? " — " + modelData.album : "") + (modelData.duration ? " · " + Math.floor(modelData.duration / 60) + " min" : "")
                    showTypeBadge: false
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    // Right-click removes the favorite; middle-click adds it to the queue.
                    onContextMenu: function(mouse) {
                      if (root.service) root.service.removeFavorite(modelData)
                    }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }
  
                Repeater {
                  model: root.service && root.service.favorites ? root.service.favorites[root.favFilter] || [] : []
                  delegate: favRowDelegate
                }
  
                Text {
                  visible: !root.service || !root.service.favorites || !(root.service.favorites[root.favFilter] || []).length
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.service ? "No " + root.favFilter + " favorites yet. Right-click a favorite to remove it; middle-click adds it to the queue." : "Loading…"
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
  
                readonly property bool drilled: root.service && root.service.drillItem !== null

                Component {
                  id: playlistDelegate
                  SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: modelData.name || "?"
                    subtitle: modelData.owner || MaApi.providerLabel(MaApi.providerDomain(modelData))
                    showTypeBadge: false
                    showSourceBadge: true
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    // Click opens the tracks; right-click adds the playing track
                    // to a library playlist; middle-click queues the playlist.
                    onClicked: if (root.service) root.service.openCollection(modelData)
                    onContextMenu: function(mouse) { if (root.service) root.service.addCurrentToPlaylist(modelData) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }

                Repeater {
                  model: root.service && !playlistsTab.drilled ? root.service.playlists : []
                  delegate: playlistDelegate
                }

                Text {
                  visible: !playlistsTab.drilled && (!root.service || !root.service.playlists || root.service.playlists.length === 0)
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.service ? "No playlists found." : "Loading…"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: !playlistsTab.drilled && root.service && root.service.playlists.length > 0
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Click opens a playlist. Right-click adds the playing track to it (library playlists). Middle-click queues it."
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // Drill-down: tracks of the opened playlist / album / artist.
                Row {
                  visible: playlistsTab.drilled
                  width: parent.width
                  spacing: Style.space(6)
                  Button {
                    id: drillBackBtn
                    iconText: "󰁍"
                    tooltipText: "Back"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: if (root.service) root.service.closeCollection()
                  }
                  Text {
                    width: parent.width - drillBackBtn.width - drillPlayBtn.width - Style.space(12)
                    text: root.service && root.service.drillItem ? root.service.drillItem.name + (root.service.drillLoading ? "  …" : "") : ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Button {
                    id: drillPlayBtn
                    text: "Play all"
                    foreground: root.bar.foreground
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: if (root.service && root.service.drillItem) root.service.playUri(root.service.activePlayerId, root.service.drillItem.uri)
                  }
                }

                Repeater {
                  model: root.service && playlistsTab.drilled ? root.service.drillItems : []
                  delegate: SearchResultRow {
                    required property var modelData
                    required property int index
                    bar: root.bar
                    imageUrl: modelData.image_url || ""
                    title: (modelData.track_number ? modelData.track_number + ". " : "") + (modelData.name || "?")
                    subtitle: (modelData.artist || "") + (modelData.album ? " — " + modelData.album : "")
                    showTypeBadge: false
                    source: MaApi.providerLabel(MaApi.providerDomain(modelData))
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }

                Text {
                  visible: playlistsTab.drilled && root.service && !root.service.drillLoading && root.service.drillItems.length === 0
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "No tracks."
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
                    subtitle: (modelData.artist ? modelData.artist + " · " : "") + MaApi.formatRelativeTime(modelData.last_played)
                    showTypeBadge: true
                    showSourceBadge: true
                    onClicked: if (root.service) root.service.playUri(root.service.activePlayerId, modelData.uri)
                    onContextMenu: function(mouse) { if (root.service) root.service.enqueue(modelData.uri, "next", modelData.name) }
                    onMiddleClicked: if (root.service) root.service.enqueue(modelData.uri, "add", modelData.name)
                  }
                }
  
                Repeater {
                  model: root.service ? root.service.recentItems : []
                  delegate: recentDelegate
                }
  
                Text {
                  visible: !root.service || !root.service.recentItems || root.service.recentItems.length === 0
                  width: parent.width
                  wrapMode: Text.WordWrap
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

