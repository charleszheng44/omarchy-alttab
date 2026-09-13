import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "Model.js" as Model

Item {
    id: root

    property bool opened: false
    property bool loading: false
    property bool acceptPending: false
    property int generation: 0
    property int pendingSteps: 0
    property var apps: []
    property var closedWindows: ({})
    property int selected: 0
    property var targetScreen: null

    function cycle(direction) {
        if (opened) {
            if (loading) pendingSteps += direction;
            else selected = Model.wrap(selected + direction, apps.length);
            return;
        }
        generation++;
        apps = [];
        selected = 0;
        closedWindows = ({});
        pendingSteps = direction;
        acceptPending = false;
        loading = true;
        const monitor = Hyprland.focusedMonitor;
        targetScreen = Quickshell.screens.find(s => monitor && s.name === monitor.name)
            || Quickshell.screens[0] || null;
        opened = true;
        if (!snapshot.running) startSnapshot();
    }

    function startSnapshot() {
        snapshot.generation = generation;
        snapshot.running = true;
    }

    function cancel() {
        opened = false;
        loading = false;
        acceptPending = false;
    }

    function accept() {
        if (!opened) return;
        if (loading) { acceptPending = true; return; }
        const app = apps[selected];
        const address = app && app.windows[0];
        cancel();
        // The selected app's newest surviving window, including other workspaces.
        if (address) Qt.callLater(() => Hyprland.dispatch(
            "hl.dsp.focus({window=" + JSON.stringify("address:" + address) + "})"));
    }

    function iconSource(icon) {
        if (icon.startsWith("/")) return "file://" + icon;
        return Quickshell.iconPath(icon, true)
            || Quickshell.iconPath("application-x-executable", true);
    }

    onSelectedChanged: Qt.callLater(() => {
        const left = selected * root.slotWidth;
        strip.contentX = Math.max(0, Math.min(left - (strip.width - root.slotWidth) / 2,
            strip.contentWidth - strip.width));
    })

    Process {
        id: snapshot
        property int generation: 0
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector { id: snapshotOutput }
        stderr: StdioCollector {}
        onExited: code => {
            if (!root.opened) return;
            if (generation !== root.generation) { root.startSnapshot(); return; }
            if (code !== 0) { console.warn("App switcher: cannot read windows"); root.cancel(); return; }
            try {
                root.apps = Model.buildApps(JSON.parse(snapshotOutput.text),
                    DesktopEntries.applications.values, root.closedWindows);
                root.loading = false;
                if (root.apps.length === 0) { root.cancel(); return; }
                root.selected = Model.wrap(root.pendingSteps, root.apps.length);
                if (root.acceptPending) root.accept();
            } catch (error) {
                console.warn("App switcher:", error);
                root.cancel();
            }
        }
    }

    // All initial key presses and releases share Hyprland's ordered event socket.
    // Even an Alt release before the window query finishes commits correctly.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "custom") {
                if (event.data === "zc-app-switcher:next") root.cycle(1);
                else if (event.data === "zc-app-switcher:previous") root.cycle(-1);
                else if (event.data === "zc-app-switcher:accept") root.accept();
                else if (event.data === "zc-app-switcher:cancel") root.cancel();
            } else if (event.name === "closewindow" && root.opened) {
                const address = "0x" + event.data.replace(/^0x/, "");
                root.closedWindows[address] = true;
                const updated = Model.removeWindow(root.apps, root.selected, address);
                root.apps = updated.apps;
                root.selected = updated.selected;
                if (!root.loading && root.apps.length === 0) root.cancel();
            } else if ((event.name === "monitorremoved" || event.name === "lockscreen") && root.opened) {
                root.cancel();
            }
        }
    }

    IpcHandler {
        target: "zc-app-switcher"
        function next(): void { root.cycle(1); }
        function previous(): void { root.cycle(-1); }
        function accept(): void { root.accept(); }
        function cancel(): void { root.cancel(); }
        function state(): string {
            return JSON.stringify({ opened: root.opened, loading: root.loading,
                selected: root.selected, screen: root.targetScreen ? root.targetScreen.name : "",
                apps: root.apps });
        }
    }

    readonly property real maxWidth: Math.max(180, (targetScreen ? targetScreen.width : 1200) - 80)
    readonly property int iconSize: Math.max(40, Math.min(80,
        Math.floor((maxWidth - 40) / Math.max(1, apps.length)) - 20))
    readonly property int slotWidth: iconSize + 20

    PanelWindow {
        id: panel
        visible: root.opened
        screen: root.targetScreen
        implicitWidth: Math.min(root.maxWidth, Math.max(1, root.apps.length) * root.slotWidth + 40) + 48
        implicitHeight: root.iconSize + 108
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "zc-app-switcher"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        mask: Region { item: card }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                    root.cycle((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1);
                else if (event.key === Qt.Key_Left) root.cycle(-1);
                else if (event.key === Qt.Key_Right) root.cycle(1);
                else if (event.key === Qt.Key_Escape) root.cancel();
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.accept();
                event.accepted = true;
            }
            // Hyprland's key listener is authoritative for modifier release;
            // Qt may report an unmapped key when Alt predates keyboard focus.
            Keys.onReleased: event => { event.accepted = true; }
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: panel.width - 48
            height: panel.height - 48
            visible: root.apps.length > 0
            radius: 20
            color: "#f036363a"
            border.width: 1
            border.color: "#45ffffff"
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: "#70000000"
                shadowBlur: 0.6
                shadowVerticalOffset: 8
                shadowHorizontalOffset: 0
            }

            Flickable {
                id: strip
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
                height: root.iconSize + 34
                contentWidth: appRow.width
                contentHeight: height
                clip: true
                interactive: contentWidth > width
                boundsBehavior: Flickable.StopAtBounds

                Row {
                    id: appRow
                    Repeater {
                        model: root.apps
                        delegate: Item {
                            id: tile
                            required property var modelData
                            required property int index
                            width: root.slotWidth
                            height: strip.height
                            Rectangle {
                                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top }
                                width: root.iconSize + 14
                                height: root.iconSize + 14
                                radius: 12
                                color: "#36ffffff"
                                visible: root.selected === tile.index
                            }
                            Image {
                                id: appIcon
                                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 7 }
                                width: root.iconSize
                                height: root.iconSize
                                source: root.iconSource(tile.modelData.icon)
                                sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                                asynchronous: false
                                onStatusChanged: if (status === Image.Error)
                                    source = Quickshell.iconPath("application-x-executable", true);
                            }
                            Text {
                                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                text: tile.modelData.name
                                textFormat: Text.PlainText
                                font.family: "UbuntuMono Nerd Font"
                                font.pixelSize: 13
                                color: "#f5f5f7"
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                visible: root.selected === tile.index
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                // Opening underneath the pointer must not change the selection.
                                onPositionChanged: if (containsMouse) root.selected = tile.index;
                                onClicked: { root.selected = tile.index; root.accept(); }
                            }
                        }
                    }
                }
            }
        }
    }
}
