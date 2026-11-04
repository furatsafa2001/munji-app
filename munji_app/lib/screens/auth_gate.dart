import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/account_service.dart';
import '../services/background_monitor.dart';
import '../services/device_service.dart';
import '../theme/munji_theme.dart';
import 'caregiver_screens.dart';
import 'device_screen.dart';
import 'patient_shell.dart';

/// Decides where a verified user lands.
///
/// A patient who has never paired a device is sent through device setup once —
/// it is not optional, because Munji cannot monitor anything without it.
/// A paired patient lands on the home tabs; a caregiver on the list of
/// people they look after. The pairing flag lives in
/// Firestore (`devicePaired`) rather than in the device service, because the
/// service is rebuilt on every launch and would otherwise forget.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.isArabic,
    required this.onLocaleChanged,
  });

  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _uid = FirebaseAuth.instance.currentUser!.uid;

  // Held in state so a locale change does not reopen it, and replaced on
  // retry, because a stream that failed (rules, network) stays failed.
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _profile = _open();

  // On a fresh install the local cache answers first, with "no document".
  // Give the server this long before calling it a connection problem.
  static const _serverGrace = Duration(seconds: 8);
  Timer? _grace;
  bool _graceOver = false;

  @override
  void initState() {
    super.initState();
    _startGrace();
  }

  @override
  void dispose() {
    _grace?.cancel();
    super.dispose();
  }

  void _startGrace() {
    _grace?.cancel();
    _graceOver = false;
    _grace = Timer(_serverGrace, () {
      if (mounted) setState(() => _graceOver = true);
    });
  }

  // includeMetadataChanges, so the server's answer arrives even when it
  // matches the cache (both "no document"), and we can tell the two apart.
  Stream<DocumentSnapshot<Map<String, dynamic>>> _open() => FirebaseFirestore
      .instance
      .collection('users')
      .doc(_uid)
      .snapshots(includeMetadataChanges: true);

  // The language saved in the profile is applied once per sign-in, so a
  // choice made in Profile survives restarts.
  bool _localeApplied = false;

  void _retry() => setState(() {
        _profile = _open();
        _startGrace();
      });

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    final onLocaleChanged = widget.onLocaleChanged;
    final uid = _uid;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _profile,
      builder: (context, snap) {
        // Every path out of here leads somewhere the user can act. A spinner
        // or "loading" that never ends is how a patient got stuck before.
        if (snap.hasError) {
          debugPrint('[authgate] error: ${snap.error}');
          return AccountProblemScreen(
            isArabic: isArabic,
            kind: AccountProblem.unreachable,
            onRetry: _retry,
          );
        }

        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final doc = snap.data!;
        final data = doc.data();

        if (data == null) {
          // Only the server can say a profile is missing. A cache miss is
          // either the server still on its way or no connection.
          if (doc.metadata.isFromCache && !_graceOver) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return AccountProblemScreen(
            isArabic: isArabic,
            kind: doc.metadata.isFromCache
                ? AccountProblem.unreachable
                : AccountProblem.missingProfile,
            onRetry: _retry,
          );
        }

        // A document without a valid role was not made by sign-up (it was
        // edited by hand, or half-deleted). Never guess a role for it.
        final role = data['role'];
        if (role != 'patient' && role != 'caregiver') {
          return AccountProblemScreen(
            isArabic: isArabic,
            kind: AccountProblem.missingProfile,
            onRetry: _retry,
          );
        }

        final isPatient = role == 'patient';
        final paired = data['devicePaired'] == true;

        if (!_localeApplied) {
          _localeApplied = true;
          final wantArabic = data['locale'] != 'en';
          if (wantArabic != isArabic) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => onLocaleChanged(wantArabic));
          }
        }

        // Screen-off monitoring, once there is a patch to monitor.
        if (isPatient && paired) {
          BackgroundMonitor.start(isArabic: isArabic);
        } else {
          BackgroundMonitor.stop();
        }

        // Only a patient's phone reports device status. start() is a no-op
        // once running, so rebuilds of this stream do not restart it.
        if (isPatient) {
          MunjiDevice.registry.start();
          MunjiDevice.hourly.start();
        }

        if (isPatient && !paired) {
          return DeviceScreen(
            isArabic: isArabic,
            mode: DeviceScreenMode.setup,
            onDone: () async {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .update({'devicePaired': true});
              // The stream above picks the change up and swaps the screen.
            },
          );
        }

        if (isPatient) {
          return PatientShell(
            isArabic: isArabic,
            onLocaleChanged: onLocaleChanged,
            fullName: (data['fullName'] ?? '') as String,
          );
        }

        return CaregiverShell(
          isArabic: isArabic,
          onLocaleChanged: onLocaleChanged,
        );
      },
    );
  }
}

enum AccountProblem { unreachable, missingProfile }

/// Shown when the signed-in user's profile cannot be loaded. Always offers a
/// way forward: try again, or sign out.
class AccountProblemScreen extends StatefulWidget {
  const AccountProblemScreen({
    super.key,
    required this.isArabic,
    required this.kind,
    required this.onRetry,
  });

  final bool isArabic;
  final AccountProblem kind;
  final VoidCallback onRetry;

  @override
  State<AccountProblemScreen> createState() => _AccountProblemScreenState();
}

class _AccountProblemScreenState extends State<AccountProblemScreen> {
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    if (widget.kind == AccountProblem.missingProfile) _signOutIfDeleted();
  }

  /// The phone keeps a session even after the account is deleted in the
  /// console (or the app reinstalled: iOS keeps it in the Keychain). Asking
  /// the server tells us at once, and a deleted account goes straight back
  /// to sign-in.
  Future<void> _signOutIfDeleted() async {
    try {
      await FirebaseAuth.instance.currentUser?.reload();
    } on FirebaseAuthException catch (e) {
      const gone = {
        'user-not-found',
        'user-disabled',
        'user-token-expired',
        'invalid-user-token',
      };
      if (gone.contains(e.code)) await _signOut();
    } catch (_) {
      // offline: leave the choice to the user
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    if (mounted) setState(() => _signingOut = true);
    // main.dart listens to auth and shows sign-in once this completes.
    await AccountService().signOut();
  }

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    final missing = widget.kind == AccountProblem.missingProfile;

    final title = missing
        ? (ar ? 'حسابك غير مكتمل' : 'Your account is incomplete')
        : (ar ? 'تعذّر تحميل حسابك' : 'We could not load your account');
    final body = missing
        ? (ar
            ? 'لم نجد بيانات حسابك. سجّل الخروج ثم أنشئ حسابًا جديدًا، أو تواصل مع الدعم.'
            : 'We could not find your account details. Sign out and create a new account, or contact support.')
        : (ar
            ? 'تأكد من اتصالك بالإنترنت ثم حاول مرة أخرى.'
            : 'Check your internet connection, then try again.');

    return Scaffold(
      backgroundColor: MunjiColors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(MunjiSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  missing ? Icons.person_off_outlined : Icons.cloud_off_outlined,
                  size: 56,
                  color: MunjiColors.muted,
                ),
                const SizedBox(height: MunjiSpace.xl),
                Text(title, style: MunjiText.h2, textAlign: TextAlign.center),
                const SizedBox(height: MunjiSpace.md),
                Text(body, style: MunjiText.body, textAlign: TextAlign.center),
                const SizedBox(height: MunjiSpace.xxl + MunjiSpace.sm),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _signingOut ? null : widget.onRetry,
                    child: Text(ar ? 'إعادة المحاولة' : 'Try again'),
                  ),
                ),
                const SizedBox(height: MunjiSpace.sm),
                TextButton(
                  onPressed: _signingOut ? null : _signOut,
                  child: Text(
                    ar ? 'تسجيل الخروج' : 'Sign out',
                    style: MunjiText.label.copyWith(color: MunjiColors.red),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
