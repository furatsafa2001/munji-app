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
  // the app sends unverified users to the verify screen, and the emulator
  // never delivers the email, so seeded accounts start verified
  await auth.updateUser(uid, { emailVerified: true });
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
    devicePaired: true,       // skips the mandatory pairing screen
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
    devicePaired: true,       // skips the mandatory pairing screen
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
  const device = (serial, battery, hr, rmssd) => ({
    status: 'paired', serial, model: 'munji-v1', firmware: null,
    pairedAt: now(), connected: true, charging: null, worn: true,
    battery, hr, rmssd, lastSeenAt: now()
  });
  batch.set(db.doc(`users/${SAFA}/device/current`), device('MUNJI-3C84270B4F2A', 85, 72, 38));
  batch.set(db.doc(`users/${AHMED}/device/current`), device('MUNJI-3C84270B7B11', 64, 81, 24));

  // ---------------------------------------------------- hourly + daily
  // Two weeks of plausible days for Safa, 07:00 to 23:00 Riyadh, so every
  // report period has something to show. Deterministic, so screenshots and
  // tests are repeatable. Two days are left empty on purpose: reports must
  // show a gap, not draw a line through it.
  const SEED_DAYS = 14;
  const emptyDays = new Set([5, 9]);
  // within the last 7 days: the upload trigger refuses older start times
  const RECORDING_DAYS = new Set([1, 3, 6]);
  const wave = (d, h) => Math.sin((d * 24 + h) / 5);
  let hourlyCount = 0;
  for (let back = SEED_DAYS; back >= 1; back--) {
    const key = dayKey(Date.now() - back * DAY_MS);
    const start0 = dayStartMs(key);
    const hours = [];
    if (!emptyDays.has(back)) {
      for (let h = 7; h < 23; h++) {
        const start = start0 + h * HOUR_MS;
        const base = 66 + 8 * wave(back, h) + (h >= 17 && h <= 19 ? 14 : 0); // evening walk
        const charging = h === 13 ? 40 : 0;
        const leadOff = (back + h) % 7 === 0 ? 8 : 1;
        const doc = {
          hourStart: Timestamp.fromMillis(start),
          dayKey: key,
          hrAvg: Math.round(base * 10) / 10,
          hrMin: Math.round(base - 12),
          hrMax: Math.round(base + 22),
          hrvAvg: Math.round((42 - (base - 66) * 0.6) * 10) / 10,
          qualityPct: null,
          monitoredMin: 60 - charging - leadOff,
          leadOffMin: leadOff,
          chargingMin: charging,
          disconnectedMin: 0,
          expireAt: Timestamp.fromMillis(start + 90 * DAY_MS),
          createdAt: now()
        };
        hours.push(doc);
        batch.set(db.doc(`users/${SAFA}/hourly/${hourKey(start)}`), doc);
        hourlyCount++;
      }
    }
    if (hours.length) {
      // the trigger builds this in real life; written here so the seed
      // works without the functions emulator
      batch.set(db.doc(`users/${SAFA}/daily/${key}`), {
        dayKey: key,
        date: Timestamp.fromMillis(start0),
        ...computeDailyVitals(hours),
        recordingsCount: RECORDING_DAYS.has(back) ? 1 : 0,
        expireAt: Timestamp.fromMillis(start0 + 730 * DAY_MS),
        updatedAt: now()
      });
    }
  }

  // --------------------------------------------------------- careLinks
  // id = {patientId}_{caregiverId} so rules can look it up without a query
  batch.set(db.doc(`careLinks/${SAFA}_${NORA}`), {
    patientId: SAFA, caregiverId: NORA, relation: 'daughter',
    patientName: 'Safa Khan', caregiverName: 'Nora Khan',
    status: 'active', priority: 1,
    createdAt: now(), activatedAt: now(), revokedAt: null
  });
  batch.set(db.doc(`careLinks/${AHMED}_${NORA}`), {
    patientId: AHMED, caregiverId: NORA, relation: 'daughter',
    patientName: 'Ahmed Khan', caregiverName: 'Nora Khan',
    status: 'active', priority: 1,
    createdAt: now(), activatedAt: now(), revokedAt: null
  });

  // --------------------------------------------------------- linkCodes
  // one live code so the mobile team can test redemption before the
  // callable function exists (week 2)
  batch.set(db.doc('linkCodes/482913'), {
    patientId: SAFA,
    createdAt: now(),
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 10 * 60 * 1000),
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

  // -------------------------------------------------------- recordings
  // Real .ecg files with a synthetic but realistic single-lead trace
  // (P, QRS, T, a little baseline wander and noise), so the history screen
  // and its PDF can be tried without a patch. The document is written
  // first: if the functions emulator is running, its trigger validates the
  // file and finds the document already there, which it treats as done.
  const UV_PER_LSB = 1.5258789;
  function synthEcg(bpm, seed) {
    let x = seed;
    const rand = () => ((x = (x * 9301 + 49297) % 233280) / 233280);
    const fs = 250, n = 30 * fs, mv = new Float64Array(n);
    const waves = [ // [offset s, amplitude mV, width s]
      [-0.20, 0.12, 0.025], [-0.045, -0.10, 0.010], [0, 1.05, 0.011],
      [0.04, -0.28, 0.012], [0.26, 0.30, 0.045]
    ];
    let t = 0.5;
    while (t < 30.5) {
      for (const [off, amp, w] of waves) {
        const c = t + off;
        const from = Math.max(0, Math.floor((c - 5 * w) * fs));
        const to = Math.min(n, Math.ceil((c + 5 * w) * fs));
        for (let i = from; i < to; i++) mv[i] += amp * Math.exp(-(((i / fs - c) / w) ** 2) / 2);
      }
      t += (60 / bpm) * (0.96 + 0.08 * rand());
    }
    const out = new Array(n);
    for (let i = 0; i < n; i++) {
      const wander = 0.06 * Math.sin(2 * Math.PI * 0.25 * i / fs);
      const noise = (rand() - 0.5) * 0.03;
      out[i] = Math.round(((mv[i] + wander + noise) * 1000) / UV_PER_LSB);
    }
    return out;
  }

  const recs = [
    { id: 'rec_seed_today01', back: 0, minutesAgo: 25, bpm: 74, saved: false },
    { id: 'rec_seed_day1_01', back: 1, hour: 9, bpm: 68, saved: true },
    { id: 'rec_seed_day3_01', back: 3, hour: 18, bpm: 88, saved: false },
    { id: 'rec_seed_day6_01', back: 6, hour: 21, bpm: 63, saved: false }
  ];
  let recordingNote = 'skipped (storage emulator not running)';
  try {
    const bucket = admin.storage().bucket();
    for (const [i, r] of recs.entries()) {
      const startedAtMs = r.back === 0
        ? Date.now() - r.minutesAgo * 60 * 1000
        : dayStartMs(dayKey(Date.now() - r.back * DAY_MS)) + r.hour * HOUR_MS;
      const path = `patients/${SAFA}/recordings/${r.id}.ecg`;
      await db.doc(`users/${SAFA}/recordings/${r.id}`).set({
        kind: 'manual',
        eventId: null,
        startedAt: Timestamp.fromMillis(startedAtMs),
        durationSec: 30,
        sampleRateHz: 250,
        uvPerLsb: UV_PER_LSB,
        storagePath: path,
        avgHr: r.bpm,
        deviceSerial: 'MUNJI-3C84270B4F2A',
        firmware: null,
        resultCode: null,
        resultTier: null,
        modelVersion: null,
        saved: r.saved,
        createdAt: now()
      });
      await bucket.file(path).save(
        buildRecording({ samples: synthEcg(r.bpm, 17 + i), startedAtMs }),
        {
          contentType: 'application/octet-stream',
          metadata: { metadata: { kind: 'manual', avgHr: String(r.bpm), deviceSerial: 'MUNJI-3C84270B4F2A' } }
        }
      );
    }
    recordingNote = `${recs.length} with files (today, 1, 3 and 6 days ago)`;
  } catch (e) {
    // storage emulator not started; the rest of the seed is still usable
  }

  console.log('seeded:');
  console.log('  users              3   safa, ahmed, nora');
  console.log('  device/current     2   one per patient');
  console.log(`  hourly           ${hourlyCount}   safa, last 14 days 07:00-23:00 (two days empty)`);
  console.log('  daily             12   safa, last 14 days');
  console.log('  careLinks          2   both patients linked to nora');
  console.log('  linkCodes          1   482913, expires in 10 min');
  console.log('  medAlarms          3   one added by the caregiver');
  console.log('  auditLog           1   log_seed_1');
  console.log(`  recordings        4   ${recordingNote}`);
  console.log('passwords: Test1234!');
}

main().catch(e => { console.error(e); process.exit(1); });
