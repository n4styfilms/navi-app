// Run inside the disposable demo Auth and Realtime Database emulators.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {setTimeout as sleep} from 'node:timers/promises';
import {initializeTestEnvironment} from '@firebase/rules-unit-testing';
import {initializeApp, deleteApp} from 'firebase/app';
import {getAuth, connectAuthEmulator, createUserWithEmailAndPassword, signOut} from 'firebase/auth';
import {getDatabase, connectDatabaseEmulator, ref, get, set, update, onValue, goOffline,
  serverTimestamp, query, orderByChild, startAt} from 'firebase/database';

const projectId = 'demo-navi-friends';
assert.equal(process.env.GCLOUD_PROJECT, projectId);
const ruleFixture = await initializeTestEnvironment({projectId, database: {
  host: '127.0.0.1', port: 9000,
  rules: await readFile(new URL('../database.rules.json', import.meta.url), 'utf8')
}});
const clients = [];
const listeners = [];
const report = {};
let live;
const bytes = (value) => Buffer.byteLength(JSON.stringify(value), 'utf8');
const runId = randomUUID();
const day = 86_400_000;

async function waitFor(check, message) {
  const deadline = Date.now() + 15_000;
  while (!check()) {
    if (Date.now() >= deadline) throw new Error(message);
    await sleep(25);
  }
}

async function createClient(index) {
  const app = initializeApp({apiKey: 'fake-api-key', projectId,
    databaseURL: `https://${projectId}.firebaseio.com`}, `navi-traffic-${index}`);
  const auth = getAuth(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', {disableWarnings: true});
  const db = getDatabase(app);
  connectDatabaseEmulator(db, '127.0.0.1', 9000);
  const client = {app, auth, db, sequence: 0};
  clients.push(client);
  const account = await createUserWithEmailAndPassword(auth, `${runId}-${index}@example.test`,
    'synthetic-traffic-fixture-password');
  client.uid = account.user.uid;
  client.index = index;
}

async function publishPosition(client, moving) {
  const uid = client.uid;
  const sequence = ++client.sequence;
  const measuredAtMs = Date.now();
  const sample = {sharingGeneration: 1, sequence, measuredAtMs};
  const payload = {
    [`live/${uid}/position`]: {...sample, latitude: 43.7295 + client.index * 0.001,
      longitude: 7.4208 + (moving ? sequence : 4) * 0.0004, accuracyMeters: 5, receivedAtMs: serverTimestamp()},
    [`live/${uid}/speed`]: {...sample, metersPerSecond: moving ? 12 : 0},
    [`liveControl/${uid}/publishedSequence`]: sequence,
  };
  await update(ref(client.db), payload);
  if (live) {
    live.writeBatches++;
    live.writtenValueBytes += bytes(payload);
  }
}

async function measureLive(label, moving, intervalMs, count) {
  const start = Date.now();
  live = {intervalMs, writeBatches: 0, readCallbacks: 0, writtenValueBytes: 0, readValueBytes: 0};
  for (let batch = 0; batch < count; batch++) {
    if (batch) await sleep(intervalMs);
    await Promise.all(clients.map((client) => publishPosition(client, moving)));
    await waitFor(() => live.readCallbacks >= (batch + 1) * 5 * 4 * 3, 'Missing live subscriber callbacks');
  }
  assert.equal(live.readCallbacks, count * 5 * 4 * 3);
  report[label] = {...live, elapsedMs: Date.now() - start};
  live = undefined;
}

try {
  for (let index = 0; index < 5; index++) await createClient(index);
  await assert.rejects(get(ref(clients[0].db, 'live')), /permission.denied/i);
  for (const client of clients) {
    const setup = {};
    for (const peer of clients.filter((other) => other !== client)) {
      setup[`friendConsent/${client.uid}/${peer.uid}`] = true;
      setup[`grants/${client.uid}/${peer.uid}`] = {position: true, speed: true, trips: true};
    }
    setup[`liveControl/${client.uid}`] = {enabled: true, generation: 1};
    await update(ref(client.db), setup);
  }
  // Speed listeners require a committed position and speed in the live generation.
  await Promise.all(clients.map((client) => publishPosition(client, false)));
  const initial = new Set();
  let listenerError;
  for (const client of clients) {
    for (const peer of clients.filter((other) => other !== client)) {
      for (const path of [`liveControl/${peer.uid}`, `live/${peer.uid}/position`, `live/${peer.uid}/speed`]) {
        listeners.push(onValue(ref(client.db, path), (snapshot) => {
          initial.add(client.uid + '/' + path);
          if (live && snapshot.exists()) {
            live.readCallbacks++;
            live.readValueBytes += bytes(snapshot.val());
          }
        }, (error) => { listenerError = error; }));
      }
    }
  }
  await waitFor(() => initial.size === 5 * 4 * 3 || listenerError, 'Live subscriptions did not initialise');
  assert.ifError(listenerError);
  // Publish at the foreground movement and stationary cadences from PresencePolicy.
  await sleep(5000);
  await measureLive('foregroundMoving', true, 5000, 3);
  await sleep(60_000);
  await measureLive('stationary', false, 60_000, 2);
  assert.ifError(listenerError);

  const startedAtMs = Date.now() - 60_000;
  const endedAtMs = Date.now() - 1000;
  const summary = {startedAtMs, endedAtMs, distanceMeters: 80, durationSeconds: 59};
  const geometry = {segment: 0, vertices: [{latE5: 4372950, lonE5: 742080}, {latE5: 4372990, lonE5: 742130}]};
  const sharedTrips = {writeBatches: 0, readRequests: 0, writtenValueBytes: 0, readValueBytes: 0};
  for (const owner of clients) {
    const paths = {
      [`tripIndex/${owner.uid}/traffic-trip`]: summary,
      [`tripSegments/${owner.uid}/traffic-trip/0`]: geometry,
    };
    await update(ref(owner.db), paths);
    sharedTrips.writeBatches++;
    sharedTrips.writtenValueBytes += bytes(paths);
    for (const peer of clients.filter((other) => other !== owner)) {
      const list = await get(query(ref(peer.db, `tripIndex/${owner.uid}`), orderByChild('endedAtMs'), startAt(Date.now() - day + 0.5)));
      const shape = await get(ref(peer.db, `tripSegments/${owner.uid}/traffic-trip`));
      assert.deepEqual(list.child('traffic-trip').val(), summary);
      assert.deepEqual(shape.child('0').val(), geometry);
      sharedTrips.readRequests += 2;
      sharedTrips.readValueBytes += bytes(list.val()) + bytes(shape.val());
    }
  }
  report.sharedTrips = sharedTrips;
} finally {
  listeners.forEach((unsubscribe) => unsubscribe());
  await Promise.all(clients.map(async ({app, auth, db}) => {
    goOffline(db);
    await signOut(auth);
    await deleteApp(app);
  }));
  await ruleFixture.cleanup();
}
const result = JSON.stringify({accounts: clients.length, scope: 'decoded JSON values', ...report}, null, 2);
await new Promise((resolve, reject) => process.stdout.write(result + '\n', error => error ? reject(error) : resolve()));
// The SDK may leave a transport timer scheduled after deleting its test clients.
process.exit(0);
