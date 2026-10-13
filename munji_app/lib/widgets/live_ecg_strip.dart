import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/device_config.dart';
import '../services/real_device_service.dart';
import '../theme/munji_theme.dart';

/// A small, patient-facing live ECG trace.
///
/// Unlike the engineer's live readings screen this one has no paper grid
/// and no fixed mV scale: it fits the trace to its own height so a patient
/// sees their heartbeat clearly whatever the electrode contact is like.
/// The scale has a floor, so a flat line with noise is drawn as a flat
/// line rather than blown up into fake beats.
class LiveEcgStrip extends StatefulWidget {
  const LiveEcgStrip({
    super.key,
    required this.service,
    this.seconds = 3,
    this.height = 72,
  });

  final RealMunjiDeviceService service;
  final int seconds;
  final double height;

  @override
  State<LiveEcgStrip> createState() => _LiveEcgStripState();
}

class _LiveEcgStripState extends State<LiveEcgStrip> {
  late final int _n = DeviceConfig.sampleRateHz * widget.seconds;
  late final Float32List _trace = Float32List(_n)
    ..fillRange(0, _n, double.nan);
  int _cursor = 0;
  final _repaint = ValueNotifier<int>(0);
  StreamSubscription<EcgPacket>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.service.ecgStream.listen(_onPacket);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repaint.dispose();
    super.dispose();
  }

  void _onPacket(EcgPacket p) {
    for (final raw in p.samples) {
      _trace[_cursor] = raw * DeviceConfig.uvPerLsb / 1000; // mV
      _cursor = (_cursor + 1) % _n;
    }
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      // time runs left to right on an ECG in every language
      textDirection: TextDirection.ltr,
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: _StripPainter(
            trace: _trace,
            cursor: () => _cursor,
            repaint: _repaint,
          ),
        ),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.trace,
    required this.cursor,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Float32List trace;
  final int Function() cursor;

  /// Smallest half-range the trace is fitted to, in mV. Keeps noise on a
  /// flat signal looking flat.
  static const _minHalfRangeMv = 0.25;

  @override
  void paint(Canvas canvas, Size size) {
    // baseline guide
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = MunjiColors.line
        ..strokeWidth = 1,
    );

    var sum = 0.0;
    var k = 0;
    for (final v in trace) {
      if (v.isNaN) continue;
      sum += v;
      k++;
    }
    if (k == 0) return;
    final mean = sum / k;

    var maxDev = 0.0;
    for (final v in trace) {
      if (v.isNaN) continue;
      maxDev = math.max(maxDev, (v - mean).abs());
    }
    final half = math.max(maxDev * 1.1, _minHalfRangeMv);
    final pxPerMv = (size.height / 2) / half;

    final n = trace.length;
    final c = cursor();
    const gap = 10;
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
      final y = (mid - (v - mean) * pxPerMv).clamp(0.0, size.height);
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
        ..color = MunjiColors.blue
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.trace != trace;
}
