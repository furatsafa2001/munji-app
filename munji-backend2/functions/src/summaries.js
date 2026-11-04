const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { db, Timestamp, FieldValue } = require('./admin');
const { computeDailyVitals } = require('./daily');
const { dayStartMs, DAY_MS } = require('./riyadh');

const DAILY_RETENTION_MS = 730 * DAY_MS;   // two years

function dailyRef(patientId, key) {
  return db.doc(`users/${patientId}/daily/${key}`);
}

function dailyBase(key) {
  const start = dayStartMs(key);
  return {
    dayKey: key,
    date: Timestamp.fromMillis(start),
    expireAt: Timestamp.fromMillis(start + DAILY_RETENTION_MS),
    updatedAt: FieldValue.serverTimestamp()
  };
}

/**
 * Rebuilds the vitals fields of one day from all of that day's hours.
 * Merges, so recordingsCount (owned by refreshRecordingsCount) is kept.
 */
async function recomputeDailyVitals(patientId, key) {
  const hours = await db.collection(`users/${patientId}/hourly`)
    .where('dayKey', '==', key)
    .get();
  const vitals = computeDailyVitals(hours.docs.map((d) => d.data()));
  await dailyRef(patientId, key).set({ ...dailyBase(key), ...vitals }, { merge: true });
}

/** Counts the recordings that started on one day and stores the count. */
async function refreshRecordingsCount(patientId, key) {
  const start = dayStartMs(key);
  const agg = await db.collection(`users/${patientId}/recordings`)
    .where('startedAt', '>=', Timestamp.fromMillis(start))
    .where('startedAt', '<', Timestamp.fromMillis(start + DAY_MS))
    .count()
    .get();
  await dailyRef(patientId, key).set(
    { ...dailyBase(key), recordingsCount: agg.data().count },
    { merge: true }
  );
}

// Created, not written: hourly documents are create-only, and the TTL
// deletion after 90 days must not trigger a recompute that would wipe the
// day's vitals once its hours are gone.
const onHourlyCreated = onDocumentCreated('users/{patientId}/hourly/{hourId}', async (event) => {
  const { patientId, hourId } = event.params;
  await recomputeDailyVitals(patientId, hourId.slice(0, 8));
});

module.exports = { onHourlyCreated, recomputeDailyVitals, refreshRecordingsCount };
