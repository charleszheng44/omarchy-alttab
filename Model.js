// Pure model shared by QML and the regression checks.
function key(value) {
    return String(value || "").trim().replace(/\.desktop$/i, "").toLowerCase();
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
        groups[id].windows.push(window.address);
    }
    return apps;
}

function wrap(index, count) {
    return count > 0 ? ((index % count) + count) % count : 0;
}

function removeWindow(apps, selected, address) {
    const selectedId = apps[selected] ? apps[selected].id : "";
    const remaining = apps.map(app => ({
        id: app.id, name: app.name, icon: app.icon,
        windows: app.windows.filter(value => value !== address)
    })).filter(app => app.windows.length > 0);
    const found = remaining.findIndex(app => app.id === selectedId);
    return { apps: remaining, selected: found >= 0 ? found : Math.min(selected, Math.max(0, remaining.length - 1)) };
}
