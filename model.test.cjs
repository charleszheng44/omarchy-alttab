const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(__dirname + '/Model.js', 'utf8'), context);
const { buildApps, removeWindow, updateWindow, navigate, wrap } = context;
const plain = value => JSON.parse(JSON.stringify(value));
const addresses = app => app.windows.map(window => window.address);
const selection = (app = 0, window = 0, picker = false) => ({ app, window, picker });
const move = (apps, state, type, step = 1) => plain(navigate(apps, state, { type, step }));
const entries = [
  { id: 'google-chrome.desktop', startupClass: 'Google-chrome', name: 'Google Chrome', icon: 'google-chrome' },
  { id: 'foot', startupClass: 'foot', name: 'Foot', icon: 'foot' },
  { id: 'org.editor', startupClass: 'Code', name: 'Editor', icon: 'code' }
];
const window = (address, cls, rank, extra = {}) => ({
  address, class: cls, initialClass: cls, mapped: true, focusHistoryID: rank, ...extra
});
const clients = [
  window('0x10', 'google-chrome', 3, { title: 'Personal — Chrome', workspace: {id: 1} }),
  window('0x20', 'foot', 0),
  window('0x30', 'google-chrome', 1, { title: 'Project, notes — Chrome', workspace: {id: 5, name: 'Work'} }),
  window('0x40', 'Code', 2),
  window('0x50', 'org.editor', 4, { hidden: true }),
  window('0x60', 'gone', 0, { mapped: false })
];
const apps = plain(buildApps(clients, entries));
assert.deepEqual(apps.map(a => a.name), ['Foot', 'Google Chrome', 'Editor']);
assert.deepEqual(addresses(apps[1]), ['0x30', '0x10'], 'Choose the newest window across workspaces');
assert.deepEqual(addresses(apps[2]), ['0x40', '0x50'], 'Desktop ID and StartupWMClass identify the same app, including grouped hidden windows');
assert.deepEqual(apps[1].windows, [
  { address: '0x30', title: 'Project, notes — Chrome', workspace: 'Work' },
  { address: '0x10', title: 'Personal — Chrome', workspace: '1' }
], 'Each window keeps its own title and workspace');
assert.equal(wrap(1, apps.length), 1);
assert.equal(wrap(-1, apps.length), 2);
assert.equal(wrap(3, apps.length), 0);
assert.equal(wrap(1, 0), 0);
assert.equal(wrap(1, 1), 0);
assert.deepEqual(plain(buildApps([], entries)), []);
const removed = plain(removeWindow(apps, selection(1), '0x30'));
assert.equal(removed.apps[removed.selection.app].windows[0].address, '0x10', 'Fall back if the newest window closes');
const removedApp = plain(removeWindow(removed.apps, removed.selection, '0x10'));
assert.equal(removedApp.apps[removedApp.selection.app].name, 'Editor', 'Keep a valid selection if the whole app closes');
assert.equal(plain(removeWindow(apps, selection(2), '0x20')).selection.app, 1, 'Removing an earlier app preserves selection');
assert.equal(plain(buildApps(clients, entries, {'0x30': true}))[1].name, 'Editor', 'Exclude windows closed during the snapshot');
const odd = plain(buildApps([
  window('0x70', '__proto__', -1), window('0x80', 'Unknown', 0),
  window('invalid', 'bad', 0)
], []));
assert.deepEqual(odd.map(a => a.name), ['Unknown', '__proto__']);
assert.equal(plain(buildApps([window('0x90', 'dynamic', 0, {initialClass: 'foot'})], entries))[0].name, 'Foot');

let state = move(apps, selection(), 'app');
assert.deepEqual(state, selection(1));
state = move(apps, state, 'down');
assert.deepEqual(state, selection(1, 0, true), 'First Down opens the list at the recent window');
state = move(apps, state, 'down');
assert.deepEqual(state, selection(1, 1, true), 'Second Down selects the other Chrome window');
state = move(apps, state, 'down');
assert.deepEqual(state, selection(1, 0, true), 'Window navigation wraps');
state = move(apps, state, 'up');
assert.deepEqual(state, selection(1, 1, true), 'Up wraps backwards');
state = move(apps, state, 'app');
assert.deepEqual(state, selection(2), 'Changing apps closes the picker and resets window selection');
assert.deepEqual(move(apps, selection(1), 'window'), selection(1, 1, true), 'Backtick chooses the next window immediately');
assert.deepEqual(move(apps, selection(1), 'window', -1), selection(1, 1, true), 'Shift+backtick chooses the previous window');
assert.deepEqual(move(apps, selection(), 'window'), selection(0, 0, true), 'Single-window apps keep a valid selection');
assert.deepEqual(move([], selection(), 'window'), selection(), 'No windows is safe');
assert.deepEqual(move(apps, selection(1), 'up'), selection(1), 'Up outside the picker does not change selection');
assert.deepEqual(plain(navigate(apps, selection(), {type: 'selectApp', index: 1})), selection(1));
assert.deepEqual(plain(navigate(apps, selection(1), {type: 'selectWindow', index: 1})), selection(1, 1, true));

const ordered = [
  {type: 'app', step: 1}, {type: 'window', step: 1},
  {type: 'app', step: 1}, {type: 'down'}, {type: 'up'}
].reduce((state, action) => plain(navigate(apps, state, action)), selection());
assert.deepEqual(ordered, selection(2, 1, true), 'Queued mixed app/window actions preserve order');
const closedEarlier = plain(removeWindow(apps, selection(1, 1, true), '0x30'));
assert.deepEqual(closedEarlier.selection, selection(1, 0, true), 'Closing an earlier window preserves the chosen address');
assert.equal(closedEarlier.apps[1].windows[0].address, '0x10');
const closedSelected = plain(removeWindow(apps, selection(1, 1, true), '0x10'));
assert.deepEqual(closedSelected.selection, selection(1, 0, true), 'Closing the selected window picks a surviving window');
const closedLast = plain(removeWindow(closedSelected.apps, closedSelected.selection, '0x30'));
assert.deepEqual(closedLast.selection, selection(1), 'Closing the last window returns to app selection');
assert.equal(closedLast.apps[1].name, 'Editor');
assert.deepEqual(plain(removeWindow([apps[0]], selection(0, 0, true), '0x20')), {apps: [], selection: selection()});

const changed = plain(updateWindow(apps, '0x10', {title: 'New, title', workspace: '8'}));
assert.equal(changed[1].windows[1].title, 'New, title');
assert.equal(changed[1].windows[1].workspace, '8');
assert.deepEqual(addresses(changed[1]), addresses(apps[1]), 'Metadata changes preserve ordering');
assert.equal(apps[1].windows[1].title, 'Personal — Chrome', 'Metadata updates do not mutate the previous snapshot');
assert.equal(context.label('One\nTwo\tThree'), 'One Two Three');
assert.equal(apps[0].windows[0].title, 'Untitled window');
console.log('Model checks passed: grouping, recency, window metadata, app/window navigation, ordered input, closing windows, and fallbacks.');
