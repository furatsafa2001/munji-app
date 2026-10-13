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
///   * every minute while connected, carrying the latest `hr` and `rmssd`,
///     which is what the caregiver's home screen shows
///   * every 5 minutes while not connected, so a stale `lastSeenAt` means
///     the phone itself has gone quiet
///   * always the whole document, with `lastSeenAt` as a server timestamp
///
/// `hr` and `rmssd` are null whenever there is no fresh value: no beat in
/// the last few seconds, or HRV still settling after a reconnect. A
/// caregiver must never see an old number presented as current.
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

  /// `worn` older than this is reported as unknown. The current firmware
  /// only checks electrodes between measurement cycles.
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
    }
    _ticker = Timer.periodic(DeviceConfig.liveWriteEvery, (_) => _tick());

    // the link may already be up when the patient lands on the home screen
    await _onStateChange(_service.state);
  }

  void stop() {
    _sub?.cancel();
    _leadSub?.cancel();
    _ticker?.cancel();
    _sub = null;
    _leadSub = null;
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

    if (connected != _lastConnected) {
      _lastConnected = connected;
      await _write();
    }
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
      'charging': null, // firmware does not report it yet
      'worn': _worn(),
      'battery': battery.clamp(0, 100),
      'hr': _hr(),
      'rmssd': _rmssd(),
      'lastSeenAt': FieldValue.serverTimestamp(),
    };

    try {
      await _ref(uid).set(doc);
      _lastWriteAt = DateTime.now();
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

  /// RMSSD once it has settled, one decimal, otherwise null.
  double? _rmssd() {
    final s = _service;
    if (s is! RealMunjiDeviceService) return null;
    if (s.state.phase != DevicePhase.connected) return null;
    final r = s.settledRmssd;
    if (r == null || r > 1000) return null;
    return (r * 10).round() / 10;
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
