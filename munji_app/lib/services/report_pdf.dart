import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'report_data.dart';

/// The period report as a PDF, in the app's language.
///
/// Always one row per day, even when the screen showed hours, so a printed
/// month fits on a page or two and a doctor can scan it. The figures are
/// the same ones the screen shows (ReportSummary), so the two never
/// disagree. Font is Tajawal, bundled, because the default PDF fonts have
/// no Arabic.
class ReportPdf {
  static Future<Uint8List> build({
    required ReportSummary summary,
    required String patientName,
    required bool arabic,
    DateTime? generatedAt,
  }) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Bold.ttf'));
    final t = _T(arabic);
    final p = summary.period;
    final days = _byDay(summary);
    final now = generatedAt ?? DateTime.now();

    final doc = pw.Document(
      title: t.title,
      author: 'Munji',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );

    const blue = PdfColor.fromInt(0xFF00537A);
    const muted = PdfColor.fromInt(0xFF6B7C8F);
    const line = PdfColor.fromInt(0xFFE3EAF1);

    pw.Widget stat(String label, String value, [String? sub]) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            margin: const pw.EdgeInsets.symmetric(horizontal: 3),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: line),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: muted)),
                pw.SizedBox(height: 4),
                pw.Text(value, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                if (sub != null)
                  pw.Text(sub, style: const pw.TextStyle(fontSize: 8, color: muted)),
              ],
            ),
          ),
        );

    String n(double? v) => v == null ? '-' : v.round().toString();
    String hours(int min) => (min / 60).toStringAsFixed(1);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        header: (ctx) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 8),
          margin: const pw.EdgeInsets.only(bottom: 12),
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: blue, width: 1.5)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(t.title,
                  style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold, color: blue)),
              pw.Text('Munji', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: blue)),
            ],
          ),
        ),
        footer: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Text(t.disclaimer, style: const pw.TextStyle(fontSize: 7.5, color: muted)),
            pw.SizedBox(height: 4),
            pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: muted),
                textAlign: pw.TextAlign.center),
          ],
        ),
        build: (ctx) => [
          // who and when
          pw.Table(
            columnWidths: const {0: pw.FixedColumnWidth(90), 1: pw.FlexColumnWidth()},
            children: [
              _kv(t.patient, patientName.isEmpty ? '-' : patientName),
              _kv(t.period, '${t.date(p.first)}  –  ${t.date(p.last)}  (${p.days} ${t.daysWord})'),
              _kv(t.generated, '${t.date(Riyadh.dateOf(now))}  ${_hm(now)}'),
            ],
          ),
          pw.SizedBox(height: 16),

          // the four numbers
          pw.Row(children: [
            stat(t.avgHr, '${n(summary.hrAvg)} bpm',
                summary.hrMin == null ? null : '${t.range}: ${n(summary.hrMin)} - ${n(summary.hrMax)}'),
            stat(t.avgHrv, summary.hrvAvg == null ? '-' : '${n(summary.hrvAvg)} ms', 'RMSSD'),
            stat(t.monitored, '${hours(summary.monitoredMin)} ${t.hoursWord}',
                '${(summary.coverage * 100).round()}% ${t.ofPeriod}'),
            stat(t.recordings, '${summary.recordings}', t.ecg30),
          ]),
          pw.SizedBox(height: 20),

          pw.Text(t.daily, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headers: [t.colDate, t.colAvg, t.colMin, t.colMax, t.colHrv, t.colMonitored, t.colRec],
            data: [
              for (final d in days)
                [
                  t.date(d.start),
                  n(d.hrAvg),
                  n(d.hrMin),
                  n(d.hrMax),
                  n(d.hrvAvg),
                  d.monitoredMin == 0 ? '-' : hours(d.monitoredMin),
                  d.recordings == 0 ? '-' : '${d.recordings}',
                ],
            ],
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: blue),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.center,
            oddRowDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF5F8FB)),
            border: pw.TableBorder.all(color: line, width: 0.5),
          ),
          pw.SizedBox(height: 12),
          pw.Text(t.notes, style: const pw.TextStyle(fontSize: 8.5, color: muted)),
        ],
      ),
    );

    return doc.save();
  }

  static pw.TableRow _kv(String k, String v) => pw.TableRow(children: [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Text(k, style: const pw.TextStyle(fontSize: 10, color: PdfColor.fromInt(0xFF6B7C8F))),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Text(v, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ),
      ]);

  static String _hm(DateTime t) {
    final r = t.toUtc().add(Riyadh.offset);
    return '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}';
  }

  /// Hour buckets folded into days, using the same weighting as the server.
  static List<ReportBucket> _byDay(ReportSummary s) {
    if (!s.period.hourly) return s.buckets;
    final out = <ReportBucket>[];
    for (var d = 0; d < s.period.days; d++) {
      final hours = s.buckets.skip(d * 24).take(24).toList();
      final day = ReportSummary(ReportPeriod(s.period.first, s.period.first), hours);
      out.add(ReportBucket(
        start: s.period.first.add(Duration(days: d)),
        hrAvg: day.hrAvg,
        hrMin: day.hrMin,
        hrMax: day.hrMax,
        hrvAvg: day.hrvAvg,
        monitoredMin: day.monitoredMin,
        leadOffMin: day.leadOffMin,
        recordings: day.recordings,
      ));
    }
    return out;
  }
}

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

  String date(DateTime d) =>
      '${d.day} ${(ar ? _monthsAr : _monthsEn)[d.month - 1]} ${d.year}';

  String get title => ar ? 'تقرير متابعة القلب' : 'Heart monitoring report';
  String get patient => ar ? 'المريض' : 'Patient';
  String get period => ar ? 'الفترة' : 'Period';
  String get generated => ar ? 'تاريخ الإصدار' : 'Generated';
  String get daysWord => ar ? 'يوم' : 'days';
  String get hoursWord => ar ? 'ساعة' : 'h';
  String get avgHr => ar ? 'متوسط النبض' : 'Average heart rate';
  String get range => ar ? 'المدى' : 'Range';
  String get avgHrv => ar ? 'متوسط HRV' : 'Average HRV';
  String get monitored => ar ? 'مدة المراقبة' : 'Monitored';
  String get ofPeriod => ar ? 'من الفترة' : 'of the period';
  String get recordings => ar ? 'تسجيلات ECG' : 'ECG recordings';
  String get ecg30 => ar ? '30 ثانية لكل تسجيل' : '30 seconds each';
  String get daily => ar ? 'التفاصيل اليومية' : 'Day by day';
  String get colDate => ar ? 'التاريخ' : 'Date';
  String get colAvg => ar ? 'متوسط النبض' : 'Avg HR';
  String get colMin => ar ? 'الأدنى' : 'Min';
  String get colMax => ar ? 'الأعلى' : 'Max';
  String get colHrv => 'HRV (ms)';
  String get colMonitored => ar ? 'مراقبة (ساعة)' : 'Monitored (h)';
  String get colRec => ar ? 'تسجيلات' : 'Recordings';
  String get notes => ar
      ? 'النبض بالنبضة في الدقيقة (bpm). المتوسطات موزونة بمدة المراقبة. الخلايا الفارغة (-) تعني أن الجهاز لم يكن يراقب. HRV هو RMSSD من اللاصقة.'
      : 'Heart rate in beats per minute. Averages are weighted by monitored time. A dash means the patch was not monitoring. HRV is RMSSD from the patch.';
  String get disclaimer => ar
      ? 'هذا التقرير من جهاز منجي للمتابعة المنزلية، وليس تشخيصًا طبيًا ولا يغني عن رأي الطبيب.'
      : 'This report comes from the Munji home monitoring patch. It is not a medical diagnosis and does not replace a doctor\'s assessment.';
}
