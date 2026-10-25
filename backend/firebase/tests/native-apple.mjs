// Invoke only inside the disposable demo Auth/Database emulator suite.
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {initializeTestEnvironment} from '@firebase/rules-unit-testing';

assert.equal(process.env.GCLOUD_PROJECT, 'demo-navi-friends');
const [binary, report] = process.argv.slice(2);
assert.ok(binary && report, 'Expected compiled native Apple probe and output report');
const env = await initializeTestEnvironment({projectId: 'demo-navi-friends', database: {
  host: '127.0.0.1', port: 9000, rules: await readFile(new URL('../database.rules.json', import.meta.url), 'utf8')
}});
try {
  await env.clearDatabase();
  let transcript = '';
  const child = spawn(binary, [], {stdio: ['ignore', 'pipe', 'pipe']});
  const collect = chunk => { transcript += chunk.toString(); process.stdout.write(chunk); };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  const timer = setTimeout(() => child.kill('SIGTERM'), 300_000);
  const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
  clearTimeout(timer);
  await writeFile(report + '.log', transcript);
  assert.equal(code, 0, transcript);
  const flags = ['native_apple_auth_cloned', 'native_apple_listener_revoked', 'native_apple_fresh_session_denied_old_peer',
    'native_apple_late_session_completion_closed', 'native_apple_failed_open_cleanup', 'native_apple_friend_actions',
    'native_apple_peer_snapshots', 'native_apple_gated_publication'];
  for (const flag of flags) assert.ok(transcript.includes(flag + '=true'), transcript);
  assert.ok(transcript.includes('NAVI_APPLE_NATIVE_SUCCESS proofs=8'), transcript);
  await writeFile(report, JSON.stringify({proofs: flags, passed: flags.length}, null, 2));
} finally {
  await env.cleanup();
}
