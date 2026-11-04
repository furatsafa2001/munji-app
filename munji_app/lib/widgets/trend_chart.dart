import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/munji_theme.dart';

/// A small chart for the reports screen.
///
/// [values] are the line (nulls break it: unmonitored time is a gap, never
/// a line drawn through it). [low] and [high], if given, draw a soft band
/// behind the line, used for heart-rate min to max. [bars] draws columns
/// instead of a line, for monitored time.
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.values,
    this.low,
    this.high,
    this.bars = false,
    this.color = MunjiColors.blue,
    this.height = 140,
    this.xLabels = const [],
    this.unit = '',
    this.fixedMax,
  });

  final List<double?> values;
  final List<double?>? low;
  final List<double?>? high;
  final bool bars;
  final Color color;
  final double height;

  /// Up to three labels: start, middle, end.
  final List<String> xLabels;
  final String unit;

  /// For bars: the top of the scale (60 minutes, 24 hours…).
  final double? fixedMax;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      // time runs left to right on a chart in every language
      textDirection: TextDirection.ltr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: CustomPaint(
              painter: _TrendPainter(
                values: values,
                low: low,
                high: high,
                bars: bars,
                color: color,
                unit: unit,
                fixedMax: fixedMax,
              ),
            ),
          ),
          if (xLabels.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final l in xLabels)
                  Text(l, style: MunjiText.small.copyWith(fontSize: 10.5)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.values,
    required this.low,
    required this.high,
    required this.bars,
    required this.color,
    required this.unit,
    required this.fixedMax,
  });

  final List<double?> values;
  final List<double?>? low;
  final List<double?>? high;
  final bool bars;
  final Color color;
  final String unit;
  final double? fixedMax;

  static const _labelW = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n == 0) return;

    final all = <double>[
      ...values.whereType<double>(),
      ...?low?.whereType<double>(),
      ...?high?.whereType<double>(),
    ];
    if (all.isEmpty) {
      _empty(canvas, size);
      return;
    }

    double lo, hi;
    if (bars) {
      lo = 0;
      hi = fixedMax ?? all.reduce(math.max);
      if (hi <= 0) hi = 1;
    } else {
      lo = all.reduce(math.min);
      hi = all.reduce(math.max);
      final pad = math.max((hi - lo) * 0.15, 3);
      lo = (lo - pad).floorToDouble();
      hi = (hi + pad).ceilToDouble();
    }

    final plot = Rect.fromLTWH(_labelW, 6, size.width - _labelW, size.height - 12);
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    double x(int i) => n == 1
        ? plot.center.dx
        : plot.left + i / (n - 1) * plot.width;

    // grid and y labels
    final grid = Paint()
      ..color = MunjiColors.line
      ..strokeWidth = 1;
    for (final v in [lo, (lo + hi) / 2, hi]) {
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), grid);
      _text(canvas, v.round().toString(), Offset(0, yy - 7), _labelW - 6);
    }

    if (bars) {
      final w = math.max(2.0, plot.width / n * 0.62);
      final p = Paint()..color = color.withValues(alpha: 0.8);
      for (var i = 0; i < n; i++) {
        final v = values[i];
        if (v == null || v <= 0) continue;
        final cx = n == 1 ? plot.center.dx : plot.left + (i + 0.5) / n * plot.width;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - w / 2, y(math.min(v, hi)), cx + w / 2, plot.bottom),
            const Radius.circular(2),
          ),
          p,
        );
      }
      return;
    }

    // band
    if (low != null && high != null) {
      final band = Paint()
        ..color = color.withValues(alpha: 0.14)
        ..strokeWidth = math.max(2.0, plot.width / n * 0.5)
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < n; i++) {
        final a = low![i];
        final b = high![i];
        if (a == null || b == null) continue;
        canvas.drawLine(Offset(x(i), y(a)), Offset(x(i), y(b)), band);
      }
    }

    // line, broken where there is no data
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = color;
    final path = Path();
    var pen = false;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) {
        pen = false;
        continue;
      }
      final o = Offset(x(i), y(v));
      if (pen) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        pen = true;
      }
      // isolated points would be invisible as a line
      final prev = i > 0 ? values[i - 1] : null;
      final next = i < n - 1 ? values[i + 1] : null;
      if (prev == null && next == null) canvas.drawCircle(o, 2.5, dot);
    }
    canvas.drawPath(path, line);
  }

  void _empty(Canvas canvas, Size size) {
    final p = Paint()
      ..color = MunjiColors.line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), p);
  }

  void _text(Canvas canvas, String s, Offset at, double width) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: MunjiText.small.copyWith(fontSize: 10)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_TrendPainter old) => true;
}
