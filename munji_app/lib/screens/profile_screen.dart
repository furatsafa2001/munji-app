import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../l10n/strings.dart';
import '../services/account_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';
import '../l10n/device_strings.dart';
import 'device_screen.dart';
import 'sign_in_screen.dart';

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
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => SignInScreen(
          isArabic: widget.isArabic,
          onLocaleChanged: widget.onLocaleChanged,
        ),
      ),
      (_) => false,
    );
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
            if (p == null) {
              return Center(child: Text(s.loading, style: MunjiText.body));
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
                  MunjiField(label: s.fullName, controller: _name),
                  const SizedBox(height: 16),
                  MunjiField(
                    label: s.phone,
                    helper: s.phoneHelp,
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textDirection: TextDirection.ltr,
                    inputFormatters: [
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
                  const SizedBox(height: MunjiSpace.sm),
                  MunjiRow(
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
                  const SizedBox(height: 26),
                  MunjiRow(
                    icon: Icons.logout,
                    title: s.signOut,
                    tone: PillTone.critical,
                    onTap: _confirmSignOut,
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
