const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(__dirname + '/Model.js', 'utf8'), context);
const { buildApps, removeWindow, wrap } = context;
const plain = value => JSON.parse(JSON.stringify(value));
const entries = [
  { id: 'google-chrome.desktop', startupClass: 'Google-chrome', name: 'Google Chrome', icon: 'google-chrome' },
  { id: 'foot', startupClass: 'foot', name: 'Foot', icon: 'foot' },
  { id: 'org.editor', startupClass: 'Code', name: 'Editor', icon: 'code' }
];
const window = (address, cls, rank, extra = {}) => ({
  address, class: cls, initialClass: cls, mapped: true, focusHistoryID: rank, ...extra
});
const clients = [
  window('0x10', 'google-chrome', 3, { workspace: {id: 1} }),
  window('0x20', 'foot', 0),
  window('0x30', 'google-chrome', 1, { workspace: {id: 5} }),
  window('0x40', 'Code', 2),
  window('0x50', 'org.editor', 4, { hidden: true }),
  window('0x60', 'gone', 0, { mapped: false })
];
const apps = plain(buildApps(clients, entries));
assert.deepEqual(apps.map(a => a.name), ['Foot', 'Google Chrome', 'Editor']);
assert.deepEqual(apps[1].windows, ['0x30', '0x10'], 'Choose the newest window across workspaces');
assert.deepEqual(apps[2].windows, ['0x40', '0x50'], 'Desktop ID and StartupWMClass identify the same app, including grouped hidden windows');
assert.equal(wrap(1, apps.length), 1);
assert.equal(wrap(-1, apps.length), 2);
assert.equal(wrap(3, apps.length), 0);
assert.equal(wrap(1, 0), 0);
assert.equal(wrap(1, 1), 0);
assert.deepEqual(plain(buildApps([], entries)), []);
const removed = plain(removeWindow(apps, 1, '0x30'));
assert.equal(removed.apps[removed.selected].windows[0], '0x10', 'Fall back if the newest window closes');
const removedApp = plain(removeWindow(removed.apps, removed.selected, '0x10'));
assert.equal(removedApp.apps[removedApp.selected].name, 'Editor', 'Keep a valid selection if the whole app closes');
assert.equal(plain(removeWindow(apps, 2, '0x20')).selected, 1, 'Removing an earlier app preserves selection');
assert.equal(plain(buildApps(clients, entries, {'0x30': true}))[1].name, 'Editor', 'Exclude windows closed during the snapshot');
const odd = plain(buildApps([
  window('0x70', '__proto__', -1), window('0x80', 'Unknown', 0),
  window('invalid', 'bad', 0)
], []));
assert.deepEqual(odd.map(a => a.name), ['Unknown', '__proto__']);
assert.equal(plain(buildApps([window('0x90', 'dynamic', 0, {initialClass: 'foot'})], entries))[0].name, 'Foot');
console.log('Model checks passed: grouping, recency, desktop identity, closing windows, empty/single app, wraparound, and unknown apps.');
