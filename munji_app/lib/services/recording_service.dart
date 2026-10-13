import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'ecg_capture.dart';

/// Uploads a finished capture and waits for the server to accept it.
///
/// The app writes only the file. The `onRecordingUploaded` function reads
/// it back, checks header, sample count and size, and only then creates
/// `users/{uid}/recordings/{id}`. A file it rejects is deleted. So the
/// recording counts as saved when that document appears, not when the
/// upload finishes.
///
/// The bucket is in me-central2 (Dammam), so recordings stay in the
/// Kingdom. Until CNTXT billing is active it exists only in the emulator.
class RecordingService {
  RecordingService({FirebaseStorage? storage, FirebaseFirestore? db, FirebaseAuth? auth})
      : _storage = storage ?? FirebaseStorage.instance,
        _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseStorage _storage;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// How long to wait for the server check before calling it saved anyway.
  static const confirmTimeout = Duration(seconds: 30);

  /// 20 characters from [A-Za-z0-9], as the storage rules require.
  static String newId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(20, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Uploads [bytes] as recording [id]. Returns normally when the server has
  /// accepted it (or is still checking it after [confirmTimeout]); throws
  /// [RecordingException] otherwise. Safe to call again with the same id.
  Future<RecordingResult> upload({
    required String id,
    required Uint8List bytes,
    double? avgHr,
    String? deviceSerial,
    String? firmware,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw const RecordingException(CaptureFailure.uploadFailed);

    final ref = _storage.ref('patients/$uid/recordings/$id.ecg');
    final doc = _db.doc('users/$uid/recordings/$id');

    final meta = SettableMetadata(
      contentType: 'application/octet-stream',
      customMetadata: {
        'kind': 'manual',
        if (avgHr != null) 'avgHr': avgHr.round().toString(),
        if (deviceSerial != null) 'deviceSerial': deviceSerial,
        if (firmware != null) 'firmware': firmware,
      },
    );

    try {
      await ref.putData(bytes, meta);
    } on FirebaseException catch (e) {
      debugPrint('[rec] upload failed: ${e.code}');
      throw RecordingException(_isMissingStorage(e.code)
          ? CaptureFailure.storageUnavailable
          : CaptureFailure.uploadFailed);
    }

    // wait for the server's check to create the document
    try {
      await doc
          .snapshots()
          .firstWhere((s) => s.exists)
          .timeout(confirmTimeout);
      return RecordingResult.saved;
    } on TimeoutException {
      // either still being checked, or rejected and deleted
      try {
        await ref.getMetadata();
        return RecordingResult.stillChecking;
      } on FirebaseException catch (e) {
        if (e.code == 'object-not-found') {
          throw const RecordingException(CaptureFailure.rejected);
        }
        return RecordingResult.stillChecking;
      }
    }
  }

  static bool _isMissingStorage(String code) =>
      code == 'bucket-not-found' ||
      code == 'project-not-found' ||
      code == 'unknown' ||
      code == 'no-default-bucket';
}

enum RecordingResult {
  /// The server accepted the file and created its record.
  saved,

  /// Uploaded, but the server check had not finished in time. It will
  /// appear in the history once it does.
  stillChecking,
}

class RecordingException implements Exception {
  const RecordingException(this.failure);
  final CaptureFailure failure;
}
