import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../services/device_config.dart';
import '../services/device_service.dart';
import '../services/history_data.dart';
import '../services/real_device_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/vitals.dart';
import 'device_screen.dart';

/// The patient's home (design v66): the heart with heart rate, ECG, HRV
/// and the device around it, the monitoring status under it, and a way
/// into the 30-second ECG capture. The caregiver's view of this patient is
/// built from the same widgets (widgets/vitals.dart).
///
/// What it does and does not claim:
///   * The status is about *monitoring*, not about the heart. "Normal"
///     is a diagnosis and needs the AI model (month 3); until then the card
///     says whether Munji is actually watching, and what to fix if not.
///   * The ECG tile shows when the last recording was made, never a rhythm.
///   * The ECG line in the status card is decoration, not the patient's
///     trace. It carries no "live" label, and it goes flat whenever the
///     patch is not streaming, so it never suggests a heartbeat that is not
///     being monitored. The real ECG is the one-time capture.
///   * A heart rate older than 5 seconds is shown as "last reading, 2 min
///     ago", never as the current value.
///   * HRV is never live. It comes from the latest guided 30-second
///     recording, taken at rest, with the time it was measured.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.isArabic,
    required this.fullName,
    required this.onOpenCapture,
  });

  final bool isArabic;
  final String fullName;

  /// Opens the 30-second ECG capture (the Monitor tab).
  final VoidCallback onOpenCapture;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _Signal { none, good, fair, poor, electrodeOff, charging, settling }

enum _Status { monitoring, attention, connecting, offline, charging, settling }

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final MunjiDeviceService _service = MunjiDevice.instance;
  RealMunjiDeviceService? get _real =>
      _service is RealMunjiDeviceService ? _service : null;

  late DeviceState _state = _service.state;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _tick;

  double? _lastBpm;
  DateTime? _lastBeatAt;
  DateTime? _lastPacketAt;

  /// The latest recording with an HRV value (see HistoryRepository.latestHrv).
  Recording? _hrvRec;

  /// (received, dropped) once a second for the last 10 seconds.
  final _linkWindow = ListQueue<(int, int)>();


  _T get t => _T(widget.isArabic);

  @override
  void initState() {
    super.initState();
    _subs.add(_service.changes.listen((s) {
      if (mounted) setState(() => _state = s);
    }));

    final real = _real;
    if (real != null) {
      _subs.add(real.heartStream.listen((h) {
        _lastBpm = h.bpm;
        _lastBeatAt = h.receivedAt;
        if (mounted) setState(() {});
      }));
      _subs.add(real.ecgStream.listen((p) => _lastPacketAt = p.receivedAt));
    }

    _subs.add(HistoryRepository().latestHrv().listen(
          (r) {
            if (mounted) setState(() => _hrvRec = r);
          },
          onError: (Object e) => debugPrint('[home] HRV not loaded: $e'),
        ));

    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());
    WidgetsBinding.instance.addObserver(this);

    // Munji is meant to be connected at all times. After an app restart the
    // link is down, so bring it back without asking.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconnectIfIdle());
  }

  /// Back from the phone's settings (Bluetooth turned on, permission
  /// granted) or from the background: check again without a tap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final p = _service.state.phase;
    if (p == DevicePhase.bluetoothOff) {
      _service.refresh();
    } else if (p == DevicePhase.idle || p == DevicePhase.offline) {
      _service.connect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    super.dispose();
  }

  void _reconnectIfIdle() {
    final p = _service.state.phase;
    if (p == DevicePhase.idle || p == DevicePhase.offline) _service.connect();
  }

  void _everySecond() {
    final real = _real;
    if (real != null) {
      _linkWindow.addLast((real.packetsReceived, real.droppedPackets));
      while (_linkWindow.length > 10) {
        _linkWindow.removeFirst();
      }
    }
    if (mounted) setState(() {});
  }

  // ── derived state ────────────────────────────────────────────────────────

  bool get _connected => _state.phase == DevicePhase.connected;

  bool get _beatIsLive =>
      _connected &&
      _lastBeatAt != null &&
      DateTime.now().difference(_lastBeatAt!) <= DeviceConfig.heartStaleAfter;

  bool get _leadsOff {
    final l = _real?.leads;
    if (l == null || !_connected) return false;
    if (DateTime.now().difference(l.receivedAt) > const Duration(seconds: 15)) {
      return false;
    }
    return !l.allAttached;
  }

  double? get _packetLoss {
    if (_linkWindow.length < 2) return null;
    final got = _linkWindow.last.$1 - _linkWindow.first.$1;
    final lost = _linkWindow.last.$2 - _linkWindow.first.$2;
    if (got + lost <= 0) return null;
    return lost / (got + lost);
  }

  /// Worked out from what can be measured today: electrode contact, data
  /// arriving, packet loss, beats being detected. The AI quality gate
  /// replaces this when it ships.
  _Signal get _signal {
    if (!_connected) return _Signal.none;
    // The firmware stops the ECG on the charger and while an electrode is
    // off. Neither is a weak signal: say what it is.
    if (_state.charging == true) return _Signal.charging;
    if (_leadsOff) return _Signal.electrodeOff;
    // electrodes on, the patch holds readings back for ~30 s on purpose
    if (_state.stabilizing == true) return _Signal.settling;
    final lp = _lastPacketAt;
    if (lp == null || DateTime.now().difference(lp).inSeconds > 2) {
      return _Signal.poor;
    }
    final loss = _packetLoss;
    if (loss != null && loss > 0.05) return _Signal.fair;
    if (!_beatIsLive) return _Signal.fair;
    return _Signal.good;
  }

  _Status get _status {
    switch (_state.phase) {
      case DevicePhase.connected:
        if (_state.charging == true) return _Status.charging;
        if (_state.stabilizing == true && !_leadsOff) return _Status.settling;
        return _signal == _Signal.good ? _Status.monitoring : _Status.attention;
      case DevicePhase.scanning:
      case DevicePhase.found:
      case DevicePhase.connecting:
      case DevicePhase.reconnecting:
        return _Status.connecting;
      case DevicePhase.idle:
      case DevicePhase.offline:
      case DevicePhase.bluetoothOff:
        return _Status.offline;
    }
  }

  void _openDevice() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceScreen(isArabic: widget.isArabic),
    ));
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
          children: [
            GreetingHeader(isArabic: ar, name: widget.fullName),
            const SizedBox(height: MunjiSpace.lg),
            _statusCard(),
            const SizedBox(height: MunjiSpace.md),
            _captureCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final status = _status;
    final (title, sub) = switch (status) {
      _Status.monitoring => (t.monitoring, t.monitoringSub),
      _Status.attention => (
          t.checkPatch,
          _leadsOff ? t.leadsOffSub : t.weakSignalSub,
        ),
      _Status.connecting => (t.connecting, t.connectingSub),
      _Status.charging => (t.charging, t.chargingSub),
      _Status.settling => (t.settling, t.settlingSub(_real?.stabilizeSecondsLeft)),
      _Status.offline => (
          _state.phase == DevicePhase.bluetoothOff ? t.btOff : t.offline,
          _state.phase == DevicePhase.bluetoothOff ? t.btOffSub : t.offlineSub,
        ),
    };
    final canReconnect = status == _Status.offline &&
        _state.phase != DevicePhase.bluetoothOff;
    final needsPermission = _state.phase == DevicePhase.bluetoothOff &&
        (_real?.permissionMissing ?? false);
    final blocked = needsPermission && (_real?.permissionBlocked ?? false);

    final ar = widget.isArabic;
    final live = _beatIsLive;
    final ecg = switch (_signal) {
      _Signal.good => EcgState.valid,
      _Signal.fair || _Signal.poor => EcgState.noisy,
      _Signal.electrodeOff => EcgState.electrodeOff,
      _Signal.settling => EcgState.settling,
      _Signal.charging || _Signal.none => EcgState.paused,
    };
    // Same four numbers, same order, as the caregiver's view of this patient.
    final stats = [
      hrStat(ar: ar, bpm: _lastBpm, live: live),
      hrvStat(ar: ar, rmssd: _hrvRec?.rmssd, measuredAt: _hrvRec?.startedAt),
      ecgStat(ar: ar, state: ecg),
      batteryStat(
          ar: ar,
          battery: _state.battery,
          charging: _state.charging,
          full: _state.batteryFull,
          onTap: _openDevice),
    ];

    if (needsPermission) {
      return StatusPanel(
        isArabic: widget.isArabic,
        stats: stats,
        status: MonitorStatus.offline,
        title: t.permissionTitle,
        subtitle: blocked ? t.permissionBlockedSub : t.permissionSub,
        action: Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: blocked ? openAppSettings : _service.refresh,
            child: Text(blocked ? t.openSettings : t.allowAccess),
          ),
        ),
      );
    }

    return StatusPanel(
      isArabic: widget.isArabic,
      stats: stats,
      status: switch (status) {
        _Status.monitoring => MonitorStatus.live,
        _Status.attention => MonitorStatus.attention,
        _Status.connecting => MonitorStatus.connecting,
        _Status.offline => MonitorStatus.offline,
        _Status.charging => MonitorStatus.charging,
        _Status.settling => MonitorStatus.stabilizing,
      },
      title: title,
      subtitle: sub,
      action: canReconnect
          ? Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _service.connect,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(t.reconnect),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MunjiColors.blue,
                  side: const BorderSide(color: MunjiColors.blue100),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(MunjiRadius.pill),
                  ),
                ),
              ),
            )
          : null,
    );
  }

  Widget _captureCard() => ActionCard(
        icon: Icons.monitor_heart_outlined,
        title: t.captureTitle,
        subtitle: t.captureSub,
        onTap: widget.onOpenCapture,
      );
}

// ── strings ────────────────────────────────────────────────────────────────

class _T {
  const _T(this.ar);
  final bool ar;

  String get morning => ar ? 'صباح الخير،' : 'Good morning,';
  String get evening => ar ? 'مساء الخير،' : 'Good evening,';
  String get fallbackName => ar ? 'أهلًا' : 'Welcome';

  String get statusLabel => ar ? 'حالة المراقبة' : 'Monitoring';
  String get monitoring => ar ? 'المراقبة مستمرة' : 'Monitoring';
  String get monitoringSub =>
      ar ? 'اللاصقة تعمل والإشارة جيدة' : 'The patch is working and the signal is good';
  String get checkPatch => ar ? 'تحقق من اللاصقة' : 'Check the patch';
  String get leadsOffSub => ar
      ? 'أحد الأقطاب غير ملامس للجلد، اضغط على اللاصقة'
      : 'An electrode is not touching the skin, press the patch down';
  String get weakSignalSub =>
      ar ? 'الإشارة ضعيفة، ابقَ ثابتًا قليلًا' : 'The signal is weak, stay still for a moment';
  String get connecting => ar ? 'جارٍ الاتصال' : 'Connecting';
  String get connectingSub =>
      ar ? 'نبحث عن اللاصقة ونتصل بها' : 'Looking for the patch and connecting';
  String get offline => ar ? 'غير متصل' : 'Not connected';
  String get offlineSub => ar
      ? 'تأكد أن اللاصقة مشحونة وقريبة منك'
      : 'Check the patch is charged and nearby';
  String get btOff => ar ? 'البلوتوث مقفل' : 'Bluetooth is off';
  String get btOffSub =>
      ar ? 'شغّله ليتصل منجي باللاصقة' : 'Turn it on so Munji can reach the patch';
  String get reconnect => ar ? 'إعادة الاتصال' : 'Reconnect';
  String get permissionTitle => ar ? 'الإذن مطلوب' : 'Permission needed';
  String get permissionSub => ar
      ? 'منجي يحتاج إذن الأجهزة القريبة ليصل إلى اللاصقة'
      : 'Munji needs Nearby devices access to reach the patch';
  String get permissionBlockedSub => ar
      ? 'فعّل إذن الأجهزة القريبة من إعدادات الجوال ثم ارجع'
      : 'Allow Nearby devices in your phone settings, then come back';
  String get allowAccess => ar ? 'السماح بالوصول' : 'Allow access';
  String get openSettings => ar ? 'فتح الإعدادات' : 'Open settings';

  String get heartRate => ar ? 'نبض القلب' : 'Heart rate';
  String get signal => ar ? 'الإشارة' : 'Signal';
  String get battery => ar ? 'البطارية' : 'Battery';
  String get good => ar ? 'جيدة' : 'Good';
  String get fair => ar ? 'متوسطة' : 'Fair';
  String get poor => ar ? 'ضعيفة' : 'Poor';
  String get electrodeOff => ar ? 'قطب مفصول' : 'Electrode off';
  String get settlingShort => ar ? 'تستقر' : 'Settling';
  String get settling => ar ? 'اللاصقة تستقر' : 'Patch settling';
  String settlingSub(int? left) => left == null
      ? (ar ? 'تبدأ القراءات خلال ثوانٍ. ابقَ ثابتًا.' : 'Readings start in a few seconds. Stay still.')
      : (ar
          ? 'تبدأ القراءات خلال $left ثانية تقريبًا. ابقَ ثابتًا.'
          : 'Readings start in about $left s. Stay still.');
  String get charging => ar ? 'الجهاز يشحن' : 'Charging';
  String get chargingSub => ar
      ? 'المراقبة متوقفة أثناء الشحن، وتعود بعد فصل الشاحن ولبس اللاصقة'
      : 'Monitoring pauses while charging and resumes once unplugged and worn';

  String get captureTitle => ar ? 'تسجيل تخطيط القلب' : 'Record an ECG';
  String get captureSub =>
      ar ? 'تسجيل لمدة 30 ثانية يُحفظ في سجلك' : 'A 30-second recording saved to your history';

  String secondsAgo(int s) => ar ? 'قبل $s ث' : '${s}s ago';
  String minutesAgo(int m) => ar ? 'قبل $m د' : '${m}m ago';
  String hoursAgo(int h) => ar ? 'قبل $h س' : '${h}h ago';
}
