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
try {
  await env.clearDatabase();
  const path = resolve(apk);
  const sha256 = createHash('sha256').update(await readFile(path)).digest('hex');
  assert.match(run(['install', '-r', path], 90_000), /Success/);
  const transcript = run(['shell', 'am', 'instrument', '-w',
    'app.navi.friendstest/app.organicmaps.navi.friends.FriendsSessionInstrument'], 180_000);
  await writeFile(output + '.txt', transcript);
  const flags = ['native_auth_cloned', 'native_listener_revoked',
    'native_fresh_session_denied_old_peer', 'native_late_session_completion_closed', 'native_friend_actions'];
  for (const flag of flags) assert.match(transcript, new RegExp(`${flag}=true`), transcript);
  assert.match(transcript, /INSTRUMENTATION_CODE: -1\s*$/, transcript);
  assert.doesNotMatch(transcript, /native_error=|cleanup_error=/);
  const report = {apk: path, sha256, serial, avd: 'MINT_Phone',
    package: 'app.navi.friendstest', flags, passed: true};
  await writeFile(output, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report));
} finally {
  await env.cleanup();
}
