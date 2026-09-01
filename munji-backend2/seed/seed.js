/**
 * MUNJI — emulator seed data
 *
 *   firebase emulators:start
 *   node seed/seed.js
 *
 * Uses the Admin SDK, so it bypasses security rules on purpose — this is
 * how the backend itself writes. Never point this at a real project.
 */

const admin = require('firebase-admin');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  process.env.FIRESTORE_EMULATOR_HOST = 'localhost:8080';
}
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  process.env.FIREBASE_AUTH_EMULATOR_HOST = 'localhost:9099';
}

admin.initializeApp({ projectId: 'munji-dev' });
const db = admin.firestore();
const auth = admin.auth();
const now = admin.firestore.Timestamp.now;

const SAFA = 'uid_patient_safa';
const AHMED = 'uid_patient_ahmed';
const NORA = 'uid_caregiver_nora';

async function ensureUser(uid, email, name) {
  try {
    await auth.getUser(uid);
  } catch (e) {
    await auth.createUser({ uid, email, password: 'Test1234!', displayName: name });
  }
}

async function main() {
  await ensureUser(SAFA, 'safa.khan@email.com', 'Safa Khan');
  await ensureUser(AHMED, 'ahmed.khan@email.com', 'Ahmed Khan');
  await ensureUser(NORA, 'nora.khan@email.com', 'Nora Khan');

  const batch = db.batch();

  // ------------------------------------------------------------- users
  batch.set(db.doc(`users/${SAFA}`), {
    role: 'patient',
    fullName: 'Safa Khan',
    phone: '+966567290751',
    email: 'safa.khan@email.com',
    locale: 'ar',
    fcmTokens: [],
    createdAt: now(),
    disabled: false,
    patient: {
      dob: admin.firestore.Timestamp.fromDate(new Date('1958-04-12')),
      sex: 'female',
      knownConditions: ['hypertension'],
      emergencyNumber: '911',
      caregiverIds: [NORA],
      activeDeviceId: SAFA
    }
  });

  batch.set(db.doc(`users/${AHMED}`), {
    role: 'patient',
    fullName: 'Ahmed Khan',
    phone: '+966551234500',
    email: 'ahmed.khan@email.com',
    locale: 'ar',
    fcmTokens: [],
    createdAt: now(),
    disabled: false,
    patient: {
      dob: admin.firestore.Timestamp.fromDate(new Date('1952-09-03')),
      sex: 'male',
      knownConditions: [],
      emergencyNumber: '911',
      caregiverIds: [NORA],
      activeDeviceId: AHMED
    }
  });

  batch.set(db.doc(`users/${NORA}`), {
    role: 'caregiver',
    fullName: 'Nora Khan',
    phone: '+966551234567',
    email: 'nora.khan@email.com',
    locale: 'ar',
    fcmTokens: [],
    createdAt: now(),
    disabled: false,
    caregiver: { patientIds: [SAFA, AHMED] }
  });

  // ----------------------------------------------------------- devices
  batch.set(db.doc(`devices/${SAFA}`), {
    patientId: SAFA, serial: 'MJ-4F2A', model: 'munji-v1', firmware: '0.1.0',
    pairedAt: now(), status: 'paired', battery: 85,
    signalQuality: 'good', lastSeenAt: now()
  });
  batch.set(db.doc(`devices/${AHMED}`), {
    patientId: AHMED, serial: 'MJ-7B11', model: 'munji-v1', firmware: '0.1.0',
    pairedAt: now(), status: 'paired', battery: 64,
    signalQuality: 'good', lastSeenAt: now()
  });

  // --------------------------------------------------------- careLinks
  // id = {patientId}_{caregiverId} so rules can look it up without a query
  batch.set(db.doc(`careLinks/${SAFA}_${NORA}`), {
    patientId: SAFA, caregiverId: NORA, relation: 'daughter',
    status: 'active', priority: 1,
    createdAt: now(), activatedAt: now()
  });
  batch.set(db.doc(`careLinks/${AHMED}_${NORA}`), {
    patientId: AHMED, caregiverId: NORA, relation: 'daughter',
    status: 'active', priority: 1,
    createdAt: now(), activatedAt: now()
  });

  // --------------------------------------------------------- linkCodes
  // one live code so the mobile team can test redemption before the
  // callable function exists (week 2)
  batch.set(db.doc('linkCodes/482913'), {
    patientId: SAFA,
    createdAt: now(),
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 15 * 60 * 1000),
    used: false,
    attempts: 0
  });

  // --------------------------------------------------------- medAlarms
  // document id is {patientUid}_{medKey} — two people adding the same
  // medicine collide on the same id instead of creating a double dose
  const alarms = [
    { key: 'aspirin100mg',      name: 'Aspirin 100 mg',      time: '08:00', by: SAFA, role: 'patient' },
    { key: 'bisoprolol5mg',     name: 'Bisoprolol 5 mg',     time: '13:00', by: SAFA, role: 'patient' },
    { key: 'atorvastatin20mg',  name: 'Atorvastatin 20 mg',  time: '20:00', by: NORA, role: 'caregiver' }
  ];
  alarms.forEach(a => {
    batch.set(db.doc(`medAlarms/${SAFA}_${a.key}`), {
      patientId: SAFA, medKey: a.key, medName: a.name, dose: '1 tablet',
      timeLocal: a.time, repeatDays: [0, 1, 2, 3, 4, 5, 6],
      enabled: true, createdBy: a.by, createdByRole: a.role,
      updatedAt: now(), updatedBy: a.by
    });
  });

  // -------------------------------------------------------- recordings
  // written by the storage finalize trigger in real life; seeded here so
  // the collection exists and the mobile team has something to read
  batch.set(db.doc('recordings/rec_seed_1'), {
    patientId: SAFA,
    startedAt: now(),
    durationSec: 30,
    avgHr: 74,
    resultClass: null,
    resultTier: null,
    storagePath: `recordings/${SAFA}/rec_seed_1.json.gz`,
    pdfPath: null,
    createdBy: SAFA,
    modelVersion: null
  });

  // ---------------------------------------------------------- auditLog
  batch.set(db.doc('auditLog/log_seed_1'), {
    actorId: 'system',
    actorRole: 'system',
    action: 'link_created',
    targetType: 'careLinks',
    targetId: `${SAFA}_${NORA}`,
    at: now(),
    meta: { source: 'seed' }
  });

  await batch.commit();
  console.log('seeded 7 collections:');
  console.log('  users        3   safa, ahmed, nora');
  console.log('  devices      2   one per patient, id = patient uid');
  console.log('  careLinks    2   both patients linked to nora');
  console.log('  linkCodes    1   482913, expires in 15 min');
  console.log('  medAlarms    3   one added by the caregiver');
  console.log('  recordings   1   rec_seed_1');
  console.log('  auditLog     1   log_seed_1');
  console.log('passwords: Test1234!');
}

main().catch(e => { console.error(e); process.exit(1); });
