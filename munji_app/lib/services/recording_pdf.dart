import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'ecg_capture.dart';
import 'history_data.dart';
import 'report_data.dart';

/// One recording on A4 landscape, three 10-second rows at the standard
/// 25 mm/s and 10 mm/mV, so a doctor can read it like any printed strip.
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

    // 1 mm in PDF points
    const mm = PdfPageFormat.mm;
    const secondsPerRow = 10;
    final perRow = data.sampleRateHz * secondsPerRow;
    final rowW = secondsPerRow * 25 * mm; // 250 mm
    final rowH = 30 * mm; // 3 mV

    pw.Widget strip(int r) => pw.CustomPaint(
          size: PdfPoint(rowW, rowH),
          painter: (PdfGraphics g, PdfPoint size) {
            // grid, 1 mm minor, 5 mm major
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
            final from = r * perRow;
            final to = ((r + 1) * perRow).clamp(0, data.samples.length);
            if (to <= from) return;
            var sum = 0.0;
            for (var k = from; k < to; k++) {
              sum += data.mvAt(k);
            }
            final mean = sum / (to - from);
            // PDF y grows upwards
            final mid = size.y * 0.45;
            g
              ..setStrokeColor(PdfColors.black)
              ..setLineWidth(0.5);
            for (var k = from; k < to; k++) {
              final x = (k - from) / perRow * size.x;
              final y = (mid + (data.mvAt(k) - mean) * 10 * mm).clamp(0.0, size.y);
              if (k == from) {
                g.moveTo(x, y);
              } else {
                g.lineTo(x, y);
              }
            }
            g.strokePath();
          },
        );

    final rows = (data.samples.length / perRow).ceil();
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(20),
      textDirection: arabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
      build: (ctx) => pw.Column(
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
              '${arabic ? 'المدة' : 'Duration'}: ${data.duration.inSeconds} s',
              if (recording.deviceSerial != null) recording.deviceSerial!,
            ].join('     '),
            style: const pw.TextStyle(fontSize: 9),
          ),
          pw.SizedBox(height: 8),
          for (var r = 0; r < rows; r++) ...[
            pw.Directionality(
              textDirection: pw.TextDirection.ltr,
              child: pw.Row(children: [
                pw.SizedBox(
                  width: 22,
                  child: pw.Text('${r * secondsPerRow}s', style: const pw.TextStyle(fontSize: 7, color: muted)),
                ),
                strip(r),
              ]),
            ),
            pw.SizedBox(height: 6),
          ],
          pw.Spacer(),
          pw.Text(
            arabic
                ? '25 mm/s · 10 mm/mV · قطب واحد من لاصقة منجي. للمتابعة فقط، وليس تشخيصًا طبيًا.'
                : '25 mm/s · 10 mm/mV · single lead from the Munji patch. For monitoring only, not a diagnosis.',
            style: const pw.TextStyle(fontSize: 7.5, color: muted),
          ),
        ],
      ),
    ));
    return doc.save();
  }
}
