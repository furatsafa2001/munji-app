/**
 * MUNJI Cloud Functions. Everything runs in me-central1 (Doha) until CNTXT opens me-central2 (see src/admin.js).
 *
 *   onRecordingUploaded   storage finalize: validate .ecg, create its document
 *   onRecordingDeleted    storage delete: remove the document
 *   purgeRecordingsDaily  03:00 Riyadh: delete unsaved recordings after 90 days
 *   onHourlyCreated       firestore: rebuild the day's summary
 *   linkCodeGenerate      callable: patient gets a 6-digit link code
 *   linkCodeRedeem        callable: caregiver redeems it
 *   linkRevoke            callable: either side ends a link
 */

const recordings = require('./src/recordings');
const summaries = require('./src/summaries');
const linkCallables = require('./src/linkCallables');

exports.onRecordingUploaded = recordings.onRecordingUploaded;
exports.onRecordingDeleted = recordings.onRecordingDeleted;
exports.purgeRecordingsDaily = recordings.purgeRecordingsDaily;
exports.onHourlyCreated = summaries.onHourlyCreated;
exports.linkCodeGenerate = linkCallables.linkCodeGenerate;
exports.linkCodeRedeem = linkCallables.linkCodeRedeem;
exports.linkRevoke = linkCallables.linkRevoke;
