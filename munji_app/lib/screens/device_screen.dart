import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../l10n/device_strings.dart';
import '../services/device_config.dart';
import '../services/device_service.dart';
import '../services/real_device_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/pairing_orb.dart';
import 'live_readings_screen.dart';

/// Why this screen exists twice.
///
/// [setup] runs once, straight after sign-up. There is no way back — Munji
/// cannot monitor anything until the device is paired, so offering a back
/// button would just produce accounts that do nothing.
///
/// [settings] is the page reached from Profile → Devices. Because the device
/// is worn and stays connected, this is almost always a *status* page, not a
/// wizard: it opens on "monitoring is live" and only turns into a recovery
/// flow when the link actually drops.
enum DeviceScreenMode { setup, settings }

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.isArabic,
    this.mode = DeviceScreenMode.settings,
    this.onDone,
  });

  final bool isArabic;
  final DeviceScreenMode mode;

  /// Called when setup finishes. Send the user to the dashboard here.
  final VoidCallback? onDone;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  final _service = MunjiDevice.instance;
  StreamSubscription<DeviceState>? _sub;
  Timer? _clock;
  late DeviceState _state;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _state = _service.state;
    _sub = _service.changes.listen((s) {
      if (!mounted) return;
      final wasConnecting = _state.phase == DevicePhase.connecting;
      setState(() => _state = s);
      if (wasConnecting && s.phase == DevicePhase.connected) {
        _toast(DS(widget.isArabic).deviceConnectedToast);
      }
    });
    // Keeps "updated 4s ago" honest without rebuilding the whole tree.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _state.phase == DevicePhase.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: MunjiText.label.copyWith(color: Colors.white)),
        backgroundColor: MunjiColors.ink,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MunjiRadius.r2)),
      ));
  }

  // ---- mapping service state onto what the screen shows ----

  OrbStage get _orbStage {
    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
      case DevicePhase.idle:
        return OrbStage.bluetooth;
      case DevicePhase.scanning:
        return OrbStage.scanning;
      case DevicePhase.found:
        return OrbStage.found;
      case DevicePhase.connecting:
      case DevicePhase.reconnecting:
        return OrbStage.connecting;
      case DevicePhase.connected:
        return OrbStage.connected;
      case DevicePhase.offline:
        return OrbStage.offline;
    }
  }

  /// 1, 2 or 3 — searching and found both live inside step two, as in the
  /// prototype.
  int get _step {
    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
      case DevicePhase.idle:
        return 1;
      case DevicePhase.scanning:
      case DevicePhase.found:
        return 2;
      default:
        return 3;
    }
  }

  String _lead(DS t) {
    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
        return t.bluetoothOff;
      case DevicePhase.idle:
        return t.turnOnBluetooth;
      case DevicePhase.scanning:
        return t.searching;
      case DevicePhase.found:
        return t.deviceFound;
      case DevicePhase.connecting:
        return t.connecting;
      case DevicePhase.reconnecting:
        return t.reconnecting;
      case DevicePhase.connected:
        return widget.mode == DeviceScreenMode.settings
            ? t.monitoringLive
            : t.connected;
      case DevicePhase.offline:
        return t.deviceOffline;
    }
  }

  String _subText(DS t) {
    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
        return t.bluetoothOffSub;
      case DevicePhase.idle:
        return t.turnOnBluetoothSub;
      case DevicePhase.scanning:
        return t.searchingSub;
      case DevicePhase.found:
        return t.foundSub;
      case DevicePhase.connecting:
        return t.connectingSub;
      case DevicePhase.reconnecting:
        return t.reconnectingSub;
      case DevicePhase.connected:
        return widget.mode == DeviceScreenMode.settings
            ? t.streamingNow
            : t.connectedSub(_state.battery ?? 0);
      case DevicePhase.offline:
        return (_state.battery ?? 1) <= 0
            ? t.batteryEmptySub
            : t.deviceOfflineSub;
    }
  }

  /// Null means no button at all — the scanning step has none, because there
  /// is nothing for the user to decide while Munji is looking.
  String? _buttonLabel(DS t) {
    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
        return t.openSettings;
      case DevicePhase.idle:
        return t.continueLabel;
      case DevicePhase.scanning:
        return null;
      case DevicePhase.found:
        return t.connect;
      case DevicePhase.connecting:
        return t.connectingBtn;
      case DevicePhase.reconnecting:
        return null;
      case DevicePhase.connected:
        return widget.mode == DeviceScreenMode.setup ? t.startUsing : t.done;
      case DevicePhase.offline:
        return t.tryAgain;
    }
  }

  bool get _buttonWaiting => _state.phase == DevicePhase.connecting;

  Future<void> _onTap() async {
    setState(() => _pressed = true);
    await Future.delayed(const Duration(milliseconds: 170));
    if (!mounted) return;
    setState(() => _pressed = false);

    switch (_state.phase) {
      case DevicePhase.bluetoothOff:
        await _service.refresh();
        break;
      case DevicePhase.idle:
        await _service.startScan();
        break;
      case DevicePhase.found:
      case DevicePhase.offline:
        await _service.connect();
        break;
      case DevicePhase.connected:
        if (widget.mode == DeviceScreenMode.setup) {
          _toast(DS(widget.isArabic).setupComplete);
          widget.onDone?.call();
        } else if (Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DS(widget.isArabic);
    final w = MediaQuery.sizeOf(context).width;
    final label = _buttonLabel(t);
    final isSetup = widget.mode == DeviceScreenMode.setup;

    return Scaffold(
      body: Container(
        // Full-bleed white → soft grey. No cards on this screen: the device
        // is the only object, the words sit under it, the action sits at the foot.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFFFFF), Color(0xFFFAFBFC), Color(0xFFF6F8F9)],
            stops: [0.0, 0.52, 1.0],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: (w * 0.07).clamp(20, 28), vertical: 16),
            child: Column(
              children: [
                // back button, setup has none on purpose
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      if (!isSetup)
                        _IconButton(
                          icon: Icons.arrow_back_ios_new_rounded,
                          onTap: () => Navigator.maybePop(context),
                        ),
                      const Spacer(),
                      if (_state.phase == DevicePhase.idle ||
                          _state.phase == DevicePhase.scanning)
                        _IconButton(
                          icon: Icons.help_outline_rounded,
                          onTap: () => _showHelp(t),
                        ),
                    ],
                  ),
                ),

                // 1 · 2 · 3 — hidden once the device is simply up
                if (!(widget.mode == DeviceScreenMode.settings &&
                    _state.phase == DevicePhase.connected))
                  _StepDots(step: _step),

                // the stage
                Expanded(
                  child: Center(
                    child: PairingOrb(stage: _orbStage, width: w),
                  ),
                ),

                // the words
                _Words(
                  key: ValueKey(_state.phase),
                  lead: _lead(t),
                  sub: _subText(t),
                  showDots: _state.phase == DevicePhase.scanning ||
                      _state.phase == DevicePhase.reconnecting,
                  width: w,
                ),

                // live figures — only worth showing when there is a live link
                if (_state.phase == DevicePhase.connected &&
                    widget.mode == DeviceScreenMode.settings) ...[
                  SizedBox(height: (w * 0.056).clamp(16, 22)),
                  _StatsRow(state: _state, t: t),
                ],

                // the single action
                SizedBox(height: (w * 0.056).clamp(16, 22)),
                if (label != null)
                  AnimatedScale(
                    scale: _pressed ? 0.965 : 1,
                    duration: const Duration(milliseconds: 180),
                    curve: const Cubic(0.22, 1, 0.36, 1),
                    child: Opacity(
                      opacity: _buttonWaiting ? 0.55 : 1,
                      child: SizedBox(
                        width: double.infinity,
                        height: (w * 0.17).clamp(48, 54),
                        child: ElevatedButton(
                          onPressed: _buttonWaiting ? null : _onTap,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: MunjiColors.blue,
                            disabledBackgroundColor: MunjiColors.blue,
                            foregroundColor: Colors.white,
                            disabledForegroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                  (w * 0.05).clamp(14, 17)),
                            ),
                          ),
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ),
                  )
                else
                  SizedBox(height: (w * 0.17).clamp(48, 54)),

                // Bench testing only, see DeviceConfig.showLiveReadings.
                if (_state.phase == DevicePhase.connected &&
                    DeviceConfig.showLiveReadings &&
                    _service is RealMunjiDeviceService)
                  TextButton(
                    onPressed: _openLiveReadings,
                    child: Text(
                      widget.isArabic ? 'القراءات المباشرة' : 'Live readings',
                      style: MunjiText.label.copyWith(color: MunjiColors.blue),
                    ),
                  ),

                if (_state.paired &&
                    widget.mode == DeviceScreenMode.settings &&
                    _state.phase != DevicePhase.connecting)
                  TextButton(
                    onPressed: () => _confirmForget(t),
                    child: Text(t.forgetDevice,
                        style: MunjiText.small
                            .copyWith(color: MunjiColors.muted)),
                  ),

                if (kDebugMode) _DebugRow(service: _service),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openLiveReadings() {
    final service = _service;
    if (service is! RealMunjiDeviceService) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LiveReadingsScreen(
        service: service,
        isArabic: widget.isArabic,
      ),
    ));
  }

  void _showHelp(DS t) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.howToPair, style: MunjiText.h3),
            const SizedBox(height: 8),
            Text(t.howToPairBody,
                style: MunjiText.small.copyWith(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmForget(DS t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(t.forgetDevice, style: MunjiText.h3),
        content: Text(t.forgetConfirm, style: MunjiText.small),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.forget,
                style: const TextStyle(color: MunjiColors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await MunjiDevice.registry.markUnpaired();
      await _service.forget();
    }
  }
}

// ---------------------------------------------------------------- pieces

class _StepDots extends StatelessWidget {
  const _StepDots({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    Widget dot(int i) {
      final on = step == i;
      final done = step > i;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 450),
        curve: const Cubic(0.22, 1, 0.36, 1),
        width: on ? 24 : 8,
        height: 8,
        decoration: BoxDecoration(
          color: on
              ? MunjiColors.blue
              : done
                  ? MunjiColors.blue.withValues(alpha: 0.34)
                  : MunjiColors.blue100,
          borderRadius: BorderRadius.circular(99),
        ),
      );
    }

    Widget bar(int after) => AnimatedContainer(
          duration: const Duration(milliseconds: 450),
          margin: const EdgeInsets.symmetric(horizontal: 5),
          width: 20,
          height: 1.5,
          decoration: BoxDecoration(
            color: step > after
                ? MunjiColors.blue.withValues(alpha: 0.22)
                : MunjiColors.blue100,
            borderRadius: BorderRadius.circular(2),
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [dot(1), bar(1), dot(2), bar(2), dot(3)],
      ),
    );
  }
}

/// Lead line and sub line, sliding in from the side on every change — the
/// same 480ms ease as the prototype, mirrored in Arabic.
class _Words extends StatelessWidget {
  const _Words({
    super.key,
    required this.lead,
    required this.sub,
    required this.showDots,
    required this.width,
  });

  final String lead;
  final String sub;
  final bool showDots;
  final double width;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return TweenAnimationBuilder<double>(
      key: ValueKey('$lead|$sub'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 480),
      curve: const Cubic(0.22, 1, 0.36, 1),
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset((1 - v) * (rtl ? -20 : 20), 0),
          child: child,
        ),
      ),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: (width * 0.78).clamp(210, 280)),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    lead,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: (width * 0.059).clamp(16, 21),
                      fontWeight: FontWeight.w800,
                      color: MunjiColors.ink,
                      letterSpacing: -0.4,
                      height: 1.25,
                    ),
                  ),
                ),
                if (showDots) const _TypingDots(),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: (width * 0.039).clamp(11, 13.5),
                height: 1.55,
                fontWeight: FontWeight.w500,
                color: MunjiColors.slate,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 5, left: 3, right: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value + (1 - i * 0.13)) % 1.0;
            final o = t < 0.45 ? 0.2 + (t / 0.45) * 0.65 : 0.85 - ((t - 0.45) / 0.55) * 0.65;
            return Padding(
              padding: const EdgeInsets.only(left: 1.5, right: 1.5),
              child: Opacity(
                opacity: o.clamp(0.2, 0.85),
                child: Container(
                  width: 3.5,
                  height: 3.5,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: MunjiColors.muted),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// Battery, signal, last update. Only rendered on a live link — showing
/// stale figures next to "offline" is worse than showing nothing.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.state, required this.t});
  final DeviceState state;
  final DS t;

  String _ago() {
    final seen = state.lastSeen;
    if (seen == null) return t.justNow;
    final s = DateTime.now().difference(seen).inSeconds;
    if (s < 3) return t.justNow;
    if (s < 60) return t.secondsAgo(s);
    if (s < 3600) return t.minutesAgo(s ~/ 60);
    return t.hoursAgo(s ~/ 3600);
  }

  String _signal() {
    switch (state.signal) {
      case 3:
        return t.strong;
      case 2:
        return t.fair;
      case 1:
        return t.weak;
      default:
        return t.none;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget cell(IconData icon, String label, String value, Color tint) {
      return Expanded(
        child: Column(
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(height: 5),
            Text(value,
                style: MunjiText.label.copyWith(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(label,
                style: MunjiText.small.copyWith(fontSize: 10.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );
    }

    final b = state.battery ?? 0;
    return Row(
      children: [
        cell(Icons.battery_full_rounded, t.battery, '$b%',
            b <= 15 ? MunjiColors.orange : MunjiColors.ok700),
        cell(Icons.signal_cellular_alt_rounded, t.signal, _signal(),
            MunjiColors.ok700),
        cell(Icons.sync_rounded, t.lastUpdate, _ago(), MunjiColors.ok700),
      ],
    );
  }
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        width: 38,
        height: 38,
        child: Icon(icon, size: 17, color: MunjiColors.ink),
      ),
    );
  }
}

/// Debug builds only. Lets you reach the states the firmware will eventually
/// produce without a device on the desk.
class _DebugRow extends StatelessWidget {
  const _DebugRow({required this.service});
  final MunjiDeviceService service;

  @override
  Widget build(BuildContext context) {
    if (service is! FakeMunjiDeviceService) return const SizedBox.shrink();
    final f = service as FakeMunjiDeviceService;
    final s = MunjiText.small.copyWith(fontSize: 10.5);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(onPressed: f.simulateDrop, child: Text('drop', style: s)),
          TextButton(
              onPressed: f.simulateBatteryDead,
              child: Text('battery 0', style: s)),
          TextButton(
              onPressed: f.simulateBluetoothOff, child: Text('bt off', style: s)),
        ],
      ),
    );
  }
}
