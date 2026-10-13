/**
 * Patient to caregiver linking.
 *
 *   linkCodeGenerate   patient asks for a 6-digit code (valid 10 minutes)
 *   linkCodeRedeem     caregiver enters the code and becomes linked
 *   linkRevoke         either side ends the link
 *
 * Why this lives on the server: `patient.caregiverIds` is what every
 * Firestore rule consults to let a caregiver read a patient's data. If a
 * client could write it, any account could grant itself access to anyone.
 * And six digits is a million combinations, so redemption must be rate
 * limited per caller, which only the server can enforce.
 *
 * Rate limiting is per caregiver, not per code: someone guessing tries a
 * different code each time, so a counter on the code would never trip.
 * Five wrong codes in 15 minutes locks that account out of redeeming until
 * the window passes.
 *
 * The core functions take `db` and `now` so the tests can run them against
 * the emulator with a fixed clock. The exported callables are thin wrappers.
 */

const crypto = require('crypto');
const { HttpsError } = require('firebase-functions/v2/https');

const CODE_TTL_MS = 10 * 60 * 1000;
const MAX_CAREGIVERS = 5;
const ATTEMPT_LIMIT = 5;
const ATTEMPT_WINDOW_MS = 15 * 60 * 1000;
const RELATIONS = ['son', 'daughter', 'spouse', 'sibling', 'parent', 'friend', 'other'];

// ── pure helpers (unit tested without the emulator) ──────────────────────

function newCode() {
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0');
}

function isCodeShape(code) {
  return typeof code === 'string' && /^\d{6}$/.test(code);
}

function cleanRelation(r) {
  return RELATIONS.includes(r) ? r : null;
}

/**
 * Given the caller's attempt record, is another redemption allowed?
 * Returns the record to store if this attempt fails.
 */
function attemptState(record, nowMs) {
  const fresh = record && nowMs - record.windowStart < ATTEMPT_WINDOW_MS;
  const count = fresh ? record.count : 0;
  return {
    allowed: count < ATTEMPT_LIMIT,
    onFailure: {
      windowStart: fresh ? record.windowStart : nowMs,
      count: count + 1
    }
  };
}

function displayName(user) {
  const n = user && typeof user.fullName === 'string' ? user.fullName.trim() : '';
  return n.slice(0, 80);
}

// ── core (runs against Firestore) ────────────────────────────────────────

async function generateCode(db, uid, nowMs, Timestamp) {
  const userSnap = await db.doc(`users/${uid}`).get();
  const user = userSnap.data();
  if (!user || user.role !== 'patient' || user.disabled) {
    throw new HttpsError('failed-precondition', 'not-patient');
  }
  const linked = (user.patient && user.patient.caregiverIds) || [];
  if (linked.length >= MAX_CAREGIVERS) {
    throw new HttpsError('failed-precondition', 'too-many-caregivers');
  }

  // one live code per patient: retire any earlier one
  const old = await db.collection('linkCodes')
    .where('patientId', '==', uid)
    .where('used', '==', false)
    .get();
  if (!old.empty) {
    const batch = db.batch();
    old.docs.forEach((d) => batch.update(d.ref, { used: true, retired: true }));
    await batch.commit();
  }

  for (let i = 0; i < 8; i++) {
    const code = newCode();
    const ref = db.doc(`linkCodes/${code}`);
    const ok = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const d = snap.data();
      if (d && !d.used && d.expiresAt.toMillis() > nowMs) return false; // taken
      tx.set(ref, {
        patientId: uid,
        createdAt: Timestamp.fromMillis(nowMs),
        expiresAt: Timestamp.fromMillis(nowMs + CODE_TTL_MS),
        used: false,
        attempts: 0
      });
      return true;
    });
    if (ok) return { code, expiresAt: nowMs + CODE_TTL_MS };
  }
  throw new HttpsError('unavailable', 'try-again');
}

async function redeemCode(db, uid, data, nowMs, { Timestamp, FieldValue }) {
  const code = data && data.code;
  if (!isCodeShape(code)) throw new HttpsError('invalid-argument', 'bad-code');
  const relation = cleanRelation(data && data.relation);

  const callerSnap = await db.doc(`users/${uid}`).get();
  const caller = callerSnap.data();
  if (!caller || caller.role !== 'caregiver' || caller.disabled) {
    throw new HttpsError('failed-precondition', 'not-caregiver');
  }

  const attemptRef = db.doc(`linkAttempts/${uid}`);
  const codeRef = db.doc(`linkCodes/${code}`);

  // The transaction returns an outcome instead of throwing, so the failed
  // attempt counter is committed even when the code is wrong.
  const outcome = await db.runTransaction(async (tx) => {
    const attemptSnap = await tx.get(attemptRef);
    const state = attemptState(attemptSnap.data(), nowMs);
    if (!state.allowed) return { error: ['resource-exhausted', 'too-many-attempts'] };

    const codeSnap = await tx.get(codeRef);
    const c = codeSnap.data();
    if (!c || c.used || c.expiresAt.toMillis() <= nowMs) {
      tx.set(attemptRef, state.onFailure);
      // one message for unknown, used and expired: no oracle
      return { error: ['not-found', 'invalid-code'] };
    }

    const patientId = c.patientId;
    const patientRef = db.doc(`users/${patientId}`);
    const linkRef = db.doc(`careLinks/${patientId}_${uid}`);
    const [patientSnap, linkSnap] = await Promise.all([tx.get(patientRef), tx.get(linkRef)]);
    const patient = patientSnap.data();
    if (!patient || patient.role !== 'patient' || patient.disabled) {
      return { error: ['not-found', 'invalid-code'] };
    }
    const link = linkSnap.data();
    if (link && link.status === 'active') {
      return { error: ['already-exists', 'already-linked'] };
    }
    const current = (patient.patient && patient.patient.caregiverIds) || [];
    if (current.length >= MAX_CAREGIVERS) {
      return { error: ['failed-precondition', 'too-many-caregivers'] };
    }

    const now = Timestamp.fromMillis(nowMs);
    tx.update(codeRef, { used: true, usedBy: uid, usedAt: now });
    tx.set(linkRef, {
      patientId,
      caregiverId: uid,
      patientName: displayName(patient),
      caregiverName: displayName(caller),
      relation,
      status: 'active',
      priority: current.length === 0 ? 1 : 2,
      createdAt: link ? link.createdAt : now,
      activatedAt: now,
      revokedAt: null
    });
    tx.update(patientRef, { 'patient.caregiverIds': FieldValue.arrayUnion(uid) });
    tx.update(db.doc(`users/${uid}`), { 'caregiver.patientIds': FieldValue.arrayUnion(patientId) });
    tx.delete(attemptRef);
    tx.create(db.collection('auditLog').doc(), {
      actorId: uid,
      actorRole: 'caregiver',
      action: 'link_created',
      targetType: 'careLinks',
      targetId: `${patientId}_${uid}`,
      at: now
    });
    return { patientId, patientName: displayName(patient) };
  });

  if (outcome.error) throw new HttpsError(outcome.error[0], outcome.error[1]);
  return outcome;
}

async function revokeLink(db, uid, data, nowMs, { Timestamp, FieldValue }) {
  const patientId = data && data.patientId;
  const caregiverId = data && data.caregiverId;
  if (typeof patientId !== 'string' || typeof caregiverId !== 'string'
      || !patientId || !caregiverId) {
    throw new HttpsError('invalid-argument', 'bad-ids');
  }
  if (uid !== patientId && uid !== caregiverId) {
    throw new HttpsError('permission-denied', 'not-a-party');
  }

  const linkRef = db.doc(`careLinks/${patientId}_${caregiverId}`);
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(linkRef);
    const link = snap.data();
    if (!link || link.status !== 'active') return { error: ['not-found', 'no-link'] };

    const now = Timestamp.fromMillis(nowMs);
    tx.update(linkRef, { status: 'revoked', revokedAt: now, revokedBy: uid });
    tx.update(db.doc(`users/${patientId}`),
      { 'patient.caregiverIds': FieldValue.arrayRemove(caregiverId) });
    tx.update(db.doc(`users/${caregiverId}`),
      { 'caregiver.patientIds': FieldValue.arrayRemove(patientId) });
    tx.create(db.collection('auditLog').doc(), {
      actorId: uid,
      actorRole: uid === patientId ? 'patient' : 'caregiver',
      action: 'link_revoked',
      targetType: 'careLinks',
      targetId: `${patientId}_${caregiverId}`,
      at: now
    });
    return { ok: true };
  });

  if (outcome.error) throw new HttpsError(outcome.error[0], outcome.error[1]);
  return outcome;
}

module.exports = {
  CODE_TTL_MS,
  MAX_CAREGIVERS,
  ATTEMPT_LIMIT,
  ATTEMPT_WINDOW_MS,
  RELATIONS,
  newCode,
  isCodeShape,
  cleanRelation,
  attemptState,
  displayName,
  generateCode,
  redeemCode,
  revokeLink
};
