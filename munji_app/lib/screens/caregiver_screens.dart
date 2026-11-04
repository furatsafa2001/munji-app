import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/account_service.dart';
import '../services/history_data.dart';
import '../services/link_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';
import '../widgets/vitals.dart';
import 'history_screen.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';

// ── what the caregiver can tell from device/current ─────────────────────────

enum LiveKind { live, connectedNoReading, notConnected, stale, noDevice, charging, stabilizing }

/// The caregiver never sees the patient's phone, only `device/current`,
/// which the phone rewrites every few seconds while connected and at once
/// when something important changes (see device_registry.dart). These
/// thresholds turn it into something a worried relative can read at a
/// glance.
class PatientLive {
  PatientLive(this.data);

  final Map<String, dynamic>? data;

  /// The phone writes every 5 seconds while connected, so 20 seconds means
  /// several missed writes in a row: the numbers are no longer current.
  static const freshFor = Duration(seconds: 20);

  /// Past this the phone itself has gone quiet (schema: "no recent data").
  static const staleAfter = Duration(minutes: 15);

  DateTime? get lastSeen => (data?['lastSeenAt'] as Timestamp?)?.toDate();
  double? get hr => (data?['hr'] as num?)?.toDouble();
  int? get battery => (data?['battery'] as num?)?.toInt();
  bool get connected => data?['connected'] == true;
  bool? get charging => data?['charging'] as bool?;
  bool? get worn => data?['worn'] as bool?;
  bool get stabilizing => data?['stabilizing'] == true;

  LiveKind get kind {
    final d = data;
    if (d == null || d['status'] != 'paired') return LiveKind.noDevice;
    final seen = lastSeen;
    if (seen == null) return LiveKind.stale;
    final age = DateTime.now().difference(seen);
    if (age > staleAfter) return LiveKind.stale;
    if (!connected) return LiveKind.notConnected;
    if (age > freshFor) return LiveKind.stale;
    // the patch does not measure on the charger: not a problem to fix
    if (charging == true) return LiveKind.charging;
    if (stabilizing && worn != false) return LiveKind.stabilizing;
    return hr == null ? LiveKind.connectedNoReading : LiveKind.live;
  }

  bool get isLive => kind == LiveKind.live;

  MonitorStatus get status => switch (kind) {
        LiveKind.live => MonitorStatus.live,
        LiveKind.connectedNoReading => MonitorStatus.attention,
        LiveKind.notConnected => MonitorStatus.offline,
        LiveKind.stale => MonitorStatus.noData,
        LiveKind.noDevice => MonitorStatus.noDevice,
        LiveKind.charging => MonitorStatus.charging,
        LiveKind.stabilizing => MonitorStatus.stabilizing,
      };

  /// Title and explanation for the monitoring card, written for the
  /// caregiver (about the patient, not to them).
  (String, String) describe(bool ar) {
    final seen = lastSeen;
    switch (kind) {
      case LiveKind.live:
        return (
          ar ? 'المراقبة مستمرة' : 'Monitoring',
          ar ? 'اللاصقة تعمل والقراءات تصل' : 'The patch is working and readings are arriving',
        );
      case LiveKind.connectedNoReading:
        return (
          ar ? 'تحقق من اللاصقة' : 'Check the patch',
          worn == false
              ? (ar ? 'أحد الأقطاب غير ملامس للجلد' : 'An electrode is not touching the skin')
              : (ar ? 'متصلة، لكن لا توجد قراءة الآن' : 'Connected, but no reading right now'),
        );
      case LiveKind.notConnected:
        return (
          ar ? 'غير متصل' : 'Not connected',
          ar
              ? 'اللاصقة غير متصلة بجوال المريض${seen == null ? '' : ' · ${agoText(seen, ar)}'}'
              : 'The patch is not connected to the patient\'s phone${seen == null ? '' : ' · ${agoText(seen, ar)}'}',
        );
      case LiveKind.stale:
        return (
          ar ? 'لا توجد بيانات حديثة' : 'No recent data',
          seen == null
              ? (ar ? 'لم يصل شيء من جوال المريض بعد' : 'Nothing has arrived from the patient\'s phone yet')
              : (ar
                  ? 'آخر تحديث من جوال المريض ${agoText(seen, ar)}'
                  : 'Last update from the patient\'s phone ${agoText(seen, ar)}'),
        );
      case LiveKind.charging:
        return (
          ar ? 'الجهاز يشحن' : 'Charging',
          ar
              ? 'المراقبة متوقفة أثناء الشحن، وتعود بعد فصل الشاحن ولبس اللاصقة'
              : 'Monitoring pauses while charging and resumes once unplugged and worn',
        );
      case LiveKind.stabilizing:
        return (
          ar ? 'اللاصقة تستقر' : 'Patch settling',
          ar
              ? 'تبدأ القراءات خلال 30 ثانية تقريبًا من لبس اللاصقة'
              : 'Readings start about 30 seconds after the patch goes on',
        );
      case LiveKind.noDevice:
        return (
          ar ? 'لم يُربط جهاز بعد' : 'No device yet',
          ar ? 'لم يوصل المريض جهاز منجي بعد' : 'The patient has not paired a Munji device yet',
        );
    }
  }

  /// One line for the patient list.
  String line(bool ar) {
    final seen = lastSeen;
    if (kind == LiveKind.live && seen != null) {
      return ar ? 'مباشر · ${agoText(seen, ar)}' : 'Live · ${agoText(seen, ar)}';
    }
    return describe(ar).$1;
  }
}

/// Rebuilds every few seconds, so "12s ago" and "live" stay true.
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
    _t = Timer.periodic(const Duration(seconds: 5), (_) {
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
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: IndexedStack(
        index: _index,
        children: [
          CaregiverHomeScreen(isArabic: ar),
          ProfileScreen(isArabic: ar, onLocaleChanged: widget.onLocaleChanged),
        ],
      ),
      bottomNavigationBar: MunjiNavBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          MunjiNavItem(Icons.people_alt_rounded, ar ? 'المرضى' : 'Patients'),
          MunjiNavItem(Icons.person_outline_rounded, ar ? 'حسابي' : 'Profile'),
        ],
      ),
    );
  }
}

// ── home: the patients I look after ───────────────────────────────────────

class CaregiverHomeScreen extends StatefulWidget {
  CaregiverHomeScreen({super.key, required this.isArabic, LinkService? links})
      : links = links ?? LinkService();

  final bool isArabic;
  final LinkService links;

  @override
  State<CaregiverHomeScreen> createState() => _CaregiverHomeScreenState();
}

class _CaregiverHomeScreenState extends State<CaregiverHomeScreen> {
  final _uid = FirebaseAuth.instance.currentUser!.uid;
  late final Stream<List<CareLink>> _links = widget.links.forCaregiver(_uid);
  late final Stream<Map<String, dynamic>?> _me = AccountService().watchProfile(_uid);

  // One listener per patient, shared by the summary and the cards, so both
  // always agree.
  final _subs = <String, StreamSubscription<Map<String, dynamic>?>>{};
  final _live = <String, PatientLive>{};

  bool get ar => widget.isArabic;

  void _follow(List<CareLink> links) {
    final ids = links.map((l) => l.patientId).toSet();
    for (final id in _subs.keys.toList()) {
      if (!ids.contains(id)) {
        _subs.remove(id)?.cancel();
        _live.remove(id);
      }
    }
    for (final id in ids) {
      _subs.putIfAbsent(
        id,
        () => _deviceStream(id).listen(
          (d) {
            if (mounted) setState(() => _live[id] = PatientLive(d));
          },
          onError: (_) {},
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    super.dispose();
  }

  void _addPatient() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EnterCodeScreen(isArabic: ar, links: widget.links),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<List<CareLink>>(
          stream: _links,
          builder: (context, snap) {
            final list = snap.data;
            if (list != null) _follow(list);
            return _Ticker(
              builder: (context) => ListView(
                padding: const EdgeInsets.fromLTRB(
                    MunjiSpace.lg, MunjiSpace.md, MunjiSpace.lg, MunjiSpace.xxl),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: StreamBuilder<Map<String, dynamic>?>(
                          stream: _me,
                          builder: (context, me) => GreetingHeader(
                            isArabic: ar,
                            name: (me.data?['fullName'] as String?) ?? '',
                          ),
                        ),
                      ),
                      if (list != null && list.isNotEmpty)
                        IconButton.filledTonal(
                          tooltip: ar ? 'إضافة مريض' : 'Add a patient',
                          onPressed: _addPatient,
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                        ),
                    ],
                  ),
                  const SizedBox(height: MunjiSpace.lg),
                  if (snap.hasError)
                    MunjiError(ar ? 'تعذّر التحميل. تأكد من اتصالك بالإنترنت.' : 'Could not load. Check your connection.')
                  else if (list == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (list.isEmpty)
                    _FirstLink(isArabic: ar, onAdd: _addPatient)
                  else ...[
                    _Summary(isArabic: ar, links: list, live: _live),
                    const SizedBox(height: MunjiSpace.xl),
                    MunjiSectionLabel(ar ? 'مرضاي' : 'My patients'),
                    for (final l in list) ...[
                      _PatientCard(
                        link: l,
                        live: _live[l.patientId],
                        isArabic: ar,
                        links: widget.links,
                      ),
                      const SizedBox(height: MunjiSpace.md),
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// "Everyone is being monitored", or how many need a look. About the
/// patches and phones, never about anyone's heart.
class _Summary extends StatelessWidget {
  const _Summary({required this.isArabic, required this.links, required this.live});

  final bool isArabic;
  final List<CareLink> links;
  final Map<String, PatientLive> live;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final n = links.length;
    final known = links.where((l) => live[l.patientId] != null).toList();
    final needLook = known.where((l) => !live[l.patientId]!.isLive).length;
    final loading = known.length < n;
    final allLive = !loading && needLook == 0;

    final title = loading
        ? (ar ? 'جارٍ التحديث…' : 'Updating…')
        : allLive
            ? (ar ? 'المراقبة تعمل' : 'All monitored')
            : (ar ? '$needLook بحاجة لانتباه' : '$needLook need a look');
    final sub = ar
        ? 'عدد من ترعاهم: $n'
        : (n == 1 ? '1 person in your care' : '$n people in your care');

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 8, 16),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x1A00537A)),
        boxShadow: MunjiShadow.e1,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ar ? 'من ترعاهم' : 'People in your care',
                    style: MunjiText.label.copyWith(
                        color: MunjiColors.slate, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(title,
                    style: MunjiText.h1.copyWith(
                        fontSize: 26,
                        color: allLive ? MunjiColors.blue : MunjiColors.ink)),
                const SizedBox(height: 4),
                Text(sub,
                    style: MunjiText.body.copyWith(
                        color: MunjiColors.slate,
                        fontWeight: FontWeight.w500,
                        fontSize: 14)),
              ],
            ),
          ),
          SizedBox(
            width: 104,
            height: 104,
            child: Opacity(
              opacity: allLive ? 1 : 0.6,
              child: Image.asset('assets/images/heart.webp', fit: BoxFit.contain),
            ),
          ),
        ],
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                  color: MunjiColors.blue50, shape: BoxShape.circle),
              child: const Icon(Icons.link_rounded, size: 30, color: MunjiColors.blue),
            ),
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
  const _PatientCard({
    required this.link,
    required this.live,
    required this.isArabic,
    required this.links,
  });

  final CareLink link;
  final PatientLive? live;
  final bool isArabic;
  final LinkService links;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final l = live ?? PatientLive(null);
    final status = live == null ? MonitorStatus.connecting : l.status;
    final color = monitorColor(status);
    final name = link.patientName.isEmpty ? (ar ? 'المريض' : 'Patient') : link.patientName;
    final relation = link.relation == null ? null : relationLabel(link.relation, ar);

    return Material(
      color: MunjiColors.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => CaregiverPatientScreen(link: link, isArabic: ar, links: links),
        )),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x1A00537A)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: MunjiColors.blue,
                child: Text(name.characters.first,
                    style: MunjiText.h3.copyWith(color: Colors.white)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: MunjiText.h3, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (relation != null)
                      Text(relation,
                          style: MunjiText.small.copyWith(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (l.isLive) ...[
                          const Icon(Icons.favorite_rounded, size: 13, color: MunjiColors.red),
                          const SizedBox(width: 4),
                          Text(
                            ar ? '${l.hr!.round()} نبضة/د' : '${l.hr!.round()} bpm',
                            style: MunjiText.small.copyWith(
                                fontSize: 12.5, color: MunjiColors.ink, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            live == null ? (ar ? 'جارٍ التحميل…' : 'Loading…') : l.line(ar),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: MunjiText.small.copyWith(
                                fontSize: 12, color: MunjiColors.slate, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(MunjiRadius.pill),
                ),
                child: Text(monitorShort(status, ar),
                    style: MunjiText.small.copyWith(
                        fontSize: 11.5, fontWeight: FontWeight.w800, color: color)),
              ),
              const Icon(Icons.chevron_right_rounded, color: MunjiColors.muted),
            ],
          ),
        ),
      ),
    );
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
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(MunjiSpace.sm, MunjiSpace.xs, MunjiSpace.lg, 0),
              child: DetailHeader(title: ar ? 'رمز المريض' : 'Patient code'),
            ),
            Expanded(child: _linkedName != null ? _done() : _form()),
          ],
        ),
      ),
    );
  }

  Widget _form() {
    return ListView(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      children: [
        Center(
          child: Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(color: MunjiColors.blue50, shape: BoxShape.circle),
            child: const Icon(Icons.shield_rounded, color: MunjiColors.blue, size: 26),
          ),
        ),
        const SizedBox(height: MunjiSpace.md),
        Text(ar ? 'أدخل رمز المريض' : 'Enter the patient\'s code',
            style: MunjiText.h2, textAlign: TextAlign.center),
        const SizedBox(height: MunjiSpace.xs),
        Text(
          ar
              ? 'اطلب من المريض الرمز المكوّن من 6 أرقام من: حسابي ← إضافة مرافق.'
              : 'Ask the patient for the 6-digit code in Profile, Add caregiver.',
          style: MunjiText.body.copyWith(color: MunjiColors.slate, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
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

/// What the caregiver sees for one patient: monitoring status, the numbers
/// (heart rate, HRV, signal, battery), then the patient's ECG recordings and
/// reports. No capture here: recording is something the patient does.
class CaregiverPatientScreen extends StatefulWidget {
  const CaregiverPatientScreen({
    super.key,
    required this.link,
    required this.isArabic,
    required this.links,
  });

  final CareLink link;
  final bool isArabic;
  final LinkService links;

  @override
  State<CaregiverPatientScreen> createState() => _CaregiverPatientScreenState();
}

class _CaregiverPatientScreenState extends State<CaregiverPatientScreen> {
  late final Stream<Map<String, dynamic>?> _device = _deviceStream(widget.link.patientId);
  // the last few: the newest for "last recording", and the newest with an
  // HRV value for the HRV number
  late final Stream<List<Recording>> _lastRecording =
      HistoryRepository().latest(limit: 10, uid: widget.link.patientId);

  bool get ar => widget.isArabic;

  String get _name =>
      widget.link.patientName.isEmpty ? (ar ? 'المريض' : 'Patient') : widget.link.patientName;

  void _openRecordings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HistoryScreen(
        isArabic: ar,
        fullName: _name,
        patientId: widget.link.patientId,
      ),
    ));
  }

  void _openReports() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReportsScreen(
        isArabic: ar,
        fullName: _name,
        patientId: widget.link.patientId,
      ),
    ));
  }

  bool _confirming = false;

  Future<void> _unlink() async {
    if (_confirming) return;
    _confirming = true;
    final link = widget.link;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ar ? 'إلغاء الربط؟' : 'Unlink?'),
        content: Text(ar
            ? 'لن ترى بيانات $_name ولن تصلك تنبيهاته.'
            : 'You will no longer see $_name\'s data or receive their alerts.'),
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
    _confirming = false;
    if (ok != true || !mounted) return;
    try {
      await widget.links.revoke(patientId: link.patientId, caregiverId: link.caregiverId);
      if (mounted) Navigator.of(context).pop();
    } on LinkException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message(ar))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        child: StreamBuilder<Map<String, dynamic>?>(
          stream: _device,
          builder: (context, snap) => StreamBuilder<List<Recording>>(
            stream: _lastRecording,
            builder: (context, rec) => _Ticker(builder: (context) {
              final loading = !snap.hasData && !snap.hasError &&
                  snap.connectionState == ConnectionState.waiting;
              final live = PatientLive(snap.data);
              final status = loading ? MonitorStatus.connecting : live.status;
              final (title, sub) = loading
                  ? (ar ? 'جارٍ التحميل…' : 'Loading…', ar ? 'نجلب آخر حالة' : 'Fetching the latest status')
                  : live.describe(ar);
              final seen = live.lastSeen;
              final isLive = live.isLive;
              final lastRec = rec.data?.isNotEmpty == true ? rec.data!.first.startedAt : null;
              final hrvRec = HistoryRepository.latestWithHrv(rec.data ?? const []);

              // what the ECG is doing, from what the patient's phone reports
              final ecg = switch (live.kind) {
                LiveKind.live => EcgState.valid,
                LiveKind.stabilizing => EcgState.settling,
                LiveKind.connectedNoReading when live.worn == false =>
                  EcgState.electrodeOff,
                LiveKind.connectedNoReading => EcgState.settling,
                _ => EcgState.paused,
              };

              return ListView(
                padding: const EdgeInsetsDirectional.fromSTEB(
                    MunjiSpace.sm, MunjiSpace.xs, MunjiSpace.lg, MunjiSpace.xxl),
                children: [
                  DetailHeader(
                    title: _name,
                    subtitle: seen == null
                        ? monitorShort(status, ar)
                        : '${monitorShort(status, ar)} · ${ar ? 'تحديث' : 'updated'} ${agoText(seen, ar)}',
                    subtitleColor: monitorColor(status),
                  ),
                  const SizedBox(height: MunjiSpace.md),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: MunjiSpace.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        StatusPanel(
                          isArabic: ar,
                          status: status,
                          title: title,
                          subtitle: sub,
                          stats: [
                            hrStat(ar: ar, bpm: live.hr, live: isLive),
                            hrvStat(
                                ar: ar,
                                rmssd: hrvRec?.rmssd,
                                measuredAt: hrvRec?.startedAt),
                            ecgStat(ar: ar, state: ecg),
                            batteryStat(
                                ar: ar,
                                battery: live.battery,
                                charging: live.charging),
                          ],
                        ),
                        const SizedBox(height: MunjiSpace.sm),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            ar
                                ? 'القراءات تصل من جوال المريض خلال ثوانٍ. للمتابعة فقط، وليست تشخيصًا.'
                                : 'Readings arrive from the patient\'s phone within seconds. For monitoring only, not a diagnosis.',
                            style: MunjiText.small.copyWith(fontSize: 11.5),
                          ),
                        ),
                        const SizedBox(height: MunjiSpace.lg),
                        ActionCard(
                          icon: Icons.monitor_heart_outlined,
                          title: ar ? 'تسجيلات تخطيط القلب' : 'ECG recordings',
                          subtitle: lastRec == null
                              ? (ar ? 'لا توجد تسجيلات بعد' : 'No recordings yet')
                              : (ar
                                  ? 'آخر تسجيل ${agoText(lastRec, ar)} · افتح وشارك PDF'
                                  : 'Last one ${agoText(lastRec, ar)} · open and share the PDF'),
                          onTap: _openRecordings,
                        ),
                        const SizedBox(height: MunjiSpace.md),
                        ActionCard(
                          icon: Icons.insert_chart_outlined_rounded,
                          title: ar ? 'التقارير' : 'Reports',
                          subtitle: ar
                              ? 'النبض و HRV على أيام وأسابيع'
                              : 'Heart rate and HRV over days and weeks',
                          onTap: _openReports,
                        ),
                        const SizedBox(height: MunjiSpace.lg),
                        TextButton.icon(
                          onPressed: _unlink,
                          icon: const Icon(Icons.link_off_rounded, size: 18),
                          label: Text(ar ? 'إلغاء الربط' : 'Unlink'),
                          style: TextButton.styleFrom(foregroundColor: MunjiColors.red),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}
