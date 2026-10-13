import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'device_registry.dart';
import 'device_service.dart';
import 'real_device_service.dart';

/// Builds `users/{uid}/hourly/{yyyyMMddHH}` on the patient's phone.
///
/// This is what reports are made of: the server's `onHourlyCreated` folds
/// every hour of a day into `daily/{yyyyMMdd}`, and the reports screen reads
/// hours (short periods) or days (long ones).
///
/// Every 5 seconds the current state is put in one of three buckets:
///   monitored      connected, electrodes on, ECG arriving
///   leadOff        connected but an electrode is off
///   disconnected   anything else
/// (`chargingMin` stays 0: the firmware does not report charging yet.)
/// Heart rate comes from every beat; HRV is sampled every 5 seconds once it
/// has settled after a reconnect.
///
/// A finished hour is written two minutes after it ends, because the rules
/// compare against the server clock and a phone running slightly fast would
/// otherwise be refused. Hours are create-only, so a second write of the
/// same hour is refused by the rules and ignored here.
///
/// Known limit: if the app is killed, the hour in progress is lost. A
/// background service would fix that and comes with the alerting work.
class HourlyRecorder {
  HourlyRecorder({
    required MunjiDeviceService service,
    required DeviceRegistry registry,
    FirebaseFirestore? db,
    FirebaseAuth? auth,
  })  : _service = service,
        _registry = registry,
        _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final MunjiDeviceService _service;
  final DeviceRegistry _registry;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  static const _sampleEvery = Duration(seconds: 5);
  static const _writeDelay = Duration(minutes: 2);
  static const _hourMs = 3600 * 1000;

  Timer? _timer;
  StreamSubscription<HeartReading>? _heartSub;
  StreamSubscription<EcgPacket>? _ecgSub;
  DateTime? _lastPacketAt;

  HourBucket? _current;
  final _pending = <HourBucket>[];

  bool get isRunning => _timer != null;

  void start() {
    if (isRunning) return;
    final s = _service;
    if (s is RealMunjiDeviceService) {
      _heartSub = s.heartStream.listen((h) => _bucketFor(DateTime.now()).addBeat(h.bpm));
      _ecgSub = s.ecgStream.listen((p) => _lastPacketAt = p.receivedAt);
    }
    _timer = Timer.periodic(_sampleEvery, (_) => _sample());
  }

  void stop() {
    _timer?.cancel();
    _heartSub?.cancel();
    _ecgSub?.cancel();
    _timer = null;
    _heartSub = null;
    _ecgSub = null;
    _current = null;
    _pending.clear();
  }

  HourBucket _bucketFor(DateTime now) {
    final start = HourBucket.hourStartOf(now);
    final cur = _current;
    if (cur != null && cur.hourStart == start) return cur;
    if (cur != null) _pending.add(cur);
    return _current = HourBucket(start);
  }

  void _sample() {
    final now = DateTime.now();
    final bucket = _bucketFor(now);
    bucket.addSeconds(_classify(now), _sampleEvery.inSeconds);

    final s = _service;
    if (s is RealMunjiDeviceService) {
      final r = s.settledRmssd;
      if (r != null) bucket.addRmssd(r);
    }
    _flush(now);
  }

  HourState _classify(DateTime now) {
    final s = _service;
    if (s.state.phase != DevicePhase.connected) return HourState.disconnected;
    if (s is RealMunjiDeviceService) {
      final l = s.leads;
      if (l != null &&
          now.difference(l.receivedAt) < const Duration(seconds: 15) &&
          !l.allAttached) {
        return HourState.leadOff;
      }
      final p = _lastPacketAt;
      if (p == null || now.difference(p) > const Duration(seconds: 3)) {
        return HourState.disconnected;
      }
    }
    return HourState.monitored;
  }

  Future<void> _flush(DateTime now) async {
    if (_pending.isEmpty) return;
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final ready = _pending
        .where((b) => now.millisecondsSinceEpoch >=
            b.hourStart.millisecondsSinceEpoch + _hourMs + _writeDelay.inMilliseconds)
        .toList();
    for (final b in ready) {
      _pending.remove(b);
      // nothing to report for someone who has no patch
      if (!_registry.isPaired && b.isEmpty) continue;
      try {
        await _db
            .collection('users')
            .doc(uid)
            .collection('hourly')
            .doc(b.hourKey)
            .set(b.toDoc());
        debugPrint('[hourly] wrote ${b.hourKey}');
      } catch (e) {
        // already written by an earlier session, or offline (Firestore
        // queues it); either way nothing to retry here
        debugPrint('[hourly] ${b.hourKey} not written: $e');
      }
    }
  }
}

enum HourState { monitored, leadOff, disconnected }

/// One hour of data, before it becomes a document. Pure, so it is tested
/// without Firebase (test/hourly_bucket_test.dart).
class HourBucket {
  HourBucket(this.hourStart);

  /// Riyadh is UTC+3 all year, so an hour starts on the same instant in
  /// UTC and in Riyadh; only the key needs the offset.
  static DateTime hourStartOf(DateTime t) {
    final ms = t.toUtc().millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(ms - ms % (3600 * 1000), isUtc: true);
  }

  final DateTime hourStart;

  int monitoredSec = 0;
  int leadOffSec = 0;
  int disconnectedSec = 0;

  double _hrSum = 0;
  int _hrCount = 0;
  double? hrMin;
  double? hrMax;
  double _rmssdSum = 0;
  int _rmssdCount = 0;

  bool get isEmpty => monitoredSec == 0 && leadOffSec == 0 && _hrCount == 0;

  /// yyyyMMddHH in Asia/Riyadh, which is what the rules check the id against.
  String get hourKey {
    final r = hourStart.add(const Duration(hours: 3));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${r.year}${two(r.month)}${two(r.day)}${two(r.hour)}';
  }

  void addSeconds(HourState s, int seconds) {
    // never more than an hour in total, whatever the timer does
    final room = 3600 - (monitoredSec + leadOffSec + disconnectedSec);
    final n = math.min(seconds, math.max(0, room));
    switch (s) {
      case HourState.monitored:
        monitoredSec += n;
      case HourState.leadOff:
        leadOffSec += n;
      case HourState.disconnected:
        disconnectedSec += n;
    }
  }

  void addBeat(double bpm) {
    if (bpm < 20 || bpm > 300) return;
    _hrSum += bpm;
    _hrCount++;
    hrMin = hrMin == null ? bpm : math.min(hrMin!, bpm);
    hrMax = hrMax == null ? bpm : math.max(hrMax!, bpm);
  }

  void addRmssd(double ms) {
    if (ms <= 0 || ms > 2000) return;
    _rmssdSum += ms;
    _rmssdCount++;
  }

  double? get hrAvg => _hrCount == 0 ? null : _round1(_hrSum / _hrCount);
  double? get hrvAvg => _rmssdCount == 0 ? null : _round1(_rmssdSum / _rmssdCount);

  static double _round1(double x) => (x * 10).round() / 10;

  /// Minutes are floored separately, so their sum can never pass 60.
  Map<String, dynamic> toDoc() => {
        'hourStart': Timestamp.fromDate(hourStart),
        'dayKey': hourKey.substring(0, 8),
        'hrAvg': hrAvg,
        'hrMin': hrMin == null ? null : _round1(hrMin!),
        'hrMax': hrMax == null ? null : _round1(hrMax!),
        'hrvAvg': hrvAvg,
        'qualityPct': null,
        'monitoredMin': monitoredSec ~/ 60,
        'leadOffMin': leadOffSec ~/ 60,
        'chargingMin': 0,
        'disconnectedMin': disconnectedSec ~/ 60,
        'expireAt': Timestamp.fromDate(hourStart.add(const Duration(days: 90))),
        'createdAt': FieldValue.serverTimestamp(),
      };
}
