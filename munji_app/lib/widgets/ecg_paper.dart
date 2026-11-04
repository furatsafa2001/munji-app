import 'package:flutter/material.dart';

import '../services/ecg_capture.dart';
import '../theme/munji_theme.dart';

/// A whole recording on ECG paper, a few seconds per row, the way a
/// printed strip reads: one large square is 0.2 s across and 0.5 mV high
/// (25 mm/s, 10 mm/mV).
///
/// Each row is drawn around its own mean so baseline drift does not push
/// it off the paper. Values beyond the row's height are clipped, and the
/// clip is visible as a flat top: the paper never pretends to fit a
/// spike that it cut.
class EcgPaper extends StatelessWidget {
  const EcgPaper({super.key, required this.data, this.secondsPerRow = 2.5});

  final EcgRecordingData data;

  /// Fewer seconds per row means bigger squares. 2.5 s on a phone gives
  /// squares twice the size of the old 5 s rows, readable without zooming;
  /// EcgZoomScreen goes further with pinch-to-zoom.
  final double secondsPerRow;

  @override
  Widget build(BuildContext context) {
    final perRow = (data.sampleRateHz * secondsPerRow).round();
    final rows = (data.samples.length / perRow).ceil();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(builder: (context, c) {
        final big = c.maxWidth / (secondsPerRow / 0.2);
        final h = big * 6; // 3 mV tall
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r < rows; r++) ...[
              Row(
                children: [
                  Text('${_sec(r * secondsPerRow)}s',
                      style: MunjiText.small.copyWith(fontSize: 10)),
                ],
              ),
              const SizedBox(height: 2),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: h,
                  child: CustomPaint(
                    painter: _RowPainter(
                      data: data,
                      from: r * perRow,
                      to: ((r + 1) * perRow).clamp(0, data.samples.length),
                      perRow: perRow,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        );
      }),
    );
  }
}

String _sec(double s) =>
    s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1);

/// The recording full screen, pinch to zoom up to 6x and drag to move.
/// For reading details (P waves, QRS width) on a phone.
class EcgZoomScreen extends StatelessWidget {
  const EcgZoomScreen({super.key, required this.data, required this.title});
  final EcgRecordingData data;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.surface,
      appBar: AppBar(
        backgroundColor: MunjiColors.surface,
        surfaceTintColor: MunjiColors.surface,
        title: Text(title, style: MunjiText.h3),
      ),
      body: LayoutBuilder(builder: (context, c) {
        // wider than the screen so the starting view is already larger
        final width = c.maxWidth < 700 ? 700.0 : c.maxWidth;
        return InteractiveViewer(
          constrained: false,
          minScale: 0.5,
          maxScale: 6,
          boundaryMargin: const EdgeInsets.all(40),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: width,
              child: EcgPaper(data: data, secondsPerRow: 2.5),
            ),
          ),
        );
      }),
    );
  }
}

class _RowPainter extends CustomPainter {
  _RowPainter({required this.data, required this.from, required this.to, required this.perRow});

  final EcgRecordingData data;
  final int from;
  final int to;
  final int perRow;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFBFB));
    final big = size.width / (perRow / data.sampleRateHz / 0.2);
    final small = big / 5;
    final minor = Paint()
      ..color = const Color(0xFFF6DCDC)
      ..strokeWidth = 0.6;
    final major = Paint()
      ..color = const Color(0xFFE9AEAE)
      ..strokeWidth = 1;
    var i = 0;
    for (var x = 0.0; x <= size.width + 0.1; x += small, i++) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), i % 5 == 0 ? major : minor);
    }
    i = 0;
    for (var y = size.height; y >= -0.1; y -= small, i++) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), i % 5 == 0 ? major : minor);
    }

    if (to <= from) return;
    var sum = 0.0;
    for (var k = from; k < to; k++) {
      sum += data.mvAt(k);
    }
    final mean = sum / (to - from);
    final mid = size.height * 0.55;
    final pxPerMv = big / 0.5;

    final path = Path();
    for (var k = from; k < to; k++) {
      final x = (k - from) / perRow * size.width;
      final y = (mid - (data.mvAt(k) - mean) * pxPerMv).clamp(0.0, size.height);
      if (k == from) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = MunjiColors.ink
        ..strokeWidth = 1.3
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_RowPainter old) => old.data != data || old.from != from;
}
