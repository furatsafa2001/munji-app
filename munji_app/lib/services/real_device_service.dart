import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

/// Which electrodes have lost skin contact.
class LeadStatus {
  const LeadStatus({required this.raw, required this.allAttached});
  final int raw;
  final bool allAttached;
}

/// Talks to the real Munji device over BLE.
class RealMunjiDeviceService implements MunjiDeviceService {
  RealMunjiDeviceService() {
    _watchAdapter();
  }

  DeviceState _state = const DeviceState(phase: DevicePhase.idle);
  final _controller = StreamController<DeviceState>.broadcast();

  final _ecg = StreamController<EcgPacket>.broadcast();
  Stream<EcgPacket> get ecgStream => _ecg.stream;

  final _leads = StreamController<LeadStatus>.broadcast();
  Stream<LeadStatus> get leadStream => _leads.stream;

  LeadStatus? _lastLeads;
  LeadStatus? get leads => _lastLeads;

  String? _serial;
  String? get serialNumber => _serial;

  int? _lastSequence;
  int _droppedPackets = 0;
  int get droppedPackets => _droppedPackets;

  BluetoothDevice? _device;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<int>>? _ecgSub;
  StreamSubscription<List<int>>? _batterySub;
  StreamSubscription<List<int>>? _leadSub;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceState> get changes => _controller.stream;

  void _emit(DeviceState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
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

  @override
  Future<void> startScan() async {
    if (!DeviceConfig.isConfigured) {
      debugPrint('[ble] DeviceConfig is empty');
      return;
    }

    if (!await _waitForAdapterOn()) {
      _emit(_state.copyWith(phase: DevicePhase.bluetoothOff));
      return;
    }

    _emit(_state.copyWith(phase: DevicePhase.scanning));
    debugPrint('[ble] scanning for "${DeviceConfig.namePrefix}…"');

    var found = false;

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
    } catch (e) {
      debugPrint('[ble] scan failed: $e');
    }

    // startScan returns when the timeout elapses.
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

      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          debugPrint('[ble] disconnected — retrying');
          _emit(_state.copyWith(phase: DevicePhase.reconnecting));
          Future.delayed(const Duration(seconds: 3), () {
            if (_state.phase == DevicePhase.reconnecting) connect();
          });
        }
      });

      await _discoverAndSubscribe(device);

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
        } else if (c.uuid == batteryUuid) {
          if (c.properties.read) {
            final v = await c.read();
            if (v.isNotEmpty) _emit(_state.copyWith(battery: v.first));
          }
          if (c.properties.notify) {
            await c.setNotifyValue(true);
            await _batterySub?.cancel();
            _batterySub = c.lastValueStream.listen((v) {
              if (v.isNotEmpty) _emit(_state.copyWith(battery: v.first));
            });
          }
        } else if (c.uuid == serialUuid) {
          if (c.properties.read) {
            final v = await c.read();
            _serial = String.fromCharCodes(v).trim();
            debugPrint('[ble] serial: $_serial');
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

    _emit(_state.copyWith(lastSeen: DateTime.now()));
  }

  /// Electrode contact. A non-zero byte means at least one lead is off.
  void _onLeadStatus(List<int> bytes) {
    if (bytes.isEmpty) return;
    final raw = bytes.first;
    final status = LeadStatus(raw: raw, allAttached: raw == 0);
    _lastLeads = status;
    if (!_leads.isClosed) _leads.add(status);
    debugPrint('[ble] leads attached: ${status.allAttached}');
  }

  // ── Forgetting ───────────────────────────────────────────────────────────

  @override
  Future<void> forget() async {
    await _ecgSub?.cancel();
    await _batterySub?.cancel();
    await _leadSub?.cancel();
    await _connSub?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _serial = null;
    _lastSequence = null;
    _droppedPackets = 0;
    _lastLeads = null;
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
    _controller.close();
    _ecg.close();
    _leads.close();
  }
}
