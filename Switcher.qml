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
    property var pendingActions: []
    property var apps: []
    property var closedWindows: ({})
    property var windowChanges: ({})
    property var selection: ({ app: 0, window: 0, picker: false })
    readonly property int selected: selection.app
    readonly property int selectedWindow: selection.window
    readonly property bool windowPicker: selection.picker
    readonly property var currentWindows: apps[selected] ? apps[selected].windows : []
    property var targetScreen: null
    property point lastPointer: Qt.point(NaN, NaN)

    function rememberPointer(area) {
        lastPointer = area.mapToGlobal(area.mouseX, area.mouseY);
    }

    function pointerMoved(area, mouse) {
        const position = area.mapToGlobal(mouse.x, mouse.y);
        const moved = Number.isFinite(lastPointer.x)
            && (position.x !== lastPointer.x || position.y !== lastPointer.y);
        lastPointer = position;
        return moved;
    }

    function cycle(direction) {
        navigate({ type: "app", step: direction });
    }

    function cycleWindow(direction) {
        navigate({ type: "window", step: direction });
    }

    function chooseApp(index) {
        if (index !== selected) navigate({ type: "selectApp", index: index });
    }

    function navigate(action) {
        if (opened) {
            if (loading) pendingActions = pendingActions.concat([action]);
            else selection = Model.navigate(apps, selection, action);
            return;
        }
        generation++;
        apps = [];
        selection = ({ app: 0, window: 0, picker: false });
        closedWindows = ({});
        windowChanges = ({});
        pendingActions = [action];
        lastPointer = Qt.point(NaN, NaN);
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
        const window = app && app.windows[selectedWindow];
        const address = window && window.address;
        cancel();
        // Window selection defaults to the app's newest surviving window.
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

    function revealWindow() {
        Qt.callLater(() => windowList.positionViewAtIndex(selectedWindow, ListView.Contain));
    }
    onSelectedWindowChanged: revealWindow()
    onWindowPickerChanged: {
        lastPointer = Qt.point(NaN, NaN);
        revealWindow();
    }
    onCurrentWindowsChanged: revealWindow()

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
                for (const address of Object.keys(root.windowChanges))
                    root.apps = Model.updateWindow(root.apps, address, root.windowChanges[address]);
                root.loading = false;
                if (root.apps.length === 0) { root.cancel(); return; }
                // Replay mixed app/window inputs in order, including very fast taps.
                for (const action of root.pendingActions)
                    root.selection = Model.navigate(root.apps, root.selection, action);
                root.pendingActions = [];
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
                else if (event.data === "zc-app-switcher:window-next") root.cycleWindow(1);
                else if (event.data === "zc-app-switcher:window-previous") root.cycleWindow(-1);
                else if (event.data === "zc-app-switcher:accept") root.accept();
                else if (event.data === "zc-app-switcher:cancel") root.cancel();
            } else if (event.name === "closewindow" && root.opened) {
                const address = "0x" + event.data.replace(/^0x/, "");
                root.closedWindows[address] = true;
                const updated = Model.removeWindow(root.apps, root.selection, address);
                root.apps = updated.apps;
                root.selection = updated.selection;
                if (!root.loading && root.apps.length === 0) root.cancel();
            } else if (root.opened && (event.name === "windowtitlev2" || event.name === "movewindowv2")) {
                const comma = event.data.indexOf(",");
                if (comma < 0) return;
                const address = "0x" + event.data.slice(0, comma).replace(/^0x/, "");
                const rest = event.data.slice(comma + 1);
                const changes = event.name === "windowtitlev2"
                    ? { title: Model.label(rest, "Untitled window") }
                    : { workspace: Model.label(rest.slice(rest.indexOf(",") + 1), "Unknown") };
                root.windowChanges[address] = Object.assign({}, root.windowChanges[address], changes);
                if (!root.loading) root.apps = Model.updateWindow(root.apps, address, changes);
            } else if ((event.name === "monitorremoved" || event.name === "lockscreen") && root.opened) {
                root.cancel();
            }
        }
    }

    IpcHandler {
        target: "zc-app-switcher"
        function next(): void { root.cycle(1); }
        function previous(): void { root.cycle(-1); }
        function nextWindow(): void { root.cycleWindow(1); }
        function previousWindow(): void { root.cycleWindow(-1); }
        function showWindows(): void { root.navigate({ type: "showWindows" }); }
        function accept(): void { root.accept(); }
        function cancel(): void { root.cancel(); }
        function state(): string {
            return JSON.stringify({ opened: root.opened, loading: root.loading,
                selected: root.selected, selectedWindow: root.selectedWindow,
                windowPicker: root.windowPicker, screen: root.targetScreen ? root.targetScreen.name : "",
                apps: root.apps });
        }
    }

    readonly property real maxWidth: Math.max(180, (targetScreen ? targetScreen.width : 1200) - 80)
    readonly property int iconSize: Math.max(40, Math.min(80,
        Math.floor((maxWidth - 40) / Math.max(1, apps.length)) - 20))
    readonly property int slotWidth: iconSize + 20
    readonly property real appStripWidth: Math.min(maxWidth, Math.max(1, apps.length) * slotWidth + 40)
    readonly property int windowRowHeight: 44
    readonly property int maxWindowRows: Math.max(1, Math.min(5,
        Math.floor(((targetScreen ? targetScreen.height : 800) - iconSize - 224) / windowRowHeight)))
    readonly property int windowListHeight: Math.min(currentWindows.length, maxWindowRows) * windowRowHeight

    PanelWindow {
        id: panel
        visible: root.opened
        screen: root.targetScreen
        implicitWidth: Math.min(root.maxWidth, Math.max(root.appStripWidth, root.windowPicker ? 420 : 0)) + 48
        implicitHeight: root.iconSize + 108 + (root.windowPicker ? root.windowListHeight + 36 : 0)
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
                else if (event.key === Qt.Key_Down) root.navigate({ type: "down" });
                else if (event.key === Qt.Key_Up) root.navigate({ type: "up" });
                else if (event.key === Qt.Key_QuoteLeft || event.key === Qt.Key_AsciiTilde)
                    root.cycleWindow((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
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
                anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 20 }
                width: root.appStripWidth - 40
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
                                // Compare global coordinates: resizing the panel is not pointer movement.
                                onEntered: root.rememberPointer(this)
                                onPositionChanged: mouse => {
                                    if (containsMouse && root.pointerMoved(this, mouse)) root.chooseApp(tile.index);
                                }
                                onClicked: { root.chooseApp(tile.index); root.accept(); }
                            }
                            Rectangle {
                                anchors { right: appIcon.right; top: appIcon.top; rightMargin: -3; topMargin: -3 }
                                width: Math.max(20, countLabel.implicitWidth + 10)
                                height: 20
                                radius: 10
                                color: "#68686d"
                                border { width: 1; color: "#90ffffff" }
                                visible: tile.modelData.windows.length > 1
                                Text {
                                    id: countLabel
                                    anchors.centerIn: parent
                                    text: tile.modelData.windows.length
                                    font { family: "UbuntuMono Nerd Font"; pixelSize: 12; bold: true }
                                    color: "#ffffff"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.chooseApp(tile.index);
                                        root.navigate({ type: "showWindows" });
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: divider
                anchors { left: parent.left; right: parent.right; top: strip.bottom; margins: 20; topMargin: 12 }
                height: 1
                color: "#28ffffff"
                visible: root.windowPicker
            }

            ListView {
                id: windowList
                anchors { left: parent.left; right: parent.right; top: divider.bottom; leftMargin: 12; rightMargin: 12; topMargin: 8 }
                height: root.windowListHeight
                visible: root.windowPicker
                model: root.currentWindows
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: root.selectedWindow
                delegate: Rectangle {
                    id: windowTile
                    required property var modelData
                    required property int index
                    width: windowList.width
                    height: root.windowRowHeight
                    radius: 8
                    color: root.selectedWindow === index ? "#30ffffff" : "transparent"
                    Text {
                        id: windowTitle
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 10; rightMargin: 10; topMargin: 5 }
                        text: windowTile.modelData.title
                        textFormat: Text.PlainText
                        font { family: "UbuntuMono Nerd Font"; pixelSize: 13 }
                        color: "#f5f5f7"
                        elide: Text.ElideRight
                    }
                    Text {
                        anchors { left: windowTitle.left; right: windowTitle.right; top: windowTitle.bottom; topMargin: 2 }
                        text: "Workspace " + windowTile.modelData.workspace
                        textFormat: Text.PlainText
                        font { family: "UbuntuMono Nerd Font"; pixelSize: 11 }
                        color: "#bcbcc3"
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.rememberPointer(this)
                        onPositionChanged: mouse => {
                            if (containsMouse && root.pointerMoved(this, mouse))
                                root.navigate({ type: "selectWindow", index: windowTile.index });
                        }
                        onClicked: {
                            root.navigate({ type: "selectWindow", index: windowTile.index });
                            root.accept();
                        }
                    }
                }
                Rectangle {
                    anchors.right: parent.right
                    width: 2
                    radius: 1
                    y: windowList.visibleArea.yPosition * windowList.height
                    height: windowList.visibleArea.heightRatio * windowList.height
                    color: "#70ffffff"
                    visible: windowList.contentHeight > windowList.height
                }
            }
        }
    }
}
