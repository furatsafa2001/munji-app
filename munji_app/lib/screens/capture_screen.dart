import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/device_service.dart';
import '../services/ecg_capture.dart';
import '../services/real_device_service.dart';
import '../services/recording_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/live_ecg_strip.dart';
import '../services/history_data.dart';
import 'history_screen.dart';

/// The one-time 30-second ECG capture: the patient's real trace.
///
/// Flow: ready -> recording (30 s) -> saving -> done, or failed with a
/// reason and a way forward. The recording stops early, with a clear
/// reason, if the patch disconnects, an electrode is off for more than
/// 3 seconds, data stops arriving, or too many packets are lost. A trace
/// with holes is worse than no trace, because someone may read it.
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.isArabic,
    this.fullName = '',
    RecordingService? recordings,
  }) : _recordings = recordings;

  final bool isArabic;
  final String fullName;
  final RecordingService? _recordings;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

enum _Phase { ready, recording, saving, done, failed }

class _CaptureScreenState extends State<CaptureScreen> {
  final MunjiDeviceService _service = MunjiDevice.instance;
  RealMunjiDeviceService? get _real =>
      _service is RealMunjiDeviceService ? _service : null;
  late final RecordingService _recordings = widget._recordings ?? RecordingService();
  final _history = HistoryRepository();
  late final Stream<List<Recording>> _latest = _history.latest();

  late DeviceState _state = _service.state;
  StreamSubscription<DeviceState>? _stateSub;

  _Phase _phase = _Phase.ready;
  CaptureBuffer? _buffer;
  CaptureFailure? _failure;
  RecordingResult? _result;

  // kept after a failed upload so "try again" re-sends the same recording
  Uint8List? _pendingBytes;
  String? _pendingId;
  double? _avgHr;
  DateTime? _startedAt;

  final _captureSubs = <StreamSubscription<dynamic>>[];
  Timer? _watchdog;
  DateTime? _leadsOffSince;
  DateTime? _lastPacketAt;

  _T get t => _T(widget.isArabic);

  @override
  void initState() {
    super.initState();
    _stateSub = _service.changes.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
      if (_phase == _Phase.recording && s.phase != DevicePhase.connected) {
        _fail(CaptureFailure.disconnected);
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _stopCapture();
    super.dispose();
  }

  bool get _connected => _state.phase == DevicePhase.connected;

  bool get _leadsOffNow {
    final l = _real?.leads;
    if (l == null) return false;
    if (DateTime.now().difference(l.receivedAt) > const Duration(seconds: 15)) return false;
    return !l.allAttached;
  }

  // ── capture ──────────────────────────────────────────────────────────────

  void _start() {
    final real = _real;
    if (real == null || !_connected) return;

    final buffer = CaptureBuffer();
    _stopCapture();
    setState(() {
      _buffer = buffer;
      _phase = _Phase.recording;
      _failure = null;
      _result = null;
      _pendingBytes = null;
      _pendingId = null;
      _leadsOffSince = null;
      _lastPacketAt = DateTime.now();
    });

    _captureSubs.add(real.ecgStream.listen((p) {
      if (_phase != _Phase.recording) return;
      _lastPacketAt = p.receivedAt;
      final failure = buffer.addPacket(
        sequence: p.sequence,
        packetSamples: p.samples,
        receivedAt: p.receivedAt,
      );
      if (failure != null) {
        _fail(failure);
      } else if (buffer.isFull) {
        _finish();
      }
    }));
    _captureSubs.add(real.heartStream.listen((h) => buffer.addBeat(h.bpm)));

    // once a second: countdown, electrode contact, data still arriving
    _watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_phase != _Phase.recording) return;
      final now = DateTime.now();
      if (_leadsOffNow) {
        _leadsOffSince ??= now;
        if (now.difference(_leadsOffSince!) > const Duration(seconds: 3)) {
          _fail(CaptureFailure.leadsOff);
          return;
        }
      } else {
        _leadsOffSince = null;
      }
      if (now.difference(_lastPacketAt!) > const Duration(seconds: 3)) {
        _fail(CaptureFailure.signalLost);
        return;
      }
      if (mounted) setState(() {});
    });
  }

  void _stopCapture() {
    for (final s in _captureSubs) {
      s.cancel();
    }
    _captureSubs.clear();
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _cancel() {
    _stopCapture();
    setState(() {
      _phase = _Phase.ready;
      _buffer = null;
    });
  }

  void _fail(CaptureFailure f) {
    _stopCapture();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _failure = f;
    });
  }

  Future<void> _finish() async {
    final buffer = _buffer!;
    _stopCapture();
    _pendingBytes = buffer.toFile();
    _pendingId = RecordingService.newId();
    _avgHr = buffer.avgHr;
    _startedAt = buffer.startedAt;
    await _upload();
  }

  Future<void> _upload() async {
    final bytes = _pendingBytes;
    final id = _pendingId;
    if (bytes == null || id == null) return;
    setState(() => _phase = _Phase.saving);
    try {
      final r = await _recordings.upload(
        id: id,
        bytes: bytes,
        avgHr: _avgHr,
        deviceSerial: _real?.serialNumber,
        firmware: _real?.firmwareVersion,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _phase = _Phase.done;
        _pendingBytes = null;
      });
    } on RecordingException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = e.failure;
      });
    }
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MunjiSpace.xs),
              child: Text(t.title, style: MunjiText.h1),
            ),
            const SizedBox(height: MunjiSpace.lg),
            switch (_phase) {
              _Phase.ready => _ready(),
              _Phase.recording => _recording(),
              _Phase.saving => _saving(),
              _Phase.done => _done(),
              _Phase.failed => _failed(),
            },
            if (_phase == _Phase.ready || _phase == _Phase.done) _recent(),
            const SizedBox(height: MunjiSpace.lg),
            Text(t.disclaimer,
                style: MunjiText.small.copyWith(fontSize: 11.5)),
          ],
        ),
      ),
    );
  }

  void _openHistory() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => HistoryScreen(isArabic: widget.isArabic, fullName: widget.fullName),
      ));

  /// The last three recordings, and the way into the full history.
  Widget _recent() {
    return StreamBuilder<List<Recording>>(
      stream: _latest,
      builder: (context, snap) {
        final list = snap.data ?? const <Recording>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: MunjiSpace.xl),
            Row(
              children: [
                Expanded(child: Text(t.recent, style: MunjiText.h3)),
                TextButton(onPressed: _openHistory, child: Text(t.seeAll)),
              ],
            ),
            const SizedBox(height: MunjiSpace.xs),
            if (snap.hasData && list.isEmpty)
              Text(t.noRecordings, style: MunjiText.small)
            else
              for (final r in list) ...[
                RecordingTile(
                  recording: r,
                  isArabic: widget.isArabic,
                  showDay: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => RecordingScreen(
                      recording: r,
                      isArabic: widget.isArabic,
                      fullName: widget.fullName,
                      repository: _history,
                    ),
                  )),
                ),
                const SizedBox(height: MunjiSpace.sm),
              ],
          ],
        );
      },
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: MunjiColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x1A00537A)),
          boxShadow: MunjiShadow.e1,
        ),
        child: child,
      );

  Widget _ready() {
    final leadsOff = _connected && _leadsOffNow;
    final canStart = _connected && !leadsOff && _real != null;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.readyTitle, style: MunjiText.h3),
          const SizedBox(height: MunjiSpace.md),
          _Step(icon: Icons.event_seat_outlined, text: t.step1),
          _Step(icon: Icons.do_not_touch_outlined, text: t.step2),
          _Step(icon: Icons.timer_outlined, text: t.step3),
          const SizedBox(height: MunjiSpace.lg),
          _Check(ok: _connected, text: _connected ? t.patchOk : t.patchNo),
          const SizedBox(height: 6),
          _Check(
            ok: _connected && !leadsOff,
            text: !_connected ? t.contactUnknown : (leadsOff ? t.contactNo : t.contactOk),
          ),
          const SizedBox(height: MunjiSpace.xl),
          ElevatedButton.icon(
            onPressed: canStart ? _start : null,
            icon: const Icon(Icons.fiber_manual_record_rounded),
            label: Text(t.start),
          ),
        ],
      ),
    );
  }

  Widget _recording() {
    final b = _buffer!;
    final real = _real!;
    final warn = _leadsOffSince != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          child: Column(
            children: [
              SizedBox(
                width: 132,
                height: 132,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CircularProgressIndicator(
                      value: b.progress,
                      strokeWidth: 8,
                      backgroundColor: MunjiColors.blue50,
                      color: MunjiColors.blue,
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${b.secondsLeft}',
                              style: const TextStyle(
                                fontSize: 44,
                                fontWeight: FontWeight.w800,
                                color: MunjiColors.ink,
                                fontFeatures: [FontFeature.tabularFigures()],
                              )),
                          Text(t.seconds, style: MunjiText.small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: MunjiSpace.lg),
              Text(warn ? t.holdContact : t.stayStill,
                  style: MunjiText.label.copyWith(
                      color: warn ? MunjiColors.warn700 : MunjiColors.slate),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
        const SizedBox(height: MunjiSpace.md),
        _card(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                        color: MunjiColors.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(t.recordingLabel, style: MunjiText.label),
                ],
              ),
              const SizedBox(height: MunjiSpace.sm),
              LiveEcgStrip(service: real, height: 140),
            ],
          ),
        ),
        const SizedBox(height: MunjiSpace.lg),
        OutlinedButton(onPressed: _cancel, child: Text(t.cancel)),
      ],
    );
  }

  Widget _saving() {
    return _card(
      child: Column(
        children: [
          const SizedBox(height: MunjiSpace.md),
          const CircularProgressIndicator(),
          const SizedBox(height: MunjiSpace.lg),
          Text(t.saving, style: MunjiText.h3),
          const SizedBox(height: 4),
          Text(t.savingSub, style: MunjiText.small, textAlign: TextAlign.center),
          const SizedBox(height: MunjiSpace.md),
        ],
      ),
    );
  }

  Widget _done() {
    final hr = _avgHr;
    final at = _startedAt;
    final time = at == null
        ? ''
        : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle_rounded, size: 56, color: MunjiColors.green),
          const SizedBox(height: MunjiSpace.md),
          Text(t.saved, style: MunjiText.h2, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            _result == RecordingResult.stillChecking ? t.stillChecking : t.savedSub,
            style: MunjiText.small,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: MunjiSpace.lg),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: MunjiColors.bg,
              borderRadius: BorderRadius.circular(MunjiRadius.r4),
            ),
            child: Row(
              children: [
                Expanded(child: _Fact(value: '30', unit: t.secShort, label: t.duration)),
                Expanded(
                  child: _Fact(
                    value: hr == null ? '--' : hr.round().toString(),
                    unit: 'BPM',
                    label: t.avgHr,
                  ),
                ),
                Expanded(child: _Fact(value: time, label: t.time)),
              ],
            ),
          ),
          const SizedBox(height: MunjiSpace.xl),
          ElevatedButton(
            onPressed: () => setState(() => _phase = _Phase.ready),
            child: Text(t.again),
          ),
        ],
      ),
    );
  }

  Widget _failed() {
    final f = _failure!;
    final canResend = _pendingBytes != null &&
        (f == CaptureFailure.uploadFailed || f == CaptureFailure.storageUnavailable);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.error_outline_rounded, size: 52, color: MunjiColors.orange),
          const SizedBox(height: MunjiSpace.md),
          Text(t.failTitle(f), style: MunjiText.h3, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(t.failSub(f), style: MunjiText.small, textAlign: TextAlign.center),
          const SizedBox(height: MunjiSpace.xl),
          if (canResend) ...[
            ElevatedButton(onPressed: _upload, child: Text(t.resend)),
            const SizedBox(height: MunjiSpace.sm),
            OutlinedButton(
              onPressed: () => setState(() {
                _phase = _Phase.ready;
                _pendingBytes = null;
              }),
              child: Text(t.discard),
            ),
          ] else
            ElevatedButton(
              onPressed: () => setState(() => _phase = _Phase.ready),
              child: Text(t.tryAgain),
            ),
        ],
      ),
    );
  }
}

// ── pieces ─────────────────────────────────────────────────────────────────

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 20, color: MunjiColors.blue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  style: MunjiText.body.copyWith(
                      fontSize: 14, color: MunjiColors.slate, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );
}

class _Check extends StatelessWidget {
  const _Check({required this.ok, required this.text});
  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
              size: 18, color: ok ? MunjiColors.green : MunjiColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: MunjiText.label.copyWith(
                    color: ok ? MunjiColors.ink : MunjiColors.muted, fontSize: 13.5)),
          ),
        ],
      );
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
                      fontSize: 20,
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

  String get title => ar ? 'تسجيل تخطيط القلب' : 'Record an ECG';
  String get readyTitle => ar ? 'قبل البدء' : 'Before you start';
  String get step1 => ar ? 'اجلس واسترخِ، وضع يديك في حضنك' : 'Sit down and relax, hands in your lap';
  String get step2 => ar ? 'لا تتكلم ولا تتحرك أثناء التسجيل' : 'Do not talk or move while recording';
  String get step3 => ar ? 'يستغرق التسجيل 30 ثانية' : 'The recording takes 30 seconds';
  String get patchOk => ar ? 'اللاصقة متصلة' : 'Patch connected';
  String get patchNo => ar ? 'اللاصقة غير متصلة' : 'Patch not connected';
  String get contactOk => ar ? 'الأقطاب ملامسة للجلد' : 'Electrodes touching the skin';
  String get contactNo => ar ? 'أحد الأقطاب غير ملامس، اضغط على اللاصقة' : 'An electrode is off, press the patch down';
  String get contactUnknown => ar ? 'تلامس الأقطاب غير معروف' : 'Electrode contact unknown';
  String get start => ar ? 'ابدأ التسجيل' : 'Start recording';

  String get seconds => ar ? 'ثانية' : 'seconds';
  String get stayStill => ar ? 'ابقَ ثابتًا وتنفّس بهدوء' : 'Stay still and breathe normally';
  String get holdContact =>
      ar ? 'أحد الأقطاب غير ملامس، اضغط على اللاصقة' : 'An electrode is off, press the patch down';
  String get recordingLabel => ar ? 'جارٍ التسجيل' : 'Recording';
  String get cancel => ar ? 'إلغاء' : 'Cancel';

  String get saving => ar ? 'جارٍ الحفظ' : 'Saving';
  String get savingSub =>
      ar ? 'نرفع التسجيل ونتحقق منه على الخادم' : 'Uploading and checking the recording';

  String get saved => ar ? 'تم حفظ التسجيل' : 'Recording saved';
  String get savedSub => ar ? 'تجده في السجل' : 'You will find it in your history';
  String get stillChecking => ar
      ? 'تم الرفع، والتحقق جارٍ. سيظهر في السجل خلال لحظات'
      : 'Uploaded and still being checked. It will appear in your history shortly';
  String get duration => ar ? 'المدة' : 'Duration';
  String get secShort => ar ? 'ث' : 's';
  String get avgHr => ar ? 'متوسط النبض' : 'Avg heart rate';
  String get time => ar ? 'الوقت' : 'Time';
  String get again => ar ? 'تسجيل جديد' : 'New recording';
  String get recent => ar ? 'آخر التسجيلات' : 'Recent recordings';
  String get seeAll => ar ? 'عرض السجل' : 'See all';
  String get noRecordings => ar ? 'لا توجد تسجيلات بعد.' : 'No recordings yet.';

  String get resend => ar ? 'إعادة الرفع' : 'Upload again';
  String get discard => ar ? 'تجاهل وسجّل من جديد' : 'Discard and record again';
  String get tryAgain => ar ? 'حاول مجددًا' : 'Try again';

  String failTitle(CaptureFailure f) {
    switch (f) {
      case CaptureFailure.disconnected:
        return ar ? 'انقطع الاتصال باللاصقة' : 'The patch disconnected';
      case CaptureFailure.leadsOff:
        return ar ? 'أحد الأقطاب غير ملامس' : 'An electrode lost contact';
      case CaptureFailure.signalLost:
        return ar ? 'توقفت البيانات' : 'Data stopped arriving';
      case CaptureFailure.tooManyGaps:
        return ar ? 'الاتصال متقطع' : 'The connection was unstable';
      case CaptureFailure.uploadFailed:
        return ar ? 'تعذّر رفع التسجيل' : 'Could not upload';
      case CaptureFailure.rejected:
        return ar ? 'رُفض التسجيل' : 'The recording was rejected';
      case CaptureFailure.storageUnavailable:
        return ar ? 'الحفظ غير متاح حاليًا' : 'Saving is not available yet';
    }
  }

  String failSub(CaptureFailure f) {
    switch (f) {
      case CaptureFailure.disconnected:
        return ar ? 'تأكد أن اللاصقة قريبة ومشحونة، ثم سجّل من جديد.' : 'Keep the patch close and charged, then record again.';
      case CaptureFailure.leadsOff:
        return ar ? 'اضغط على اللاصقة حتى تلتصق جيدًا، ثم سجّل من جديد.' : 'Press the patch down firmly, then record again.';
      case CaptureFailure.signalLost:
        return ar ? 'قرّب الجوال من اللاصقة وسجّل من جديد.' : 'Bring the phone closer to the patch and record again.';
      case CaptureFailure.tooManyGaps:
        return ar ? 'ضاع جزء كبير من الإشارة. قرّب الجوال وسجّل من جديد.' : 'Too much of the signal was lost. Bring the phone closer and try again.';
      case CaptureFailure.uploadFailed:
        return ar ? 'تحقق من الإنترنت. التسجيل محفوظ مؤقتًا ويمكن رفعه مجددًا.' : 'Check your internet. The recording is kept so you can upload it again.';
      case CaptureFailure.rejected:
        return ar ? 'الملف لم يجتز التحقق. سجّل من جديد.' : 'The file did not pass the check. Record again.';
      case CaptureFailure.storageUnavailable:
        return ar ? 'تخزين التسجيلات داخل المملكة قيد التفعيل.' : 'In-Kingdom recording storage is being set up.';
    }
  }

  String get disclaimer => ar
      ? 'التسجيل للمتابعة وليس تشخيصًا طبيًا. إذا شعرت بألم في الصدر أو ضيق في التنفس اتصل بالطوارئ 911 فورًا.'
      : 'This recording is for monitoring, not a diagnosis. If you have chest pain or trouble breathing, call 911 now.';
}
