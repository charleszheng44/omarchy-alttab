// Pure model shared by QML and the regression checks.
function key(value) {
    return String(value || "").trim().replace(/\.desktop$/i, "").toLowerCase();
}

function label(value, fallback) {
    return String(value || fallback || "").replace(/[\r\n\t]/g, " ");
}

function workspaceLabel(workspace) {
    return workspace ? label(workspace.name || workspace.id, "Unknown") : "Unknown";
}

function buildApps(clients, entries, closed) {
    const ids = Object.create(null);
    const classes = Object.create(null);
    for (const entry of entries) {
        if (entry.id) ids[key(entry.id)] = entry;
        if (entry.startupClass && !classes[key(entry.startupClass)])
            classes[key(entry.startupClass)] = entry;
    }
    const windows = clients.filter(c => c.mapped !== false
        && /^0x[0-9a-f]+$/i.test(c.address || "") && !(closed || {})[c.address]);
    function rank(c) {
        return Number.isFinite(c.focusHistoryID) && c.focusHistoryID >= 0
            ? c.focusHistoryID : Number.MAX_SAFE_INTEGER;
    }
    windows.sort((a, b) => rank(a) - rank(b) || a.address.localeCompare(b.address));
    const apps = [];
    const groups = Object.create(null);
    for (const window of windows) {
        const current = key(window.class);
        const initial = key(window.initialClass);
        const entry = ids[current] || classes[current] || ids[initial] || classes[initial];
        const id = entry ? key(entry.id) : (current || initial || window.address);
        if (!groups[id]) {
            groups[id] = {
                id: id,
                name: entry ? String(entry.name || window.class) : String(window.class || window.initialClass || "Application"),
                icon: entry ? String(entry.icon || "") : String(window.class || window.initialClass || ""),
                windows: []
            };
            apps.push(groups[id]);
        }
        groups[id].windows.push({
            address: window.address,
            title: label(window.title, "Untitled window"),
            workspace: workspaceLabel(window.workspace)
        });
    }
    return apps;
}

function wrap(index, count) {
    return count > 0 ? ((index % count) + count) % count : 0;
}

function navigate(apps, selection, action) {
    const next = Object.assign({}, selection);
    if (!apps.length) return { app: 0, window: 0, picker: false };
    if (action.type === "app" || action.type === "selectApp") {
        next.app = wrap(action.type === "app" ? next.app + action.step : action.index, apps.length);
        next.window = 0;
        next.picker = false;
    } else {
        const count = apps[next.app].windows.length;
        if (action.type === "window" || (action.type === "down" && next.picker)
                || (action.type === "up" && next.picker)) {
            const step = action.type === "down" ? 1 : action.type === "up" ? -1 : action.step;
            next.window = wrap(next.window + step, count);
            next.picker = true;
        } else if (action.type === "down" || action.type === "showWindows") {
            next.picker = true;
        } else if (action.type === "selectWindow") {
            next.window = wrap(action.index, count);
            next.picker = true;
        }
    }
    return next;
}

function updateWindow(apps, address, changes) {
    return apps.map(app => Object.assign({}, app, { windows: app.windows.map(window =>
        window.address === address ? Object.assign({}, window, changes) : window) }));
}

function removeWindow(apps, selection, address) {
    const selectedApp = apps[selection.app];
    const selectedWindow = selectedApp && selectedApp.windows[selection.window];
    const remaining = apps.map(app => Object.assign({}, app, {
        windows: app.windows.filter(window => window.address !== address)
    })).filter(app => app.windows.length > 0);
    const found = remaining.findIndex(app => selectedApp && app.id === selectedApp.id);
    const app = found >= 0 ? found : Math.min(selection.app, Math.max(0, remaining.length - 1));
    const windows = remaining[app] ? remaining[app].windows : [];
    const windowFound = windows.findIndex(window => selectedWindow && window.address === selectedWindow.address);
    const window = found < 0 ? 0 : windowFound >= 0 ? windowFound : Math.min(selection.window, Math.max(0, windows.length - 1));
    return { apps: remaining, selection: { app, window, picker: found >= 0 && selection.picker } };
}
