const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');

const { admin, db, storage, FieldValue, Timestamp, ECG_BUCKET } = require('./admin');

// Logs carry ids only.

/** How recent the caller's sign-in must be. The app asks for the password
 *  again just before deleting, so a phone left unlocked cannot do it. */
const RECENT_LOGIN_SECONDS = 5 * 60;

/**
 * Removes one user and everything that is theirs. Safe to run again after a
 * partial failure: each step skips what is already gone, and the sign-in
 * account goes last, so the user can always retry.
 */
async function deleteAccount(uid, { nowMs = Date.now(), bucketName } = {}) {
  const now = Timestamp.fromMillis(nowMs);

  // 1. End every active link, on both sides. The other person's document is
  //    updated only if it exists: writing to a missing one would create a
  //    half-empty profile.
  const [asPatient, asCaregiver] = await Promise.all([
    db.collection('careLinks').where('patientId', '==', uid).where('status', '==', 'active').get(),
    db.collection('careLinks').where('caregiverId', '==', uid).where('status', '==', 'active').get()
  ]);
  for (const d of [...asPatient.docs, ...asCaregiver.docs]) {
    const { patientId, caregiverId } = d.data();
    const otherId = patientId === uid ? caregiverId : patientId;
    const otherRef = db.doc(`users/${otherId}`);
    await db.runTransaction(async (tx) => {
      const other = await tx.get(otherRef);
      tx.update(d.ref, { status: 'revoked', revokedAt: now, revokedBy: uid });
      if (other.exists) {
        tx.update(otherRef, patientId === uid
          ? { 'caregiver.patientIds': FieldValue.arrayRemove(uid) }
          : { 'patient.caregiverIds': FieldValue.arrayRemove(uid) });
      }
    });
  }

  // 2. Codes, rate-limit state and medication alarms that point at this user.
  const [codes, alarms] = await Promise.all([
    db.collection('linkCodes').where('patientId', '==', uid).get(),
    db.collection('medAlarms').where('patientId', '==', uid).get()
  ]);
  const batch = db.batch();
  codes.docs.forEach((d) => batch.delete(d.ref));
  alarms.docs.forEach((d) => batch.delete(d.ref));
  batch.delete(db.doc(`linkAttempts/${uid}`));
  await batch.commit();

  // 3. The profile and all its subcollections (device, hourly, daily,
  //    recordings, events).
  await db.recursiveDelete(db.doc(`users/${uid}`));

  // 4. ECG files.
  if (bucketName) {
    await storage.bucket(bucketName).deleteFiles({ prefix: `patients/${uid}/` });
  }

  // 5. A record that it happened, without any personal data.
  await db.collection('auditLog').doc().create({
    actorId: uid,
    action: 'account_deleted',
    targetType: 'users',
    targetId: uid,
    at: now
  });

  // 6. Last: the sign-in account itself.
  try {
    await admin.auth().deleteUser(uid);
  } catch (err) {
    if (err.code !== 'auth/user-not-found') throw err;
  }
}

const accountDelete = onCall(async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'sign-in');

  const authTime = request.auth.token && request.auth.token.auth_time;
  if (!authTime || Date.now() / 1000 - authTime > RECENT_LOGIN_SECONDS) {
    throw new HttpsError('failed-precondition', 'recent-login');
  }

  try {
    await deleteAccount(uid, { bucketName: ECG_BUCKET.value() });
  } catch (err) {
    logger.error('account delete failed', { uid, code: err.code || null });
    throw new HttpsError('internal', 'delete-failed');
  }
  logger.info('account deleted', { uid });
  return { ok: true };
});

module.exports = { accountDelete, deleteAccount, RECENT_LOGIN_SECONDS };
