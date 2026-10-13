import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/link_service.dart';
import '../theme/munji_theme.dart';
import 'profile_screen.dart';

// ── what the caregiver can tell from device/current ─────────────────────────

enum LiveKind { live, connectedNoReading, notConnected, stale, noDevice }

/// The caregiver never sees the patient's phone, only `device/current`,
/// which the phone rewrites every minute while connected (see
/// device_registry.dart). These thresholds turn it into something a
/// worried relative can read at a glance.
class PatientLive {
  PatientLive(this.data);

  final Map<String, dynamic>? data;

  /// The phone writes every minute while connected, so two minutes means
  /// at most one missed write.
  static const freshFor = Duration(minutes: 2);

  /// Past this the phone itself has gone quiet (schema: "no recent data").
  static const staleAfter = Duration(minutes: 15);

  DateTime? get lastSeen => (data?['lastSeenAt'] as Timestamp?)?.toDate();
  double? get hr => (data?['hr'] as num?)?.toDouble();
  double? get rmssd => (data?['rmssd'] as num?)?.toDouble();
  int? get battery => (data?['battery'] as num?)?.toInt();
  bool get connected => data?['connected'] == true;
  bool? get worn => data?['worn'] as bool?;

  LiveKind get kind {
    final d = data;
    if (d == null || d['status'] != 'paired') return LiveKind.noDevice;
    final seen = lastSeen;
    if (seen == null) return LiveKind.stale;
    final age = DateTime.now().difference(seen);
    if (age > staleAfter) return LiveKind.stale;
    if (!connected) return LiveKind.notConnected;
    if (age > freshFor) return LiveKind.stale;
    return hr == null ? LiveKind.connectedNoReading : LiveKind.live;
  }
}

String _ago(DateTime at, bool ar) {
  final s = DateTime.now().difference(at).inSeconds;
  if (s < 60) return ar ? 'قبل ${s < 5 ? 'لحظات' : '$s ث'}' : (s < 5 ? 'just now' : '${s}s ago');
  if (s < 3600) return ar ? 'قبل ${s ~/ 60} د' : '${s ~/ 60}m ago';
  if (s < 86400) return ar ? 'قبل ${s ~/ 3600} س' : '${s ~/ 3600}h ago';
  return ar ? 'قبل ${s ~/ 86400} يوم' : '${s ~/ 86400}d ago';
}

/// Rebuilds once every 15 seconds, so "2 min ago" stays true.
class _Ticker extends StatefulWidget {
  const _Ticker({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

Stream<Map<String, dynamic>?> _deviceStream(String patientId) => FirebaseFirestore.instance
    .collection('users')
    .doc(patientId)
    .collection('device')
    .doc('current')
    .snapshots()
    .map((s) => s.data());

// ── shell ──────────────────────────────────────────────────────────────────

class CaregiverShell extends StatefulWidget {
  const CaregiverShell({super.key, required this.isArabic, required this.onLocaleChanged});

  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  State<CaregiverShell> createState() => _CaregiverShellState();
}

class _CaregiverShellState extends State<CaregiverShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    final items = [
      (Icons.people_alt_rounded, ar ? 'المرضى' : 'Patients'),
      (Icons.person_outline_rounded, ar ? 'حسابي' : 'Profile'),
    ];
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: IndexedStack(
        index: _index,
        children: [
          CaregiverHomeScreen(isArabic: ar),
          ProfileScreen(isArabic: ar, onLocaleChanged: widget.onLocaleChanged),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: MunjiColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0x2100537A)),
            boxShadow: MunjiShadow.e2,
          ),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => setState(() => _index = i),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                      decoration: BoxDecoration(
                        color: i == _index ? MunjiColors.blue50 : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(items[i].$1,
                              size: 21,
                              color: i == _index ? MunjiColors.blue : MunjiColors.muted),
                          const SizedBox(height: 3),
                          Text(items[i].$2,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: i == _index ? FontWeight.w800 : FontWeight.w600,
                                color: i == _index ? MunjiColors.blue : MunjiColors.muted,
                              )),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── home: the patients I look after ───────────────────────────────────────

class CaregiverHomeScreen extends StatelessWidget {
  CaregiverHomeScreen({super.key, required this.isArabic, LinkService? links})
      : links = links ?? LinkService();

  final bool isArabic;
  final LinkService links;

  void _addPatient(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EnterCodeScreen(isArabic: isArabic, links: links),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<List<CareLink>>(
          stream: links.forCaregiver(uid),
          builder: (context, snap) {
            final list = snap.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                  MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(ar ? 'من أرعاهم' : 'People I care for',
                          style: MunjiText.h1),
                    ),
                    if (list != null && list.isNotEmpty)
                      IconButton.filledTonal(
                        tooltip: ar ? 'إضافة مريض' : 'Add a patient',
                        onPressed: () => _addPatient(context),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                      ),
                  ],
                ),
                const SizedBox(height: MunjiSpace.lg),
                if (snap.hasError)
                  Text(ar ? 'تعذّر التحميل.' : 'Could not load.', style: MunjiText.small)
                else if (list == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (list.isEmpty)
                  _FirstLink(isArabic: ar, onAdd: () => _addPatient(context))
                else
                  for (final l in list) ...[
                    _PatientCard(link: l, isArabic: ar, links: links),
                    const SizedBox(height: MunjiSpace.md),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FirstLink extends StatelessWidget {
  const _FirstLink({required this.isArabic, required this.onAdd});
  final bool isArabic;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    return Container(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x1A00537A)),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
                color: MunjiColors.blue50, shape: BoxShape.circle),
            child: const Icon(Icons.link_rounded, size: 30, color: MunjiColors.blue),
          ),
          const SizedBox(height: MunjiSpace.lg),
          Text(ar ? 'اربط حسابك بالمريض' : 'Link to a patient',
              style: MunjiText.h2, textAlign: TextAlign.center),
          const SizedBox(height: MunjiSpace.sm),
          Text(
            ar
                ? 'اطلب من المريض فتح منجي ثم: حسابي ← المرافقون ← إضافة مرافق، وأدخل الرمز الذي يظهر له.'
                : 'Ask the patient to open Munji: Profile, Caregivers, Add a caregiver. Then enter the code they see.',
            style: MunjiText.body.copyWith(
                color: MunjiColors.slate, fontWeight: FontWeight.w500, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: MunjiSpace.xl),
          ElevatedButton(
            onPressed: onAdd,
            child: Text(ar ? 'إدخال الرمز' : 'Enter code'),
          ),
        ],
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.link, required this.isArabic, required this.links});

  final CareLink link;
  final bool isArabic;
  final LinkService links;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    return StreamBuilder<Map<String, dynamic>?>(
      stream: _deviceStream(link.patientId),
      builder: (context, snap) => _Ticker(builder: (context) {
        final live = PatientLive(snap.data);
        final k = live.kind;
        final (dot, line) = _statusLine(live, ar);
        final name = link.patientName.isEmpty ? (ar ? 'المريض' : 'Patient') : link.patientName;

        return Material(
          color: MunjiColors.surface,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CaregiverPatientScreen(link: link, isArabic: ar, links: links),
            )),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0x1A00537A)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: MunjiColors.blue50,
                    child: Text(name.characters.first,
                        style: MunjiText.h3.copyWith(color: MunjiColors.blue)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: MunjiText.h3),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(line,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: MunjiText.small.copyWith(
                                      fontSize: 12.5,
                                      color: MunjiColors.slate,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (k == LiveKind.live)
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Column(
                        children: [
                          Text(live.hr!.round().toString(),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: MunjiColors.ink,
                                fontFeatures: [FontFeature.tabularFigures()],
                              )),
                          Text('BPM', style: MunjiText.small.copyWith(fontSize: 11)),
                        ],
                      ),
                    )
                  else
                    const Icon(Icons.chevron_right_rounded, color: MunjiColors.muted),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

(Color, String) _statusLine(PatientLive live, bool ar) {
  final seen = live.lastSeen;
  switch (live.kind) {
    case LiveKind.live:
      return (MunjiColors.green, ar ? 'متصل · ${_ago(seen!, ar)}' : 'Connected · ${_ago(seen!, ar)}');
    case LiveKind.connectedNoReading:
      return (
        MunjiColors.orange,
        live.worn == false
            ? (ar ? 'اللاصقة غير ملامسة للجلد' : 'Patch not touching the skin')
            : (ar ? 'متصل، لا توجد قراءة' : 'Connected, no reading'),
      );
    case LiveKind.notConnected:
      return (
        MunjiColors.muted,
        ar ? 'اللاصقة غير متصلة · ${_ago(seen!, ar)}' : 'Patch not connected · ${_ago(seen!, ar)}',
      );
    case LiveKind.stale:
      return (
        MunjiColors.orange,
        seen == null
            ? (ar ? 'لا توجد بيانات حديثة' : 'No recent data')
            : (ar ? 'لا توجد بيانات حديثة · ${_ago(seen, ar)}' : 'No recent data · ${_ago(seen, ar)}'),
      );
    case LiveKind.noDevice:
      return (MunjiColors.muted, ar ? 'لم يُربط جهاز بعد' : 'No device paired yet');
  }
}

// ── enter code ─────────────────────────────────────────────────────────────

class EnterCodeScreen extends StatefulWidget {
  const EnterCodeScreen({super.key, required this.isArabic, required this.links});

  final bool isArabic;
  final LinkService links;

  @override
  State<EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends State<EnterCodeScreen> {
  final _code = TextEditingController();
  String? _relation;
  bool _busy = false;
  String? _error;
  String? _linkedName;

  bool get ar => widget.isArabic;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = ar ? 'الرمز من 6 أرقام.' : 'The code has 6 digits.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = await widget.links.redeem(code, relation: _relation);
      if (mounted) setState(() => _linkedName = name);
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message(ar));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(ar ? 'ربط بمريض' : 'Link to a patient', style: MunjiText.h3),
      ),
      body: SafeArea(
        child: _linkedName != null ? _done() : _form(),
      ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      children: [
        Text(
          ar ? 'أدخل الرمز المكوّن من 6 أرقام الظاهر في جوال المريض.' : 'Enter the 6-digit code shown on the patient\'s phone.',
          style: MunjiText.body.copyWith(color: MunjiColors.slate, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: MunjiSpace.lg),
        Directionality(
          textDirection: TextDirection.ltr,
          child: TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            decoration: const InputDecoration(counterText: '', hintText: '000000'),
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(height: MunjiSpace.xl),
        Text(ar ? 'صلتك بالمريض (اختياري)' : 'Your relation (optional)', style: MunjiText.label),
        const SizedBox(height: MunjiSpace.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in relations)
              ChoiceChip(
                label: Text(relationLabel(r, ar)),
                selected: _relation == r,
                onSelected: (v) => setState(() => _relation = v ? r : null),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: MunjiSpace.lg),
          Container(
            padding: const EdgeInsets.all(MunjiSpace.md),
            decoration: BoxDecoration(
              color: MunjiColors.warn50,
              borderRadius: BorderRadius.circular(MunjiRadius.r2),
              border: Border.all(color: MunjiColors.warn200),
            ),
            child: Text(_error!, style: MunjiText.label.copyWith(color: MunjiColors.warn700)),
          ),
        ],
        const SizedBox(height: MunjiSpace.xl),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Text(ar ? 'ربط' : 'Link'),
        ),
      ],
    );
  }

  Widget _done() {
    final name = _linkedName!.isEmpty ? (ar ? 'المريض' : 'the patient') : _linkedName!;
    return Padding(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle_rounded, size: 64, color: MunjiColors.green),
          const SizedBox(height: MunjiSpace.lg),
          Text(ar ? 'تم الربط مع $name' : 'Linked with $name',
              style: MunjiText.h2, textAlign: TextAlign.center),
          const SizedBox(height: MunjiSpace.sm),
          Text(
            ar ? 'ستظهر حالته في الصفحة الرئيسية.' : 'Their status now shows on your home screen.',
            style: MunjiText.body.copyWith(color: MunjiColors.slate, fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: MunjiSpace.xxl),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ar ? 'تم' : 'Done'),
          ),
        ],
      ),
    );
  }
}

// ── one patient ────────────────────────────────────────────────────────────

class CaregiverPatientScreen extends StatelessWidget {
  const CaregiverPatientScreen({
    super.key,
    required this.link,
    required this.isArabic,
    required this.links,
  });

  final CareLink link;
  final bool isArabic;
  final LinkService links;

  Future<void> _unlink(BuildContext context) async {
    final ar = isArabic;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ar ? 'إلغاء الربط؟' : 'Unlink?'),
        content: Text(ar
            ? 'لن ترى بيانات ${link.patientName} ولن تصلك تنبيهاته.'
            : 'You will no longer see ${link.patientName}\'s data or receive their alerts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ar ? 'إلغاء' : 'Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: MunjiColors.red),
            child: Text(ar ? 'إلغاء الربط' : 'Unlink'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await links.revoke(patientId: link.patientId, caregiverId: link.caregiverId);
      if (context.mounted) Navigator.of(context).pop();
    } on LinkException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message(ar))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final name = link.patientName.isEmpty ? (ar ? 'المريض' : 'Patient') : link.patientName;

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(name, style: MunjiText.h3),
      ),
      body: StreamBuilder<Map<String, dynamic>?>(
        stream: _deviceStream(link.patientId),
        builder: (context, snap) => _Ticker(builder: (context) {
          final live = PatientLive(snap.data);
          final (dot, line) = _statusLine(live, ar);
          final isLive = live.kind == LiveKind.live;
          final seen = live.lastSeen;

          return ListView(
            padding: const EdgeInsets.all(MunjiSpace.lg),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: MunjiColors.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0x1A00537A)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(line, style: MunjiText.label)),
                      ],
                    ),
                    const SizedBox(height: MunjiSpace.lg),
                    Row(
                      children: [
                        Expanded(
                          child: _Big(
                            label: ar ? 'نبض القلب' : 'Heart rate',
                            value: isLive ? live.hr!.round().toString() : '--',
                            unit: 'BPM',
                          ),
                        ),
                        Expanded(
                          child: _Big(
                            label: 'HRV',
                            value: isLive && live.rmssd != null
                                ? live.rmssd!.round().toString()
                                : '--',
                            unit: 'ms',
                          ),
                        ),
                        Expanded(
                          child: _Big(
                            label: ar ? 'البطارية' : 'Battery',
                            value: live.battery == null ? '--' : '${live.battery}%',
                          ),
                        ),
                      ],
                    ),
                    if (seen != null) ...[
                      const SizedBox(height: MunjiSpace.lg),
                      Text(
                        ar ? 'آخر تحديث ${_ago(seen, ar)}' : 'Updated ${_ago(seen, ar)}',
                        style: MunjiText.small,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: MunjiSpace.md),
              Text(
                ar
                    ? 'القراءة تتحدث كل دقيقة تقريبًا عندما تكون اللاصقة متصلة بجوال المريض. للمتابعة فقط، وليست تشخيصًا.'
                    : 'Updates about once a minute while the patch is connected to the patient\'s phone. For monitoring only, not a diagnosis.',
                style: MunjiText.small.copyWith(fontSize: 11.5),
              ),
              const SizedBox(height: MunjiSpace.xxl),
              OutlinedButton.icon(
                onPressed: () => _unlink(context),
                icon: const Icon(Icons.link_off_rounded),
                label: Text(ar ? 'إلغاء الربط' : 'Unlink'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: MunjiColors.red,
                  side: const BorderSide(color: MunjiColors.danger200),
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big({required this.label, required this.value, this.unit});
  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Column(
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
                    fontSize: 24,
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
}
