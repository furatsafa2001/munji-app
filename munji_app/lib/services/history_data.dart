import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'ecg_capture.dart';
import 'report_data.dart';

/// One saved 30-second recording, as `onRecordingUploaded` wrote it.
class Recording {
  const Recording({
    required this.id,
    required this.startedAt,
    required this.durationSec,
    required this.storagePath,
    required this.avgHr,
    this.rmssd,
    required this.saved,
    required this.kind,
    required this.deviceSerial,
  });

  factory Recording.fromDoc(String id, Map<String, dynamic> d) => Recording(
        id: id,
        startedAt: (d['startedAt'] as Timestamp).toDate(),
        durationSec: (d['durationSec'] as num?)?.toInt() ?? 30,
        storagePath: d['storagePath'] as String,
        avgHr: (d['avgHr'] as num?)?.toDouble(),
        rmssd: (d['rmssd'] as num?)?.toDouble(),
        saved: d['saved'] == true,
        kind: (d['kind'] as String?) ?? 'manual',
        deviceSerial: d['deviceSerial'] as String?,
      );

  final String id;
  final DateTime startedAt;
  final int durationSec;
  final String storagePath;
  final double? avgHr;

  /// HRV (RMSSD, ms) over this recording. Null for recordings made before
  /// it was captured, or with too few beats.
  final double? rmssd;

  /// Kept past the 90-day retention.
  final bool saved;

  /// 'manual' (the patient pressed record) or 'event' (month 3, alerts).
  final String kind;
  final String? deviceSerial;
}

/// Reads and manages the patient's recordings.
///
/// Rules allow the patient to change only `saved`. Deleting goes through
/// the file: the patient deletes the .ecg and `onRecordingDeleted` removes
/// the document, so a record never outlives its data.
class HistoryRepository {
  HistoryRepository({FirebaseFirestore? db, FirebaseStorage? storage, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;

  /// A file is 15 KB; anything near this cap is not one of ours.
  static const _maxBytes = 64 * 1024;

  String get _uid => _auth.currentUser!.uid;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('recordings');

  /// Newest first, within [period].
  Stream<List<Recording>> watch(ReportPeriod period, {String? uid}) => _col(uid ?? _uid)
      .where('startedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(period.startInstant))
      .where('startedAt', isLessThan: Timestamp.fromDate(period.endInstant))
      .orderBy('startedAt', descending: true)
      .snapshots()
      .map((s) => s.docs.map((d) => Recording.fromDoc(d.id, d.data())).toList());

  /// The latest few, for the Monitor tab, or for a linked patient when
  /// [uid] is given (the rules let a linked caregiver read them).
  Stream<List<Recording>> latest({int limit = 3, String? uid}) => _col(uid ?? _uid)
      .orderBy('startedAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((s) => s.docs.map((d) => Recording.fromDoc(d.id, d.data())).toList());

  /// The latest manual recording that has an HRV value, or null. This is
  /// the HRV the home screens show: measured at rest during a guided
  /// recording, never the continuous reading. Looks at the last few
  /// recordings, since one with too few clean beats has no value.
  Stream<Recording?> latestHrv({String? uid}) =>
      latest(limit: 10, uid: uid).map(latestWithHrv);

  /// First recording, newest first, that is manual and has an HRV value.
  static Recording? latestWithHrv(List<Recording> newestFirst) {
    for (final r in newestFirst) {
      if (r.kind == 'manual' && r.rmssd != null) return r;
    }
    return null;
  }

  Future<EcgRecordingData> load(Recording r) async {
    final bytes = await _storage.ref(r.storagePath).getData(_maxBytes);
    final data = bytes == null ? null : EcgRecordingData.parse(bytes);
    if (data == null) throw const FormatException('not a recording');
    return data;
  }

  Future<void> setSaved(Recording r, bool saved) =>
      _col(_uid).doc(r.id).update({'saved': saved});

  Future<void> delete(Recording r) => _storage.ref(r.storagePath).delete();
}
