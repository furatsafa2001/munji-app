const admin = require('firebase-admin');
const { setGlobalOptions } = require('firebase-functions/v2');
const { defineString } = require('firebase-functions/params');

// Every function runs in Dammam, next to the data. Firestore triggers must
// be in the database's region, and storage triggers in the bucket's.
setGlobalOptions({ region: 'me-central2', maxInstances: 10 });

if (!admin.apps.length) admin.initializeApp();

const ECG_BUCKET = defineString('ECG_BUCKET');

module.exports = {
  admin,
  db: admin.firestore(),
  storage: admin.storage(),
  FieldValue: admin.firestore.FieldValue,
  Timestamp: admin.firestore.Timestamp,
  ECG_BUCKET
};
