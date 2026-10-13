import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/report_data.dart';
import '../services/report_pdf.dart';
import '../theme/munji_theme.dart';
import '../widgets/trend_chart.dart';

/// Reports: pick a period (3 days, week, month, or custom), see the numbers
/// and trends for it, and export them as a PDF to share with a doctor.
///
/// Three days or less are shown hour by hour, longer periods day by day.
/// Everything comes from the hourly and daily summaries; nothing here reads
/// raw ECG.
class ReportsScreen extends StatefulWidget {
  ReportsScreen({
    super.key,
    required this.isArabic,
    required this.fullName,
    ReportRepository? repository,
  }) : repository = repository ?? ReportRepository();

  final bool isArabic;
  final String fullName;
  final ReportRepository repository;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportRange _range = ReportRange.week;
  late ReportPeriod _period = ReportPeriod.of(_range);
  Future<ReportSummary>? _future;
  bool _exporting = false;

  _T get t => _T(widget.isArabic);

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<ReportSummary>? _fetch() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return widget.repository.load(uid, _period);
  }

  void _load() {
    setState(() {
      _future = _fetch();
    });
  }

  Future<void> _pick(ReportRange r) async {
    if (r != ReportRange.custom) {
      setState(() {
        _range = r;
        _period = ReportPeriod.of(r);
      });
      _load();
      return;
    }

    final today = Riyadh.dateOf(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
      initialDateRange: DateTimeRange(start: _period.first, end: _period.last),
      helpText: t.pickRange,
      saveText: t.apply,
    );
    if (picked == null) return;
    setState(() {
      _range = ReportRange.custom;
      _period = ReportPeriod(
        DateTime.utc(picked.start.year, picked.start.month, picked.start.day),
        DateTime.utc(picked.end.year, picked.end.month, picked.end.day),
      );
    });
    _load();
  }

  Future<void> _export(ReportSummary s) async {
    setState(() => _exporting = true);
    try {
      final bytes = await ReportPdf.build(
        summary: s,
        patientName: widget.fullName,
        arabic: widget.isArabic,
      );
      final name = 'munji-report-${Riyadh.dayKey(s.period.first)}-${Riyadh.dayKey(s.period.last)}.pdf';
      await Printing.sharePdf(bytes: bytes, filename: name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.exportFailed)));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            _load();
            await _future;
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: MunjiSpace.xs),
                child: Text(t.title, style: MunjiText.h1),
              ),
              const SizedBox(height: MunjiSpace.md),
              _rangePicker(),
              const SizedBox(height: MunjiSpace.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: MunjiSpace.xs),
                child: Text(t.periodText(_period),
                    style: MunjiText.label.copyWith(color: MunjiColors.slate)),
              ),
              const SizedBox(height: MunjiSpace.lg),
              FutureBuilder<ReportSummary>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) return _message(Icons.cloud_off_rounded, t.loadFailed);
                  final s = snap.data!;
                  if (s.isEmpty) return _message(Icons.insights_rounded, t.empty);
                  return _content(s);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rangePicker() {
    final items = [
      (ReportRange.threeDays, t.threeDays),
      (ReportRange.week, t.week),
      (ReportRange.month, t.month),
      (ReportRange.custom, t.custom),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(MunjiRadius.pill),
        border: Border.all(color: const Color(0x1A00537A)),
      ),
      child: Row(
        children: [
          for (final (r, label) in items)
            Expanded(
              child: GestureDetector(
                onTap: () => _pick(r),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: _range == r ? MunjiColors.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(MunjiRadius.pill),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (r == ReportRange.custom) ...[
                        Icon(Icons.date_range_rounded,
                            size: 15,
                            color: _range == r ? Colors.white : MunjiColors.slate),
                        const SizedBox(width: 4),
                      ],
                      Text(label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _range == r ? Colors.white : MunjiColors.slate,
                          )),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(ReportSummary s) {
    final b = s.buckets;
    final hourly = s.period.hourly;
    String n(double? v) => v == null ? '--' : v.round().toString();
    final hours = s.monitoredMin / 60;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── the four numbers ──
        Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.favorite_rounded,
                label: t.avgHr,
                value: n(s.hrAvg),
                unit: 'BPM',
                sub: s.hrMin == null ? null : '${n(s.hrMin)} – ${n(s.hrMax)}',
              ),
            ),
            const SizedBox(width: MunjiSpace.sm),
            Expanded(
              child: _Stat(
                icon: Icons.show_chart_rounded,
                label: t.avgHrv,
                value: n(s.hrvAvg),
                unit: 'ms',
                sub: 'RMSSD',
              ),
            ),
          ],
        ),
        const SizedBox(height: MunjiSpace.sm),
        Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.schedule_rounded,
                label: t.monitored,
                value: hours.toStringAsFixed(hours < 10 ? 1 : 0),
                unit: t.hoursUnit,
                sub: t.coverage((s.coverage * 100).round()),
              ),
            ),
            const SizedBox(width: MunjiSpace.sm),
            Expanded(
              child: _Stat(
                icon: Icons.monitor_heart_outlined,
                label: t.recordings,
                value: '${s.recordings}',
                sub: t.ecg30,
              ),
            ),
          ],
        ),
        const SizedBox(height: MunjiSpace.lg),

        // ── trends ──
        _ChartCard(
          title: t.hrTitle,
          subtitle: t.hrSub,
          child: TrendChart(
            values: [for (final x in b) x.hrAvg],
            low: [for (final x in b) x.hrMin],
            high: [for (final x in b) x.hrMax],
            color: MunjiColors.blue,
            xLabels: _xLabels(s),
          ),
        ),
        const SizedBox(height: MunjiSpace.md),
        _ChartCard(
          title: t.hrvTitle,
          subtitle: 'RMSSD (ms)',
          child: TrendChart(
            values: [for (final x in b) x.hrvAvg],
            color: MunjiColors.green,
            height: 110,
            xLabels: _xLabels(s),
          ),
        ),
        const SizedBox(height: MunjiSpace.md),
        _ChartCard(
          title: t.wearTitle,
          subtitle: hourly ? t.wearSubHourly : t.wearSubDaily,
          child: TrendChart(
            values: [
              for (final x in b) hourly ? x.monitoredMin.toDouble() : x.monitoredMin / 60
            ],
            bars: true,
            fixedMax: hourly ? 60 : 24,
            color: MunjiColors.blue500,
            height: 100,
            xLabels: _xLabels(s),
          ),
        ),
        const SizedBox(height: MunjiSpace.xl),

        // ── export ──
        ElevatedButton.icon(
          onPressed: _exporting ? null : () => _export(s),
          icon: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.picture_as_pdf_rounded),
          label: Text(t.export),
        ),
        const SizedBox(height: MunjiSpace.md),
        Text(t.disclaimer, style: MunjiText.small.copyWith(fontSize: 11.5)),
      ],
    );
  }

  List<String> _xLabels(ReportSummary s) {
    final p = s.period;
    if (p.hourly) {
      if (p.days == 1) return ['00:00', '12:00', '23:00'];
      return [t.short(p.first), t.short(p.last)];
    }
    if (p.days <= 2) return [t.short(p.first), t.short(p.last)];
    final mid = p.first.add(Duration(days: p.days ~/ 2));
    return [t.short(p.first), t.short(mid), t.short(p.last)];
  }

  Widget _message(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(
          children: [
            Icon(icon, size: 40, color: MunjiColors.muted),
            const SizedBox(height: MunjiSpace.md),
            Text(text, style: MunjiText.body, textAlign: TextAlign.center),
          ],
        ),
      );
}

// ── pieces ─────────────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.unit,
    this.sub,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? unit;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x1A00537A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: MunjiColors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: MunjiText.small.copyWith(
                        color: MunjiColors.slate, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: MunjiColors.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    )),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Text(unit!, style: MunjiText.small.copyWith(fontSize: 11.5)),
                ],
              ],
            ),
          ),
          if (sub != null)
            Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MunjiText.small.copyWith(fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x1A00537A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: MunjiText.label),
          Text(subtitle, style: MunjiText.small.copyWith(fontSize: 11.5)),
          const SizedBox(height: MunjiSpace.md),
          child,
        ],
      ),
    );
  }
}

// ── strings ────────────────────────────────────────────────────────────────

class _T {
  const _T(this.ar);
  final bool ar;

  static const _monthsAr = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
  ];
  static const _monthsEn = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String short(DateTime d) => '${d.day} ${(ar ? _monthsAr : _monthsEn)[d.month - 1]}';

  String periodText(ReportPeriod p) {
    final y = p.last.year;
    if (p.days == 1) return '${short(p.first)} $y';
    return '${short(p.first)} – ${short(p.last)} $y';
  }

  String get title => ar ? 'التقارير' : 'Reports';
  String get threeDays => ar ? '3 أيام' : '3 days';
  String get week => ar ? 'أسبوع' : 'Week';
  String get month => ar ? 'شهر' : 'Month';
  String get custom => ar ? 'مخصص' : 'Custom';
  String get pickRange => ar ? 'اختر الفترة' : 'Choose a period';
  String get apply => ar ? 'تطبيق' : 'Apply';

  String get avgHr => ar ? 'متوسط النبض' : 'Avg heart rate';
  String get avgHrv => ar ? 'متوسط HRV' : 'Avg HRV';
  String get monitored => ar ? 'مدة المراقبة' : 'Monitored';
  String get hoursUnit => ar ? 'ساعة' : 'h';
  String coverage(int pct) => ar ? '$pct% من الفترة' : '$pct% of the period';
  String get recordings => ar ? 'تسجيلات ECG' : 'ECG recordings';
  String get ecg30 => ar ? '30 ثانية لكل تسجيل' : '30 s each';

  String get hrTitle => ar ? 'نبض القلب' : 'Heart rate';
  String get hrSub => ar ? 'المتوسط، والظل من الأدنى للأعلى (bpm)' : 'Average, shaded from min to max (bpm)';
  String get hrvTitle => ar ? 'تقلب النبض HRV' : 'Heart rate variability';
  String get wearTitle => ar ? 'وقت المراقبة' : 'Time monitored';
  String get wearSubHourly => ar ? 'دقائق في كل ساعة' : 'Minutes per hour';
  String get wearSubDaily => ar ? 'ساعات في كل يوم' : 'Hours per day';

  String get export => ar ? 'تصدير تقرير PDF' : 'Export PDF report';
  String get exportFailed => ar ? 'تعذّر إنشاء التقرير.' : 'Could not create the report.';
  String get loadFailed => ar ? 'تعذّر تحميل البيانات.' : 'Could not load the data.';
  String get empty => ar
      ? 'لا توجد بيانات في هذه الفترة.\nتُسجَّل البيانات كل ساعة أثناء اتصال اللاصقة.'
      : 'No data for this period.\nData is recorded every hour while the patch is connected.';
  String get disclaimer => ar
      ? 'للمتابعة فقط، وليس تشخيصًا طبيًا. شارك التقرير مع طبيبك لتفسيره.'
      : 'For monitoring only, not a diagnosis. Share the report with your doctor to interpret it.';
}
