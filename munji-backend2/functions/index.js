/**
 * MUNJI Cloud Functions. Everything runs in me-central2 (see src/admin.js).
 *
 *   onRecordingUploaded   storage finalize: validate .ecg, create its document
 *   onRecordingDeleted    storage delete: remove the document
 *   purgeRecordingsDaily  03:00 Riyadh: delete unsaved recordings after 90 days
 *   onHourlyCreated       firestore: rebuild the day's summary
 */

const recordings = require('./src/recordings');
const summaries = require('./src/summaries');

exports.onRecordingUploaded = recordings.onRecordingUploaded;
exports.onRecordingDeleted = recordings.onRecordingDeleted;
exports.purgeRecordingsDaily = recordings.purgeRecordingsDaily;
exports.onHourlyCreated = summaries.onHourlyCreated;
