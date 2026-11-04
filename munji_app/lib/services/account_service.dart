import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'input_rules.dart';

/// Account creation and sign-in.
///
/// This is a direct port of `src/accounts.js` from the backend repo, which
/// has 13 tests against the deployed rules. If you change validation here,
/// change it there too — and remember the rules are the real gate; these
/// checks exist so the user reads "Phone must start with +966" instead of
/// "permission denied".
class AccountService {
  AccountService({FirebaseAuth? auth, FirebaseFirestore? db})
      : _auth = auth ?? FirebaseAuth.instance,
        _db = db ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  /// Must match `firestore.rules`: ^\+[0-9]{8,15}$

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authState => _auth.authStateChanges();

  /// Create the account and its profile.
  ///
  /// These are two writes that a client cannot make atomic, so
  /// if the profile fails we delete the auth account. An account with no
  /// profile is worse than no account: the person can sign in and the app
  /// has nothing to show them.
  Future<String> signUp({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required String locale,
    required String role,
  }) async {
    phone = normalizePhone(phone);
    fullName = cleanName(fullName);
    _validate(
      email: email,
      password: password,
      fullName: fullName,
      phone: phone,
      locale: locale,
      role: role,
    );

    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = cred.user!;

    try {
      await user.updateDisplayName(fullName.trim());
      await user.sendEmailVerification();
      await _db.collection('users').doc(user.uid).set(
            buildProfile(
              fullName: fullName,
              phone: phone,
              email: email.trim(),
              locale: locale,
              role: role,
            ),
          );
    } catch (e, st) {
      // ignore: avoid_print
      print('[signup-failed] $e');
      // ignore: avoid_print
      print(st);
      try {
        await user.delete();
      } catch (_) {
        // rollback failed; signIn will report profile-missing and the app
        // can call repairProfile
      }
      throw AccountException(
        'profile-write-failed',
        'Account could not be created. Please try again.',
        'تعذّر إنشاء الحساب. حاول مرة أخرى.',
      );
    }

    return user.uid;
  }

  /// Sign in and load the profile.
  ///
  /// Throws `profile-missing` when the auth account exists without a users
  /// document. The app should offer repair, not an error.
  Future<Map<String, dynamic>> signIn(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final snap = await _db.collection('users').doc(cred.user!.uid).get();

    if (!snap.exists) {
      throw AccountException(
        'profile-missing',
        'This account has no profile yet.',
        'هذا الحساب بلا ملف شخصي بعد.',
      );
    }
    return snap.data()!;
  }

  Future<Map<String, dynamic>?> getProfile(String uid) async {
    final snap = await _db.collection('users').doc(uid).get();
    return snap.exists ? snap.data() : null;
  }

  /// Live profile, so the caregiver's name change shows up everywhere at
  /// once without a manual refresh.
  Stream<Map<String, dynamic>?> watchProfile(String uid) => _db
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((s) => s.exists ? s.data() : null);

  /// Update editable profile fields.
  ///
  /// role, createdAt and the care relationship are omitted deliberately —
  /// the rules reject any attempt to change them, and the app should not
  /// pretend otherwise.
  Future<void> updateProfile(
    String uid, {
    String? fullName,
    String? phone,
    String? locale,
  }) async {
    final changes = <String, dynamic>{};

    if (fullName != null) {
      final problem = nameProblem(fullName, false);
      if (problem != null) {
        throw AccountException('invalid-name', problem, nameProblem(fullName, true)!);
      }
      changes['fullName'] = cleanName(fullName);
    }
    if (phone != null) {
      final problem = phoneProblem(phone, false);
      if (problem != null) {
        throw AccountException('invalid-phone', problem, phoneProblem(phone, true)!);
      }
      changes['phone'] = normalizePhone(phone);
    }
    if (locale != null) {
      changes['locale'] = locale;
    }
    if (changes.isEmpty) return;

    await _db.collection('users').doc(uid).update(changes);
  }

  Future<void> signOut() => _auth.signOut();

  /// Deletes the account and everything in it, for good.
  ///
  /// The password is asked again first: deleting needs a sign-in from the
  /// last few minutes (the server checks), so a phone left unlocked cannot
  /// do it. Then the `accountDelete` function ends every caregiver link and
  /// removes the profile, readings, recordings and the sign-in account.
  Future<void> deleteAccount(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      throw AccountException('no-user', 'You are not signed in.', 'لست مسجّل الدخول.');
    }
    await user.reauthenticateWithCredential(
      EmailAuthProvider.credential(email: email, password: password),
    );
    await user.getIdToken(true);
    try {
      await FirebaseFunctions.instanceFor(region: 'me-central1')
          .httpsCallable('accountDelete')
          .call<Map<String, dynamic>>();
    } on FirebaseFunctionsException catch (e) {
      throw AccountException(
        'delete-failed:${e.code}',
        'The account could not be deleted. Check your connection and try again.',
        'تعذّر حذف الحساب. تأكد من اتصالك بالإنترنت ثم حاول مرة أخرى.',
      );
    }
    await _auth.signOut();
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  /// The exact shape `firestore.rules` accepts. Kept in one place so
  /// sign-up and repair cannot drift apart.
  static Map<String, dynamic> buildProfile({
    required String fullName,
    required String phone,
    required String email,
    required String locale,
    required String role,
  }) {
    final base = <String, dynamic>{
      'role': role,
      'fullName': fullName.trim(),
      'phone': phone,
      'email': email,
      'locale': locale,
      'fcmTokens': <String>[],
      'createdAt': FieldValue.serverTimestamp(),
      'disabled': false,
    };

    // caregiverIds and patientIds start empty and stay empty until the
    // linking function writes them. The rules reject any client attempt.
    if (role == 'patient') {
      base['patient'] = {
        'knownConditions': <String>[],
        'emergencyNumber': '911',
        'caregiverIds': <String>[],
      };
    } else {
      base['caregiver'] = {'patientIds': <String>[]};
    }
    return base;
  }

  void _validate({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required String locale,
    required String role,
  }) {
    if (role != 'patient' && role != 'caregiver') {
      throw AccountException('invalid-role', 'Invalid role.', 'الدور غير صحيح.');
    }
    final nameEn = nameProblem(fullName, false);
    if (nameEn != null) {
      throw AccountException('invalid-name', nameEn, nameProblem(fullName, true)!);
    }
    final phoneEn = phoneProblem(phone, false);
    if (phoneEn != null) {
      throw AccountException('invalid-phone', phoneEn, phoneProblem(phone, true)!);
    }
    if (locale != 'ar' && locale != 'en') {
      throw AccountException('invalid-locale', 'Invalid language.', 'اللغة غير صحيحة.');
    }
    if (!email.contains('@')) {
      throw AccountException(
          'invalid-email', 'Enter a valid email.', 'أدخل بريدًا إلكترونيًا صحيحًا.');
    }
    final pwEn = passwordProblem(password, false);
    if (pwEn != null) {
      throw AccountException('weak-password', pwEn, passwordProblem(password, true)!);
    }
  }
}

/// Carries both languages so the UI never has to map error codes to text.
class AccountException implements Exception {
  AccountException(this.code, this.en, this.ar);
  final String code;
  final String en;
  final String ar;

  String message(bool isArabic) => isArabic ? ar : en;

  @override
  String toString() => 'AccountException($code)';
}

/// Firebase auth error codes, in both languages.
///
/// Raw Firebase messages are English-only and written for developers —
/// "The password is invalid or the user does not have a password" is not
/// something to show a 65-year-old patient.
String authErrorMessage(Object e, bool isArabic) {
  if (e is AccountException) return e.message(isArabic);

  if (e is FirebaseAuthException) {
    switch (e.code) {
      case 'email-already-in-use':
        return isArabic
            ? 'هذا البريد مسجّل بالفعل. جرّب تسجيل الدخول.'
            : 'This email is already registered. Try signing in.';
      case 'invalid-email':
        return isArabic ? 'البريد الإلكتروني غير صحيح.' : 'That email is not valid.';
      case 'weak-password':
        return isArabic
            ? 'كلمة المرور ضعيفة. استخدم ٨ أحرف على الأقل.'
            : 'That password is too weak. Use at least 8 characters.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        // deliberately identical for both: saying which one is wrong tells
        // an attacker whether the email exists
        return isArabic
            ? 'البريد أو كلمة المرور غير صحيحة.'
            : 'Email or password is incorrect.';
      case 'user-disabled':
        return isArabic ? 'هذا الحساب موقوف.' : 'This account has been disabled.';
      case 'too-many-requests':
        return isArabic
            ? 'محاولات كثيرة. انتظر قليلاً ثم أعد المحاولة.'
            : 'Too many attempts. Please wait and try again.';
      case 'network-request-failed':
        return isArabic
            ? 'تعذّر الاتصال. تحقق من الإنترنت.'
            : 'No connection. Check your internet.';
      case 'requires-recent-login':
        return isArabic
            ? 'لأمان حسابك، سجّل الخروج ثم الدخول مرة أخرى وأعد المحاولة.'
            : 'For your security, sign out, sign in again, then retry.';
    }
  }

  if (e is FirebaseException && e.code == 'unavailable') {
    return isArabic
        ? 'تعذّر الاتصال. تحقق من الإنترنت.'
        : 'No connection. Check your internet.';
  }

  if (e is FirebaseException && e.code == 'permission-denied') {
    return isArabic
        ? 'لا تملك صلاحية لهذه العملية.'
        : 'You do not have permission for this.';
  }

  return isArabic
      ? 'تعذّر إكمال العملية. تأكد من اتصالك بالإنترنت ثم حاول مرة أخرى.'
      : 'That did not go through. Check your internet connection and try again.';
}
