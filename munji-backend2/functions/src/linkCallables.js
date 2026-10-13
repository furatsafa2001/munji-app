const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');

const { db, Timestamp, FieldValue } = require('./admin');
const links = require('./links');

// Logs carry ids and reason codes only.

function callerUid(request) {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'sign-in');
  if (request.auth.token && request.auth.token.email_verified === false) {
    throw new HttpsError('failed-precondition', 'verify-email');
  }
  return uid;
}

const linkCodeGenerate = onCall(async (request) => {
  const uid = callerUid(request);
  const out = await links.generateCode(db, uid, Date.now(), Timestamp);
  logger.info('link code issued', { patientId: uid });
  return out;
});

const linkCodeRedeem = onCall(async (request) => {
  const uid = callerUid(request);
  try {
    const out = await links.redeemCode(db, uid, request.data, Date.now(), { Timestamp, FieldValue });
    logger.info('link created', { caregiverId: uid, patientId: out.patientId });
    return out;
  } catch (e) {
    if (e instanceof HttpsError) logger.info('link redeem refused', { caregiverId: uid, reason: e.message });
    throw e;
  }
});

const linkRevoke = onCall(async (request) => {
  const uid = callerUid(request);
  const out = await links.revokeLink(db, uid, request.data, Date.now(), { Timestamp, FieldValue });
  logger.info('link revoked', { by: uid });
  return out;
});

module.exports = { linkCodeGenerate, linkCodeRedeem, linkRevoke };
