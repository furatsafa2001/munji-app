const { onObjectFinalized, onObjectDeleted } = require('firebase-functions/v2/storage');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const logger = require('firebase-functions/logger');

const { db, storage, Timestamp, FieldValue, ECG_BUCKET } = require('./admin');
const { validateRecording } = require('./ecgFormat');
const { dayKey, DAY_MS } = require('./riyadh');
const { refreshRecordingsCount } = require('./summaries');

const PATH = /^patients\/([^/]+)\/recordings\/([A-Za-z0-9_-]{8,64})\.ecg$/;
const RETENTION_DAYS = 90;
const ALREADY_EXISTS = 6;

// Logs carry ids and fixed reason codes only, never health data.

function cleanMeta(meta) {
  const hr = Number(meta.avgHr);
  const text = (v) => (typeof v === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(v) ? v : null);
  return {
    avgHr: Number.isFinite(hr) && hr >= 20 && hr <= 300 ? Math.round(hr) : null,
    deviceSerial: text(meta.deviceSerial),
    firmware: text(meta.firmware),
    eventId: text(meta.eventId)
  };
}

/**
 * A file landed. Validate it fully, then create its document. Invalid
 * files are deleted, so the patient never sees a partial recording.
 */
const onRecordingUploaded = onObjectFinalized({ bucket: ECG_BUCKET }, async (event) => {
  const obj = event.data;
  const match = PATH.exec(obj.name || '');
  if (!match) return;
  const [, patientId, recordingId] = match;

  const file = storage.bucket(obj.bucket).file(obj.name);
  const [buffer] = await file.download();             // 30 KB at most
  const meta = obj.metadata || {};

  const check = validateRecording({ buffer, kind: meta.kind, nowMs: Date.now() });
  if (!check.ok) {
    logger.warn('recording rejected', { recordingId, reason: check.reason });
    await file.delete({ ignoreNotFound: true });
    return;
  }

  const h = check.header;
  const extra = cleanMeta(meta);
  const ref = db.doc(`users/${patientId}/recordings/${recordingId}`);

  try {
    await ref.create({
      kind: meta.kind,
      eventId: meta.kind === 'event' ? extra.eventId : null,
      startedAt: Timestamp.fromMillis(h.startedAtMs),
      durationSec: check.durationSec,
      sampleRateHz: h.sampleRateHz,
      uvPerLsb: Number(h.uvPerLsb.toPrecision(8)),
      storagePath: obj.name,
      avgHr: extra.avgHr,
      deviceSerial: extra.deviceSerial,
      firmware: extra.firmware,
      resultCode: null,
      resultTier: null,
      modelVersion: null,
      saved: false,
      createdAt: FieldValue.serverTimestamp()
    });
  } catch (err) {
    if (err.code === ALREADY_EXISTS) return;          // retried event
    throw err;
  }

  await refreshRecordingsCount(patientId, dayKey(h.startedAtMs));
  logger.info('recording accepted', { recordingId });
});

/** The file is gone (patient deleted it, or retention). Remove its document. */
const onRecordingDeleted = onObjectDeleted({ bucket: ECG_BUCKET }, async (event) => {
  const match = PATH.exec(event.data.name || '');
  if (!match) return;
  const [, patientId, recordingId] = match;

  const ref = db.doc(`users/${patientId}/recordings/${recordingId}`);
  const snap = await ref.get();
  if (!snap.exists) return;

  const startedAt = snap.get('startedAt');
  await ref.delete();
  if (startedAt) await refreshRecordingsCount(patientId, dayKey(startedAt.toMillis()));
});

/**
 * Deletes recordings the patient did not save, 90 days after creation.
 * File first, then document: a crash in between leaves a document whose
 * file is missing, which the next run cleans up, never an orphan file.
 */
async function purgeExpiredRecordings({ nowMs, bucketName, batchSize = 200 }) {
  const cutoff = Timestamp.fromMillis(nowMs - RETENTION_DAYS * DAY_MS);
  const bucket = storage.bucket(bucketName);
  let purged = 0;

  for (;;) {
    const snap = await db.collectionGroup('recordings')
      .where('saved', '==', false)
      .where('createdAt', '<', cutoff)
      .limit(batchSize)
      .get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      await bucket.file(doc.get('storagePath')).delete({ ignoreNotFound: true });
      await doc.ref.delete();
      purged += 1;
    }
    if (snap.size < batchSize) break;
  }

  logger.info('expired recordings purged', { count: purged });
  return purged;
}

const purgeRecordingsDaily = onSchedule(
  { schedule: 'every day 03:00', timeZone: 'Asia/Riyadh' },
  async () => {
    await purgeExpiredRecordings({ nowMs: Date.now(), bucketName: ECG_BUCKET.value() });
  }
);

module.exports = {
  onRecordingUploaded,
  onRecordingDeleted,
  purgeRecordingsDaily,
  purgeExpiredRecordings,
  cleanMeta,
  PATH
};
