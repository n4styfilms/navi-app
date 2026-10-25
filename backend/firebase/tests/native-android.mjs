// Runs the production Java session code through real Android Firebase SDK clients.
// Invoke inside firebase emulators:exec; all identities and coordinates are synthetic.
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
import {initializeTestEnvironment} from '@firebase/rules-unit-testing';

const [apk, output] = process.argv.slice(2);
assert.ok(apk && output, 'Usage: node tests/native-android.mjs fixture.apk report.json');
const adb = process.env.NAVI_TEST_ADB;
assert.ok(adb, 'NAVI_TEST_ADB must name the installed Android SDK adb executable');
const serial = 'emulator-5554';
function run(args, timeout = 30_000) {
  const result = spawnSync(adb, ['-s', serial, ...args], {encoding: 'utf8', timeout});
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  return result.stdout;
}
assert.equal(run(['emu', 'avd', 'name']).replaceAll('\r', '').split('\n')[0], 'MINT_Phone',
  'Only the owned disposable test AVD may be used');
const env = await initializeTestEnvironment({
  projectId: 'demo-navi-friends',
  database: {host: '127.0.0.1', port: 9000,
    rules: await readFile(new URL('../database.rules.json', import.meta.url), 'utf8')}
});
let createdDatabaseReverse = false;
try {
  await env.clearDatabase();
  // The database emulator's handshake advertises 127.0.0.1:9000. Native
  // reconnection follows that cached address rather than the initial 10.0.2.2.
  // Bridge only this owned test AVD's database port back to host loopback.
  const existing = run(['reverse', '--list']).split(/\r?\n/)
    .map(row => row.trim().split(/\s+/)).find(parts => parts.at(-2) === 'tcp:9000');
  if (existing) assert.equal(existing.at(-1), 'tcp:9000', 'An unrelated ADB reverse already owns test port 9000');
  else {
    run(['reverse', 'tcp:9000', 'tcp:9000']);
    createdDatabaseReverse = true;
  }
  const path = resolve(apk);
  const sha256 = createHash('sha256').update(await readFile(path)).digest('hex');
  assert.match(run(['install', '-r', path], 90_000), /Success/);
  const transcript = run(['shell', 'am', 'instrument', '-w',
    'app.navi.friendstest/app.organicmaps.navi.friends.FriendsSessionInstrument'], 180_000);
  await writeFile(output + '.txt', transcript);
  const pid = transcript.match(/native_pid=(\d+)/)?.[1];
  if (pid) await writeFile(output + '.logcat.txt', run(['logcat', '-d', '--pid', pid], 30_000));
  const screenshot = transcript.match(/native_ui_screenshot=(\/storage\/emulated\/0\/Android\/data\/app\.navi\.friendstest\/files\/friends-sheet\.png)/)?.[1];
  if (screenshot) run(['pull', screenshot, output + '.png']);
  const flags = ['native_auth_cloned', 'native_listener_revoked',
    'native_fresh_session_denied_old_peer', 'native_late_session_completion_closed', 'native_friend_actions',
    'native_failed_open_cleanup', 'native_peer_snapshots', 'native_gated_publication',
    'native_persistent_pause_reconnect', 'native_app_runtime_location', 'native_friends_sheet', 'native_signout_server_revoked'];
  for (const flag of flags) assert.match(transcript, new RegExp(`${flag}=true`), transcript);
  assert.match(transcript, /INSTRUMENTATION_CODE: -1\s*$/, transcript);
  assert.doesNotMatch(transcript, /native_error=|cleanup_error=/);
  const report = {apk: path, sha256, serial, avd: 'MINT_Phone',
    package: 'app.navi.friendstest', databaseReverse: 'tcp:9000 -> host loopback tcp:9000', flags, passed: true};
  await writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
} finally {
  try { await env.cleanup(); }
  finally { if (createdDatabaseReverse) run(['reverse', '--remove', 'tcp:9000']); }
}
