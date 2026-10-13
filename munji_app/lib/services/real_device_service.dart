import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_config.dart';
import 'device_service.dart';

/// One ECG packet, unpacked.
class EcgPacket {
  const EcgPacket({
    required this.sequence,
    required this.samples,
    required this.receivedAt,
  });

  /// Firmware's counter. Gaps mean packets were dropped over the air.
  final int sequence;

  /// Signed 16-bit samples, oldest first.
  final List<int> samples;

  final DateTime receivedAt;
}

/// Which electrodes have lost skin contact. See [DeviceConfig] for the bits.
class LeadStatus {
  const LeadStatus({
    required this.flags,
    required this.receivedAt,
    this.raw = const [],
  });

  final int flags;
  final DateTime receivedAt;

  /// The whole packet as received, for the live readings screen.
  final List<int> raw;

  bool get pOff => (flags & DeviceConfig.leadOffP) != 0;
  bool get nOff => (flags & DeviceConfig.leadOffN) != 0;
  bool get refOff => (flags & DeviceConfig.leadOffRef) != 0;
  bool get allAttached =>
      (flags &
          (DeviceConfig.leadOffP |
              DeviceConfig.leadOffN |
              DeviceConfig.leadOffRef |
              DeviceConfig.leadOffAny)) ==
      0;
}

/// One beat's worth of heart data from the firmware.
class HeartReading {
  const HeartReading({
    required this.bpm,
    required this.rrMs,
    required this.rmssdMs,
    required this.receivedAt,
  });

  final double bpm;
  final int rrMs;

  /// Null until the firmware has seen enough beats (it sends 0 until then).
  final double? rmssdMs;

  final DateTime receivedAt;
}

/// Talks to the real Munji device over BLE.
class RealMunjiDeviceService implements MunjiDeviceService {
  RealMunjiDeviceService() {
    _watchAdapter();
  }

  DeviceState _state = const DeviceState(phase: DevicePhase.idle);
  final _controller = StreamController<DeviceState>.broadcast();

  /// Unpacked ECG packets.
  ///
  /// Nothing listens to this yet, and that is deliberate rather than
  /// forgotten: the inference service does not exist, and raw ECG is not
  /// stored — a single channel at 250 Hz is roughly 40 MB per patient per
  /// day, with no clinical value until something classifies it. When the
  /// inference endpoint lands, the window uploader subscribes here.
  final _ecg = StreamController<EcgPacket>.broadcast();
  Stream<EcgPacket> get ecgStream => _ecg.stream;

  final _leads = StreamController<LeadStatus>.broadcast();
  Stream<LeadStatus> get leadStream => _leads.stream;

  LeadStatus? _lastLeads;
  LeadStatus? get leads => _lastLeads;

  final _heart = StreamController<HeartReading>.broadcast();
  Stream<HeartReading> get heartStream => _heart.stream;

  HeartReading? _lastHeart;

  /// The latest reading, or null when none arrived within
  /// [DeviceConfig.heartStaleAfter]. Screens show "no reading" on null and
  /// never keep displaying an old value.
  HeartReading? get heart {
    final h = _lastHeart;
    if (h == null) return null;
    if (DateTime.now().difference(h.receivedAt) > DeviceConfig.heartStaleAfter) {
      return null;
    }
    return h;
  }

  /// Throttles lastSeen updates: packets arrive ~31 times a second and the
  /// state stream should not rebuild screens that often.
  DateTime _lastSeenEmit = DateTime.fromMillisecondsSinceEpoch(0);

  String? _serial;
  String? get serialNumber => _serial;

  /// Fallback identifier when the firmware reports no serial. Not equivalent:
  /// on iOS this is a per-app identifier assigned by the OS, not the device's
  /// real address, and it can change on reinstall.
  String? get bleAddress => _device?.remoteId.str;

  String? _firmware;
  String? get firmwareVersion => _firmware;

  int? _lastSequence;
  int _droppedPackets = 0;
  int get droppedPackets => _droppedPackets;

  int _packetsReceived = 0;
  int get packetsReceived => _packetsReceived;

  DateTime? _connectedAt;

  /// When the current link came up, or null while not connected. The
  /// firmware's RMSSD swings wildly for the first minute of a link (457 ms
  /// was seen in testing), so screens wait [DeviceConfig.hrvWarmUp] after
  /// this before showing it.
  DateTime? get connectedAt => _connectedAt;

  /// The firmware's RMSSD, or null while it is still settling or no beat
  /// is recent. The one place that decides whether HRV is fit to show.
  double? get settledRmssd {
    final at = _connectedAt;
    final h = heart;
    if (at == null || h == null) return null;
    if (DateTime.now().difference(at) < DeviceConfig.hrvWarmUp) return null;
    final r = h.rmssdMs;
    return (r == null || r <= 0) ? null : r;
  }

  DateTime? _batteryAt;

  /// When the battery level last arrived. Null until the first one.
  DateTime? get batteryUpdatedAt => _batteryAt;

  /// Zero the link counters. Used by the live readings screen so a test run
  /// starts from a clean count.
  void resetCounters() {
    _droppedPackets = 0;
    _packetsReceived = 0;
  }

  void _onBattery(List<int> v) {
    if (v.isEmpty) return;
    _batteryAt = DateTime.now();
    _emit(_state.copyWith(battery: v.first));
  }

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<int>>? _ecgSub;
  StreamSubscription<List<int>>? _batterySub;
  StreamSubscription<List<int>>? _leadSub;
  StreamSubscription<List<int>>? _heartSub;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceState> get changes => _controller.stream;

  void _emit(DeviceState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  // ── Permissions ──────────────────────────────────────────────────────────

  /// Android 12+ will not surface a single BLE result without these, and it
  /// fails silently: the scan returns nothing and the adapter reads as
  /// unavailable. flutter_blue_plus does not ask on our behalf, so this runs
  /// before anything that touches the radio: refresh, scan and connect.
  ///
  /// Returns false when the user declines. iOS asks by itself on first use.
  ///
  /// Android allows one permission request at a time and throws on a second
  /// one. refresh() and startScan() can both get here together, so callers
  /// share the request that is already open instead of starting another.
  Future<bool> _ensurePermissions() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(true);
    }
    return _permissionRequest ??=
        _requestPermissions().whenComplete(() => _permissionRequest = null);
  }

  Future<bool>? _permissionRequest;

  Future<bool> _requestPermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    final denied = results.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isEmpty) return true;

    for (final e in denied) {
      debugPrint('[ble] permission denied: ${e.key} → ${e.value}');
    }
    return false;
  }

  // ── Bluetooth radio ──────────────────────────────────────────────────────

  void _watchAdapter() {
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      debugPrint('[ble] adapter: $s');

      // On iOS the very first value is `unknown` — CoreBluetooth has not
      // finished starting up. Treating that as "Bluetooth is off" is what
      // put the setup screen into its "turn Bluetooth on" state before the
      // radio had a chance to report in.
      if (s == BluetoothAdapterState.unknown ||
          s == BluetoothAdapterState.turningOn) {
        return;
      }

      if (s == BluetoothAdapterState.on) {
        if (_state.phase == DevicePhase.bluetoothOff) {
          _emit(_state.copyWith(
            phase: _state.paired ? DevicePhase.connecting : DevicePhase.idle,
          ));
          if (_state.paired) connect();
        }
      } else {
        _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      }
    });
  }

  /// Wait for the radio to actually report a usable state.
  ///
  /// Returns true once it is on. Gives up after [timeout] so a genuinely
  /// disabled radio still surfaces to the user instead of hanging.
  Future<bool> _waitForAdapterOn({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final current = FlutterBluePlus.adapterStateNow;
    if (current == BluetoothAdapterState.on) return true;

    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(timeout);
      return true;
    } catch (_) {
      debugPrint('[ble] adapter never turned on');
      return false;
    }
  }

  @override
  Future<void> refresh() async {
    if (!await FlutterBluePlus.isSupported) {
      debugPrint('[ble] this phone has no Bluetooth');
      _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      return;
    }
    // Asked here too: on Android the adapter itself reads as unavailable
    // until the app holds these, so "turn on Bluetooth" would loop.
    if (!await _ensurePermissions()) {
      _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      return;
    }
    if (!await _waitForAdapterOn()) {
      _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      return;
    }
    if (_state.paired) {
      await connect();
    } else {
      _emit(_state.copyWith(phase: DevicePhase.idle));
    }
  }

  // ── Scanning ─────────────────────────────────────────────────────────────

  /// The scan in progress, if any. A second tap joins it instead of starting
  /// a new one: Android blocks an app that starts more than five scans in 30
  /// seconds, and the block is silent (onScannerRegistered status=6).
  Future<void>? _scanInFlight;

  @override
  Future<void> startScan() =>
      _scanInFlight ??= _scan().whenComplete(() => _scanInFlight = null);

  Future<void> _scan() async {
    if (!DeviceConfig.isConfigured) {
      debugPrint('[ble] DeviceConfig is empty');
      return;
    }

    if (!await _ensurePermissions()) {
      // Staying on idle keeps the button on screen, so declining once is
      // recoverable: the next tap asks again.
      _emit(_state.copyWith(phase: DevicePhase.idle));
      return;
    }

    if (!await _waitForAdapterOn()) {
      _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      return;
    }

    _emit(_state.copyWith(phase: DevicePhase.scanning));
    debugPrint('[ble] scanning for "${DeviceConfig.namePrefix}…"');

    var found = false;
    final foundSignal = Completer<void>();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        // advName is the name in the advertisement packet; platformName is
        // what the OS has cached. Either can be the one that is populated.
        final adv = r.advertisementData.advName;
        final name = adv.isNotEmpty ? adv : r.device.platformName;

        if (name.isEmpty) continue;
        debugPrint('[ble] saw "$name" rssi=${r.rssi}');

        if (!name.toUpperCase().startsWith(DeviceConfig.namePrefix)) continue;

        found = true;
        _device = r.device;
        if (!foundSignal.isCompleted) foundSignal.complete();
        FlutterBluePlus.stopScan();
        _emit(_state.copyWith(
          phase: DevicePhase.found,
          name: name,
          signal: _rssiToBars(r.rssi),
        ));
        return;
      }
    });

    try {
      // No `withServices` filter on purpose. The Munji firmware does not put
      // its service UUID in the advertisement packet — nRF Connect shows
      // "No Services found" until after connecting — and iOS only matches
      // service filters against what is actually advertised. Filtering here
      // would hide the device completely. We match on the name instead.
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      // startScan returns as soon as the radio starts scanning; the timeout
      // stops it later. Wait here for the device or for the scan to end, so
      // the screen stays on "searching" for the whole window instead of
      // bouncing back to the button straight away.
      final ended =
          FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
      await Future.any([foundSignal.future, ended])
          .timeout(const Duration(seconds: 20), onTimeout: () {});
    } catch (e) {
      debugPrint('[ble] scan failed: $e');
    }

    await _scanSub?.cancel();
    _scanSub = null;

    if (!found && _state.phase == DevicePhase.scanning) {
      debugPrint('[ble] no Munji device in range');
      _emit(_state.copyWith(
        phase: _state.paired ? DevicePhase.offline : DevicePhase.idle,
      ));
    }
  }

  int _rssiToBars(int rssi) {
    if (rssi >= -60) return 3;
    if (rssi >= -75) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }

  // ── Connecting ───────────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (!await _ensurePermissions()) return;

    final device = _device;
    if (device == null) {
      await startScan();
      if (_device == null) return;
      return connect();
    }

    _emit(_state.copyWith(phase: DevicePhase.connecting));

    try {
      await device.connect(
        timeout: const Duration(seconds: 20),
        license: License.nonprofit,
      );
      debugPrint('[ble] connected to ${device.platformName}');

      // A new link may restart the firmware's counter. Without this reset the
      // first packet after a reconnect reads as thousands of dropped ones.
      _lastSequence = null;

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          debugPrint('[ble] disconnected — retrying');
          _connectedAt = null;
          _emit(_state.copyWith(phase: DevicePhase.reconnecting));
          Future.delayed(const Duration(seconds: 3), () {
            if (_state.phase == DevicePhase.reconnecting) connect();
          });
        }
      });

      await _discoverAndSubscribe(device);

      _connectedAt = DateTime.now();
      _emit(_state.copyWith(
        phase: DevicePhase.connected,
        paired: true,
        lastSeen: DateTime.now(),
      ));
    } catch (e) {
      debugPrint('[ble] connect failed: $e');
      _emit(_state.copyWith(
        phase: _state.paired ? DevicePhase.offline : DevicePhase.idle,
      ));
    }
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    final services = await device.discoverServices();
    debugPrint('[ble] ${services.length} services');

    // Compare Guid objects rather than strings: the plugin normalises short
    // and long forms, so 0x2A19 and its 128-bit expansion compare equal.
    final ecgUuid = Guid(DeviceConfig.ecgCharacteristicUuid);
    final leadUuid = Guid(DeviceConfig.leadOffCharacteristicUuid);
    final batteryUuid = Guid(DeviceConfig.batteryCharacteristicUuid);
    final serialUuid = Guid(DeviceConfig.serialNumberCharacteristicUuid);
    final firmwareUuid = Guid(DeviceConfig.firmwareRevisionCharacteristicUuid);
    final heartUuid = Guid(DeviceConfig.heartCharacteristicUuid);

    for (final service in services) {
      for (final c in service.characteristics) {
        if (c.uuid == ecgUuid) {
          await c.setNotifyValue(true);
          await _ecgSub?.cancel();
          _ecgSub = c.lastValueStream.listen(_onEcgPacket);
          debugPrint('[ble] subscribed to ECG');
        } else if (c.uuid == leadUuid) {
          await c.setNotifyValue(true);
          await _leadSub?.cancel();
          _leadSub = c.lastValueStream.listen(_onLeadStatus);
          if (c.properties.read) {
            final v = await c.read();
            if (v.isNotEmpty) _onLeadStatus(v);
          }
          debugPrint('[ble] subscribed to lead-off');
        } else if (c.uuid == heartUuid) {
          await c.setNotifyValue(true);
          await _heartSub?.cancel();
          _heartSub = c.lastValueStream.listen(_onHeart);
          debugPrint('[ble] subscribed to heart');
        } else if (c.uuid == batteryUuid) {
          if (c.properties.read) {
            _onBattery(await c.read());
          }
          if (c.properties.notify) {
            await c.setNotifyValue(true);
            await _batterySub?.cancel();
            _batterySub = c.lastValueStream.listen(_onBattery);
          }
        } else if (c.uuid == serialUuid) {
          if (c.properties.read) {
            final v = await c.read();
            _serial = String.fromCharCodes(v).trim();
            debugPrint('[ble] serial: $_serial');
          }
        } else if (c.uuid == firmwareUuid) {
          if (c.properties.read) {
            final v = await c.read();
            _firmware = String.fromCharCodes(v).trim();
            debugPrint('[ble] firmware: $_firmware');
          }
        }
      }
    }
  }

  // ── Reading packets ──────────────────────────────────────────────────────

  /// Unpack one 18-byte ECG packet: uint16 sequence, then 8 int16 samples.
  void _onEcgPacket(List<int> bytes) {
    if (bytes.length < DeviceConfig.expectedPacketBytes) {
      debugPrint('[ble] short ECG packet: ${bytes.length} bytes');
      return;
    }

    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final endian = DeviceConfig.littleEndian ? Endian.little : Endian.big;

    final sequence = data.getUint16(0, endian);

    // Firmware counts up and wraps at 16 bits. A jump means the radio dropped
    // packets — worth surfacing, since gaps in an ECG matter clinically.
    if (_lastSequence != null) {
      final expected = (_lastSequence! + 1) & 0xFFFF;
      if (sequence != expected) {
        final gap = (sequence - expected) & 0xFFFF;
        _droppedPackets += gap;
        debugPrint('[ble] dropped $gap packet(s)');
      }
    }
    _lastSequence = sequence;
    _packetsReceived++;

    final samples = <int>[];
    for (var i = 0; i < DeviceConfig.samplesPerPacket; i++) {
      final offset =
          DeviceConfig.headerBytes + (i * DeviceConfig.bytesPerSample);
      samples.add(DeviceConfig.signedSamples
          ? data.getInt16(offset, endian)
          : data.getUint16(offset, endian));
    }

    if (!_ecg.isClosed) {
      _ecg.add(EcgPacket(
        sequence: sequence,
        samples: samples,
        receivedAt: DateTime.now(),
      ));
    }

    final now = DateTime.now();
    if (now.difference(_lastSeenEmit) >= const Duration(seconds: 1)) {
      _lastSeenEmit = now;
      _emit(_state.copyWith(lastSeen: now));
    }
  }

  /// Electrode contact. Byte 0 carries the flags; 1 means detached.
  void _onLeadStatus(List<int> bytes) {
    if (bytes.isEmpty) return;
    final status = LeadStatus(
      flags: bytes.first,
      receivedAt: DateTime.now(),
      raw: List.unmodifiable(bytes),
    );
    final changed = _lastLeads?.allAttached != status.allAttached;
    _lastLeads = status;
    if (!_leads.isClosed) _leads.add(status);
    if (changed) debugPrint('[ble] leads attached: ${status.allAttached}');
  }

  /// One beat: BPM x 10, RR ms, RMSSD x 10, all uint16 little-endian.
  void _onHeart(List<int> bytes) {
    if (bytes.length < DeviceConfig.heartPacketBytes) return;
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final bpm10 = data.getUint16(0, Endian.little);
    final rr = data.getUint16(2, Endian.little);
    final rmssd10 = data.getUint16(4, Endian.little);
    if (bpm10 == 0) return;

    final reading = HeartReading(
      bpm: bpm10 / 10,
      rrMs: rr,
      rmssdMs: rmssd10 == 0 ? null : rmssd10 / 10,
      receivedAt: DateTime.now(),
    );
    _lastHeart = reading;
    if (!_heart.isClosed) _heart.add(reading);
  }

  // ── Forgetting ───────────────────────────────────────────────────────────

  @override
  Future<void> forget() async {
    await _ecgSub?.cancel();
    await _batterySub?.cancel();
    await _leadSub?.cancel();
    await _heartSub?.cancel();
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _serial = null;
    _firmware = null;
    _lastSequence = null;
    _droppedPackets = 0;
    _packetsReceived = 0;
    _connectedAt = null;
    _batteryAt = null;
    _lastLeads = null;
    _lastHeart = null;
    _emit(const DeviceState(phase: DevicePhase.idle));
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _adapterSub?.cancel();
    _ecgSub?.cancel();
    _batterySub?.cancel();
    _leadSub?.cancel();
    _heartSub?.cancel();
    _controller.close();
    _ecg.close();
    _leads.close();
    _heart.close();
  }
}
