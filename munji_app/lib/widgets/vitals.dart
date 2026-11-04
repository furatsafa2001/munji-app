import 'package:flutter/material.dart';

import '../theme/munji_theme.dart';

/// The pieces the patient's home and the caregiver's view of a patient are
/// both built from, so the two always look the same and show the same
/// numbers in the same places: monitoring status, then heart rate, HRV,
/// signal and battery.
///
/// None of this decides anything medical. Every status here is about
/// monitoring (is the patch working, are readings arriving), never about
/// the heart itself. A rhythm label needs the AI model and is not shown.

// ── monitoring status ──────────────────────────────────────────────────────

enum MonitorStatus {
  /// Connected, electrodes on, readings arriving.
  live,

  /// Connected but something needs fixing (electrode, weak signal).
  attention,

  /// Finding or reconnecting to the patch.
  connecting,

  /// The patch is not connected.
  offline,

  /// Caregiver only: the patient's phone has gone quiet.
  noData,

  /// Caregiver only: no patch paired yet.
  noDevice,

  /// On the charger. The patch does not measure while charging.
  charging,

  /// Electrodes just went on; the patch waits for contact to settle
  /// before sending readings.
  stabilizing,
}

Color monitorColor(MonitorStatus s) => switch (s) {
      MonitorStatus.live => MunjiColors.green,
      MonitorStatus.attention => MunjiColors.orange,
      MonitorStatus.connecting => MunjiColors.blue500,
      MonitorStatus.offline => MunjiColors.muted,
      MonitorStatus.noData => MunjiColors.orange,
      MonitorStatus.noDevice => MunjiColors.muted,
      MonitorStatus.charging => MunjiColors.blue500,
      MonitorStatus.stabilizing => MunjiColors.blue500,
    };

/// Short name for a status, as on the caregiver's patient list.
String monitorShort(MonitorStatus s, bool ar) => switch (s) {
      MonitorStatus.live => ar ? 'مباشر' : 'Live',
      MonitorStatus.attention => ar ? 'تحقق' : 'Check',
      MonitorStatus.connecting => ar ? 'يتصل' : 'Connecting',
      MonitorStatus.offline => ar ? 'غير متصل' : 'Offline',
      MonitorStatus.noData => ar ? 'لا بيانات' : 'No data',
      MonitorStatus.noDevice => ar ? 'بلا جهاز' : 'No device',
      MonitorStatus.charging => ar ? 'يشحن' : 'Charging',
      MonitorStatus.stabilizing => ar ? 'تستقر' : 'Settling',
    };

/// "just now", "12s ago", "3m ago" and so on.
String agoText(DateTime at, bool ar) {
  final s = DateTime.now().difference(at).inSeconds;
  if (s < 5) return ar ? 'الآن' : 'just now';
  if (s < 60) return ar ? 'قبل $s ث' : '${s}s ago';
  if (s < 3600) return ar ? 'قبل ${s ~/ 60} د' : '${s ~/ 60}m ago';
  if (s < 86400) return ar ? 'قبل ${s ~/ 3600} س' : '${s ~/ 3600}h ago';
  return ar ? 'قبل ${s ~/ 86400} يوم' : '${s ~/ 86400}d ago';
}

// ── decoration ─────────────────────────────────────────────────────────────

/// A stylised ECG line. Decoration only: the shape is fixed, not anyone's
/// signal, and it goes flat whenever nothing is being monitored.
class MunjiTracePainter extends CustomPainter {
  MunjiTracePainter({required this.flat, required this.color});

  final bool flat;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height * 0.55;
    final line = Paint()
      ..color = color.withValues(alpha: flat ? 0.4 : 0.85)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    const inset = 18.0;
    final width = size.width - inset * 2;
    final path = Path()..moveTo(inset, mid);
    if (flat) {
      path.lineTo(inset + width, mid);
      canvas.drawPath(path, line);
      return;
    }

    // one P-QRS-T complex, repeated
    const beats = 6;
    final w = width / beats;
    final a = size.height * 0.40;
    for (var i = 0; i < beats; i++) {
      final x0 = inset + i * w;
      Offset p(double fx, double fy) => Offset(x0 + fx * w, mid - fy * a);
      path
        ..lineTo(p(0.10, 0).dx, mid)
        ..quadraticBezierTo(p(0.15, 0.18).dx, p(0.15, 0.18).dy, p(0.20, 0).dx, mid)
        ..lineTo(p(0.28, 0).dx, mid)
        ..lineTo(p(0.31, -0.12).dx, p(0.31, -0.12).dy)
        ..lineTo(p(0.35, 1.0).dx, p(0.35, 1.0).dy)
        ..lineTo(p(0.39, -0.35).dx, p(0.39, -0.35).dy)
        ..lineTo(p(0.43, 0).dx, mid)
        ..lineTo(p(0.52, 0).dx, mid)
        ..quadraticBezierTo(p(0.60, 0.30).dx, p(0.60, 0.30).dy, p(0.68, 0).dx, mid)
        ..lineTo(x0 + w, mid);
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(MunjiTracePainter old) =>
      old.flat != flat || old.color != color;
}

// ── headers and navigation ─────────────────────────────────────────────────

/// "Good morning," over a name, as on both home screens.
class GreetingHeader extends StatelessWidget {
  const GreetingHeader({super.key, required this.isArabic, required this.name});
  final bool isArabic;
  final String name;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final morning = DateTime.now().hour < 12;
    final greeting = morning
        ? (ar ? 'صباح الخير،' : 'Good morning,')
        : (ar ? 'مساء الخير،' : 'Good evening,');
    final n = name.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MunjiSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting,
              style: MunjiText.body.copyWith(
                  color: MunjiColors.slate, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(n.isEmpty ? (ar ? 'أهلًا' : 'Welcome') : n,
              style: MunjiText.h1, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// Back arrow, a title, and a status line under it.
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleColor = MunjiColors.muted,
  });

  final String title;
  final String? subtitle;
  final Color subtitleColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const BackButtonIcon(),
          color: MunjiColors.ink,
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: MunjiText.h2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: subtitleColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MunjiText.small.copyWith(
                              fontSize: 12.5,
                              color: MunjiColors.slate,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class MunjiNavItem {
  const MunjiNavItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// The floating bottom bar. One widget for both apps so they match.
class MunjiNavBar extends StatelessWidget {
  const MunjiNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onTap,
  });

  final List<MunjiNavItem> items;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: MunjiColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x2100537A)),
          boxShadow: MunjiShadow.e2,
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _NavButton(
                  item: items[i],
                  selected: i == index,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final MunjiNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? MunjiColors.blue : MunjiColors.muted;
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? MunjiColors.blue50 : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 21, color: color),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── the status panel (status, trace, and the numbers under it) ──────────────

/// One number in the row under the trace.
class StatData {
  const StatData({
    required this.icon,
    required this.value,
    required this.label,
    this.unit,
    this.note,
    this.dim = false,
    this.onTap,
  });

  final Widget icon;
  final String value;
  final String? unit;
  final String label;

  /// A short line under the label, such as when a value was measured.
  final String? note;
  final bool dim;
  final VoidCallback? onTap;
}

StatData hrStat({required bool ar, required double? bpm, required bool live}) =>
    StatData(
      icon: Icon(Icons.favorite_rounded,
          size: 24, color: live && bpm != null ? MunjiColors.blue500 : MunjiColors.muted),
      // an old number next to "settling" or "charging" reads as current
      value: live && bpm != null ? bpm.round().toString() : '--',
      unit: 'BPM',
      label: ar ? 'نبض القلب' : 'Heart rate',
      dim: !(live && bpm != null),
    );

/// HRV past this age is shown faded: still the latest, but no longer a
/// picture of how the patient is now. Engineering choice.
const hrvStaleAfter = Duration(days: 3);

/// HRV from the latest guided recording, not a live value: HRV changes
/// with movement, posture and talking, so only a reading taken at rest
/// during a recording is comparable from day to day. [measuredAt] is when
/// that recording was made; null [rmssd] asks the patient to record one.
StatData hrvStat({
  required bool ar,
  required double? rmssd,
  required DateTime? measuredAt,
  DateTime? now,
}) {
  if (rmssd == null || measuredAt == null) {
    return StatData(
      icon: const Icon(Icons.show_chart_rounded, size: 24, color: MunjiColors.muted),
      value: '--',
      unit: 'ms',
      label: 'HRV',
      note: ar ? 'سجّل لقياسه' : 'Record to measure',
      dim: true,
    );
  }
  final stale = (now ?? DateTime.now()).difference(measuredAt) > hrvStaleAfter;
  return StatData(
    icon: Icon(Icons.show_chart_rounded,
        size: 24, color: stale ? MunjiColors.muted : MunjiColors.blue500),
    value: rmssd.round().toString(),
    unit: 'ms',
    label: 'HRV',
    note: measuredText(measuredAt, ar, now: now),
    dim: stale,
  );
}

/// "Today 09:15", "Yesterday", or "3 days ago", in Riyadh time.
String measuredText(DateTime at, bool ar, {DateTime? now}) {
  final r = at.toUtc().add(const Duration(hours: 3));
  final n = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 3));
  final days = DateTime.utc(n.year, n.month, n.day)
      .difference(DateTime.utc(r.year, r.month, r.day))
      .inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (days <= 0) return ar ? 'اليوم ${two(r.hour)}:${two(r.minute)}' : 'Today ${two(r.hour)}:${two(r.minute)}';
  if (days == 1) return ar ? 'أمس' : 'Yesterday';
  if (!ar) return '$days days ago';
  return days <= 10 ? 'قبل $days أيام' : 'قبل $days يومًا';
}

/// What the ECG itself is doing, not the Bluetooth link. Each state has
/// its own small drawing, so it reads at a glance:
///   valid        a clean beat           readings are usable
///   settling     dashes, moving dot     electrodes on, waiting to start
///   paused       flat line              stopped on purpose (charging, off)
///   electrodeOff broken line            an electrode is not on the skin
///   noisy        jagged line            data arrives but is not clean
enum EcgState { valid, settling, paused, electrodeOff, noisy }

StatData ecgStat({required bool ar, required EcgState state}) {
  final (value, color) = switch (state) {
    EcgState.valid => (ar ? 'صالح' : 'Clean', MunjiColors.green),
    EcgState.settling => (ar ? 'يتهيأ' : 'Settling', MunjiColors.orange),
    EcgState.paused => (ar ? 'متوقف' : 'Paused', MunjiColors.muted),
    EcgState.electrodeOff => (ar ? 'قطب مفصول' : 'Electrode off', MunjiColors.orange),
    EcgState.noisy => (ar ? 'مشوّش' : 'Noisy', MunjiColors.orange),
  };
  return StatData(
    icon: EcgStateIcon(state: state, color: color),
    value: value,
    label: ar ? 'التخطيط' : 'ECG',
    dim: state == EcgState.paused,
  );
}

StatData batteryStat({
  required bool ar,
  required int? battery,
  bool? charging,
  bool? full,
  VoidCallback? onTap,
}) {
  final b = battery;
  final low = b != null && b <= 20;
  final icon = charging == true
      ? Icons.battery_charging_full_rounded
      : b == null
          ? Icons.battery_unknown_rounded
          : b > 80
              ? Icons.battery_full_rounded
              : b > 50
                  ? Icons.battery_5_bar_rounded
                  : b > 20
                      ? Icons.battery_3_bar_rounded
                      : Icons.battery_1_bar_rounded;
  return StatData(
    icon: RotatedBox(
      quarterTurns: 1,
      child: Icon(icon,
          size: 26,
          color: b == null
              ? MunjiColors.muted
              : (low && charging != true ? MunjiColors.orange : MunjiColors.green)),
    ),
    value: b == null ? '--' : '$b%',
    label: charging == true
        ? (full == true
            ? (ar ? 'مشحونة ⚡' : 'Full ⚡')
            : (ar ? 'يشحن ⚡' : 'Charging ⚡'))
        : (ar ? 'البطارية' : 'Battery'),
    dim: b == null,
    onTap: onTap,
  );
}

/// Status on top, the heart beside it, a decorative trace, then the numbers.
class StatusPanel extends StatelessWidget {
  const StatusPanel({
    super.key,
    required this.isArabic,
    required this.status,
    required this.title,
    required this.subtitle,
    required this.stats,
    this.action,
  });

  final bool isArabic;
  final MonitorStatus status;
  final String title;
  final String subtitle;
  final List<StatData> stats;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final live = status == MonitorStatus.live;
    final active = live || status == MonitorStatus.attention;
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
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isArabic ? 'حالة المراقبة' : 'Monitoring',
                          style: MunjiText.label.copyWith(
                              color: MunjiColors.slate, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (status == MonitorStatus.connecting ||
                              status == MonitorStatus.stabilizing)
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
                                  color: monitorColor(status), shape: BoxShape.circle),
                            ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(title, style: MunjiText.h1.copyWith(fontSize: 26)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: MunjiText.body.copyWith(
                              color: MunjiColors.slate,
                              fontWeight: FontWeight.w500,
                              fontSize: 14)),
                      if (action != null) ...[
                        const SizedBox(height: MunjiSpace.sm),
                        action!,
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: MunjiSpace.sm),
                _HeartBadge(active: active),
              ],
            ),
          ),
          SizedBox(
            height: 88,
            child: CustomPaint(
              painter: MunjiTracePainter(
                flat: !live,
                color: active ? MunjiColors.blue500 : MunjiColors.muted,
              ),
            ),
          ),
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
                  // top-aligned, so a stat with a note line does not push
                  // the others' icons down
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < stats.length; i++) ...[
                      if (i > 0)
                        const VerticalDivider(
                          width: 1,
                          thickness: 1,
                          indent: 6,
                          endIndent: 6,
                          color: MunjiColors.line,
                        ),
                      Expanded(child: _Stat(stats[i])),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.d);
  final StatData d;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: 28, child: Center(child: d.icon)),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(d.value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: d.dim ? MunjiColors.muted : MunjiColors.ink,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
                if (d.unit != null) ...[
                  const SizedBox(width: 3),
                  Text(d.unit!,
                      style: MunjiText.small
                          .copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(d.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MunjiText.small.copyWith(
                fontSize: 12, color: MunjiColors.slate, fontWeight: FontWeight.w500)),
        if (d.note != null)
          Text(d.note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MunjiText.small.copyWith(fontSize: 10.5, color: MunjiColors.muted)),
      ],
    );
    if (d.onTap == null) return body;
    return GestureDetector(
        onTap: d.onTap, behavior: HitTestBehavior.opaque, child: body);
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
        opacity: active ? 0.85 : 0.3,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Image.asset('assets/images/heart.webp', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// The small drawing for an [EcgState]. "settling" animates: a dot moving
/// along a dashed line, so it looks like waiting, not like a fault.
class EcgStateIcon extends StatefulWidget {
  const EcgStateIcon({super.key, required this.state, required this.color});
  final EcgState state;
  final Color color;

  @override
  State<EcgStateIcon> createState() => _EcgStateIconState();
}

class _EcgStateIconState extends State<EcgStateIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(EcgStateIcon old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.state == EcgState.settling) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 40,
        height: 22,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _EcgIconPainter(widget.state, widget.color, _c.value),
          ),
        ),
      ),
    );
  }
}

class _EcgIconPainter extends CustomPainter {
  _EcgIconPainter(this.state, this.color, this.t);
  final EcgState state;
  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h * 0.6;
    final pen = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (state) {
      case EcgState.valid:
        final p = Path()
          ..moveTo(0, mid)
          ..lineTo(w * 0.30, mid)
          ..lineTo(w * 0.38, mid + h * 0.15)
          ..lineTo(w * 0.47, h * 0.05)
          ..lineTo(w * 0.56, h * 0.95)
          ..lineTo(w * 0.63, mid)
          ..lineTo(w, mid);
        canvas.drawPath(p, pen);
      case EcgState.settling:
        const dash = 4.0, gap = 3.5;
        for (var x = 0.0; x < w; x += dash + gap) {
          canvas.drawLine(Offset(x, mid), Offset((x + dash).clamp(0, w), mid),
              pen..strokeWidth = 2);
        }
        canvas.drawCircle(Offset(w * t, mid), 3, Paint()..color = color);
      case EcgState.paused:
        canvas.drawLine(Offset(0, mid), Offset(w, mid), pen);
      case EcgState.electrodeOff:
        canvas.drawLine(Offset(0, mid), Offset(w * 0.38, mid), pen);
        canvas.drawLine(Offset(w * 0.62, mid), Offset(w, mid), pen);
        // the break, with its ends lifted like a cut wire
        canvas.drawLine(Offset(w * 0.38, mid), Offset(w * 0.44, mid - h * 0.3), pen);
        canvas.drawLine(Offset(w * 0.62, mid), Offset(w * 0.56, mid + h * 0.3), pen);
      case EcgState.noisy:
        final p = Path()..moveTo(0, mid);
        const ys = [0.1, -0.25, 0.3, -0.15, 0.35, -0.3, 0.2, -0.1, 0.25, -0.2];
        for (var i = 0; i < ys.length; i++) {
          p.lineTo(w * (i + 1) / ys.length, mid + ys[i] * h);
        }
        canvas.drawPath(p, pen..strokeWidth = 1.6);
    }
  }

  @override
  bool shouldRepaint(_EcgIconPainter o) =>
      o.state != state || o.color != color || o.t != t;
}

/// A card that opens something: icon, title, one line, chevron.
class ActionCard extends StatelessWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MunjiColors.surface,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
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
                child: Icon(icon, color: MunjiColors.blue, size: 26),
              ),
              const SizedBox(width: MunjiSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: MunjiText.h3),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: MunjiText.body.copyWith(
                            color: MunjiColors.slate,
                            fontWeight: FontWeight.w500,
                            fontSize: 13.5)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: MunjiColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
