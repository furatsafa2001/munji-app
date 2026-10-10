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
if (!process.env.FIREBASE_STORAGE_EMULATOR_HOST) {
  process.env.FIREBASE_STORAGE_EMULATOR_HOST = 'localhost:9199';
}

const { buildRecording } = require('../functions/src/ecgFormat');
const { computeDailyVitals } = require('../functions/src/daily');
const { hourKey, dayKey, dayStartMs, DAY_MS } = require('../functions/src/riyadh');

const BUCKET = 'munji-dev.firebasestorage.app';

admin.initializeApp({ projectId: 'munji-dev', storageBucket: BUCKET });
const db = admin.firestore();
const auth = admin.auth();
const { Timestamp } = admin.firestore;
const now = Timestamp.now;
const HOUR_MS = 60 * 60 * 1000;

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

  // ------------------------------------------------- device/current
  // one document per patient, overwritten on each update
  const device = (serial, battery) => ({
    status: 'paired', serial, model: 'munji-v1', firmware: null,
    pairedAt: now(), connected: true, charging: null, worn: null,
    battery, lastSeenAt: now()
  });
  batch.set(db.doc(`users/${SAFA}/device/current`), device('MUNJI-3C84270B4F2A', 85));
  batch.set(db.doc(`users/${AHMED}/device/current`), device('MUNJI-3C84270B7B11', 64));

  // ---------------------------------------------------- hourly + daily
  // yesterday, 08:00 to 13:00 Riyadh, so the history screen has data
  const yKey = dayKey(Date.now() - DAY_MS);
  const yStart = dayStartMs(yKey);
  const hours = [];
  for (let h = 8; h < 14; h++) {
    const start = yStart + h * HOUR_MS;
    const doc = {
      hourStart: Timestamp.fromMillis(start),
      dayKey: yKey,
      hrAvg: 68 + h, hrMin: 55 + h, hrMax: 90 + h, hrvAvg: 38 + h / 2, qualityPct: null,
      monitoredMin: h === 11 ? 20 : 55, leadOffMin: 5, chargingMin: h === 11 ? 35 : 0,
      disconnectedMin: 0,
      expireAt: Timestamp.fromMillis(start + 90 * DAY_MS),
      createdAt: now()
    };
    hours.push(doc);
    batch.set(db.doc(`users/${SAFA}/hourly/${hourKey(start)}`), doc);
  }
  // the trigger builds this in real life; written here so the seed works
  // without the functions emulator
  batch.set(db.doc(`users/${SAFA}/daily/${yKey}`), {
    dayKey: yKey,
    date: Timestamp.fromMillis(yStart),
    ...computeDailyVitals(hours),
    recordingsCount: 0,
    expireAt: Timestamp.fromMillis(yStart + 730 * DAY_MS),
    updatedAt: now()
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

  // --------------------------------------------------------- recording
  // Uploaded as a real file. With the functions emulator running, the
  // finalize trigger validates it and creates users/{safa}/recordings/...
  const samples = Array.from({ length: 7500 }, (_, i) =>
    Math.round(600 * Math.exp(-(((i % 208) - 40) ** 2) / 20)));    // ~72 bpm spikes
  let recordingNote = 'skipped (storage emulator not running)';
  try {
    await admin.storage().bucket().file(`patients/${SAFA}/recordings/rec_seed_0001.ecg`).save(
      buildRecording({ samples, startedAtMs: Date.now() - 10 * 60 * 1000 }),
      {
        contentType: 'application/octet-stream',
        metadata: { metadata: { kind: 'manual', avgHr: '72', deviceSerial: 'MUNJI-3C84270B4F2A' } }
      }
    );
    recordingNote = 'uploaded, the trigger creates its document';
  } catch (e) {
    // storage emulator not started; the rest of the seed is still usable
  }

  console.log('seeded:');
  console.log('  users              3   safa, ahmed, nora');
  console.log('  device/current     2   one per patient');
  console.log(`  hourly             6   safa, ${yKey} 08:00-13:00`);
  console.log('  daily              1   safa, yesterday');
  console.log('  careLinks          2   both patients linked to nora');
  console.log('  linkCodes          1   482913, expires in 15 min');
  console.log('  medAlarms          3   one added by the caregiver');
  console.log('  auditLog           1   log_seed_1');
  console.log(`  recording          1   ${recordingNote}`);
  console.log('passwords: Test1234!');
}

main().catch(e => { console.error(e); process.exit(1); });
