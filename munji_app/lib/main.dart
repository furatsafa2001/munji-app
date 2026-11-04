import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'firebase_options.dart';
import 'theme/munji_theme.dart';
import 'services/account_service.dart';
import 'services/background_monitor.dart';
import 'services/device_config.dart';
import 'services/link_service.dart';
import 'services/device_service.dart';
import 'services/real_device_service.dart';
import 'screens/sign_in_screen.dart';
import 'screens/auth_gate.dart';

/// Which backend this build talks to, chosen when building, not in code:
///
///   flutter run                       real munji-dev project (default)
///   ./scripts/run_emulator.sh         local emulator on this Mac
///
/// The script passes --dart-define=MUNJI_EMULATOR=true and the Mac's LAN IP.
/// Keeping it out of the source means a build for the hardware engineer can
/// never point at someone's laptop by accident.
const bool useEmulator = bool.fromEnvironment('MUNJI_EMULATOR');

/// The Mac running `npm run emu`. A physical phone needs the Mac's LAN IP;
/// the Android emulator can use 10.0.2.2.
const String emulatorHost =
    String.fromEnvironment('MUNJI_EMULATOR_HOST', defaultValue: '10.0.2.2');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Never in a release build: release only allows encrypted traffic, and an
  // APK handed to someone else must reach the real backend.
  if (useEmulator && !kReleaseMode) {
    debugPrint('[munji] using emulator at $emulatorHost');
    await FirebaseAuth.instance.useAuthEmulator(emulatorHost, 9099);
    FirebaseFirestore.instance.useFirestoreEmulator(emulatorHost, 8080);
    FirebaseFunctions.instanceFor(region: LinkService.region)
        .useFunctionsEmulator(emulatorHost, 5001);
    await FirebaseStorage.instance.useStorageEmulator(emulatorHost, 9199);
  }

  // The real patch over BLE. Without this line the app silently runs on the
  // simulator, which is how the 9 October build lost the device.
  // iOS: let the system hand the Bluetooth link back after it relaunches
  // the app in the background. Must come before any other Bluetooth call.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      await FlutterBluePlus.setOptions(restoreState: true);
    } catch (e) {
      debugPrint('[munji] restoreState not set: $e');
    }
  }

  if (DeviceConfig.isConfigured) {
    MunjiDevice.use(RealMunjiDeviceService());
  }

  runApp(const MunjiApp());
}

class MunjiApp extends StatefulWidget {
  const MunjiApp({super.key});

  @override
  State<MunjiApp> createState() => _MunjiAppState();
}

class _MunjiAppState extends State<MunjiApp> {
  bool _isArabic = true;

  void _onLocaleChanged(bool value) => setState(() => _isArabic = value);

  @override
  Widget build(BuildContext context) {
    final locale = Locale(_isArabic ? 'ar' : 'en');

    return MaterialApp(
      title: 'Munji',
      debugShowCheckedModeBanner: false,
      theme: munjiTheme(locale),
      locale: locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(
        textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: child!,
      ),
      // userChanges() — not authStateChanges() — because it also fires after
      // user.reload(), which is how the verification screen gets out of the way.
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.userChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          final user = snap.data;
          debugPrint('[gate] user=${user?.email} verified=${user?.emailVerified}');

          if (user == null) {
            // nobody to report device status for
            MunjiDevice.hourly.stop();
            MunjiDevice.registry.stop();
            BackgroundMonitor.stop();
            return SignInScreen(
              isArabic: _isArabic,
              onLocaleChanged: _onLocaleChanged,
            );
          }

          if (!user.emailVerified) {
            return VerifyEmailScreen(isArabic: _isArabic);
          }

          // Routes by role, and sends a patient with no paired device
          // through device setup first.
          return AuthGate(
            // A different user gets a fresh gate, never the last one's stream.
            key: ValueKey(user.uid),
            isArabic: _isArabic,
            onLocaleChanged: _onLocaleChanged,
          );
        },
      ),
    );
  }
}

/// Shown after sign-up, and on every launch, until the address is confirmed.
class VerifyEmailScreen extends StatefulWidget {
  final bool isArabic;
  const VerifyEmailScreen({super.key, required this.isArabic});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  Timer? _poll;
  bool _checking = false;
  bool _sending = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    // Firebase does not push verification status, so poll for it. When the
    // user taps the link in their inbox this picks it up within 3 seconds.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      await user?.reload();
      // reload() updates emailVerified on the user object but not the ID
      // token, and the link functions check the token. Without a fresh
      // token, adding a caregiver fails with "verify your email" for up to
      // an hour after the user has verified.
      final fresh = FirebaseAuth.instance.currentUser;
      if (fresh != null && fresh.emailVerified) {
        await fresh.getIdToken(true);
      }
    } catch (_) {
      // offline or token expired; the next tick tries again
    }
  }

  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _note = null;
    });
    await _reload();
    if (!mounted) return;
    final verified = FirebaseAuth.instance.currentUser?.emailVerified ?? false;
    setState(() {
      _checking = false;
      _note = verified
          ? null
          : (widget.isArabic
              ? 'لم يتم التأكيد بعد. افتح الرابط في بريدك ثم حاول مجدداً.'
              : 'Not confirmed yet. Open the link in your inbox, then try again.');
    });
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _note = null;
    });
    try {
      await FirebaseAuth.instance.currentUser?.sendEmailVerification();
      if (!mounted) return;
      setState(() {
        _sending = false;
        _note = widget.isArabic
            ? 'تم إرسال الرابط. تحقّق من بريدك ومن مجلد الرسائل غير المرغوبة.'
            : 'Link sent. Check your inbox and your spam folder.';
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _note = e.code == 'too-many-requests'
            ? (widget.isArabic
                ? 'أرسلنا رسائل كثيرة. انتظر قليلاً ثم حاول مجدداً.'
                : 'Too many requests. Wait a moment, then try again.')
            : authErrorMessage(e, widget.isArabic);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    final email = FirebaseAuth.instance.currentUser?.email ?? '';

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.mark_email_unread_outlined, size: 64),
                const SizedBox(height: 24),
                Text(
                  ar ? 'أكّد بريدك الإلكتروني' : 'Verify your email',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  ar
                      ? 'أرسلنا رابط تأكيد إلى $email.\nافتح الرابط ثم عد إلى هنا.'
                      : 'We sent a verification link to $email.\nOpen it, then come back here.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_note != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _note!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _checking ? null : _checkNow,
                    child: Text(
                      _checking
                          ? (ar ? 'جارٍ التحقق…' : 'Checking…')
                          : (ar ? 'تحققت، تابع' : "I've verified, continue"),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _sending ? null : _resend,
                    child: Text(
                      _sending
                          ? (ar ? 'جارٍ الإرسال…' : 'Sending…')
                          : (ar ? 'إعادة إرسال الرابط' : 'Resend link'),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  child: Text(ar ? 'تسجيل الخروج' : 'Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
