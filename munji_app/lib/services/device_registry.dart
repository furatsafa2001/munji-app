import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'device_config.dart';
import 'device_service.dart';
import 'real_device_service.dart';

/// Keeps `users/{patientId}/device/current` in step with the BLE link.
///
/// The caregiver reads this document and never sees the patient's phone, so
/// it is the only way they can tell "charging" from "detached" from "the
/// phone stopped reporting". One fixed document id means re-pairing
/// overwrites, so a patient can never have two devices.
///
/// Writes, matching firestore.rules:
///   * immediately when `connected` or `worn` changes
///   * every few seconds while connected (DeviceConfig.liveWriteEvery),
///     carrying the latest `hr`, which is what the caregiver's screens show
///     (HRV is not sent: the caregiver sees the HRV of the patient's latest
///     recording, like the patient does)
///   * at once when something the caregiver should know changes: a reading
///     appears or disappears, heart rate jumps, charging starts or stops,
///     battery drops to low
///   * every 5 minutes while not connected, so a stale `lastSeenAt` means
///     the phone itself has gone quiet
///   * always the whole document, with `lastSeenAt` as a server timestamp
///
/// `hr` is null whenever there is no fresh value: no beat in the last few
/// seconds. A caregiver must never see an old number presented as current.
class DeviceRegistry {
  DeviceRegistry({
    required MunjiDeviceService service,
    FirebaseFirestore? db,
    FirebaseAuth? auth,
  })  : _service = service,
        _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final MunjiDeviceService _service;
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  StreamSubscription<DeviceState>? _sub;
  StreamSubscription<LeadStatus>? _leadSub;
  StreamSubscription<HeartReading>? _heartSub;

  // what the caregiver last saw, to decide when to publish at once
  double? _lastHr;
  bool? _lastCharging;
  bool? _lastLowBattery;

  // one write at a time; changes during a write are sent right after it
  bool _writing = false;

  // false once the rules have refused the `stabilizing` field
  bool _rulesTakeStabilizing = true;
  bool? _lastStabilizing;
  bool _writeAgain = false;
  Timer? _gapTimer;
  Timer? _ticker;
  DateTime? _lastWriteAt;

  bool? _lastConnected;
  bool? _lastWorn;
  bool _paired = false;

  /// pairedAt and serial as stored, so an ordinary update keeps pairedAt
  /// unchanged (the rules reject anything else) and a new serial resets it.
  Timestamp? _pairedAt;
  String? _pairedSerial;
  bool _loaded = false;
  int? _lastBattery;

  static const Duration heartbeat = Duration(minutes: 5);

  /// `worn` older than this is reported as unknown. While measuring, the
  /// firmware re-sends the electrode status every 2 seconds, so a value
  /// this old means the patch is not measuring (charging or not connected).
  static const Duration wornValidFor = Duration(minutes: 5);

  bool get isRunning => _sub != null;

  /// Whether this patient has a patch on record (from Firestore or a
  /// pairing in this session).
  bool get isPaired => _paired;

  String? get _uid => _auth.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _ref(String uid) =>
      _db.collection('users').doc(uid).collection('device').doc('current');

  /// Start for a signed-in patient. Safe to call more than once.
  Future<void> start() async {
    if (isRunning) return;
    final uid = _uid;
    if (uid == null) return;

    await _loadStored(uid);

    _sub = _service.changes.listen(_onStateChange);
    final s = _service;
    if (s is RealMunjiDeviceService) {
      _leadSub = s.leadStream.listen((_) => _onWornMaybeChanged());
      _heartSub = s.heartStream.listen((_) => _onHeart());
    }
    _ticker = Timer.periodic(DeviceConfig.liveWriteEvery, (_) => _tick());

    // the link may already be up when the patient lands on the home screen
    await _onStateChange(_service.state);
  }

  void stop() {
    _sub?.cancel();
    _leadSub?.cancel();
    _heartSub?.cancel();
    _gapTimer?.cancel();
    _gapTimer = null;
    _ticker?.cancel();
    _sub = null;
    _leadSub = null;
    _heartSub = null;
    _lastHr = null;
    _lastCharging = null;
    _lastStabilizing = null;
    _lastLowBattery = null;
    _ticker = null;
    _lastWriteAt = null;
    _lastConnected = null;
    _lastWorn = null;
    _paired = false;
    _pairedAt = null;
    _pairedSerial = null;
    _loaded = false;
    _lastBattery = null;
  }

  Future<void> _loadStored(String uid) async {
    try {
      final snap = await _ref(uid).get();
      final d = snap.data();
      if (d != null) {
        _paired = d['status'] == 'paired';
        _pairedAt = d['pairedAt'] as Timestamp?;
        _pairedSerial = d['serial'] as String?;
      }
      _loaded = true;
    } on FirebaseException catch (e) {
      debugPrint('[registry] read failed: ${e.code}');
    }
  }

  /// Once a minute: publish while connected, otherwise only keep the
  /// 5-minute heartbeat going.
  void _tick() {
    if (!_paired) return;
    final connected = _service.state.phase == DevicePhase.connected;
    final last = _lastWriteAt;
    if (connected ||
        last == null ||
        DateTime.now().difference(last) >= heartbeat) {
      _write();
    }
  }

  Future<void> _onStateChange(DeviceState s) async {
    final connected = s.phase == DevicePhase.connected;
    if (connected && !_paired) _paired = true;
    if (!_paired) return;

    final low = s.battery == null ? null : s.battery! <= DeviceConfig.batteryLow;
    final changed = connected != _lastConnected ||
        s.charging != _lastCharging ||
        s.stabilizing != _lastStabilizing ||
        (low != null && low != _lastLowBattery);
    _lastConnected = connected;
    _lastCharging = s.charging;
    _lastStabilizing = s.stabilizing;
    if (low != null) _lastLowBattery = low;
    if (changed) await _write();
  }

  /// A new beat. Publish now if the caregiver would see a different
  /// picture: a reading appeared or went away, or the rate moved a lot.
  Future<void> _onHeart() async {
    if (!_paired) return;
    final hr = _hr();
    final last = _lastHr;
    final appeared = (hr == null) != (last == null);
    final jumped = hr != null && last != null && (hr - last).abs() >= DeviceConfig.hrJumpBpm;
    if (appeared || jumped) await _write();
  }

  Future<void> _onWornMaybeChanged() async {
    final worn = _worn();
    if (_paired && worn != _lastWorn) {
      _lastWorn = worn;
      await _write();
    }
  }

  /// Mark the device unpaired. The document is kept: which device a patient
  /// used, and when, is worth having.
  Future<void> markUnpaired() async {
    await _write(status: 'unpaired');
    _paired = false;
  }

  Future<void> _write({String status = 'paired'}) async {
    if (status != 'paired') {
      // unpairing is never merged into a routine update
      while (_writing) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _writing = true;
      try {
        await _writeNow(status);
      } finally {
        _writing = false;
      }
      return;
    }
    if (_writing) {
      _writeAgain = true;
      return;
    }
    final last = _lastWriteAt;
    if (last != null) {
      final wait = DeviceConfig.minWriteGap - DateTime.now().difference(last);
      if (wait > Duration.zero) {
        // too soon after the last one: send it as soon as the gap is up
        _gapTimer ??= Timer(wait, () {
          _gapTimer = null;
          _write();
        });
        return;
      }
    }
    _writing = true;
    try {
      await _writeNow(status);
    } finally {
      _writing = false;
    }
    if (_writeAgain) {
      _writeAgain = false;
      await Future<void>.delayed(DeviceConfig.minWriteGap);
      await _write();
    }
  }

  Future<void> _writeNow(String status) async {
    final uid = _uid;
    if (uid == null) return;
    if (!_loaded) await _loadStored(uid);

    final battery = _service.state.battery ?? _lastBattery;
    if (battery != null) _lastBattery = battery;
    if (battery == null) {
      // the rules require a battery value; the next heartbeat tries again
      debugPrint('[registry] battery not known yet, skipping');
      return;
    }

    final serial = _serial(uid);
    final samePairing = _pairedAt != null && _pairedSerial == serial;

    final doc = <String, dynamic>{
      'status': status,
      'serial': serial,
      'model': 'munji-v1',
      'firmware': _firmware(),
      'pairedAt': samePairing ? _pairedAt : FieldValue.serverTimestamp(),
      'connected': _service.state.phase == DevicePhase.connected,
      'charging': _service.state.charging,
      'worn': _worn(),
      'battery': battery.clamp(0, 100),
      'hr': _hr(),
      'lastSeenAt': FieldValue.serverTimestamp(),
    };
    // Newer field: only sent while the deployed rules accept it (see below).
    if (_rulesTakeStabilizing) {
      doc['stabilizing'] = _service.state.stabilizing == true;
    }

    try {
      try {
        await _ref(uid).set(doc);
      } on FirebaseException catch (e) {
        // Rules from before `stabilizing` existed reject the whole write.
        // Drop the field for this session rather than stop updating the
        // caregiver.
        if (e.code != 'permission-denied' || !doc.containsKey('stabilizing')) {
          rethrow;
        }
        _rulesTakeStabilizing = false;
        doc.remove('stabilizing');
        debugPrint('[registry] rules reject stabilizing, sending without it');
        await _ref(uid).set(doc);
      }
      _lastWriteAt = DateTime.now();
      _lastHr = doc['hr'] as double?;
      if (!samePairing) {
        // read back the server's pairedAt so later writes can repeat it
        final snap = await _ref(uid).get();
        _pairedAt = snap.data()?['pairedAt'] as Timestamp?;
        _pairedSerial = serial;
      }
    } on FirebaseException catch (e) {
      // permission-denied here means the document failed the shape check in
      // firestore.rules
      debugPrint('[registry] write failed: ${e.code}');
    }
  }

  // ── fields that need care ────────────────────────────────────────────────

  /// The firmware's serial (0x2A25, from the chip's MAC) is the only
  /// identifier that is the same on every phone. The BLE address is a weak
  /// fallback: on iOS it is a per-app identifier that can change on
  /// reinstall.
  String _serial(String uid) {
    final s = _service;
    if (s is RealMunjiDeviceService) {
      final fromFirmware = s.serialNumber;
      if (fromFirmware != null && fromFirmware.isNotEmpty) return fromFirmware;
      final addr = s.bleAddress;
      if (addr != null && addr.isNotEmpty) return addr;
    }
    return 'simulated-$uid';
  }

  /// Null until the firmware exposes 0x2A26. The rules cap it at 32 chars.
  String? _firmware() {
    final s = _service;
    if (s is RealMunjiDeviceService) {
      final f = s.firmwareVersion;
      if (f == null || f.isEmpty) return null;
      return f.length > 32 ? f.substring(0, 32) : f;
    }
    return 'simulated';
  }

  /// Latest heart rate, one decimal, or null when no beat is recent.
  double? _hr() {
    final s = _service;
    if (s is! RealMunjiDeviceService) return null;
    if (s.state.phase != DevicePhase.connected) return null;
    final bpm = s.heart?.bpm;
    if (bpm == null || bpm < 20 || bpm > 300) return null;
    return (bpm * 10).round() / 10;
  }

  /// True or false only from a recent lead check, otherwise null (unknown).
  bool? _worn() {
    final s = _service;
    if (s is! RealMunjiDeviceService) return null;
    final leads = s.leads;
    if (leads == null) return null;
    if (DateTime.now().difference(leads.receivedAt) > wornValidFor) return null;
    return leads.allAttached;
  }
}
