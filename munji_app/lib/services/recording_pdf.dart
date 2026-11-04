import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'ecg_capture.dart';
import 'history_data.dart';
import 'report_data.dart';

/// One recording for a doctor, on A4 landscape:
///
///   page 1   the standard strip: 25 mm/s, 10 mm/mV, three 10-second rows,
///            the scale every ECG ruler and every cardiologist reads
///   page 2+  the same signal magnified x2: 50 mm/s, 20 mm/mV, 5 seconds
///            per row, for P waves, QRS width and intervals
///
/// Every row starts with a 1 mV calibration pulse, so the scale can be
/// checked on the paper itself, and every page states its scale and the
/// filter band. The band is the patch's own: the MAX30003 filters 0.5 to
/// 40 Hz on chip (monitoring bandwidth, not diagnostic), and the app
/// stores the samples as they arrive.
class RecordingPdf {
  static Future<Uint8List> build({
    required Recording recording,
    required EcgRecordingData data,
    required String patientName,
    required bool arabic,
  }) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Bold.ttf'));
    final doc = pw.Document(
      title: arabic ? 'تسجيل تخطيط القلب' : 'ECG recording',
      author: 'Munji',
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );

    const blue = PdfColor.fromInt(0xFF00537A);
    const muted = PdfColor.fromInt(0xFF6B7C8F);
    const minor = PdfColor.fromInt(0xFFF6DCDC);
    const major = PdfColor.fromInt(0xFFE9AEAE);

    final at = recording.startedAt.toUtc().add(Riyadh.offset);
    String two(int n) => n.toString().padLeft(2, '0');
    final when = '${at.year}-${two(at.month)}-${two(at.day)}  ${two(at.hour)}:${two(at.minute)}';
    final hr = recording.avgHr == null ? '-' : '${recording.avgHr!.round()} bpm';
    // 30 seconds is ultra-short HRV; say so, so it is read as an estimate
    final hrv = recording.rmssd == null
        ? '-'
        : '${recording.rmssd!.round()} ms (RMSSD, ${data.duration.inSeconds} ${arabic ? 'ث، قياس قصير' : 's, short-term'})';

    const mm = PdfPageFormat.mm;

    // One row of paper at a given scale, with its calibration pulse.
    pw.Widget strip({
      required int from,
      required int to,
      required double seconds,
      required double mmPerSec,
      required double mmPerMv,
      required double heightMm,
    }) {
      final w = seconds * mmPerSec * mm;
      final h = heightMm * mm;
      final pulseW = 0.2 * mmPerSec * mm + 4 * mm;

      void grid(PdfGraphics g, PdfPoint size) {
        for (var i = 0; i * mm <= size.x + 0.01; i++) {
          g
            ..setStrokeColor(i % 5 == 0 ? major : minor)
            ..setLineWidth(i % 5 == 0 ? 0.6 : 0.25)
            ..moveTo(i * mm, 0)
            ..lineTo(i * mm, size.y)
            ..strokePath();
        }
        for (var j = 0; j * mm <= size.y + 0.01; j++) {
          g
            ..setStrokeColor(j % 5 == 0 ? major : minor)
            ..setLineWidth(j % 5 == 0 ? 0.6 : 0.25)
            ..moveTo(0, j * mm)
            ..lineTo(size.x, j * mm)
            ..strokePath();
        }
      }

      final pulse = pw.CustomPaint(
        size: PdfPoint(pulseW, h),
        painter: (g, size) {
          grid(g, size);
          // PDF y grows upwards
          final base = size.y * 0.4;
          final top = base + mmPerMv * mm; // 1 mV
          final x0 = 2 * mm;
          final x1 = x0 + 0.2 * mmPerSec * mm; // 0.2 s wide
          g
            ..setStrokeColor(PdfColors.black)
            ..setLineWidth(0.8)
            ..moveTo(0, base)
            ..lineTo(x0, base)
            ..lineTo(x0, top)
            ..lineTo(x1, top)
            ..lineTo(x1, base)
            ..lineTo(size.x, base)
            ..strokePath();
        },
      );

      final trace = pw.CustomPaint(
        size: PdfPoint(w, h),
        painter: (g, size) {
          grid(g, size);
          if (to <= from) return;
          var sum = 0.0;
          for (var k = from; k < to; k++) {
            sum += data.mvAt(k);
          }
          final mean = sum / (to - from);
          final mid = size.y * 0.4;
          final perRow = seconds * data.sampleRateHz;
          g
            ..setStrokeColor(PdfColors.black)
            ..setLineWidth(0.8);
          for (var k = from; k < to; k++) {
            final x = (k - from) / perRow * size.x;
            final y = (mid + (data.mvAt(k) - mean) * mmPerMv * mm).clamp(0.0, size.y);
            if (k == from) {
              g.moveTo(x, y);
            } else {
              g.lineTo(x, y);
            }
          }
          g.strokePath();
        },
      );

      return pw.Row(children: [pulse, trace]);
    }

    pw.Widget header(String scale) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(arabic ? 'تسجيل تخطيط القلب' : 'ECG recording',
                    style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: blue)),
                pw.Text('Munji', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: blue)),
              ],
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              [
                '${arabic ? 'المريض' : 'Patient'}: ${patientName.isEmpty ? '-' : patientName}',
                '${arabic ? 'التاريخ' : 'Date'}: $when',
                '${arabic ? 'متوسط النبض' : 'Avg HR'}: $hr',
                'HRV: $hrv',
                '${arabic ? 'المدة' : 'Duration'}: ${data.duration.inSeconds} s',
                if (recording.deviceSerial != null) recording.deviceSerial!,
              ].join('     '),
              style: const pw.TextStyle(fontSize: 9),
            ),
            pw.SizedBox(height: 4),
            pw.Text(scale,
                style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: blue)),
            pw.SizedBox(height: 6),
          ],
        );

    final footer = pw.Text(
      arabic
          ? 'قطب واحد من لاصقة منجي. النبضة المستطيلة في بداية كل سطر = 1 mV. للمتابعة فقط، وليس تشخيصًا طبيًا.'
          : 'Single lead from the Munji patch. The square pulse at the start of each row is 1 mV. For monitoring only, not a diagnosis.',
      style: const pw.TextStyle(fontSize: 7.5, color: muted),
    );

    pw.Widget rowWithLabel(double startSec, pw.Widget s) => pw.Directionality(
          textDirection: pw.TextDirection.ltr,
          child: pw.Row(children: [
            pw.SizedBox(
              width: 22,
              child: pw.Text('${startSec.toStringAsFixed(0)}s',
                  style: const pw.TextStyle(fontSize: 7, color: muted)),
            ),
            s,
          ]),
        );

    void addPages({
      required String scale,
      required double seconds,
      required double mmPerSec,
      required double mmPerMv,
      required double heightMm,
      required int rowsPerPage,
    }) {
      final perRow = (seconds * data.sampleRateHz).round();
      final rows = (data.samples.length / perRow).ceil();
      for (var first = 0; first < rows; first += rowsPerPage) {
        final last = (first + rowsPerPage).clamp(0, rows);
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(20),
          textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              header(scale),
              for (var r = first; r < last; r++) ...[
                rowWithLabel(
                  r * seconds,
                  strip(
                    from: r * perRow,
                    to: ((r + 1) * perRow).clamp(0, data.samples.length),
                    seconds: seconds,
                    mmPerSec: mmPerSec,
                    mmPerMv: mmPerMv,
                    heightMm: heightMm,
                  ),
                ),
                pw.SizedBox(height: 5),
              ],
              pw.Spacer(),
              footer,
            ],
          ),
        ));
      }
    }

    // page 1: the standard strip, 4 mV tall rows so tall beats are not cut
    addPages(
      scale: arabic
          ? 'المقياس القياسي: 25 mm/s · 10 mm/mV · الترشيح 0.5-40 Hz'
          : 'Standard scale: 25 mm/s · 10 mm/mV · Filter 0.5-40 Hz',
      seconds: 10,
      mmPerSec: 25,
      mmPerMv: 10,
      heightMm: 40,
      rowsPerPage: 3,
    );

    // then the same signal magnified x2 in both directions
    addPages(
      scale: arabic
          ? 'مكبّر ×2: 50 mm/s · 20 mm/mV · الترشيح 0.5-40 Hz'
          : 'Magnified x2: 50 mm/s · 20 mm/mV · Filter 0.5-40 Hz',
      seconds: 5,
      mmPerSec: 50,
      mmPerMv: 20,
      heightMm: 50,
      rowsPerPage: 3,
    );

    return doc.save();
  }
}
