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
/// Every 5 seconds the current state is put in one of four buckets:
///   monitored      connected, electrodes on, ECG arriving
///   charging       on the charger: the patch stops the ECG on purpose
///   leadOff        an electrode is off, or the electrodes were just put on
///                  and the patch is holding the ECG back while contact
///                  settles (the 30 s stabilizing period)
///   disconnected   anything else
/// Average heart rate comes from every beat. Minimum and maximum come from
/// one-minute averages, so a single premature beat (whose short interval
/// reads as a very fast instantaneous rate) cannot become the hour's
/// maximum. HRV is not recorded here: the app shows HRV only from the
/// guided 30-second recordings, taken at rest.
///
/// A finished hour is written two minutes after it ends, because the rules
/// compare against the server clock and a phone running slightly fast would
/// otherwise be refused. Hours are create-only, so a second write of the
/// same hour is refused by the rules and ignored here.
///
/// Known limit: if the system kills the app despite the background
/// monitoring service, the hour in progress is lost.
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
      _heartSub = s.heartStream.listen((h) {
        final now = DateTime.now();
        _bucketFor(now).addBeat(h.bpm, at: now);
      });
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
    _flush(now);
  }

  HourState _classify(DateTime now) {
    final s = _service;
    if (s.state.phase != DevicePhase.connected) return HourState.disconnected;
    // Checked before the ECG: on the charger and while stabilizing the
    // patch sends no ECG by design, which is not a lost link.
    if (s.state.charging == true) return HourState.charging;
    if (s.state.stabilizing == true) return HourState.leadOff;
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

enum HourState { monitored, charging, leadOff, disconnected }

/// One hour of data, before it becomes a document. Pure, so it is tested
/// without Firebase (test/reports_test.dart).
class HourBucket {
  HourBucket(this.hourStart);

  /// Riyadh is UTC+3 all year, so an hour starts on the same instant in
  /// UTC and in Riyadh; only the key needs the offset.
  static DateTime hourStartOf(DateTime t) {
    final ms = t.toUtc().millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(ms - ms % (3600 * 1000), isUtc: true);
  }

  /// A minute needs at least this many beats before its average counts
  /// toward min and max. Engineering, not clinical: it drops minutes cut
  /// short by a reconnect or an electrode check, whose few beats would
  /// otherwise stand for the whole minute.
  static const minBeatsPerMinute = 10;

  final DateTime hourStart;

  int monitoredSec = 0;
  int chargingSec = 0;
  int leadOffSec = 0;
  int disconnectedSec = 0;

  double _hrSum = 0;
  int _hrCount = 0;

  /// Per minute of the hour (0-59): sum and count of beat rates, for the
  /// one-minute averages that min and max are read from.
  final _minuteSum = <int, double>{};
  final _minuteCount = <int, int>{};

  bool get isEmpty =>
      monitoredSec == 0 && chargingSec == 0 && leadOffSec == 0 && _hrCount == 0;

  /// yyyyMMddHH in Asia/Riyadh, which is what the rules check the id against.
  String get hourKey {
    final r = hourStart.add(const Duration(hours: 3));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${r.year}${two(r.month)}${two(r.day)}${two(r.hour)}';
  }

  void addSeconds(HourState s, int seconds) {
    // never more than an hour in total, whatever the timer does
    final room =
        3600 - (monitoredSec + chargingSec + leadOffSec + disconnectedSec);
    final n = math.min(seconds, math.max(0, room));
    switch (s) {
      case HourState.monitored:
        monitoredSec += n;
      case HourState.charging:
        chargingSec += n;
      case HourState.leadOff:
        leadOffSec += n;
      case HourState.disconnected:
        disconnectedSec += n;
    }
  }

  /// [at] places the beat in its minute. A beat without it, or outside
  /// this hour, counts toward the average only.
  void addBeat(double bpm, {DateTime? at}) {
    if (bpm < 20 || bpm > 300) return;
    _hrSum += bpm;
    _hrCount++;
    if (at == null) return;
    final offset = at.toUtc().difference(hourStart);
    if (offset.isNegative || offset >= const Duration(hours: 1)) return;
    final m = offset.inMinutes;
    _minuteSum[m] = (_minuteSum[m] ?? 0) + bpm;
    _minuteCount[m] = (_minuteCount[m] ?? 0) + 1;
  }

  /// One-minute average heart rates of the minutes with enough beats.
  List<double> get _minuteAverages => [
        for (final m in _minuteCount.keys)
          if (_minuteCount[m]! >= minBeatsPerMinute)
            _minuteSum[m]! / _minuteCount[m]!,
      ];

  double? get hrAvg => _hrCount == 0 ? null : _round1(_hrSum / _hrCount);

  double? get hrMin {
    final a = _minuteAverages;
    return a.isEmpty ? null : _round1(a.reduce(math.min));
  }

  double? get hrMax {
    final a = _minuteAverages;
    return a.isEmpty ? null : _round1(a.reduce(math.max));
  }

  static double _round1(double x) => (x * 10).round() / 10;

  /// Minutes are floored separately, so their sum can never pass 60.
  Map<String, dynamic> toDoc() => {
        'hourStart': Timestamp.fromDate(hourStart),
        'dayKey': hourKey.substring(0, 8),
        'hrAvg': hrAvg,
        'hrMin': hrMin,
        'hrMax': hrMax,
        'qualityPct': null,
        'monitoredMin': monitoredSec ~/ 60,
        'leadOffMin': leadOffSec ~/ 60,
        'chargingMin': chargingSec ~/ 60,
        'disconnectedMin': disconnectedSec ~/ 60,
        'expireAt': Timestamp.fromDate(hourStart.add(const Duration(days: 90))),
        'createdAt': FieldValue.serverTimestamp(),
      };
}
