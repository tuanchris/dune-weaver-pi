import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "." as Components

// Touch-friendly HSV colour selector. A swatch button that opens a popup with
// a saturation/value field, a hue bar, and a preset row. Emits hex strings.
//
//   colorPicked   — live while dragging (use for cheap UI preview)
//   colorCommitted — on release (use for the network write to the table)
Item {
    id: root

    // Current colour shown on the closed swatch (drive this from backend state).
    property color selectedColor: "#ffffff"
    // Quick-pick swatches (send-hex values).
    property var presets: []

    signal colorPicked(string hex)
    signal colorCommitted(string hex)

    implicitWidth: 44
    implicitHeight: 44

    // -- working HSV state (seeded from selectedColor when the popup opens) --
    property real hue: 0        // 0..1
    property real sat: 1        // 0..1
    property real val: 1        // 0..1
    readonly property color displayColor: Qt.hsva(hue, sat, val, 1)

    function _toHex(c) {
        function h2(x) {
            var s = Math.round(x * 255).toString(16)
            return s.length < 2 ? "0" + s : s
        }
        return "#" + h2(c.r) + h2(c.g) + h2(c.b)
    }
    function _seed() {
        var c = root.selectedColor
        var h = c.hsvHue
        hue = h < 0 ? 0 : h        // achromatic colours report hue -1
        sat = c.hsvSaturation
        val = c.hsvValue
    }
    function _live() { root.colorPicked(_toHex(displayColor)) }
    function _commit() { root.colorCommitted(_toHex(displayColor)) }

    // Closed-state swatch button
    Rectangle {
        anchors.fill: parent
        radius: Components.ThemeManager.radiusSm
        color: root.selectedColor
        border.width: 2
        border.color: Qt.darker(root.selectedColor, 1.4)

        MouseArea {
            anchors.fill: parent
            onClicked: popup.open()
        }
    }

    Popup {
        id: popup
        parent: Overlay.overlay
        modal: true
        dim: true
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        width: 320
        padding: Components.ThemeManager.spaceLg

        // Centre in the window.
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)

        onOpened: root._seed()

        background: Rectangle {
            color: Components.ThemeManager.cardColor
            radius: Components.ThemeManager.radiusMd
            border.width: 1
            border.color: Components.ThemeManager.borderColor
        }

        contentItem: ColumnLayout {
            spacing: Components.ThemeManager.spaceMd

            // --- Saturation / Value field ---
            Rectangle {
                id: svField
                Layout.fillWidth: true
                Layout.preferredHeight: 180
                radius: Components.ThemeManager.radiusSm
                clip: true
                color: Qt.hsva(root.hue, 1, 1, 1)   // pure hue base

                // white -> transparent (left to right = saturation)
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#ffffffff" }
                        GradientStop { position: 1.0; color: "#00ffffff" }
                    }
                }
                // transparent -> black (top to bottom = value)
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: "#00000000" }
                        GradientStop { position: 1.0; color: "#ff000000" }
                    }
                }
                // thumb
                Rectangle {
                    width: 22; height: 22; radius: 11
                    color: "transparent"
                    border.width: 3
                    border.color: root.val > 0.5 ? "#000000" : "#ffffff"
                    x: root.sat * svField.width - width / 2
                    y: (1 - root.val) * svField.height - height / 2
                }
                MouseArea {
                    anchors.fill: parent
                    function apply(mx, my) {
                        root.sat = Math.max(0, Math.min(1, mx / width))
                        root.val = Math.max(0, Math.min(1, 1 - my / height))
                        root._live()
                    }
                    onPressed: (mouse) => apply(mouse.x, mouse.y)
                    onPositionChanged: (mouse) => apply(mouse.x, mouse.y)
                    onReleased: root._commit()
                }
            }

            // --- Hue bar ---
            Rectangle {
                id: hueBar
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                radius: height / 2
                clip: true
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.000; color: "#ff0000" }
                    GradientStop { position: 0.167; color: "#ffff00" }
                    GradientStop { position: 0.333; color: "#00ff00" }
                    GradientStop { position: 0.500; color: "#00ffff" }
                    GradientStop { position: 0.667; color: "#0000ff" }
                    GradientStop { position: 0.833; color: "#ff00ff" }
                    GradientStop { position: 1.000; color: "#ff0000" }
                }
                Rectangle {
                    width: 10; height: parent.height + 6; radius: 5
                    y: -3
                    color: "transparent"
                    border.width: 3
                    border.color: "#ffffff"
                    x: root.hue * (hueBar.width - width)
                }
                MouseArea {
                    anchors.fill: parent
                    function apply(mx) {
                        root.hue = Math.max(0, Math.min(1, mx / width))
                        root._live()
                    }
                    onPressed: (mouse) => apply(mouse.x)
                    onPositionChanged: (mouse) => apply(mouse.x)
                    onReleased: root._commit()
                }
            }

            // --- Presets ---
            GridLayout {
                Layout.fillWidth: true
                visible: root.presets.length > 0
                columns: 10
                rowSpacing: Components.ThemeManager.spaceSm
                columnSpacing: Components.ThemeManager.spaceSm
                Repeater {
                    model: root.presets
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        radius: 13
                        color: modelData
                        border.width: 1
                        border.color: Qt.darker(modelData, 1.3)
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                var c = Qt.color(modelData)
                                var h = c.hsvHue
                                root.hue = h < 0 ? 0 : h
                                root.sat = c.hsvSaturation
                                root.val = c.hsvValue
                                root._live()
                                root._commit()
                            }
                        }
                    }
                }
            }

            // --- Footer: preview swatch + hex + done ---
            RowLayout {
                Layout.fillWidth: true
                spacing: Components.ThemeManager.spaceMd

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: Components.ThemeManager.radiusSm
                    color: root.displayColor
                    border.width: 1
                    border.color: Components.ThemeManager.borderColor
                }
                Label {
                    Layout.fillWidth: true
                    text: root._toHex(root.displayColor).toUpperCase()
                    font.family: Components.ThemeManager.fontMedium
                    font.pixelSize: Components.ThemeManager.fontSizeBody
                    color: Components.ThemeManager.textPrimary
                }
                Rectangle {
                    id: doneBtn
                    Layout.preferredWidth: 84
                    Layout.preferredHeight: Components.ThemeManager.touchTarget
                    radius: Components.ThemeManager.radiusSm
                    color: doneArea.pressed ? Components.ThemeManager.accentPressed
                                            : Components.ThemeManager.accent

                    Label {
                        anchors.centerIn: parent
                        text: "Done"
                        font.family: Components.ThemeManager.fontMedium
                        font.pixelSize: Components.ThemeManager.fontSizeBody
                        color: Components.ThemeManager.onAccent
                    }
                    MouseArea {
                        id: doneArea
                        anchors.fill: parent
                        onClicked: popup.close()
                    }
                }
            }
        }
    }
}
