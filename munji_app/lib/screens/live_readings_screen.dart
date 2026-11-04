import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/device_config.dart';
import '../services/device_service.dart';
import '../services/real_device_service.dart';
import '../theme/munji_theme.dart';

/// Engineer view of everything the patch sends.
///
/// Built for bench testing the hardware: is the waveform clean and correctly
/// scaled, does the beat detector agree with its own RR interval, do the
/// lead-off bits follow the electrodes, is the link dropping packets. Each
/// figure sits next to what it should be, so a wrong number stands out.
///
/// HRV is computed twice: the firmware sends its RMSSD, and this screen
/// recomputes RMSSD and SDNN from the RR intervals it receives. The two will
/// not match exactly (the firmware's window is not known here) but they
/// should be in the same range.
///
/// Not a patient screen. Reached only when [DeviceConfig.showLiveReadings].
class LiveReadingsScreen extends StatefulWidget {
  const LiveReadingsScreen({
    super.key,
    required this.service,
    required this.isArabic,
  });

  final RealMunjiDeviceService service;
  final bool isArabic;

  @override
  State<LiveReadingsScreen> createState() => _LiveReadingsScreenState();
}

class _LiveReadingsScreenState extends State<LiveReadingsScreen> {
  static const _seconds = 4;
  static final int _n = DeviceConfig.sampleRateHz * _seconds;

  /// Ring buffer of the last few seconds, in mV. NaN until filled.
  late final Float32List _trace = Float32List(_n)
    ..fillRange(0, _n, double.nan);
  int _cursor = 0;
  final _repaint = ValueNotifier<int>(0);

  /// 1 = standard 10 mm/mV.
  double _gain = 1;

  final _hrv = _HrvTracker();
  HeartReading? _heart;
  LeadStatus? _leads;
  late DeviceState _state;

  int _packetsSinceTick = 0;
  DateTime _tickStart = DateTime.now();
  double? _packetRate;
  double? _peakToPeakMv;
  double? _offsetMv;
  DateTime? _lastPacketAt;

  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _tick;

  RealMunjiDeviceService get _s => widget.service;
  _T get t => _T(widget.isArabic);

  @override
  void initState() {
    super.initState();
    _state = _s.state;
    _leads = _s.leads;
    _heart = _s.heart;

    _subs.add(_s.changes.listen((v) {
      if (mounted) setState(() => _state = v);
    }));
    _subs.add(_s.ecgStream.listen(_onPacket));
    _subs.add(_s.heartStream.listen((h) {
      _hrv.add(h);
      if (mounted) setState(() => _heart = h);
    }));
    _subs.add(_s.leadStream.listen((l) {
      if (mounted) setState(() => _leads = l);
    }));

    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _everySecond());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    _repaint.dispose();
    super.dispose();
  }

  void _onPacket(EcgPacket p) {
    _packetsSinceTick++;
    _lastPacketAt = p.receivedAt;
    for (final raw in p.samples) {
      _trace[_cursor] = raw * DeviceConfig.uvPerLsb / 1000;
      _cursor = (_cursor + 1) % _n;
    }
    _repaint.value++;
  }

  void _everySecond() {
    if (!mounted) return;
    final now = DateTime.now();
    final secs = now.difference(_tickStart).inMilliseconds / 1000;
    final stats = _recentStats(DeviceConfig.sampleRateHz * 2);
    setState(() {
      _packetRate = secs > 0 ? _packetsSinceTick / secs : null;
      _packetsSinceTick = 0;
      _tickStart = now;
      _peakToPeakMv = stats?.$1;
      _offsetMv = stats?.$2;
    });
  }

  /// Peak-to-peak and mean over the newest [count] samples, in mV.
  (double, double)? _recentStats(int count) {
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    var sum = 0.0;
    var k = 0;
    for (var i = 1; i <= count; i++) {
      final v = _trace[(_cursor - i + _n) % _n];
      if (v.isNaN) continue;
      lo = math.min(lo, v);
      hi = math.max(hi, v);
      sum += v;
      k++;
    }
    if (k == 0) return null;
    return (hi - lo, sum / k);
  }

  void _reset() {
    _s.resetCounters();
    _hrv.clear();
    setState(() {});
  }

  void _cycleGain() {
    setState(() {
      _gain = _gain == 1 ? 2 : (_gain == 2 ? 0.5 : 1);
    });
  }

  // ── formatting ───────────────────────────────────────────────────────────

  String _num(num? v, [int digits = 1]) =>
      v == null ? '–' : v.toStringAsFixed(digits);

  String _age(DateTime? at) {
    if (at == null) return t.never;
    final s = DateTime.now().difference(at).inSeconds;
    return t.secondsAgo(s);
  }

  bool _fresh(DateTime? at, int seconds) =>
      at != null && DateTime.now().difference(at).inSeconds <= seconds;

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final heart = _heart;
    final heartFresh = _fresh(heart?.receivedAt, 5);
    final bpmFromRr =
        heart != null && heart.rrMs > 0 ? 60000 / heart.rrMs : null;
    final bpmAgrees = heart != null &&
        bpmFromRr != null &&
        (heart.bpm - bpmFromRr).abs() <= 2;

    final rate = _packetRate;
    final expectedRate =
        DeviceConfig.sampleRateHz / DeviceConfig.samplesPerPacket;
    final rateOk = rate != null && (rate - expectedRate).abs() <= 2;
    final streaming = _fresh(_lastPacketAt, 2);

    final appRmssd = _hrv.rmssd;
    final devRmssd = heart?.rmssdMs;
    String? rmssdGap;
    if (appRmssd != null && devRmssd != null && appRmssd > 0) {
      final pct = ((devRmssd - appRmssd).abs() / appRmssd * 100).round();
      rmssdGap = '$pct%';
    }

    final leads = _leads;
    final battery = _state.battery;

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        foregroundColor: MunjiColors.ink,
        title: Text(t.title, style: MunjiText.h3),
        actions: [
          IconButton(
            tooltip: t.reset,
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: _reset,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // ── waveform ──
          Row(
            children: [
              Text('ECG', style: MunjiText.label),
              const SizedBox(width: 8),
              Expanded(
                child: Text(t.scale(_gain),
                    style: MunjiText.small, overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                onPressed: _cycleGain,
                child: Text('×${_gain == 0.5 ? '0.5' : _gain.toInt()}',
                    style: MunjiText.label.copyWith(color: MunjiColors.blue)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(MunjiRadius.r2),
            child: Container(
              color: const Color(0xFFFFFBFB),
              child: Directionality(
                // Time runs left to right on an ECG whatever the language.
                textDirection: TextDirection.ltr,
                child: AspectRatio(
                  aspectRatio: 20 / 8, // 4 s wide, 4 mV tall at x1
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _EcgPainter(
                          trace: _trace,
                          cursor: () => _cursor,
                          gain: _gain,
                          seconds: _seconds,
                          repaint: _repaint,
                        ),
                      ),
                      if (!streaming)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.92),
                              borderRadius:
                                  BorderRadius.circular(MunjiRadius.r1),
                            ),
                            child: Text(t.noEcg,
                                style: MunjiText.label
                                    .copyWith(color: MunjiColors.warn700)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(t.waveHint, style: MunjiText.small),

          // ── heart ──
          _Section(title: t.heart, children: [
            _Row(
              label: 'BPM',
              value: heartFresh ? _num(heart?.bpm) : '–',
              note: heartFresh ? null : t.noBeat,
              status: heartFresh ? _Status.none : _Status.warn,
              big: true,
            ),
            _Row(
              label: 'RR',
              value: heartFresh ? '${heart!.rrMs} ms' : '–',
            ),
            _Row(
              label: t.bpmFromRr,
              value: heartFresh ? _num(bpmFromRr) : '–',
              note: t.bpmFromRrNote,
              status: !heartFresh
                  ? _Status.none
                  : (bpmAgrees ? _Status.ok : _Status.warn),
            ),
            _Row(label: t.lastBeat, value: _age(heart?.receivedAt)),
          ]),

          // ── HRV ──
          _Section(title: 'HRV', subtitle: t.hrvNote, children: [
            _Row(
              label: t.rmssdDevice,
              value: devRmssd == null ? '–' : '${_num(devRmssd)} ms',
              note: devRmssd == null ? t.rmssdWait : null,
            ),
            _Row(
              label: t.rmssdApp,
              value: appRmssd == null ? '–' : '${_num(appRmssd)} ms',
              note: rmssdGap == null ? null : t.difference(rmssdGap),
            ),
            _Row(
              label: 'SDNN',
              value: _hrv.sdnn == null ? '–' : '${_num(_hrv.sdnn)} ms',
            ),
            _Row(
              label: t.beatsUsed,
              value: '${_hrv.count}',
              note: t.window(_hrv.span.inSeconds),
            ),
            _Row(
              label: t.rejected,
              value: '${_hrv.rejected}',
              note: t.rejectedNote,
              status: _hrv.rejected == 0 ? _Status.none : _Status.warn,
            ),
          ]),

          // ── electrodes ──
          _Section(title: t.electrodes, subtitle: t.electrodesNote, children: [
            if (leads == null)
              _Row(label: t.status, value: t.noLeadPacket, status: _Status.warn)
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    _LeadChip(name: 'P', off: leads.pOff, t: t),
                    const SizedBox(width: 8),
                    _LeadChip(name: 'N', off: leads.nOff, t: t),
                    const SizedBox(width: 8),
                    _LeadChip(name: 'REF', off: leads.refOff, t: t),
                  ],
                ),
              ),
              _Row(
                label: t.status,
                value: leads.allAttached ? t.allOn : t.someOff,
                status: leads.allAttached ? _Status.ok : _Status.bad,
              ),
              _Row(
                label: t.raw,
                value: leads.raw
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' ')
                    .toUpperCase(),
                mono: true,
              ),
              _Row(label: t.lastUpdate, value: _age(leads.receivedAt)),
            ],
          ]),

          // ── battery ──
          _Section(title: t.battery, children: [
            _Row(
              label: t.level,
              value: battery == null ? '–' : '$battery%',
              status: battery == null
                  ? _Status.warn
                  : (battery <= 15 ? _Status.warn : _Status.ok),
              big: true,
            ),
            _Row(
              label: t.lastUpdate,
              value: _age(_s.batteryUpdatedAt),
              note: t.batteryNote,
            ),
          ]),

          // ── link ──
          _Section(title: t.link, children: [
            _Row(
              label: t.packetsPerSecond,
              value: _num(rate),
              note: t.expected(expectedRate.toStringAsFixed(2)),
              status: rate == null
                  ? _Status.none
                  : (rateOk ? _Status.ok : _Status.bad),
            ),
            _Row(
              label: t.samplesPerSecond,
              value: rate == null
                  ? '–'
                  : (rate * DeviceConfig.samplesPerPacket).round().toString(),
              note: t.expected('${DeviceConfig.sampleRateHz}'),
            ),
            _Row(
              label: t.dropped,
              value: '${_s.droppedPackets}',
              note: t.ofReceived(_s.packetsReceived),
              status: _s.droppedPackets == 0 ? _Status.ok : _Status.warn,
            ),
            _Row(
              label: t.peakToPeak,
              value: _peakToPeakMv == null ? '–' : '${_num(_peakToPeakMv, 2)} mV',
              note: t.peakToPeakNote,
            ),
            _Row(
              label: t.offset,
              value: _offsetMv == null ? '–' : '${_num(_offsetMv, 2)} mV',
              note: t.offsetNote,
            ),
            _Row(label: t.serial, value: _s.serialNumber ?? '–', mono: true),
            _Row(label: t.firmware, value: _s.firmwareVersion ?? '–', mono: true),
          ]),
        ],
      ),
    );
  }
}

// ── HRV from RR intervals ──────────────────────────────────────────────────

class _Beat {
  const _Beat(this.at, this.rrMs);
  final DateTime at;
  final int rrMs;
}

class _Diff {
  const _Diff(this.at, this.ms);
  final DateTime at;
  final double ms;
}

/// RMSSD and SDNN over the last five minutes, the standard short-term window
/// (Task Force of the ESC and NASPE, 1996).
///
/// Beats are rejected as artifacts when RR is outside 300 to 2000 ms or
/// differs from the previous accepted beat by more than 20%. That also drops
/// ectopic beats, which is what HRV measures want. A rejected beat breaks the
/// chain, so no successive difference spans it.
class _HrvTracker {
  static const _window = Duration(minutes: 5);

  final _beats = <_Beat>[];
  final _diffs = <_Diff>[];
  int rejected = 0;
  int? _prevRr;

  void add(HeartReading h) {
    final rr = h.rrMs;
    final prev = _prevRr;
    final plausible = rr >= 300 && rr <= 2000;
    final steady = prev == null || (rr - prev).abs() <= prev * 0.2;

    if (!plausible || !steady) {
      rejected++;
      _prevRr = null;
      return;
    }

    if (prev != null) _diffs.add(_Diff(h.receivedAt, (rr - prev).toDouble()));
    _beats.add(_Beat(h.receivedAt, rr));
    _prevRr = rr;

    final cutoff = h.receivedAt.subtract(_window);
    _beats.removeWhere((b) => b.at.isBefore(cutoff));
    _diffs.removeWhere((d) => d.at.isBefore(cutoff));
  }

  void clear() {
    _beats.clear();
    _diffs.clear();
    rejected = 0;
    _prevRr = null;
  }

  int get count => _beats.length;

  Duration get span => _beats.length < 2
      ? Duration.zero
      : _beats.last.at.difference(_beats.first.at);

  double? get rmssd {
    if (_diffs.length < 2) return null;
    final meanSq =
        _diffs.fold<double>(0, (a, d) => a + d.ms * d.ms) / _diffs.length;
    return math.sqrt(meanSq);
  }

  double? get sdnn {
    if (_beats.length < 3) return null;
    final mean =
        _beats.fold<double>(0, (a, b) => a + b.rrMs) / _beats.length;
    final variance = _beats.fold<double>(
            0, (a, b) => a + (b.rrMs - mean) * (b.rrMs - mean)) /
        (_beats.length - 1);
    return math.sqrt(variance);
  }
}

// ── waveform ───────────────────────────────────────────────────────────────

/// ECG paper: a large square is 0.2 s across and 0.5 mV high at x1, the
/// standard 25 mm/s and 10 mm/mV. The trace sweeps left to right and
/// overwrites itself, with a short gap at the write position.
///
/// The trace is drawn around its own mean so a baseline offset does not
/// push it off the paper. The offset itself is reported on the screen.
class _EcgPainter extends CustomPainter {
  _EcgPainter({
    required this.trace,
    required this.cursor,
    required this.gain,
    required this.seconds,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Float32List trace;
  final int Function() cursor;
  final double gain;
  final int seconds;

  static const _minor = Color(0xFFF6DCDC);
  static const _major = Color(0xFFE9AEAE);

  @override
  void paint(Canvas canvas, Size size) {
    final big = size.width / (seconds / 0.2);
    final small = big / 5;
    final midY = size.height / 2;

    final minorPaint = Paint()
      ..color = _minor
      ..strokeWidth = 0.6;
    final majorPaint = Paint()
      ..color = _major
      ..strokeWidth = 1;

    final columns = (seconds / 0.04).round();
    for (var i = 0; i <= columns; i++) {
      final x = i * small;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          i % 5 == 0 ? majorPaint : minorPaint);
    }
    for (var j = 0; midY - j * small >= -0.5; j++) {
      final p = j % 5 == 0 ? majorPaint : minorPaint;
      final up = midY - j * small;
      final down = midY + j * small;
      canvas.drawLine(Offset(0, up), Offset(size.width, up), p);
      if (j > 0) {
        canvas.drawLine(Offset(0, down), Offset(size.width, down), p);
      }
    }

    // Mean of what is on screen, so the trace sits on the centre line.
    var sum = 0.0;
    var k = 0;
    for (final v in trace) {
      if (v.isNaN) continue;
      sum += v;
      k++;
    }
    if (k == 0) return;
    final mean = sum / k;

    final pxPerMv = big / (0.5 / gain);
    final n = trace.length;
    final c = cursor();
    const gap = 12;

    final path = Path();
    var penDown = false;
    for (var i = 0; i < n; i++) {
      final ahead = (i - c + n) % n;
      final v = trace[i];
      if (ahead < gap || v.isNaN) {
        penDown = false;
        continue;
      }
      final x = i / (n - 1) * size.width;
      final y = (midY - (v - mean) * pxPerMv).clamp(0.0, size.height);
      if (penDown) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        penDown = true;
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = MunjiColors.ink
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_EcgPainter old) =>
      old.gain != gain || old.trace != trace;
}

// ── pieces ─────────────────────────────────────────────────────────────────

enum _Status { none, ok, warn, bad }

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: MunjiText.h3),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: MunjiText.small),
          ],
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(MunjiRadius.r3),
              border: Border.all(color: MunjiColors.line),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.note,
    this.status = _Status.none,
    this.big = false,
    this.mono = false,
  });

  final String label;
  final String value;
  final String? note;
  final _Status status;
  final bool big;
  final bool mono;

  Color? get _dot {
    switch (status) {
      case _Status.ok:
        return MunjiColors.green;
      case _Status.warn:
        return MunjiColors.orange;
      case _Status.bad:
        return MunjiColors.red;
      case _Status.none:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dot = _dot;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MunjiColors.line, width: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: MunjiText.label),
                if (note != null)
                  Text(note!, style: MunjiText.small.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
          ],
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              value,
              style: (big ? MunjiText.h2 : MunjiText.body).copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeadChip extends StatelessWidget {
  const _LeadChip({required this.name, required this.off, required this.t});

  final String name;
  final bool off;
  final _T t;

  @override
  Widget build(BuildContext context) {
    final fg = off ? MunjiColors.danger700 : MunjiColors.ok700;
    final bg = off ? MunjiColors.danger50 : MunjiColors.ok50;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(MunjiRadius.r2),
          border: Border.all(
              color: off ? MunjiColors.danger200 : MunjiColors.ok200),
        ),
        child: Column(
          children: [
            Text(name, style: MunjiText.body.copyWith(color: fg)),
            Text(off ? t.off : t.on,
                style: MunjiText.small.copyWith(color: fg, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ── strings ────────────────────────────────────────────────────────────────

class _T {
  const _T(this.ar);
  final bool ar;

  String get title => ar ? 'القراءات المباشرة' : 'Live readings';
  String get reset => ar ? 'تصفير العدادات' : 'Reset counters';
  String scale(double gain) => '25 mm/s   ${(10 * gain).round()} mm/mV';

  String get noEcg => ar ? 'لا تصل بيانات ECG' : 'No ECG arriving';
  String get waveHint => ar
      ? 'المربع الكبير = 0.2 ثانية و0.5 mV عند ×1. اضغطي على ×1 لتغيير التكبير.'
      : 'One large square = 0.2 s and 0.5 mV at x1. Tap x1 to change gain.';

  String get heart => ar ? 'النبض' : 'Heart';
  String get noBeat =>
      ar ? 'لا نبضة في آخر 5 ثوانٍ' : 'No beat in the last 5 s';
  String get bpmFromRr => ar ? 'BPM محسوب من RR' : 'BPM from RR';
  String get bpmFromRrNote => ar
      ? '60000 ÷ RR، يجب أن يطابق BPM'
      : '60000 / RR, should match BPM';
  String get lastBeat => ar ? 'آخر نبضة' : 'Last beat';

  String get hrvNote => ar
      ? 'التطبيق يحسب HRV من RR آخر 5 دقائق ويقارنه بقيمة الجهاز'
      : 'The app recomputes HRV from RR over 5 minutes to compare';
  String get rmssdDevice => ar ? 'RMSSD من الجهاز' : 'RMSSD (device)';
  String get rmssdApp => ar ? 'RMSSD من التطبيق' : 'RMSSD (app)';
  String get rmssdWait =>
      ar ? 'يرسله الجهاز بعد 3 نبضات' : 'Device sends it after 3 beats';
  String difference(String pct) => ar ? 'الفرق $pct' : 'Difference $pct';
  String get beatsUsed => ar ? 'النبضات المحسوبة' : 'Beats used';
  String window(int s) =>
      ar ? 'خلال ${s ~/ 60} د ${s % 60} ث' : 'Over ${s ~/ 60} m ${s % 60} s';
  String get rejected => ar ? 'نبضات مستبعدة' : 'Rejected beats';
  String get rejectedNote => ar
      ? 'RR خارج 300 إلى 2000 ms أو تغير أكثر من 20%'
      : 'RR outside 300 to 2000 ms or a jump over 20%';

  String get electrodes => ar ? 'الأقطاب' : 'Electrodes';
  String get electrodesNote => ar
      ? 'افصلي قطبًا ويجب أن يتغير هنا فورًا'
      : 'Detach one and it should change here at once';
  String get status => ar ? 'الحالة' : 'Status';
  String get noLeadPacket =>
      ar ? 'لم تصل أي حزمة أقطاب' : 'No lead packet yet';
  String get allOn => ar ? 'كلها متصلة' : 'All attached';
  String get someOff => ar ? 'قطب مفصول' : 'Detached';
  String get on => ar ? 'متصل' : 'on';
  String get off => ar ? 'مفصول' : 'off';
  String get raw => ar ? 'البايتات الخام' : 'Raw bytes';

  String get battery => ar ? 'البطارية' : 'Battery';
  String get level => ar ? 'المستوى' : 'Level';
  String get batteryNote => ar
      ? 'الجهاز يرسل عند تغير النسبة'
      : 'The device sends when the level changes';

  String get link => ar ? 'الاتصال والإشارة' : 'Link and signal';
  String get packetsPerSecond => ar ? 'حزم في الثانية' : 'Packets per second';
  String get samplesPerSecond => ar ? 'عينات في الثانية' : 'Samples per second';
  String expected(String v) => ar ? 'المتوقع $v' : 'Expected $v';
  String get dropped => ar ? 'حزم مفقودة' : 'Dropped packets';
  String ofReceived(int n) => ar ? 'من أصل $n مستلمة' : 'Of $n received';
  String get peakToPeak => ar ? 'المدى آخر ثانيتين' : 'Peak to peak, last 2 s';
  String get peakToPeakNote => ar
      ? 'QRS عادة بين 0.5 و3 mV'
      : 'A QRS is usually 0.5 to 3 mV';
  String get offset => ar ? 'متوسط الإشارة' : 'Baseline offset';
  String get offsetNote => ar
      ? 'قريب من 0 إذا الفلتر شغال'
      : 'Near 0 when the filter is on';
  String get serial => ar ? 'الرقم التسلسلي' : 'Serial';
  String get firmware => ar ? 'إصدار الفيرموير' : 'Firmware';
  String get lastUpdate => ar ? 'آخر تحديث' : 'Last update';

  String get never => ar ? 'لم يصل' : 'Never';
  String secondsAgo(int s) {
    if (s < 60) return ar ? 'قبل $s ث' : '${s}s ago';
    final m = s ~/ 60;
    return ar ? 'قبل $m د' : '${m}m ago';
  }
}
