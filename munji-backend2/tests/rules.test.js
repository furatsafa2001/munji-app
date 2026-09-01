/**
 * MUNJI — security rules tests
 *
 *   firebase emulators:exec --only firestore "npm test"
 *
 * Every rule is tested twice: once for the case that must be allowed, once
 * for the case that must be denied. A rule with only a positive test proves
 * nothing — an open rule passes it too.
 */

const fs = require('fs');
const { initializeTestEnvironment, assertFails, assertSucceeds } =
  require('@firebase/rules-unit-testing');
const { doc, getDoc, setDoc, updateDoc, deleteDoc } = require('firebase/firestore');

const SAFA = 'uid_patient_safa';
const AHMED = 'uid_patient_ahmed';
const NORA = 'uid_caregiver_nora';
const STRANGER = 'uid_stranger';

let env;

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: 'munji-dev',
    firestore: {
      rules: fs.readFileSync('firestore.rules', 'utf8'),
      // stated explicitly so the suite runs both ways: directly with
      // `npx jest` against an already-running emulator, and wrapped in
      // `firebase emulators:exec`, which starts its own
      host: '127.0.0.1',
      port: 8080
    }
  });
});

afterAll(async () => { if (env) await env.cleanup(); });

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users', SAFA), {
      role: 'patient', fullName: 'Safa Khan', phone: '+966567290751',
      email: 'safa.khan@email.com', locale: 'ar', fcmTokens: [],
      createdAt: new Date(), disabled: false,
      patient: { caregiverIds: [NORA], emergencyNumber: '911' }
    });
    await setDoc(doc(db, 'users', AHMED), {
      role: 'patient', fullName: 'Ahmed Khan', phone: '+966551234500',
      email: 'ahmed.khan@email.com', locale: 'ar', fcmTokens: [],
      createdAt: new Date(), disabled: false,
      patient: { caregiverIds: [], emergencyNumber: '911' }
    });
    await setDoc(doc(db, 'users', NORA), {
      role: 'caregiver', fullName: 'Nora Khan', phone: '+966551234567',
      email: 'nora.khan@email.com', locale: 'ar', fcmTokens: [],
      createdAt: new Date(), disabled: false,
      caregiver: { patientIds: [SAFA] }
    });
    await setDoc(doc(db, 'devices', SAFA), {
      patientId: SAFA, serial: 'MJ-4F2A', model: 'munji-v1',
      status: 'paired', pairedAt: new Date(), battery: 85
    });
    await setDoc(doc(db, 'careLinks', `${SAFA}_${NORA}`), {
      patientId: SAFA, caregiverId: NORA, status: 'active', priority: 1
    });
    await setDoc(doc(db, 'careLinks', `${AHMED}_${NORA}`), {
      patientId: AHMED, caregiverId: NORA, status: 'active', priority: 1
    });
    await setDoc(doc(db, 'events', 'evt1'), {
      patientId: SAFA, class: 'afib', tier: 'crit', hr: 132
    });
    await setDoc(doc(db, 'medAlarms', `${SAFA}_aspirin100mg`), {
      patientId: SAFA, medKey: 'aspirin100mg', medName: 'Aspirin 100 mg',
      dose: '1 tablet', timeLocal: '08:00', repeatDays: [0,1,2,3,4,5,6],
      enabled: true, createdBy: SAFA, createdByRole: 'patient'
    });
    await setDoc(doc(db, 'linkCodes', '123456'), {
      patientId: SAFA, used: false, attempts: 0
    });
    await setDoc(doc(db, 'auditLog', 'log1'), { actorId: SAFA, action: 'view_patient' });
  });
});

const as = (uid) => env.authenticatedContext(uid).firestore();
const anon = () => env.unauthenticatedContext().firestore();

// ------------------------------------------------------------------ users

test('patient reads own profile', async () => {
  await assertSucceeds(getDoc(doc(as(SAFA), 'users', SAFA)));
});

test('linked caregiver reads the patient profile', async () => {
  await assertSucceeds(getDoc(doc(as(NORA), 'users', SAFA)));
});

test('stranger cannot read a patient profile', async () => {
  await assertFails(getDoc(doc(as(STRANGER), 'users', SAFA)));
});

test('anonymous cannot read anything', async () => {
  await assertFails(getDoc(doc(anon(), 'users', SAFA)));
});

test('patient cannot add a caregiver to their own document', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'users', SAFA), {
    'patient.caregiverIds': [NORA, STRANGER]
  }));
});

test('patient cannot change their own role', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'users', SAFA), { role: 'caregiver' }));
});

test('patient can update their own phone number', async () => {
  await assertSucceeds(updateDoc(doc(as(SAFA), 'users', SAFA), { phone: '+966500000000' }));
});

// ----------------------------------------------------------------- events

test('linked caregiver reads events', async () => {
  await assertSucceeds(getDoc(doc(as(NORA), 'events', 'evt1')));
});

test('unlinked user cannot read events', async () => {
  await assertFails(getDoc(doc(as(STRANGER), 'events', 'evt1')));
});

test('patient cannot fabricate an event', async () => {
  await assertFails(setDoc(doc(as(SAFA), 'events', 'evt_fake'), {
    patientId: SAFA, class: 'vt', tier: 'crit'
  }));
});

test('patient cannot suppress an event', async () => {
  await assertFails(deleteDoc(doc(as(SAFA), 'events', 'evt1')));
});

// -------------------------------------------------------------- medAlarms

test('patient creates their own alarm', async () => {
  await assertSucceeds(setDoc(doc(as(SAFA), 'medAlarms', `${SAFA}_omega3`), {
    patientId: SAFA, medKey: 'omega3', medName: 'Omega-3', dose: '1 capsule',
    timeLocal: '21:00', repeatDays: [0, 1, 2, 3, 4, 5, 6],
    enabled: true, createdBy: SAFA, createdByRole: 'patient'
  }));
});

test('an alarm id that does not match the medicine key is rejected', async () => {
  // without this, the collision that prevents duplicates could be bypassed
  await assertFails(setDoc(doc(as(SAFA), 'medAlarms', 'anything_i_like'), {
    patientId: SAFA, medKey: 'omega3', medName: 'Omega-3', dose: '1 capsule',
    timeLocal: '21:00', repeatDays: [0], enabled: true,
    createdBy: SAFA, createdByRole: 'patient'
  }));
});

test('the medicine key cannot be changed after creation', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'medAlarms', `${SAFA}_aspirin100mg`), {
    medKey: 'somethingelse'
  }));
});

test('linked caregiver creates an alarm for the patient', async () => {
  await assertSucceeds(setDoc(doc(as(NORA), 'medAlarms', `${SAFA}_atorvastatin20mg`), {
    patientId: SAFA, medKey: 'atorvastatin20mg', medName: 'Atorvastatin 20 mg',
    dose: '1 tablet', timeLocal: '20:00', repeatDays: [0, 1, 2, 3, 4, 5, 6],
    enabled: true, createdBy: NORA, createdByRole: 'caregiver'
  }));
});

test('caregiver cannot duplicate a medicine the patient already added', async () => {
  // same medicine, different spelling, different person — same document id,
  // so the create collides instead of producing a second reminder
  await assertFails(setDoc(doc(as(NORA), 'medAlarms', `${SAFA}_aspirin100mg`), {
    patientId: SAFA, medKey: 'aspirin100mg', medName: 'aspirin 100mg',
    dose: '1 tablet', timeLocal: '09:00', repeatDays: [0], enabled: true,
    createdBy: NORA, createdByRole: 'caregiver'
  }));
});

test('linked caregiver can toggle an alarm the patient created', async () => {
  await assertSucceeds(updateDoc(doc(as(NORA), 'medAlarms', `${SAFA}_aspirin100mg`), { enabled: false }));
});

test('linked caregiver can delete an alarm', async () => {
  await assertSucceeds(deleteDoc(doc(as(NORA), 'medAlarms', `${SAFA}_aspirin100mg`)));
});

test('a revoked caregiver loses access immediately', async () => {
  // revocation removes the uid from caregiverIds; nothing else is needed
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', SAFA), {
      role: 'patient', fullName: 'Safa Khan', phone: '+966567290751',
      email: 'safa.khan@email.com', locale: 'ar', fcmTokens: [],
      createdAt: new Date(), disabled: false,
      patient: { caregiverIds: [], emergencyNumber: '911' }
    });
  });
  await assertFails(getDoc(doc(as(NORA), 'users', SAFA)));
  await assertFails(getDoc(doc(as(NORA), 'devices', SAFA)));
  await assertFails(updateDoc(doc(as(NORA), 'medAlarms', `${SAFA}_aspirin100mg`), { enabled: false }));
});

test('caregiver cannot manage alarms for a patient they are not linked to', async () => {
  // Nora has a careLink to Ahmed, but Ahmed's caregiverIds is empty —
  // the denormalised list is what rules trust, and it is server-written
  await assertFails(setDoc(doc(as(NORA), 'medAlarms', `${AHMED}_aspirin100mg`), {
    patientId: AHMED, medKey: 'aspirin100mg', medName: 'Aspirin 100 mg',
    dose: '1 tablet', timeLocal: '08:00', repeatDays: [0], enabled: true,
    createdBy: NORA, createdByRole: 'caregiver'
  }));
});

test('stranger cannot create an alarm for a patient', async () => {
  await assertFails(setDoc(doc(as(STRANGER), 'medAlarms', 'alarm_x'), {
    patientId: SAFA, medName: 'X', dose: '1', timeLocal: '08:00',
    repeatDays: [0], enabled: true, createdBy: STRANGER, createdByRole: 'caregiver'
  }));
});

test('alarm cannot be reassigned to another patient', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'medAlarms', `${SAFA}_aspirin100mg`), { patientId: AHMED }));
});

test('either side can change the time of a shared alarm', async () => {
  await assertSucceeds(updateDoc(doc(as(SAFA), 'medAlarms', `${SAFA}_aspirin100mg`), { timeLocal: '09:00' }));
  await assertSucceeds(updateDoc(doc(as(NORA), 'medAlarms', `${SAFA}_aspirin100mg`), { timeLocal: '10:00' }));
});

// ------------------------------------------------- linkCodes / auditLog

test('nobody can read link codes', async () => {
  await assertFails(getDoc(doc(as(NORA), 'linkCodes', '123456')));
  await assertFails(getDoc(doc(as(SAFA), 'linkCodes', '123456')));
});

test('nobody can read the audit log', async () => {
  await assertFails(getDoc(doc(as(SAFA), 'auditLog', 'log1')));
});

test('nobody can write to the audit log', async () => {
  await assertFails(setDoc(doc(as(SAFA), 'auditLog', 'log_fake'), { actorId: SAFA }));
});

// ------------------------------------------------- shape validation

test('profile with a malformed phone number is rejected', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'users', SAFA), { phone: '0567290751' }));
});

test('profile with an unsupported locale is rejected', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'users', SAFA), { locale: 'fr' }));
});

test('new account cannot be created pre-linked to a patient', async () => {
  await assertFails(setDoc(doc(as(STRANGER), 'users', STRANGER), {
    role: 'caregiver', fullName: 'Stranger', phone: '+966500000001',
    email: 's@x.com', locale: 'en', fcmTokens: [],
    createdAt: new Date(), disabled: false,
    caregiver: { patientIds: [SAFA] }
  }));
});

test('valid new account is accepted', async () => {
  await assertSucceeds(setDoc(doc(as(STRANGER), 'users', STRANGER), {
    role: 'caregiver', fullName: 'New Caregiver', phone: '+966500000002',
    email: 'new@x.com', locale: 'en', fcmTokens: [],
    createdAt: new Date(), disabled: false,
    caregiver: { patientIds: [] }
  }));
});

// --------------------------------------------------------------- devices

test('patient updates their own device battery', async () => {
  await assertSucceeds(updateDoc(doc(as(SAFA), 'devices', SAFA), { battery: 70 }));
});

test('battery outside 0-100 is rejected', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'devices', SAFA), { battery: 150 }));
});

test('a device document cannot be created under someone else\'s id', async () => {
  await assertFails(setDoc(doc(as(SAFA), 'devices', 'dev_second'), {
    patientId: SAFA, serial: 'MJ-9999', model: 'munji-v1',
    status: 'paired', pairedAt: new Date(), battery: 90
  }));
});

test('device cannot be reassigned to another patient', async () => {
  await assertFails(updateDoc(doc(as(SAFA), 'devices', SAFA), { patientId: AHMED }));
});

test('caregiver can read the device but not write it', async () => {
  await assertSucceeds(getDoc(doc(as(NORA), 'devices', SAFA)));
  await assertFails(updateDoc(doc(as(NORA), 'devices', SAFA), { battery: 10 }));
});

// ------------------------------------------------------------- careLinks

test('either party reads their care link', async () => {
  await assertSucceeds(getDoc(doc(as(SAFA), 'careLinks', `${SAFA}_${NORA}`)));
  await assertSucceeds(getDoc(doc(as(NORA), 'careLinks', `${SAFA}_${NORA}`)));
});

test('nobody can create a care link from the client', async () => {
  await assertFails(setDoc(doc(as(STRANGER), 'careLinks', `${SAFA}_${STRANGER}`), {
    patientId: SAFA, caregiverId: STRANGER, status: 'active'
  }));
});
