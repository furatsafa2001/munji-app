/**
 * MUNJI — account flow tests
 *
 * Runs against the emulator with the real deployed rules, so a profile
 * that these tests accept is one the live database would also accept.
 *
 *   npm run emu          (one terminal)
 *   npx jest             (another)
 */

const { initializeApp, deleteApp } = require('firebase/app');
const admin = require('firebase-admin');
const { getAuth, connectAuthEmulator, signOut } = require('firebase/auth');
const { getFirestore, connectFirestoreEmulator, doc, getDoc } = require('firebase/firestore');

const {
  signUp, signIn, repairProfile, getProfile, validate, AccountError
} = require('../src/accounts');

let app, auth, db;

const PATIENT = {
  email: 'test.patient@munji.co',
  password: 'Test1234!',
  fullName: 'Test Patient',
  phone: '+966512345678',
  locale: 'ar',
  role: 'patient'
};

const CAREGIVER = {
  email: 'test.caregiver@munji.co',
  password: 'Test1234!',
  fullName: 'Test Caregiver',
  phone: '+966512345679',
  locale: 'en',
  role: 'caregiver'
};

beforeAll(async () => {
  process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8080';
  process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9099';
  if (!admin.apps.length) admin.initializeApp({ projectId: 'munji-dev' });

  app = initializeApp({ projectId: 'munji-dev', apiKey: 'fake-api-key' }, 'accounts-test');
  auth = getAuth(app);
  db = getFirestore(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
  connectFirestoreEmulator(db, '127.0.0.1', 8080);
});

afterAll(async () => {
  if (app) await deleteApp(app);
  await Promise.all(admin.apps.map(a => a && a.delete()));
});

beforeEach(async () => {
  // the auth emulator exposes a wipe endpoint; keeps runs independent
  await fetch(
    'http://127.0.0.1:9099/emulator/v1/projects/munji-dev/accounts',
    { method: 'DELETE' }
  );
  await signOut(auth).catch(() => {});
});

// ------------------------------------------------------- local validation

test('rejects a local phone number', () => {
  expect(() => validate({ ...PATIENT, phone: '0512345678' }))
    .toThrow(/international format/);
});

test('rejects an unsupported role', () => {
  expect(() => validate({ ...PATIENT, role: 'doctor' }))
    .toThrow(/patient or caregiver/);
});

test('rejects an unsupported locale', () => {
  expect(() => validate({ ...PATIENT, locale: 'fr' })).toThrow(/ar or en/);
});

test('rejects a short password', () => {
  expect(() => validate({ ...PATIENT, password: 'abc' })).toThrow(/8 characters/);
});

test('accepts a valid patient', () => {
  expect(() => validate(PATIENT)).not.toThrow();
});

// -------------------------------------------------------------- sign-up

test('patient sign-up creates the account and the profile', async () => {
  const { uid } = await signUp(auth, db, PATIENT);
  const snap = await getDoc(doc(db, 'users', uid));

  expect(snap.exists()).toBe(true);
  const d = snap.data();
  expect(d.role).toBe('patient');
  expect(d.fullName).toBe('Test Patient');
  expect(d.phone).toBe('+966512345678');
  expect(d.disabled).toBe(false);
  expect(d.patient.emergencyNumber).toBe('911');
});

test('a new patient starts with no caregivers', async () => {
  const { uid } = await signUp(auth, db, PATIENT);
  const d = (await getDoc(doc(db, 'users', uid))).data();
  expect(d.patient.caregiverIds).toEqual([]);
});

test('caregiver sign-up creates the caregiver shape', async () => {
  const { uid } = await signUp(auth, db, CAREGIVER);
  const d = (await getDoc(doc(db, 'users', uid))).data();

  expect(d.role).toBe('caregiver');
  expect(d.caregiver.patientIds).toEqual([]);
  expect(d.patient).toBeUndefined();
});

test('sign-up is refused before the account is created when input is bad', async () => {
  await expect(signUp(auth, db, { ...PATIENT, phone: '0512345678' }))
    .rejects.toThrow(AccountError);
  expect(auth.currentUser).toBeNull();
});

test('the same email cannot be used twice', async () => {
  await signUp(auth, db, PATIENT);
  await signOut(auth);
  await expect(signUp(auth, db, PATIENT)).rejects.toThrow();
});

// -------------------------------------------------------------- sign-in

test('sign-in returns the profile', async () => {
  await signUp(auth, db, PATIENT);
  await signOut(auth);

  const { profile } = await signIn(auth, db, PATIENT.email, PATIENT.password);
  expect(profile.role).toBe('patient');
  expect(profile.fullName).toBe('Test Patient');
});

test('sign-in fails with a wrong password', async () => {
  await signUp(auth, db, PATIENT);
  await signOut(auth);
  await expect(signIn(auth, db, PATIENT.email, 'WrongPass1!')).rejects.toThrow();
});

// ------------------------------------------------------- profile repair

test('an account without a profile can be repaired', async () => {
  const { uid } = await signUp(auth, db, PATIENT);

  // Simulate the rollback itself failing: the Auth account survives but the
  // profile does not. The client cannot delete it — `allow delete: if false`
  // — so this uses the Admin SDK, which bypasses rules exactly as the real
  // rollback path does. The earlier REST attempt reported success without
  // deleting anything, which is why the assertion below now verifies it.
  await admin.firestore().doc(`users/${uid}`).delete();
  expect(await getProfile(db, uid)).toBeNull();

  await expect(signIn(auth, db, PATIENT.email, PATIENT.password))
    .rejects.toThrow(/no profile/);

  // signIn threw, but the credentials were accepted, so the user is signed
  // in and repairProfile can write the missing document
  await repairProfile(auth, db, PATIENT);

  const repaired = await getProfile(db, uid);
  expect(repaired).not.toBeNull();
  expect(repaired.role).toBe('patient');
  expect(repaired.patient.caregiverIds).toEqual([]);
});

test('repair refuses when a profile already exists', async () => {
  await signUp(auth, db, PATIENT);
  await expect(repairProfile(auth, db, PATIENT)).rejects.toThrow(/already exists/);
});