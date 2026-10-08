import QtQuick
import QtQuick.Controls
import qs.Commons

// Scrollbar drawn with the shell's theme tokens. The stock Qt ScrollBar paints
// a flat gray track from the Qt palette, which ignores the Omarchy theme and,
// with AlwaysOn, stayed on screen even when nothing could scroll. This one is
// a thin pill in the popup's foreground colour that only appears while the
// content actually overflows, brightens on hover and turns accent while
// dragged.
ScrollBar {
  id: control

  property QtObject bar: null
  readonly property color baseColor: bar ? bar.foreground : Color.popups.text
  readonly property bool overflowing: size < 1.0

  policy: ScrollBar.AsNeeded
  visible: overflowing
  hoverEnabled: true
  minimumSize: 0.08
  padding: 0
  leftPadding: Style.space(2)
  rightPadding: Style.space(2)
  implicitWidth: Style.space(4) + leftPadding + rightPadding

  background: null

  contentItem: Rectangle {
    implicitWidth: Style.space(4)
    radius: width / 2
    color: control.pressed
      ? Color.accent
      : Util.alpha(control.baseColor, control.hovered ? 0.55 : 0.28)
    Behavior on color { ColorAnimation { duration: 140 } }
  }
}
