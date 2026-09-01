import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/munji_theme.dart';

/// What the orb is showing. Deliberately separate from `DevicePhase` — the
/// visual has fewer states than the service does, and keeping them apart
/// stops the animation from being rewritten every time a service state is
/// added.
enum OrbStage {
  /// Bluetooth mark, rings breathing outward, a bead drifting round the orbit.
  bluetooth,

  /// The device, with the scan ring turning.
  scanning,

  /// The device, still, with the check badge in brand blue.
  found,

  /// The device, with the handshake travelling down to the words.
  connecting,

  /// The device, check badge in green.
  connected,

  /// The device, dimmed. Nothing is moving because nothing is happening.
  offline,
}

/// The single object on the pairing screen.
///
/// Motion rules from the design spec: slow, one thing at a time, nothing
/// bounces or spins. The scan ring eases to a stop rather than vanishing,
/// which is why its rotation is driven by a ticker instead of a repeating
/// controller.
class PairingOrb extends StatefulWidget {
  const PairingOrb({
    super.key,
    required this.stage,
    required this.width,
  });

  final OrbStage stage;

  /// Available width, used to size everything the way the prototype's
  /// container queries did.
  final double width;

  @override
  State<PairingOrb> createState() => _PairingOrbState();
}

class _PairingOrbState extends State<PairingOrb> with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _orbit;
  late final AnimationController _breathe;
  late final AnimationController _beam;

  // Scan ring: speed eased toward a target, exactly as in the prototype, so
  // it glides to rest when the device is found.
  Ticker? _scanTicker;
  double _scanAngle = 0;
  double _scanSpeed = 0;
  double _scanTarget = 0;
  Duration _scanLast = Duration.zero;

  // A short pop when the device is first found.
  bool _pop = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 4600))
      ..repeat();
    _orbit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 14000))
      ..repeat();
    _breathe = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 6400))
      ..repeat();
    _beam = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat();

    _scanTicker = createTicker(_onScanTick);
    _syncScan();
  }

  @override
  void didUpdateWidget(PairingOrb old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) {
      _syncScan();
      if (widget.stage == OrbStage.found && old.stage == OrbStage.scanning) {
        setState(() => _pop = true);
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _pop = false);
        });
      }
    }
  }

  void _syncScan() {
    _scanTarget = widget.stage == OrbStage.scanning ? 72 : 0;
    if (_scanTarget > 0 && !(_scanTicker?.isActive ?? false)) {
      _scanLast = Duration.zero;
      _scanTicker?.start();
    }
  }

  void _onScanTick(Duration elapsed) {
    if (_scanLast == Duration.zero) _scanLast = elapsed;
    final dtMs =
        math.min(50.0, (elapsed - _scanLast).inMicroseconds / 1000.0);
    _scanLast = elapsed;

    _scanSpeed += (_scanTarget - _scanSpeed) * math.min(1.0, dtMs / 500.0);
    _scanAngle = (_scanAngle + _scanSpeed * dtMs / 1000.0) % 360.0;

    if (_scanTarget <= 0 && _scanSpeed <= 0.3) {
      _scanSpeed = 0;
      _scanLast = Duration.zero;
      _scanTicker?.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scanTicker?.dispose();
    _pulse.dispose();
    _orbit.dispose();
    _breathe.dispose();
    _beam.dispose();
    super.dispose();
  }

  // ---- sizing, ported from the prototype's clamp() rules ----

  double get _orb => _clamp(196, 0.68, 248);

  double _clamp(double lo, double factor, double hi) {
    final v = widget.width * factor;
    return v < lo ? lo : (v > hi ? hi : v);
  }

  bool get _showDevice => widget.stage != OrbStage.bluetooth;
  bool get _showCheck =>
      widget.stage == OrbStage.found ||
      widget.stage == OrbStage.connecting ||
      widget.stage == OrbStage.connected;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final orb = _orb;
    final btSize = _clamp(94, 0.335, 118);
    final devWidth = _clamp(120, 0.44, 160);
    final checkSize = _clamp(30, 0.11, 38);
    final travel = _clamp(30, 0.11, 42);

    return SizedBox(
      width: orb,
      height: orb + travel,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          SizedBox(
            width: orb,
            height: orb,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // rings breathing outward — step one only
                if (widget.stage == OrbStage.bluetooth) ...[
                  _pulseRing(0.0, orb),
                  _pulseRing(1.53 / 4.6, orb),
                  _pulseRing(3.06 / 4.6, orb),
                ],

                // the still outer ring
                Container(
                  width: orb,
                  height: orb,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: MunjiColors.blue.withValues(alpha: 0.07),
                        width: 1),
                  ),
                ),

                // the bead drifting round the orbit
                if (widget.stage == OrbStage.bluetooth)
                  AnimatedBuilder(
                    animation: _orbit,
                    builder: (_, __) => Transform.rotate(
                      angle: _orbit.value * 2 * math.pi,
                      child: SizedBox(
                        width: orb,
                        height: orb,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Transform.translate(
                            offset: const Offset(0, -3),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: MunjiColors.blue500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // the Bluetooth mark
                AnimatedOpacity(
                  opacity: widget.stage == OrbStage.bluetooth ? 1 : 0,
                  duration: const Duration(milliseconds: 500),
                  child: AnimatedScale(
                    scale: widget.stage == OrbStage.bluetooth ? 1 : 0.9,
                    duration: const Duration(milliseconds: 550),
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    child: Container(
                      width: btSize,
                      height: btSize,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: MunjiColors.blue,
                      ),
                      child: Center(
                        child: CustomPaint(
                          size: Size.square(_clamp(44, 0.156, 56)),
                          painter: _BluetoothMarkPainter(),
                        ),
                      ),
                    ),
                  ),
                ),

                // the scan ring
                AnimatedOpacity(
                  opacity: widget.stage == OrbStage.scanning ? 1 : 0,
                  duration: const Duration(milliseconds: 700),
                  child: Transform.rotate(
                    angle: _scanAngle * math.pi / 180,
                    child: CustomPaint(
                      size: Size.square(orb),
                      painter: _ScanRingPainter(),
                    ),
                  ),
                ),

                // the device
                AnimatedOpacity(
                  opacity: _showDevice
                      ? (widget.stage == OrbStage.offline ? 0.42 : 1)
                      : 0,
                  duration: const Duration(milliseconds: 550),
                  child: AnimatedScale(
                    scale: !_showDevice ? 0.9 : (_pop ? 1.06 : 1.0),
                    duration: const Duration(milliseconds: 600),
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    child: AnimatedBuilder(
                      animation: _breathe,
                      builder: (_, child) {
                        // 1 → 1.016 → 1, the same slow breath as the mockup.
                        final s = _showDevice &&
                                widget.stage != OrbStage.offline
                            ? 1 +
                                0.016 *
                                    (0.5 -
                                        0.5 *
                                            math.cos(_breathe.value *
                                                2 *
                                                math.pi))
                            : 1.0;
                        return Transform.scale(scale: s, child: child);
                      },
                      child: SizedBox(
                        width: devWidth,
                        height: devWidth * 560 / 448,
                        child: Image.asset(
                          'assets/munji_device.webp',
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                          // Never let a missing asset take the screen down —
                          // the page still has to tell the user their status.
                          errorBuilder: (_, __, ___) => Center(
                            child: Container(
                              width: devWidth * 0.72,
                              height: devWidth * 0.72,
                              decoration: BoxDecoration(
                                color: MunjiColors.blue100,
                                borderRadius:
                                    BorderRadius.circular(devWidth * 0.24),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // the check badge
                Positioned(
                  top: orb * 0.06,
                  left: rtl ? orb * 0.07 : null,
                  right: rtl ? null : orb * 0.07,
                  child: AnimatedOpacity(
                    opacity: _showCheck ? 1 : 0,
                    duration: const Duration(milliseconds: 450),
                    child: AnimatedScale(
                      scale: _showCheck ? 1 : 0.66,
                      duration: const Duration(milliseconds: 550),
                      curve: const Cubic(0.22, 1, 0.36, 1),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: checkSize,
                        height: checkSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.stage == OrbStage.connected
                              ? MunjiColors.green
                              : MunjiColors.blue,
                        ),
                        child: Center(
                          child: CustomPaint(
                            size: Size.square(checkSize * 0.47),
                            painter: _CheckPainter(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // the handshake travelling down to the words
          Positioned(
            top: orb,
            child: SizedBox(
              width: 6,
              height: travel,
              child: widget.stage == OrbStage.connecting
                  ? AnimatedBuilder(
                      animation: _beam,
                      builder: (_, __) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _beamDot(0.0, travel),
                          _beamDot(0.38 / 1.5, travel),
                          _beamDot(0.76 / 1.5, travel),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pulseRing(double offset, double orb) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) {
        final t = (_pulse.value + offset) % 1.0;
        // scale .44 → 1, eased hard out so it slows as it fades
        final eased = const Cubic(0.32, 0.06, 0.36, 1).transform(t);
        final scale = 0.44 + (1 - 0.44) * eased;
        // opacity 0 → .9 by 14%, then back to 0
        final opacity =
            t < 0.14 ? (t / 0.14) * 0.9 : 0.9 * (1 - (t - 0.14) / 0.86);
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: orb,
              height: orb,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: MunjiColors.blue.withValues(alpha: 0.16), width: 1),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _beamDot(double delay, double travel) {
    final t = (_beam.value + (1 - delay)) % 1.0;
    final opacity = t < 0.22
        ? (t / 0.22) * 0.85
        : (t < 0.78 ? 0.85 : 0.85 * (1 - (t - 0.78) / 0.22));
    return Positioned(
      top: t * travel,
      left: 0,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: MunjiColors.blue500,
          ),
        ),
      ),
    );
  }
}

/// The Bluetooth mark, drawn rather than rasterised — v55 rejected the bitmap
/// for looking soft at large sizes. A path is crisp at any size.
class _BluetoothMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24.0;
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(12 * k, 2.6 * k)
      ..lineTo(12 * k, 21.4 * k)
      ..moveTo(12 * k, 2.6 * k)
      ..lineTo(17.7 * k, 7.3 * k)
      ..lineTo(6.3 * k, 16.7 * k)
      ..moveTo(12 * k, 21.4 * k)
      ..lineTo(17.7 * k, 16.7 * k)
      ..lineTo(6.3 * k, 7.3 * k);

    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// A 91° arc with a bead at its leading edge. Matches the prototype's
/// stroke-dasharray of 150 on a 591-unit circumference.
class _ScanRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - 1;
    final c = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: c, radius: r);

    final arc = Paint()
      ..color = MunjiColors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // 150 / 591 of a full turn, ending at the 3 o'clock position.
    const sweep = 150 / 591 * 2 * math.pi;
    canvas.drawArc(rect, -sweep, sweep, false, arc);

    // the bead, ringed in white so it reads over the arc
    final dot = Offset(c.dx + r, c.dy);
    canvas.drawCircle(dot, 5.5, Paint()..color = MunjiColors.blue);
    canvas.drawCircle(
      dot,
      5.5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _CheckPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 18.0;
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(
      Path()
        ..moveTo(3 * k, 9.4 * k)
        ..lineTo(7.2 * k, 13.6 * k)
        ..lineTo(15 * k, 4.6 * k),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
