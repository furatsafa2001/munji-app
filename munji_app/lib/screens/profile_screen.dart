import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../l10n/strings.dart';
import '../services/account_service.dart';
import '../services/input_rules.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';
import '../l10n/device_strings.dart';
import '../services/background_monitor.dart';
import '../services/device_service.dart';
import 'caregivers_screen.dart';
import 'device_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.isArabic, required this.onLocaleChanged});
  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _service = AccountService();
  bool _editing = false;
  bool _busy = false;
  String? _error;

  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _phone = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '؟';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  Future<void> _save(String uid) async {
    setState(() { _busy = true; _error = null; });
    try {
      await _service.updateProfile(uid,
          fullName: _name.text, phone: _phone.text.replaceAll(' ', ''));
      if (mounted) {
        setState(() => _editing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S(widget.isArabic).saved)),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = authErrorMessage(e, widget.isArabic));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final s = S(widget.isArabic);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MunjiRadius.r3)),
        title: Text(s.signOut, style: MunjiText.h3),
        // sign-out stops monitoring; saying so is more honest than a bare
        // "are you sure?"
        content: Text(s.signOutConfirm, style: MunjiText.small.copyWith(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel, style: MunjiText.label),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.signOut,
                style: MunjiText.label.copyWith(color: MunjiColors.red)),
          ),
        ],
      ),
    );

    if (ok != true) return;
    await _service.signOut();
    if (!mounted) return;
    // Back to the root route only. The auth stream in main.dart shows
    // sign-in from there. Pushing a SignInScreen of our own (as this used
    // to) replaced that root, so signing up or in afterwards went nowhere.
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }

  Future<void> _confirmDelete(bool isPatient) async {
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeleteAccountDialog(
        isArabic: widget.isArabic,
        isPatient: isPatient,
        service: _service,
      ),
    );
    if (deleted != true || !mounted) return;
    // main.dart's auth stream shows sign-in from the root route
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = S(widget.isArabic);
    final user = _service.currentUser;

    if (user == null) {
      return Scaffold(
        body: Center(
          child: Text(s.signIn, style: MunjiText.body),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        // live stream, so an edit made on another device shows up here
        child: StreamBuilder<Map<String, dynamic>?>(
          stream: _service.watchProfile(user.uid),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final p = snap.data;
            if (snap.hasError || p == null) {
              // Never a "loading" that does not end: say what is wrong and
              // leave a way out.
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(MunjiSpace.xxl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MunjiError(widget.isArabic
                          ? 'تعذّر تحميل بيانات حسابك. تأكد من اتصالك بالإنترنت.'
                          : 'Could not load your account. Check your connection.'),
                      const SizedBox(height: MunjiSpace.lg),
                      TextButton(
                        onPressed: _confirmSignOut,
                        child: Text(s.signOut,
                            style: MunjiText.label
                                .copyWith(color: MunjiColors.red)),
                      ),
                    ],
                  ),
                ),
              );
            }

            final name = (p['fullName'] ?? '') as String;
            final isPatient = p['role'] == 'patient';
            final created = p['createdAt'];
            String? since;
            if (created is Timestamp) {
              final d = created.toDate();
              since = '${d.year}/${d.month.toString().padLeft(2, '0')}';
            }

            if (!_editing) {
              _name.text = name;
              _phone.text = (p['phone'] ?? '') as String;
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Text(s.profile, style: MunjiText.h1),
                const SizedBox(height: 20),

                // identity card — pill sits beside the name so the email
                // has full width and never wraps mid-word
                MunjiCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 58, height: 58,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [MunjiColors.blue, MunjiColors.green],
                            begin: Alignment.topLeft, end: Alignment.bottomRight,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(_initials(name),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 19,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(name,
                                      style: MunjiText.h3,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                const SizedBox(width: 8),
                                MunjiPill(isPatient ? s.patient : s.caregiver),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(p['email'] ?? '',
                                textDirection: TextDirection.ltr,
                                style: MunjiText.small.copyWith(fontSize: 12)),
                            Text(p['phone'] ?? '',
                                textDirection: TextDirection.ltr,
                                style: MunjiText.small.copyWith(fontSize: 12)),
                            if (since != null) ...[
                              const SizedBox(height: 4),
                              Text('${s.memberSince} $since',
                                  style: MunjiText.small.copyWith(fontSize: 11)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                if (_editing) ...[
                  MunjiSectionLabel(s.editProfile),
                  MunjiField(
                    label: s.fullName,
                    controller: _name,
                    inputFormatters: [LengthLimitingTextInputFormatter(nameMax + 10)],
                  ),
                  const SizedBox(height: 16),
                  MunjiField(
                    label: s.phone,
                    helper: s.phoneHelp,
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textDirection: TextDirection.ltr,
                    inputFormatters: [
                      const AsciiDigitsFormatter(),
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
                      LengthLimitingTextInputFormatter(16),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    MunjiError(_error!),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _busy ? null : () => _save(user.uid),
                    child: _busy
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white))
                        : Text(s.save),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() { _editing = false; _error = null; }),
                    child: Text(s.cancel, style: MunjiText.label),
                  ),
                ] else ...[
                  MunjiSectionLabel(s.account),
                  MunjiRow(
                    icon: Icons.edit_outlined,
                    title: s.editProfile,
                    onTap: () => setState(() => _editing = true),
                  ),
                  const SizedBox(height: MunjiSpace.sm),
                  MunjiRow(
                    icon: Icons.language,
                    title: s.language,
                    subtitle: widget.isArabic ? 'العربية' : 'English',
                    trailing: Switch(
                      value: widget.isArabic,
                      activeColor: MunjiColors.blue,
                      onChanged: (v) async {
                        widget.onLocaleChanged(v);
                        await _service.updateProfile(user.uid,
                            locale: v ? 'ar' : 'en');
                      },
                    ),
                  ),
                  if (isPatient) const SizedBox(height: MunjiSpace.sm),
                  if (isPatient) MunjiRow(
                    icon: Icons.bluetooth,
                    title: DS(widget.isArabic).munjiDevice,
                    subtitle: DS(widget.isArabic).device,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DeviceScreen(
                          isArabic: widget.isArabic,
                          mode: DeviceScreenMode.settings,
                        ),
                      ),
                    ),
                  ),
                  if (isPatient) ...[
                    const SizedBox(height: MunjiSpace.sm),
                    MunjiRow(
                      icon: Icons.group_outlined,
                      title: widget.isArabic ? 'المرافقون' : 'My caregivers',
                      subtitle: widget.isArabic
                          ? 'من يتابع حالتك'
                          : 'Who follows your heart data',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              CaregiversScreen(isArabic: widget.isArabic),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 26),
                  MunjiRow(
                    icon: Icons.logout,
                    title: s.signOut,
                    tone: PillTone.critical,
                    onTap: _confirmSignOut,
                  ),
                  const SizedBox(height: MunjiSpace.sm),
                  MunjiRow(
                    icon: Icons.delete_forever_outlined,
                    title: widget.isArabic ? 'حذف الحساب' : 'Delete account',
                    subtitle: widget.isArabic
                        ? 'حذف نهائي لحسابك وبياناتك'
                        : 'Permanently remove your account and data',
                    tone: PillTone.critical,
                    onTap: () => _confirmDelete(isPatient),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Asks for the password, says plainly what will be lost, then deletes.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({
    required this.isArabic,
    required this.isPatient,
    required this.service,
  });

  final bool isArabic;
  final bool isPatient;
  final AccountService service;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get ar => widget.isArabic;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_password.text.isEmpty) {
      setState(() => _error = ar ? 'اكتب كلمة المرور للتأكيد' : 'Enter your password to confirm');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // Nothing may write for this account while it is being removed.
    MunjiDevice.hourly.stop();
    MunjiDevice.registry.stop();
    await BackgroundMonitor.stop();
    try {
      await widget.service.deleteAccount(_password.text);
      try {
        await MunjiDevice.instance.forget();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // still here: put monitoring back the way it was
      if (widget.isPatient) {
        MunjiDevice.registry.start();
        MunjiDevice.hourly.start();
        if (MunjiDevice.registry.isPaired) BackgroundMonitor.start(isArabic: ar);
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = authErrorMessage(e, ar);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lose = widget.isPatient
        ? (ar
            ? 'سيُحذف نهائيًا: ملفك، قراءاتك، تقاريرك، تسجيلات تخطيط القلب، وربطك بكل المرافقين. لا يمكن التراجع.'
            : 'This permanently deletes your profile, readings, reports, ECG recordings and every caregiver link. It cannot be undone.')
        : (ar
            ? 'سيُحذف حسابك نهائيًا ويُلغى ربطك بكل من ترعاهم. بياناتهم لا تتأثر. لا يمكن التراجع.'
            : 'This permanently deletes your account and ends every link to the people you care for. Their data is not affected. It cannot be undone.');

    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(MunjiRadius.r3)),
      title: Text(ar ? 'حذف الحساب؟' : 'Delete account?', style: MunjiText.h3),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(lose, style: MunjiText.small.copyWith(fontSize: 13)),
            const SizedBox(height: MunjiSpace.lg),
            TextField(
              controller: _password,
              obscureText: true,
              enabled: !_busy,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: ar ? 'كلمة المرور' : 'Password',
              ),
              onSubmitted: (_) => _busy ? null : _delete(),
            ),
            if (_error != null) ...[
              const SizedBox(height: MunjiSpace.md),
              MunjiError(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(ar ? 'إلغاء' : 'Cancel', style: MunjiText.label),
        ),
        TextButton(
          onPressed: _busy ? null : _delete,
          child: _busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(ar ? 'حذف نهائي' : 'Delete for good',
                  style: MunjiText.label.copyWith(color: MunjiColors.red)),
        ),
      ],
    );
  }
}
