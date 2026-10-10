import 'dart:async';

import 'device_registry.dart';

/// MUNJI device connection.
///
/// The Munji device is meant to be connected at all times — it is worn, it
/// streams, and it stays paired. Pairing is a one-off event at sign-up; after
/// that the only reason the link breaks is a flat battery, the device being
/// taken off and switched off, the phone leaving range, or Bluetooth being
/// turned off on the phone.
///
/// So this service models a *link that is normally up*, not a wizard the user
/// runs. [DevicePhase.connected] is the resting state. Everything else is
/// either first-time setup or a recovery path back to connected.
enum DevicePhase {
  /// Bluetooth is off on the phone. Nothing can happen until it is on.
  bluetoothOff,

  /// Paired, but the device is not answering — flat battery, or switched off.
  /// This is the state the user actually has to do something about.
  offline,

  /// Not paired yet. Only reached once, at sign-up.
  idle,

  /// Looking for the device. Setup step 2.
  scanning,

  /// Device found and identified, waiting for the user to confirm. Setup step 3.
  found,

  /// Handshake in progress. Setup step 4, and also the auto-recovery path.
  connecting,

  /// Resting state — streaming live.
  connected,

  /// The link dropped but the device is presumed alive (out of range). Munji
  /// retries on its own; the user is told, not asked.
  reconnecting,
}

class DeviceState {
  const DeviceState({
    required this.phase,
    this.name = 'Munji Device',
    this.battery,
    this.signal = 3,
    this.lastSeen,
    this.paired = false,
  });

  final DevicePhase phase;
  final String name;

  /// 0–100, or null when the device has not reported yet.
  final int? battery;

  /// 0 none, 1 weak, 2 fair, 3 strong.
  final int signal;

  /// When the device last sent anything. Drives "updated 4s ago".
  final DateTime? lastSeen;

  final bool paired;

  bool get isLive => phase == DevicePhase.connected;

  /// True while Munji is doing the work itself and the user should just wait.
  bool get isBusy =>
      phase == DevicePhase.scanning ||
      phase == DevicePhase.connecting ||
      phase == DevicePhase.reconnecting;

  /// True when monitoring has actually stopped — the only states worth
  /// interrupting the user for.
  bool get needsAttention =>
      phase == DevicePhase.offline || phase == DevicePhase.bluetoothOff;

  DeviceState copyWith({
    DevicePhase? phase,
    String? name,
    int? battery,
    int? signal,
    DateTime? lastSeen,
    bool? paired,
  }) {
    return DeviceState(
      phase: phase ?? this.phase,
      name: name ?? this.name,
      battery: battery ?? this.battery,
      signal: signal ?? this.signal,
      lastSeen: lastSeen ?? this.lastSeen,
      paired: paired ?? this.paired,
    );
  }
}

/// What the UI is allowed to know about the device.
///
/// The screen talks to this and nothing else, so the day the firmware exists
/// the only thing that changes is which implementation is constructed in
/// [MunjiDevice.instance]. No screen code moves.
abstract class MunjiDeviceService {
  DeviceState get state;
  Stream<DeviceState> get changes;

  /// Setup step 1 → 2.
  Future<void> startScan();

  /// Setup step 3 → 4. Also the manual retry from [DevicePhase.offline].
  Future<void> connect();

  /// Drop the pairing entirely. Monitoring stops until a new device is paired.
  Future<void> forget();

  /// Re-check the phone's Bluetooth radio.
  Future<void> refresh();

  void dispose();
}

/// Stand-in used until the device firmware is ready.
///
/// It is deliberately not random: Safa should see the same thing every time
/// she opens the app. Drops only happen when [simulateDrop] or
/// [simulateBatteryDead] is called from the debug row.
class FakeMunjiDeviceService implements MunjiDeviceService {
  FakeMunjiDeviceService({bool alreadyPaired = false})
      : _state = alreadyPaired
            ? DeviceState(
                phase: DevicePhase.connected,
                battery: 85,
                signal: 3,
                lastSeen: DateTime.now(),
                paired: true,
              )
            : const DeviceState(phase: DevicePhase.idle) {
    if (alreadyPaired) _startBatteryDrain();
  }

  DeviceState _state;
  final _controller = StreamController<DeviceState>.broadcast();
  Timer? _step;
  Timer? _drain;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceState> get changes => _controller.stream;

  void _emit(DeviceState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  void _startBatteryDrain() {
    _drain?.cancel();
    // One point every 90s. Fast enough to see it move during a demo, slow
    // enough that it never looks broken.
    _drain = Timer.periodic(const Duration(seconds: 90), (_) {
      if (_state.phase != DevicePhase.connected) return;
      final b = (_state.battery ?? 85) - 1;
      if (b <= 0) {
        simulateBatteryDead();
      } else {
        _emit(_state.copyWith(battery: b, lastSeen: DateTime.now()));
      }
    });
  }

  @override
  Future<void> startScan() async {
    _step?.cancel();
    _emit(_state.copyWith(phase: DevicePhase.scanning));
    _step = Timer(const Duration(milliseconds: 2600), () {
      _emit(_state.copyWith(
        phase: DevicePhase.found,
        battery: 85,
        signal: 3,
      ));
    });
  }

  @override
  Future<void> connect() async {
    _step?.cancel();
    _emit(_state.copyWith(phase: DevicePhase.connecting));
    _step = Timer(const Duration(milliseconds: 1500), () {
      _emit(_state.copyWith(
        phase: DevicePhase.connected,
        battery: _state.battery ?? 85,
        signal: 3,
        lastSeen: DateTime.now(),
        paired: true,
      ));
      _startBatteryDrain();
    });
  }

  @override
  Future<void> forget() async {
    _step?.cancel();
    _drain?.cancel();
    _emit(const DeviceState(phase: DevicePhase.idle));
  }

  @override
  Future<void> refresh() async {
    if (_state.phase == DevicePhase.bluetoothOff) {
      _emit(_state.copyWith(
        phase: _state.paired ? DevicePhase.connecting : DevicePhase.idle,
      ));
      if (_state.paired) await connect();
    }
  }

  // ---- debug hooks, wired to the row that only shows in debug builds ----

  /// Out of range. Munji retries by itself and comes back.
  void simulateDrop() {
    _step?.cancel();
    _emit(_state.copyWith(phase: DevicePhase.reconnecting, signal: 0));
    _step = Timer(const Duration(seconds: 4), () {
      _emit(_state.copyWith(
        phase: DevicePhase.connected,
        signal: 3,
        lastSeen: DateTime.now(),
      ));
    });
  }

  /// Flat battery. Monitoring is genuinely stopped — no auto-recovery.
  void simulateBatteryDead() {
    _step?.cancel();
    _drain?.cancel();
    _emit(_state.copyWith(phase: DevicePhase.offline, battery: 0, signal: 0));
  }

  void simulateBluetoothOff() {
    _step?.cancel();
    _drain?.cancel();
    _emit(_state.copyWith(phase: DevicePhase.bluetoothOff, signal: 0));
  }

  @override
  void dispose() {
    _step?.cancel();
    _drain?.cancel();
    _controller.close();
  }
}

/// Single shared instance, so the dashboard header and this screen never
/// disagree about whether the device is up.
class MunjiDevice {
  MunjiDevice._();

  static MunjiDeviceService? _instance;
  static DeviceRegistry? _registry;

  static MunjiDeviceService get instance =>
      _instance ??= FakeMunjiDeviceService(alreadyPaired: false);

  /// Keeps devices/{uid} in step with the link. Created lazily so tests can
  /// construct the service without touching Firestore.
  static DeviceRegistry get registry =>
      _registry ??= DeviceRegistry(service: instance);

  /// Swap in the real BLE implementation here once the firmware exists.
  static void use(MunjiDeviceService service) {
    _instance?.dispose();
    _registry?.stop();
    _registry = null;
    _instance = service;
  }
}
