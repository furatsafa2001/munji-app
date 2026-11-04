import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../services/ecg_capture.dart';
import '../services/history_data.dart';
import '../services/recording_pdf.dart';
import '../services/report_data.dart';
import '../theme/munji_theme.dart';
import '../widgets/ecg_paper.dart';

/// Every 30-second recording the patient made, newest first, filtered by
/// the same periods as reports (3 days, week, month, custom).
class HistoryScreen extends StatefulWidget {
  HistoryScreen({
    super.key,
    required this.isArabic,
    required this.fullName,
    this.patientId,
    HistoryRepository? repository,
  }) : repository = repository ?? HistoryRepository();

  final bool isArabic;
  final String fullName;
  final HistoryRepository repository;

  /// Whose recordings. Null for the signed-in patient. A linked caregiver
  /// passes the patient's id and gets a read-only view: they can open and
  /// share a recording's PDF, but not keep or delete it (only the patient
  /// can, and the rules say so too).
  final String? patientId;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  ReportRange _range = ReportRange.month;
  late ReportPeriod _period = ReportPeriod.of(_range);
  late Stream<List<Recording>> _stream =
      widget.repository.watch(_period, uid: widget.patientId);

  _T get t => _T(widget.isArabic);

  void _setPeriod(ReportRange r, ReportPeriod p) {
    setState(() {
      _range = r;
      _period = p;
      _stream = widget.repository.watch(p, uid: widget.patientId);
    });
  }

  Future<void> _pick(ReportRange r) async {
    if (r != ReportRange.custom) {
      _setPeriod(r, ReportPeriod.of(r));
      return;
    }
    final today = Riyadh.dateOf(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
      initialDateRange: DateTimeRange(start: _period.first, end: _period.last),
    );
    if (picked == null) return;
    _setPeriod(
      ReportRange.custom,
      ReportPeriod(
        DateTime.utc(picked.start.year, picked.start.month, picked.start.day),
        DateTime.utc(picked.end.year, picked.end.month, picked.end.day),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(
          widget.patientId == null ? t.title : '${t.title} · ${widget.fullName}',
          style: MunjiText.h3,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: StreamBuilder<List<Recording>>(
        stream: _stream,
        builder: (context, snap) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                MunjiSpace.lg, MunjiSpace.sm, MunjiSpace.lg, MunjiSpace.xxl),
            children: [
              _RangePicker(range: _range, onPick: _pick, t: t),
              const SizedBox(height: MunjiSpace.lg),
              if (snap.hasError)
                _message(Icons.cloud_off_rounded, t.loadFailed)
              else if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snap.data!.isEmpty)
                _message(Icons.monitor_heart_outlined, t.empty)
              else
                ..._grouped(snap.data!),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _grouped(List<Recording> list) {
    final out = <Widget>[];
    String? lastDay;
    for (final r in list) {
      final day = Riyadh.dayKey(Riyadh.dateOf(r.startedAt));
      if (day != lastDay) {
        lastDay = day;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
          child: Text(t.dayLabel(Riyadh.dateOf(r.startedAt)),
              style: MunjiText.label.copyWith(color: MunjiColors.slate)),
        ));
      }
      out.add(RecordingTile(
        recording: r,
        isArabic: widget.isArabic,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => RecordingScreen(
            recording: r,
            isArabic: widget.isArabic,
            fullName: widget.fullName,
            repository: widget.repository,
            readOnly: widget.patientId != null,
          ),
        )),
      ));
      out.add(const SizedBox(height: MunjiSpace.sm));
    }
    return out;
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

/// One row in a list of recordings. Also used by the Monitor tab.
class RecordingTile extends StatelessWidget {
  const RecordingTile({
    super.key,
    required this.recording,
    required this.isArabic,
    required this.onTap,
    this.showDay = false,
  });

  final Recording recording;
  final bool isArabic;
  final VoidCallback onTap;

  /// Outside the day-grouped history the time alone is ambiguous.
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final t = _T(isArabic);
    final r = recording;
    return Material(
      color: MunjiColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0x1A00537A)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: MunjiColors.blue50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.monitor_heart_outlined, color: MunjiColors.blue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      showDay
                          ? '${t.dayLabel(Riyadh.dateOf(r.startedAt))} · ${t.time(r.startedAt)}'
                          : t.time(r.startedAt),
                      style: MunjiText.label,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        t.seconds(r.durationSec),
                        if (r.kind == 'event') t.eventKind,
                      ].join(' · '),
                      style: MunjiText.small.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (r.saved)
                const Padding(
                  padding: EdgeInsetsDirectional.only(end: 8),
                  child: Icon(Icons.bookmark_rounded, size: 18, color: MunjiColors.blue),
                ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(r.avgHr == null ? '--' : r.avgHr!.round().toString(),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: MunjiColors.ink,
                          fontFeatures: [FontFeature.tabularFigures()],
                        )),
                    const SizedBox(width: 3),
                    Text('BPM', style: MunjiText.small.copyWith(fontSize: 10.5)),
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

/// One recording on ECG paper, with save, share as PDF, and delete.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({
    super.key,
    required this.recording,
    required this.isArabic,
    required this.fullName,
    required this.repository,
    this.readOnly = false,
  });

  final Recording recording;
  final bool isArabic;
  final String fullName;
  final HistoryRepository repository;

  /// A caregiver's view: open and share, never keep or delete.
  final bool readOnly;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final Future<EcgRecordingData> _data = widget.repository.load(widget.recording);
  late bool _saved = widget.recording.saved;
  bool _busy = false;

  _T get t => _T(widget.isArabic);

  void _snack(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _toggleSave() async {
    final next = !_saved;
    setState(() => _saved = next);
    try {
      await widget.repository.setSaved(widget.recording, next);
      if (mounted) _snack(next ? t.savedOn : t.savedOff);
    } catch (_) {
      if (mounted) {
        setState(() => _saved = !next);
        _snack(t.failed);
      }
    }
  }

  Future<void> _share(EcgRecordingData data) async {
    setState(() => _busy = true);
    try {
      final bytes = await RecordingPdf.build(
        recording: widget.recording,
        data: data,
        patientName: widget.fullName,
        arabic: widget.isArabic,
      );
      await Printing.sharePdf(bytes: bytes, filename: 'munji-ecg-${widget.recording.id}.pdf');
    } catch (_) {
      if (mounted) _snack(t.failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _confirming = false;

  Future<void> _delete() async {
    if (_confirming) return; // a double tap opens one dialog, not two
    _confirming = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.deleteTitle),
        content: Text(t.deleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: MunjiColors.red),
            child: Text(t.delete),
          ),
        ],
      ),
    );
    _confirming = false;
    if (ok != true || !mounted) return;
    try {
      await widget.repository.delete(widget.recording);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) _snack(t.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(t.dayLabel(Riyadh.dateOf(r.startedAt)), style: MunjiText.h3),
        actions: [
          if (!widget.readOnly)
          IconButton(
            tooltip: _saved ? t.unsave : t.save,
            onPressed: _toggleSave,
            icon: Icon(_saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                color: MunjiColors.blue),
          ),
        ],
      ),
      body: FutureBuilder<EcgRecordingData>(
        future: _data,
        builder: (context, snap) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                MunjiSpace.lg, MunjiSpace.sm, MunjiSpace.lg, MunjiSpace.xxl),
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: MunjiColors.surface,
                  borderRadius: BorderRadius.circular(MunjiRadius.r4),
                  border: Border.all(color: const Color(0x1A00537A)),
                ),
                child: Row(
                  children: [
                    Expanded(child: _Fact(value: t.time(r.startedAt), label: t.timeLabel)),
                    Expanded(
                      child: _Fact(
                        value: r.avgHr == null ? '--' : '${r.avgHr!.round()}',
                        unit: 'BPM',
                        label: t.avgHr,
                      ),
                    ),
                    Expanded(
                      child: _Fact(
                        value: r.rmssd == null ? '--' : '${r.rmssd!.round()}',
                        unit: 'ms',
                        label: 'HRV',
                      ),
                    ),
                    Expanded(child: _Fact(value: '${r.durationSec}', unit: t.secShort, label: t.duration)),
                  ],
                ),
              ),
              const SizedBox(height: MunjiSpace.md),
              Text('25 mm/s · 10 mm/mV', style: MunjiText.small.copyWith(fontSize: 11)),
              const SizedBox(height: MunjiSpace.sm),
              if (snap.hasError)
                Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Text(t.loadFailed, style: MunjiText.body, textAlign: TextAlign.center),
                )
              else if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => EcgZoomScreen(
                        data: snap.data!,
                        title: widget.isArabic ? 'تخطيط القلب مكبّرًا' : 'ECG, zoomed',
                      ),
                    )),
                    icon: const Icon(Icons.zoom_in_rounded),
                    label: Text(widget.isArabic ? 'تكبير' : 'Zoom'),
                  ),
                ),
                EcgPaper(data: snap.data!),
                const SizedBox(height: MunjiSpace.lg),
                ElevatedButton.icon(
                  onPressed: _busy ? null : () => _share(snap.data!),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.ios_share_rounded),
                  label: Text(t.share),
                ),
              ],
              const SizedBox(height: MunjiSpace.sm),
              if (!widget.readOnly)
              OutlinedButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(t.delete),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MunjiColors.red,
                  side: const BorderSide(color: MunjiColors.danger200),
                ),
              ),
              const SizedBox(height: MunjiSpace.md),
              if (!widget.readOnly) ...[
                Text(_saved ? t.keptForever : t.retention,
                    style: MunjiText.small.copyWith(fontSize: 11.5)),
                const SizedBox(height: 4),
              ],
              Text(t.disclaimer, style: MunjiText.small.copyWith(fontSize: 11.5)),
            ],
          );
        },
      ),
    );
  }
}

// ── pieces ─────────────────────────────────────────────────────────────────

class _RangePicker extends StatelessWidget {
  const _RangePicker({required this.range, required this.onPick, required this.t});

  final ReportRange range;
  final ValueChanged<ReportRange> onPick;
  final _T t;

  @override
  Widget build(BuildContext context) {
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
                onTap: () => onPick(r),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: range == r ? MunjiColors.blue : Colors.transparent,
                    borderRadius: BorderRadius.circular(MunjiRadius.pill),
                  ),
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: range == r ? Colors.white : MunjiColors.slate,
                      )),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.value, required this.label, this.unit});
  final String value;
  final String? unit;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: MunjiColors.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    )),
                if (unit != null) ...[
                  const SizedBox(width: 3),
                  Text(unit!, style: MunjiText.small.copyWith(fontSize: 11)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: MunjiText.small.copyWith(color: MunjiColors.slate)),
        ],
      );
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
  static const _daysAr = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
  static const _daysEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String dayLabel(DateTime riyadhDate) {
    final today = Riyadh.dateOf(DateTime.now());
    final diff = today.difference(riyadhDate).inDays;
    if (diff == 0) return ar ? 'اليوم' : 'Today';
    if (diff == 1) return ar ? 'أمس' : 'Yesterday';
    final wd = (ar ? _daysAr : _daysEn)[riyadhDate.weekday - 1];
    final m = (ar ? _monthsAr : _monthsEn)[riyadhDate.month - 1];
    return '$wd ${riyadhDate.day} $m';
  }

  String time(DateTime t) {
    final r = t.toUtc().add(Riyadh.offset);
    final h = r.hour % 12 == 0 ? 12 : r.hour % 12;
    final mm = r.minute.toString().padLeft(2, '0');
    final pm = r.hour >= 12;
    return ar ? '$h:$mm ${pm ? 'م' : 'ص'}' : '$h:$mm ${pm ? 'PM' : 'AM'}';
  }

  String get title => ar ? 'سجل التسجيلات' : 'Recordings';
  String get threeDays => ar ? '3 أيام' : '3 days';
  String get week => ar ? 'أسبوع' : 'Week';
  String get month => ar ? 'شهر' : 'Month';
  String get custom => ar ? 'مخصص' : 'Custom';
  String seconds(int s) => ar ? '$s ثانية' : '$s s';
  String get eventKind => ar ? 'تسجيل تنبيه' : 'Alert';
  String get empty => ar
      ? 'لا توجد تسجيلات في هذه الفترة.\nسجّل من تبويب القياس.'
      : 'No recordings in this period.\nRecord one from the Monitor tab.';
  String get loadFailed => ar ? 'تعذّر التحميل.' : 'Could not load.';

  String get timeLabel => ar ? 'الوقت' : 'Time';
  String get avgHr => ar ? 'متوسط النبض' : 'Avg HR';
  String get duration => ar ? 'المدة' : 'Duration';
  String get secShort => ar ? 'ث' : 's';
  String get save => ar ? 'احفظ' : 'Keep';
  String get unsave => ar ? 'إلغاء الحفظ' : 'Don\'t keep';
  String get savedOn => ar ? 'سيُحتفظ بالتسجيل دائمًا' : 'This recording will be kept';
  String get savedOff => ar ? 'سيُحذف بعد 90 يومًا' : 'It will be deleted after 90 days';
  String get share => ar ? 'مشاركة PDF مع الطبيب' : 'Share PDF with a doctor';
  String get delete => ar ? 'حذف التسجيل' : 'Delete recording';
  String get deleteTitle => ar ? 'حذف التسجيل؟' : 'Delete this recording?';
  String get deleteBody => ar ? 'لا يمكن التراجع عن الحذف.' : 'This cannot be undone.';
  String get cancel => ar ? 'إلغاء' : 'Cancel';
  String get failed => ar ? 'حدث خطأ، حاول مجددًا.' : 'Something went wrong. Try again.';
  String get retention => ar
      ? 'التسجيلات غير المحفوظة تُحذف تلقائيًا بعد 90 يومًا. اضغط 🔖 للاحتفاظ به.'
      : 'Recordings not kept are deleted after 90 days. Tap 🔖 to keep this one.';
  String get keptForever => ar ? 'هذا التسجيل محفوظ ولن يُحذف تلقائيًا.' : 'This recording is kept and will not expire.';
  String get disclaimer => ar ? 'للمتابعة فقط، وليس تشخيصًا طبيًا.' : 'For monitoring only, not a diagnosis.';
}
