/**
 * MUNJI — Cloud Storage rules tests
 *
 *   npm run test:rules     (starts the firestore + storage emulators)
 *
 * Storage rules read caregiverIds from Firestore, so both emulators run and
 * the patient documents are seeded first.
 */

const fs = require('fs');
const { initializeTestEnvironment, assertFails, assertSucceeds } =
  require('@firebase/rules-unit-testing');
const { doc, setDoc } = require('firebase/firestore');
const { ref, uploadBytes, getBytes, deleteObject } = require('firebase/storage');

const BUCKET = 'munji-dev.firebasestorage.app';
const SAFA = 'uid_patient_safa';
const NORA = 'uid_caregiver_nora';
const STRANGER = 'uid_stranger';

const PATH = `patients/${SAFA}/recordings/rec_test_0001.ecg`;
const BYTES = new Uint8Array(15032);
const META = { contentType: 'application/octet-stream', customMetadata: { kind: 'manual' } };

let env;

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: 'munji-dev',
    firestore: { rules: fs.readFileSync('firestore.rules', 'utf8'), host: '127.0.0.1', port: 8080 },
    storage: { rules: fs.readFileSync('storage.rules', 'utf8'), host: '127.0.0.1', port: 9199 }
  });
});

afterAll(async () => { if (env) await env.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', SAFA), {
      role: 'patient', patient: { caregiverIds: [NORA] }
    });
    await uploadBytes(ref(ctx.storage(BUCKET), PATH), BYTES, META);
  });
});

const st = (uid) => env.authenticatedContext(uid).storage(BUCKET);
const newPath = (patient = SAFA) => `patients/${patient}/recordings/rec_new_0001.ecg`;

test('patient uploads a recording to their own folder', async () => {
  await assertSucceeds(uploadBytes(ref(st(SAFA), newPath()), BYTES, META));
});

test('patient cannot upload into another patient\'s folder', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), newPath('uid_patient_ahmed')), BYTES, META));
});

test('caregiver cannot upload for the patient', async () => {
  await assertFails(uploadBytes(ref(st(NORA), newPath()), BYTES, META));
});

test('upload without kind metadata is rejected', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), newPath()), BYTES,
    { contentType: 'application/octet-stream' }));
});

test('event strips are not open yet', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), newPath()), BYTES,
    { contentType: 'application/octet-stream', customMetadata: { kind: 'event' } }));
});

test('oversized upload is rejected', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), newPath()), new Uint8Array(40 * 1024), META));
});

test('wrong file name is rejected', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), `patients/${SAFA}/recordings/x.json`), BYTES, META));
});

test('an existing recording cannot be overwritten', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), PATH), BYTES, META));
});

test('patient and linked caregiver download, stranger cannot', async () => {
  await assertSucceeds(getBytes(ref(st(SAFA), PATH)));
  await assertSucceeds(getBytes(ref(st(NORA), PATH)));
  await assertFails(getBytes(ref(st(STRANGER), PATH)));
});

test('patient deletes their recording, caregiver cannot', async () => {
  await assertFails(deleteObject(ref(st(NORA), PATH)));
  await assertSucceeds(deleteObject(ref(st(SAFA), PATH)));
});

test('a revoked caregiver loses file access immediately', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', SAFA), { role: 'patient', patient: { caregiverIds: [] } });
  });
  await assertFails(getBytes(ref(st(NORA), PATH)));
});

test('anything outside patients/ is closed', async () => {
  await assertFails(uploadBytes(ref(st(SAFA), 'public/x.ecg'), BYTES, META));
});
