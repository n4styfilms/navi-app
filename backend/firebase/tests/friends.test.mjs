import {after, before, beforeEach, test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {ref, set, get, update, remove, onValue, serverTimestamp, query, orderByChild, startAt} from 'firebase/database';

const DAY = 86_400_000;
let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-navi-friends',
    database: {host: '127.0.0.1', port: 9000,
      rules: await readFile(new URL('../database.rules.json', import.meta.url), 'utf8')}
  });
});
after(async () => { if (env) await env.cleanup(); });
beforeEach(async () => { await env.clearDatabase(); });
const db = (uid) => (uid ? env.authenticatedContext(uid) : env.unauthenticatedContext()).database();
const position = (extra = {}) => ({sequence: 1, latitude: 43.7295, longitude: 7.4208,
  accuracyMeters: 5, measuredAtMs: Date.now(), receivedAtMs: serverTimestamp(), ...extra});
const speed = (extra = {}) => ({sequence: 1, metersPerSecond: 8, measuredAtMs: Date.now(), ...extra});
const grant = (extra = {}) => ({position: true, speed: false, trips: false, ...extra});
const trip = (extra = {}) => ({startedAtMs: Date.now() - 60_000, endedAtMs: Date.now() - 1000,
  distanceMeters: 300, durationSeconds: 59, ...extra});
async function seed({consent = true, rights = grant(), oldTrip = false, staleSpeed = false} = {}) {
  await env.withSecurityRulesDisabled(async (context) => {
    await set(ref(context.database()), {
      friendConsent: {alice: {bob: true}, ...(consent ? {bob: {alice: true}} : {})},
      grants: {alice: {bob: rights}},
      profiles: {alice: {displayName: 'Alice'}},
      live: {alice: {position: position({receivedAtMs: Date.now()}),
        speed: speed({sequence: staleSpeed ? 0 : 1})}},
      tripIndex: {alice: {ride: trip(oldTrip ? {startedAtMs: Date.now() - 32 * DAY,
        endedAtMs: Date.now() - 31 * DAY} : {})}},
      tripChunks: {alice: {ride: {0: {createdAtMs: Date.now(), points: {
        0: {latitude: 43.7295, longitude: 7.4208, accuracyMeters: 5, measuredAtMs: Date.now() - 20_000}
      }}}}}
    });
  });
}

test('confirmed friend can read explicitly shared position', async () => {
  await seed();
  const value = await assertSucceeds(get(ref(db('bob'), 'live/alice/position')));
  assert.equal(value.val().latitude, 43.7295);
});
test('one-sided consent, stranger and anonymous position reads deny', async () => {
  await seed({consent: false});
  for (const uid of ['bob', 'eve', null]) await assertFails(get(ref(db(uid), 'live/alice/position')));
});
test('only owner can write location; owner can remove it', async () => {
  await assertSucceeds(set(ref(db('alice'), 'live/alice/position'), position()));
  await assertFails(set(ref(db('eve'), 'live/alice/position'), position({sequence: 2})));
  await assertSucceeds(remove(ref(db('alice'), 'live/alice/position')));
});
test('root, user catalog and entire live record reads deny', async () => {
  await seed({rights: grant({speed: true, trips: true})});
  for (const path of ['', 'live', 'live/alice', 'profiles', 'grants', 'friendConsent', 'tripIndex'])
    await assertFails(get(ref(db('bob'), path || undefined)));
});
test('position permission does not grant speed, trips or raw points', async () => {
  await seed();
  for (const path of ['live/alice/speed', 'tripIndex/alice/ride', 'tripChunks/alice/ride/0'])
    await assertFails(get(ref(db('bob'), path)));
});
test('speed requires both position and speed permission, and matching sequence', async () => {
  await seed({rights: grant({speed: true})});
  await assertSucceeds(get(ref(db('bob'), 'live/alice/speed')));
  await set(ref(db('alice'), 'grants/alice/bob'), grant({position: false, speed: true}));
  await assertFails(get(ref(db('bob'), 'live/alice/speed')));
  await seed({rights: grant({speed: true}), staleSpeed: true});
  await assertFails(get(ref(db('bob'), 'live/alice/speed')));
});
test('owner controls each complete boolean grant', async () => {
  await seed();
  await assertSucceeds(set(ref(db('alice'), 'grants/alice/bob'), grant({trips: true})));
  await assertFails(set(ref(db('bob'), 'grants/alice/bob'), grant({speed: true})));
  await assertFails(set(ref(db('alice'), 'grants/alice/bob'), {position: true}));
  await assertFails(set(ref(db('alice'), 'grants/alice/bob'), grant({speed: 'true'})));
  await assertFails(set(ref(db('alice'), 'grants/alice/bob'), {...grant(), admin: true}));
});
test('friendship consent can only be changed by its owner', async () => {
  await assertSucceeds(set(ref(db('alice'), 'friendConsent/alice/bob'), true));
  await assertFails(set(ref(db('bob'), 'friendConsent/alice/bob'), true));
  await assertFails(set(ref(db('alice'), 'friendConsent/alice/alice'), true));
  await assertFails(set(ref(db('alice'), 'friendConsent/alice/bob'), 'true'));
});
test('revoking a grant denies further direct reads', async () => {
  await seed();
  const reader = db('bob');
  await assertSucceeds(get(ref(reader, 'live/alice/position')));
  await update(ref(db('alice'), 'grants/alice/bob'), {position: false});
  await assertFails(get(ref(reader, 'live/alice/position')));
});
test('removing friendship cancels an existing location subscription', async () => {
  await seed();
  let unsubscribe;
  const canceled = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Listener did not lose permission after consent revocation')), 5000);
    let seen = false;
    unsubscribe = onValue(ref(db('bob'), 'live/alice/position'), () => {
      if (seen) return; seen = true;
      remove(ref(db('alice'), 'friendConsent/alice/bob')).catch(reject);
    }, (error) => {
      clearTimeout(timer);
      if (!seen) reject(new Error('Authorized subscription never delivered an initial position'));
      else resolve(error);
    });
  });
  try {assert.match((await canceled).code, /PERMISSION_DENIED/i);} finally {unsubscribe?.();}
});
test('position schema bounds, required fields and monotonic sequence are enforced', async () => {
  const owner = db('alice');
  for (const extra of [{latitude: 91}, {longitude: -181}, {accuracyMeters: -1},
    {latitude: '43.7'}, {bearingDegrees: 360}, {sequence: 1.5}, {sequence: -1},
    {measuredAtMs: Date.now() + DAY}, {receivedAtMs: 0}, {privateEmail: 'hidden@example.invalid'}])
    await assertFails(set(ref(owner, 'live/alice/position'), position(extra)));
  const missing = position(); delete missing.accuracyMeters;
  await assertFails(set(ref(owner, 'live/alice/position'), missing));
  await assertSucceeds(set(ref(owner, 'live/alice/position'), position()));
  await assertFails(set(ref(owner, 'live/alice/position'), position()));
  await assertSucceeds(set(ref(owner, 'live/alice/position'), position({sequence: 2})));
});
test('valid speed can omit unavailable meters per second; malformed speed denies', async () => {
  await seed(); const owner = db('alice');
  const unknown = speed(); delete unknown.metersPerSecond;
  await assertSucceeds(set(ref(owner, 'live/alice/speed'), unknown));
  for (const extra of [{metersPerSecond: -1}, {metersPerSecond: 'fast'}, {sequence: 0}, {extra: true}])
    await assertFails(set(ref(owner, 'live/alice/speed'), speed(extra)));
});
test('requests are addressed, authenticated and do not expose the inbox', async () => {
  const request = {createdAtMs: serverTimestamp()};
  await assertSucceeds(set(ref(db('alice'), 'requests/bob/alice'), request));
  await assertSucceeds(get(ref(db('bob'), 'requests/bob')));
  await assertFails(get(ref(db('eve'), 'requests/bob')));
  await assertFails(set(ref(db('eve'), 'requests/bob/alice'), request));
  await assertFails(set(ref(db(null), 'requests/bob/anonymous'), request));
  await assertSucceeds(remove(ref(db('bob'), 'requests/bob/alice')));
});
test('display name belongs to owner and is visible to confirmed friends only', async () => {
  await seed();
  await assertSucceeds(get(ref(db('bob'), 'profiles/alice')));
  await assertFails(get(ref(db('eve'), 'profiles/alice')));
  await assertSucceeds(set(ref(db('alice'), 'profiles/alice'), {displayName: 'New name'}));
  await assertFails(set(ref(db('bob'), 'profiles/alice'), {displayName: 'Changed by friend'}));
  await assertFails(set(ref(db('alice'), 'profiles/alice'), {displayName: 'x'.repeat(41)}));
  await assertFails(set(ref(db('alice'), 'profiles/alice'), {displayName: 'Alice', email: 'private@example.invalid'}));
});
test('trip permission gives active index and chunks; revocation denies both', async () => {
  await seed({rights: grant({trips: true})});
  for (const path of ['tripIndex/alice/ride', 'tripChunks/alice/ride/0'])
    await assertSucceeds(get(ref(db('bob'), path)));
  await update(ref(db('alice'), 'grants/alice/bob'), {trips: false});
  for (const path of ['tripIndex/alice/ride', 'tripChunks/alice/ride/0'])
    await assertFails(get(ref(db('bob'), path)));
});
test('expired trips and orphan chunks are unreadable even if cleanup has not run', async () => {
  await seed({rights: grant({trips: true}), oldTrip: true});
  for (const uid of ['alice', 'bob']) for (const path of ['tripIndex/alice/ride', 'tripChunks/alice/ride/0'])
    await assertFails(get(ref(db(uid), path)));
  await env.withSecurityRulesDisabled((context) => remove(ref(context.database(), 'tripIndex/alice/ride')));
  await assertFails(get(ref(db('bob'), 'tripChunks/alice/ride/0')));
});
test('trip lists require a server-enforced recent-time query', async () => {
  await seed({rights: grant({trips: true})});
  await assertFails(get(ref(db('bob'), 'tripIndex/alice')));
  await assertFails(get(query(ref(db('bob'), 'tripIndex/alice'), orderByChild('endedAtMs'), startAt(0.5))));
  // Emulator 4.11.2 mishandles integer query-bound comparisons. A fractional
  // millisecond is a valid numeric cursor on both the emulator and real RTDB.
  // Keep the cursor inside the 30-day interval and allow for small clock skew.
  const recent = query(ref(db('bob'), 'tripIndex/alice'), orderByChild('endedAtMs'), startAt(Date.now() - 30 * DAY + 60_000.5));
  const snapshot = await assertSucceeds(get(recent));
  assert.equal(snapshot.size, 1);
  assert.equal(snapshot.child('ride').exists(), true);
});
test('owner writes bounded trip chunks; stranger and extra or oversized points deny', async () => {
  const owner = db('alice');
  await assertSucceeds(set(ref(owner, 'tripIndex/alice/ride'), trip()));
  const chunk = {createdAtMs: serverTimestamp(), points: {
    0: {latitude: 43.7295, longitude: 7.4208, accuracyMeters: 5, measuredAtMs: Date.now() - 20_000}
  }};
  await assertSucceeds(set(ref(owner, 'tripChunks/alice/ride/0'), chunk));
  await assertFails(set(ref(db('eve'), 'tripChunks/alice/ride/0'), chunk));
  await assertFails(set(ref(owner, 'tripChunks/alice/ride/1'), {...chunk, points: {...chunk.points, 100: chunk.points[0]}}));
  await assertFails(set(ref(owner, 'tripChunks/alice/ride/1'), {...chunk, points: {0: {...chunk.points[0], latitude: -91}}}));
  await assertFails(set(ref(owner, 'tripIndex/alice/other'), trip({distanceMeters: -1})));
  await assertSucceeds(remove(ref(owner, 'tripChunks/alice/ride/0')));
  await assertSucceeds(remove(ref(owner, 'tripIndex/alice/ride')));
});
