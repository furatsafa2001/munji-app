import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/device_config.dart';
import '../services/device_service.dart';
import '../services/real_device_service.dart';
import '../theme/munji_theme.dart';
import 'device_screen.dart';

/// The patient's home. Deliberately calm: one status card, three numbers,
/// and a way into the 30-second ECG capture.
///
/// What it does and does not claim:
///   * The status is about *monitoring*, not about the heart. "Normal"
///     is a diagnosis and needs the AI model (month 3); until then the card
///     says whether Munji is actually watching, and what to fix if not.
///   * The ECG line in the status card is decoration, not the patient's
///     trace. It carries no "live" label, and it goes flat whenever the
///     patch is not streaming, so it never suggests a heartbeat that is not
///     being monitored. The real ECG is the one-time capture.
///   * A heart rate older than 5 seconds is shown as "last reading, 2 min
///     ago", never as the current value.
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

enum _Signal { none, good, fair, poor }

enum _Status { monitoring, attention, connecting, offline }

class _HomeScreenState extends State<HomeScreen> {
  final MunjiDeviceService _service = MunjiDevice.instance;
  RealMunjiDeviceService? get _real =>
      _service is RealMunjiDeviceService ? _service : null;

  late DeviceState _state = _service.state;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _tick;

  double? _lastBpm;
  DateTime? _lastBeatAt;
  DateTime? _lastPacketAt;

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

    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());

    // Munji is meant to be connected at all times. After an app restart the
    // link is down, so bring it back without asking.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconnectIfIdle());
  }

  @override
  void dispose() {
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
    if (_leadsOff) return _Signal.poor;
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

  String _ago(DateTime at) {
    final s = DateTime.now().difference(at).inSeconds;
    if (s < 60) return t.secondsAgo(s);
    if (s < 3600) return t.minutesAgo(s ~/ 60);
    return t.hoursAgo(s ~/ 3600);
  }

  void _openDevice() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceScreen(isArabic: widget.isArabic),
    ));
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
          children: [
            _header(),
            const SizedBox(height: MunjiSpace.lg),
            _statusCard(),
            const SizedBox(height: MunjiSpace.md),
            _captureCard(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final greeting = DateTime.now().hour < 12 ? t.morning : t.evening;
    final name = widget.fullName.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MunjiSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting,
              style: MunjiText.body.copyWith(
                  color: MunjiColors.slate, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(name.isEmpty ? t.fallbackName : name, style: MunjiText.h1),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final status = _status;
    final (dot, title, sub) = switch (status) {
      _Status.monitoring => (MunjiColors.green, t.monitoring, t.monitoringSub),
      _Status.attention => (
          MunjiColors.orange,
          t.checkPatch,
          _leadsOff ? t.leadsOffSub : t.weakSignalSub,
        ),
      _Status.connecting => (MunjiColors.blue500, t.connecting, t.connectingSub),
      _Status.offline => (
          MunjiColors.muted,
          _state.phase == DevicePhase.bluetoothOff ? t.btOff : t.offline,
          _state.phase == DevicePhase.bluetoothOff ? t.btOffSub : t.offlineSub,
        ),
    };
    final canReconnect = status == _Status.offline &&
        _state.phase != DevicePhase.bluetoothOff;

    return Container(
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x1A00537A)),
        boxShadow: MunjiShadow.e1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── status ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.statusLabel,
                          style: MunjiText.label.copyWith(
                              color: MunjiColors.slate,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (status == _Status.connecting)
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: MunjiColors.blue500),
                            )
                          else
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                  color: dot, shape: BoxShape.circle),
                            ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(title,
                                style: MunjiText.h1.copyWith(fontSize: 28)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(sub,
                          style: MunjiText.body.copyWith(
                              color: MunjiColors.slate,
                              fontWeight: FontWeight.w500,
                              fontSize: 14)),
                      if (canReconnect) ...[
                        const SizedBox(height: MunjiSpace.sm),
                        OutlinedButton.icon(
                          onPressed: _service.connect,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(t.reconnect),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: MunjiColors.blue,
                            side: const BorderSide(color: MunjiColors.blue100),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(MunjiRadius.pill),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: MunjiSpace.sm),
                _HeartBadge(active: _connected),
              ],
            ),
          ),

          // ── decorative trace ──
          SizedBox(
            height: 96,
            child: CustomPaint(
              painter: _DecorTracePainter(
                flat: !_beatIsLive,
                color: _connected ? MunjiColors.blue500 : MunjiColors.muted,
              ),
            ),
          ),

          // ── numbers ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: MunjiColors.bg,
                borderRadius: BorderRadius.circular(MunjiRadius.r4),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(child: _hrStat()),
                    const _Divider(),
                    Expanded(child: _signalStat()),
                    const _Divider(),
                    Expanded(child: _batteryStat()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hrStat() {
    final live = _beatIsLive;
    final bpm = _lastBpm;
    final value = bpm == null ? '--' : bpm.round().toString();
    final label = live
        ? t.heartRate
        : (_lastBeatAt == null ? t.heartRate : _ago(_lastBeatAt!));
    return _Stat(
      icon: Icon(Icons.favorite_rounded,
          size: 24, color: live ? MunjiColors.blue500 : MunjiColors.muted),
      value: value,
      unit: 'BPM',
      label: label,
      dim: !live,
    );
  }

  Widget _signalStat() {
    final s = _signal;
    final (bars, color, text) = switch (s) {
      _Signal.good => (4, MunjiColors.blue500, t.good),
      _Signal.fair => (2, MunjiColors.orange, t.fair),
      _Signal.poor => (1, MunjiColors.orange, t.poor),
      _Signal.none => (0, MunjiColors.muted, '--'),
    };
    return _Stat(
      icon: _Bars(filled: bars, color: color),
      value: text,
      label: t.signal,
      dim: s == _Signal.none,
    );
  }

  Widget _batteryStat() {
    final b = _state.battery;
    final low = b != null && b <= 20;
    final icon = b == null
        ? Icons.battery_unknown_rounded
        : b > 80
            ? Icons.battery_full_rounded
            : b > 50
                ? Icons.battery_5_bar_rounded
                : b > 20
                    ? Icons.battery_3_bar_rounded
                    : Icons.battery_1_bar_rounded;
    return GestureDetector(
      onTap: _openDevice,
      behavior: HitTestBehavior.opaque,
      child: _Stat(
        icon: Transform.rotate(
          angle: math.pi / 2,
          child: Icon(icon,
              size: 26,
              color: b == null
                  ? MunjiColors.muted
                  : (low ? MunjiColors.orange : MunjiColors.green)),
        ),
        value: b == null ? '--' : '$b%',
        label: t.battery,
        dim: b == null,
      ),
    );
  }

  Widget _captureCard() {
    return Material(
      color: MunjiColors.surface,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: widget.onOpenCapture,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x1A00537A)),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: MunjiColors.blue50,
                  borderRadius: BorderRadius.circular(MunjiRadius.r3),
                ),
                child: const Icon(Icons.monitor_heart_outlined,
                    color: MunjiColors.blue, size: 26),
              ),
              const SizedBox(width: MunjiSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.captureTitle, style: MunjiText.h3),
                    const SizedBox(height: 3),
                    Text(t.captureSub,
                        style: MunjiText.body.copyWith(
                            color: MunjiColors.slate,
                            fontWeight: FontWeight.w500,
                            fontSize: 13.5)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: MunjiColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

// ── pieces ─────────────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    this.unit,
    this.dim = false,
  });

  final Widget icon;
  final String value;
  final String? unit;
  final String label;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 28, child: Center(child: icon)),
        const SizedBox(height: 6),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: dim ? MunjiColors.muted : MunjiColors.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(unit!,
                    style: MunjiText.small.copyWith(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MunjiText.small.copyWith(
                fontSize: 12.5,
                color: MunjiColors.slate,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const VerticalDivider(
        width: 1,
        thickness: 1,
        indent: 6,
        endIndent: 6,
        color: MunjiColors.line,
      );
}

class _Bars extends StatelessWidget {
  const _Bars({required this.filled, required this.color});

  final int filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 4,
              height: 7.0 + i * 5,
              decoration: BoxDecoration(
                color: i < filled
                    ? color
                    : MunjiColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (i < 3) const SizedBox(width: 3),
          ],
        ],
      ),
    );
  }
}

class _HeartBadge extends StatelessWidget {
  const _HeartBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [
          MunjiColors.blue50,
          MunjiColors.blue50.withValues(alpha: 0),
        ]),
      ),
      child: Opacity(
        opacity: active ? 0.55 : 0.25,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset('assets/images/heart.webp', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// A stylised ECG line with a faint grid behind it. Decoration only: the
/// shape is fixed, not the patient's signal. Flat when nothing is being
/// monitored.
class _DecorTracePainter extends CustomPainter {
  _DecorTracePainter({required this.flat, required this.color});

  final bool flat;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = MunjiColors.blue100.withValues(alpha: 0.5)
      ..strokeWidth = 0.6;
    const step = 14.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final mid = size.height * 0.55;
    final line = Paint()
      ..color = color.withValues(alpha: flat ? 0.45 : 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final path = Path()..moveTo(0, mid);
    if (flat) {
      path.lineTo(size.width, mid);
      canvas.drawPath(path, line);
      return;
    }

    // one P-QRS-T complex, repeated
    const beats = 5;
    final w = size.width / beats;
    final a = size.height * 0.42; // R height
    for (var i = 0; i < beats; i++) {
      final x0 = i * w;
      Offset p(double fx, double fy) => Offset(x0 + fx * w, mid - fy * a);
      path
        ..lineTo(p(0.10, 0).dx, mid)
        ..quadraticBezierTo(p(0.15, 0.18).dx, p(0.15, 0.18).dy,
            p(0.20, 0).dx, mid) // P
        ..lineTo(p(0.28, 0).dx, mid)
        ..lineTo(p(0.31, -0.12).dx, p(0.31, -0.12).dy) // Q
        ..lineTo(p(0.35, 1.0).dx, p(0.35, 1.0).dy) // R
        ..lineTo(p(0.39, -0.35).dx, p(0.39, -0.35).dy) // S
        ..lineTo(p(0.43, 0).dx, mid)
        ..lineTo(p(0.52, 0).dx, mid)
        ..quadraticBezierTo(p(0.60, 0.30).dx, p(0.60, 0.30).dy,
            p(0.68, 0).dx, mid) // T
        ..lineTo(x0 + w, mid);
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_DecorTracePainter old) =>
      old.flat != flat || old.color != color;
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

  String get heartRate => ar ? 'نبض القلب' : 'Heart rate';
  String get signal => ar ? 'الإشارة' : 'Signal';
  String get battery => ar ? 'البطارية' : 'Battery';
  String get good => ar ? 'جيدة' : 'Good';
  String get fair => ar ? 'متوسطة' : 'Fair';
  String get poor => ar ? 'ضعيفة' : 'Poor';

  String get captureTitle => ar ? 'تسجيل تخطيط القلب' : 'Record an ECG';
  String get captureSub =>
      ar ? 'تسجيل لمدة 30 ثانية يُحفظ في سجلك' : 'A 30-second recording saved to your history';

  String secondsAgo(int s) => ar ? 'قبل $s ث' : '${s}s ago';
  String minutesAgo(int m) => ar ? 'قبل $m د' : '${m}m ago';
  String hoursAgo(int h) => ar ? 'قبل $h س' : '${h}h ago';
}
