import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/link_service.dart';
import '../theme/munji_theme.dart';

/// Patient: who can see my heart data, and a way to add or remove them.
class CaregiversScreen extends StatelessWidget {
  CaregiversScreen({super.key, required this.isArabic, LinkService? links})
      : links = links ?? LinkService();

  final bool isArabic;
  final LinkService links;

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(ar ? 'المرافقون' : 'My caregivers', style: MunjiText.h3),
      ),
      body: StreamBuilder<List<CareLink>>(
        stream: links.forPatient(uid),
        builder: (context, snap) {
          if (snap.hasError) {
            return _Message(
              icon: Icons.cloud_off_rounded,
              text: ar ? 'تعذّر تحميل المرافقين.' : 'Could not load caregivers.',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;

          return ListView(
            padding: const EdgeInsets.all(MunjiSpace.lg),
            children: [
              Text(
                ar
                    ? 'المرافق يرى نبضك وحالة جهازك، ويصله تنبيه عند أي خطر.'
                    : 'A caregiver sees your heart rate and device status, and is alerted if something is wrong.',
                style: MunjiText.body.copyWith(
                    color: MunjiColors.slate, fontWeight: FontWeight.w500, fontSize: 14),
              ),
              const SizedBox(height: MunjiSpace.lg),
              if (list.isEmpty)
                _EmptyCard(isArabic: ar)
              else
                for (final l in list) ...[
                  _CaregiverTile(link: l, isArabic: ar, links: links),
                  const SizedBox(height: MunjiSpace.sm),
                ],
              const SizedBox(height: MunjiSpace.lg),
              if (list.length < 5)
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AddCaregiverScreen(isArabic: ar, links: links),
                  )),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(ar ? 'إضافة مرافق' : 'Add a caregiver'),
                )
              else
                Text(
                  ar ? 'وصلت للحد الأقصى (5 مرافقين).' : 'You have the maximum of 5 caregivers.',
                  style: MunjiText.small,
                  textAlign: TextAlign.center,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.isArabic});
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(MunjiRadius.r4),
        border: Border.all(color: MunjiColors.line),
      ),
      child: Column(
        children: [
          const Icon(Icons.group_outlined, size: 36, color: MunjiColors.blue500),
          const SizedBox(height: MunjiSpace.sm),
          Text(isArabic ? 'لا يوجد مرافقون بعد' : 'No caregivers yet',
              style: MunjiText.h3),
          const SizedBox(height: 4),
          Text(
            isArabic
                ? 'أضف أحد أفراد عائلتك ليتابع حالتك.'
                : 'Add a family member so they can keep an eye on you.',
            style: MunjiText.small,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _CaregiverTile extends StatelessWidget {
  const _CaregiverTile({required this.link, required this.isArabic, required this.links});

  final CareLink link;
  final bool isArabic;
  final LinkService links;

  Future<void> _remove(BuildContext context) async {
    final ar = isArabic;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ar ? 'إزالة المرافق؟' : 'Remove caregiver?'),
        content: Text(ar
            ? 'لن يتمكن ${link.caregiverName} من رؤية بياناتك أو استلام التنبيهات.'
            : '${link.caregiverName} will no longer see your data or receive alerts.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ar ? 'إلغاء' : 'Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: MunjiColors.red),
              child: Text(ar ? 'إزالة' : 'Remove')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await links.revoke(patientId: link.patientId, caregiverId: link.caregiverId);
    } on LinkException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message(ar))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = isArabic;
    final name = link.caregiverName.isEmpty ? relationLabel(null, ar) : link.caregiverName;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: MunjiColors.surface,
        borderRadius: BorderRadius.circular(MunjiRadius.r3),
        border: Border.all(color: MunjiColors.line),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: MunjiColors.blue50,
            child: Text(name.characters.first,
                style: MunjiText.h3.copyWith(color: MunjiColors.blue)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: MunjiText.label),
                const SizedBox(height: 2),
                Text(
                  [
                    relationLabel(link.relation, ar),
                    if (link.priority == 1) (ar ? 'المرافق الأساسي' : 'Primary'),
                  ].join(' · '),
                  style: MunjiText.small.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: ar ? 'إزالة' : 'Remove',
            onPressed: () => _remove(context),
            icon: const Icon(Icons.person_remove_outlined, color: MunjiColors.muted),
          ),
        ],
      ),
    );
  }
}

/// Patient: show a code for the caregiver to type in.
///
/// The screen watches the patient's links, so the moment the caregiver
/// redeems the code it switches to a confirmation without the patient
/// doing anything.
class AddCaregiverScreen extends StatefulWidget {
  const AddCaregiverScreen({super.key, required this.isArabic, required this.links});

  final bool isArabic;
  final LinkService links;

  @override
  State<AddCaregiverScreen> createState() => _AddCaregiverScreenState();
}

class _AddCaregiverScreenState extends State<AddCaregiverScreen> {
  LinkCode? _code;
  LinkException? _error;
  bool _loading = true;
  Timer? _tick;
  StreamSubscription<List<CareLink>>? _sub;
  Set<String>? _before;
  CareLink? _joined;

  bool get ar => widget.isArabic;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser!.uid;
    _sub = widget.links.forPatient(uid).listen((list) {
      final ids = list.map((l) => l.caregiverId).toSet();
      final before = _before;
      if (before == null) {
        _before = ids;
        return;
      }
      final added = list.where((l) => !before.contains(l.caregiverId));
      if (added.isNotEmpty && mounted) {
        setState(() => _joined = added.first);
        _tick?.cancel();
      }
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _newCode();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _newCode() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await widget.links.generate();
      if (mounted) setState(() => _code = c);
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MunjiColors.bg,
      appBar: AppBar(
        backgroundColor: MunjiColors.bg,
        surfaceTintColor: MunjiColors.bg,
        title: Text(ar ? 'إضافة مرافق' : 'Add a caregiver', style: MunjiText.h3),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(MunjiSpace.xl),
          child: _joined != null ? _success() : _codeView(),
        ),
      ),
    );
  }

  Widget _codeView() {
    if (_loading && _code == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        text: _error!.message(ar),
        action: ar ? 'حاول مجددًا' : 'Try again',
        onAction: _newCode,
      );
    }

    final code = _code!;
    final left = code.expiresAt.difference(DateTime.now());
    final expired = left.isNegative;
    final mm = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = left.inSeconds.remainder(60).toString().padLeft(2, '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          ar ? 'اطلب من المرافق إدخال هذا الرمز في تطبيق منجي' : 'Ask your caregiver to enter this code in the Munji app',
          style: MunjiText.body.copyWith(color: MunjiColors.slate, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.xl),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final ch in code.code.split(''))
                Container(
                  width: 46,
                  height: 58,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: expired ? MunjiColors.bg : MunjiColors.surface,
                    borderRadius: BorderRadius.circular(MunjiRadius.r2),
                    border: Border.all(color: MunjiColors.blue100),
                  ),
                  child: Text(ch,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: expired ? MunjiColors.muted : MunjiColors.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ),
            ],
          ),
        ),
        const SizedBox(height: MunjiSpace.md),
        Text(
          expired
              ? (ar ? 'انتهت صلاحية الرمز' : 'This code has expired')
              : (ar ? 'ينتهي خلال $mm:$ss' : 'Expires in $mm:$ss'),
          style: MunjiText.label.copyWith(
              color: expired ? MunjiColors.warn700 : MunjiColors.slate),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.xl),
        if (expired)
          ElevatedButton(
            onPressed: _loading ? null : _newCode,
            child: Text(ar ? 'رمز جديد' : 'New code'),
          )
        else
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code.code));
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ar ? 'تم نسخ الرمز' : 'Code copied')));
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(ar ? 'نسخ الرمز' : 'Copy code'),
          ),
        const Spacer(),
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: MunjiSpace.sm),
            Expanded(
              child: Text(
                ar ? 'بانتظار إدخال الرمز…' : 'Waiting for the code to be entered…',
                style: MunjiText.small,
              ),
            ),
          ],
        ),
        const SizedBox(height: MunjiSpace.sm),
        Text(
          ar
              ? 'الرمز يعمل مرة واحدة، ولا تشاركه إلا مع شخص تثق به.'
              : 'The code works once. Only share it with someone you trust.',
          style: MunjiText.small.copyWith(fontSize: 11),
        ),
      ],
    );
  }

  Widget _success() {
    final name = _joined!.caregiverName;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_rounded, size: 64, color: MunjiColors.green),
        const SizedBox(height: MunjiSpace.lg),
        Text(
          ar ? 'تم ربط $name' : '$name is now linked',
          style: MunjiText.h2,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.sm),
        Text(
          ar
              ? 'يستطيع الآن متابعة نبضك وحالة جهازك.'
              : 'They can now follow your heart rate and device status.',
          style: MunjiText.body.copyWith(color: MunjiColors.slate, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.xxl),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(ar ? 'تم' : 'Done'),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action, this.onAction});

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MunjiSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: MunjiColors.muted),
            const SizedBox(height: MunjiSpace.md),
            Text(text, style: MunjiText.body, textAlign: TextAlign.center),
            if (action != null) ...[
              const SizedBox(height: MunjiSpace.lg),
              OutlinedButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
