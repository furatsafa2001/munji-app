/**
 * MUNJI — medication alarms
 *
 * The duplicate problem: the patient adds "Aspirin 100 mg" and, the same
 * evening, their caregiver adds "aspirin 100mg". Two alarms, one dose. The
 * patient takes it twice.
 *
 * The fix is structural rather than a warning message. The document ID is
 * derived from the medicine name, so both attempts land on the same ID and
 * the second one is rejected by the database — no cooperation between the
 * two apps is required, and no timing window exists where both writes
 * succeed.
 */

const { doc, getDoc, setDoc, updateDoc, deleteDoc, collection, query, where, getDocs } =
  require('firebase/firestore');

/**
 * Normalise a medicine name into a stable key.
 *
 *   'Aspirin 100 mg'  -> 'aspirin100mg'
 *   'aspirin 100mg'   -> 'aspirin100mg'
 *   'ASPIRIN  100 MG' -> 'aspirin100mg'
 *
 * Arabic names normalise too: أ إ آ collapse to ا, and ة to ه, because the
 * same medicine is routinely typed both ways.
 */
function medKey(medName) {
  return String(medName)
    .trim()
    .toLowerCase()
    .replace(/[أإآ]/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/[ىي]/g, 'ي')
    .replace(/[\u064B-\u0652]/g, '')   // Arabic diacritics
    .replace(/[^a-z0-9\u0600-\u06FF]/g, '');
}

function alarmId(patientId, medName) {
  return `${patientId}_${medKey(medName)}`;
}

class AlarmError extends Error {
  constructor(code, message, existing) {
    super(message);
    this.name = 'AlarmError';
    this.code = code;
    this.existing = existing || null;
  }
}

/**
 * Add an alarm.
 *
 * Throws `duplicate` when this medicine already has one, carrying the
 * existing alarm so the app can offer to open it instead. The app should
 * present that as a choice, not an error — the person was trying to help.
 */
async function addAlarm(db, uid, role, { patientId, medName, dose, timeLocal, repeatDays }) {
  const id = alarmId(patientId, medName);
  const ref = doc(db, 'medAlarms', id);

  const existing = await getDoc(ref);
  if (existing.exists()) {
    const d = existing.data();
    throw new AlarmError(
      'duplicate',
      `${d.medName} already has a reminder at ${d.timeLocal}.`,
      { id, ...d }
    );
  }

  const payload = {
    patientId,
    medKey: medKey(medName),
    medName: medName.trim(),
    dose: dose || '',
    timeLocal,
    repeatDays: repeatDays || [0, 1, 2, 3, 4, 5, 6],
    enabled: true,
    createdBy: uid,
    createdByRole: role,
    updatedAt: new Date(),
    updatedBy: uid
  };

  // if two people write at the same instant, the rules reject the second —
  // the ID collision is what makes this safe, not the check above
  try {
    await setDoc(ref, payload);
  } catch (err) {
    const now = await getDoc(ref);
    if (now.exists()) {
      throw new AlarmError(
        'duplicate',
        `${medName} already has a reminder.`,
        { id, ...now.data() }
      );
    }
    throw err;
  }

  return { id, ...payload };
}

async function updateAlarm(db, uid, id, changes) {
  const forbidden = ['patientId', 'medKey', 'createdBy'];
  for (const f of forbidden) {
    if (f in changes) {
      throw new AlarmError('immutable-field', `${f} cannot be changed.`);
    }
  }
  await updateDoc(doc(db, 'medAlarms', id), {
    ...changes,
    updatedAt: new Date(),
    updatedBy: uid
  });
}

async function toggleAlarm(db, uid, id, enabled) {
  await updateAlarm(db, uid, id, { enabled });
}

async function deleteAlarm(db, id) {
  await deleteDoc(doc(db, 'medAlarms', id));
}

async function listAlarms(db, patientId) {
  const snap = await getDocs(
    query(collection(db, 'medAlarms'), where('patientId', '==', patientId))
  );
  return snap.docs
    .map(d => ({ id: d.id, ...d.data() }))
    .sort((a, b) => a.timeLocal.localeCompare(b.timeLocal));
}

module.exports = {
  medKey,
  alarmId,
  addAlarm,
  updateAlarm,
  toggleAlarm,
  deleteAlarm,
  listAlarms,
  AlarmError
};
