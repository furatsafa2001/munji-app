/**
 * Linking against the Firestore emulator.
 *
 *   cd munji-backend2
 *   npm run test:links
 *
 * which wraps this file in `firebase emulators:exec --only firestore`.
 */
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'munji-dev';
if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error('Run through `npm run test:links` so the emulator is up.');
}

const admin = require('firebase-admin');
if (!admin.apps.length) admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT });
const db = admin.firestore();
const { Timestamp, FieldValue } = admin.firestore;
const deps = { Timestamp, FieldValue };

const links = require('../src/links');

const P = 'p_patient';
const P2 = 'p_patient2';
const C = 'c_caregiver';
const C2 = 'c_caregiver2';
const T0 = Date.UTC(2026, 9, 12, 9, 0, 0);

async function wipe() {
  for (const col of ['users', 'linkCodes', 'linkAttempts', 'careLinks', 'auditLog']) {
    const snap = await db.collection(col).get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
  }
}

async function seedUsers() {
  await db.doc(`users/${P}`).set({
    role: 'patient', fullName: 'Safa Khan', disabled: false,
    patient: { caregiverIds: [], emergencyNumber: '911' }
  });
  await db.doc(`users/${P2}`).set({
    role: 'patient', fullName: 'Ahmed Khan', disabled: false,
    patient: { caregiverIds: [], emergencyNumber: '911' }
  });
  await db.doc(`users/${C}`).set({
    role: 'caregiver', fullName: 'Nora Khan', disabled: false,
    caregiver: { patientIds: [] }
  });
  await db.doc(`users/${C2}`).set({
    role: 'caregiver', fullName: 'Omar Khan', disabled: false,
    caregiver: { patientIds: [] }
  });
}

const code = (code) => ({ code });

beforeEach(async () => {
  await wipe();
  await seedUsers();
});

afterAll(async () => {
  await wipe();
  await admin.app().delete();
});

async function expectError(promise, httpsCode, message) {
  await expect(promise).rejects.toMatchObject({ code: httpsCode, message });
}

// ── generate ──

test('a patient gets a six-digit code valid for 10 minutes', async () => {
  const out = await links.generateCode(db, P, T0, Timestamp);
  expect(out.code).toMatch(/^\d{6}$/);
  expect(out.expiresAt).toBe(T0 + 10 * 60 * 1000);
  const d = (await db.doc(`linkCodes/${out.code}`).get()).data();
  expect(d.patientId).toBe(P);
  expect(d.used).toBe(false);
});

test('a caregiver cannot generate a code', async () => {
  await expectError(links.generateCode(db, C, T0, Timestamp), 'failed-precondition', 'not-patient');
});

test('a new code retires the previous one', async () => {
  const first = await links.generateCode(db, P, T0, Timestamp);
  const second = await links.generateCode(db, P, T0 + 1000, Timestamp);
  expect(second.code).not.toBe(first.code);
  const old = (await db.doc(`linkCodes/${first.code}`).get()).data();
  expect(old.used).toBe(true);
  await expectError(links.redeemCode(db, C, code(first.code), T0 + 2000, deps), 'not-found', 'invalid-code');
});

// ── redeem ──

test('redeeming links both sides and writes the audit log', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  const out = await links.redeemCode(db, C, { code: c, relation: 'daughter' }, T0 + 60000, deps);
  expect(out).toEqual({ patientId: P, patientName: 'Safa Khan' });

  const link = (await db.doc(`careLinks/${P}_${C}`).get()).data();
  expect(link).toMatchObject({
    patientId: P, caregiverId: C, patientName: 'Safa Khan', caregiverName: 'Nora Khan',
    relation: 'daughter', status: 'active', priority: 1
  });
  expect((await db.doc(`users/${P}`).get()).data().patient.caregiverIds).toEqual([C]);
  expect((await db.doc(`users/${C}`).get()).data().caregiver.patientIds).toEqual([P]);
  expect((await db.doc(`linkCodes/${c}`).get()).data().used).toBe(true);

  const audit = await db.collection('auditLog').where('action', '==', 'link_created').get();
  expect(audit.size).toBe(1);
});

test('the second caregiver is priority 2', async () => {
  const a = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(a.code), T0 + 1000, deps);
  const b = await links.generateCode(db, P, T0 + 2000, Timestamp);
  await links.redeemCode(db, C2, code(b.code), T0 + 3000, deps);
  expect((await db.doc(`careLinks/${P}_${C2}`).get()).data().priority).toBe(2);
});

test('a code works once', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(c), T0 + 1000, deps);
  await expectError(links.redeemCode(db, C2, code(c), T0 + 2000, deps), 'not-found', 'invalid-code');
});

test('an expired code is refused', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await expectError(
    links.redeemCode(db, C, code(c), T0 + 10 * 60 * 1000 + 1, deps), 'not-found', 'invalid-code');
});

test('a patient cannot redeem', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await expectError(links.redeemCode(db, P2, code(c), T0 + 1000, deps), 'failed-precondition', 'not-caregiver');
});

test('linking the same pair twice is refused and the code stays usable', async () => {
  const a = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(a.code), T0 + 1000, deps);
  const b = await links.generateCode(db, P, T0 + 2000, Timestamp);
  await expectError(links.redeemCode(db, C, code(b.code), T0 + 3000, deps), 'already-exists', 'already-linked');
  expect((await db.doc(`linkCodes/${b.code}`).get()).data().used).toBe(false);
});

test('badly shaped codes are refused before any lookup', async () => {
  await expectError(links.redeemCode(db, C, code('12ab56'), T0, deps), 'invalid-argument', 'bad-code');
});

test('five wrong codes lock the caregiver out for 15 minutes', async () => {
  for (let i = 0; i < 5; i++) {
    await expectError(links.redeemCode(db, C, code('000000'), T0 + i, deps), 'not-found', 'invalid-code');
  }
  const { code: c } = await links.generateCode(db, P, T0 + 10, Timestamp);
  // even the right code is refused while locked
  await expectError(links.redeemCode(db, C, code(c), T0 + 20, deps), 'resource-exhausted', 'too-many-attempts');
  // and allowed again after the window
  const later = T0 + 15 * 60 * 1000 + 30;
  const fresh = await links.generateCode(db, P, later, Timestamp);
  await links.redeemCode(db, C, code(fresh.code), later + 1, deps);
  expect((await db.doc(`linkAttempts/${C}`).get()).exists).toBe(false);
});

test('a patient can have at most five caregivers', async () => {
  const ids = ['c1', 'c2', 'c3', 'c4', 'c5'];
  await db.doc(`users/${P}`).update({ 'patient.caregiverIds': ids });
  await expectError(links.generateCode(db, P, T0, Timestamp), 'failed-precondition', 'too-many-caregivers');
});

// ── revoke ──

test('the patient can end a link', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(c), T0 + 1000, deps);
  await links.revokeLink(db, P, { patientId: P, caregiverId: C }, T0 + 2000, deps);

  const link = (await db.doc(`careLinks/${P}_${C}`).get()).data();
  expect(link.status).toBe('revoked');
  expect(link.revokedBy).toBe(P);
  expect((await db.doc(`users/${P}`).get()).data().patient.caregiverIds).toEqual([]);
  expect((await db.doc(`users/${C}`).get()).data().caregiver.patientIds).toEqual([]);
});

test('the caregiver can end a link too', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(c), T0 + 1000, deps);
  await links.revokeLink(db, C, { patientId: P, caregiverId: C }, T0 + 2000, deps);
  expect((await db.doc(`careLinks/${P}_${C}`).get()).data().status).toBe('revoked');
});

test('someone outside the link cannot end it', async () => {
  const { code: c } = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(c), T0 + 1000, deps);
  await expectError(
    links.revokeLink(db, C2, { patientId: P, caregiverId: C }, T0 + 2000, deps),
    'permission-denied', 'not-a-party');
});

test('a revoked pair can link again with a new code', async () => {
  const a = await links.generateCode(db, P, T0, Timestamp);
  await links.redeemCode(db, C, code(a.code), T0 + 1000, deps);
  await links.revokeLink(db, P, { patientId: P, caregiverId: C }, T0 + 2000, deps);
  const b = await links.generateCode(db, P, T0 + 3000, Timestamp);
  await links.redeemCode(db, C, code(b.code), T0 + 4000, deps);
  const link = (await db.doc(`careLinks/${P}_${C}`).get()).data();
  expect(link.status).toBe('active');
  expect(link.revokedAt).toBeNull();
});
