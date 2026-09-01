/// MUNJI strings, Arabic and English.
///
/// Copy follows the review decisions: Munji monitors, it does not
/// "protect"; it never diagnoses; and the phone number is required at
/// sign-up because alerts depend on it.
class S {
  S(this.isArabic);
  final bool isArabic;

  String _(String ar, String en) => isArabic ? ar : en;

  // sign up
  String get createAccount => _('إنشاء حساب', 'Create account');
  String get signUpSubtitle => _(
      'دقيقة واحدة، ثم نوصّل جهازك',
      'One minute, then we connect your device');
  String get iAm => _('أنا', 'I am');
  String get patient => _('مريض', 'Patient');
  String get caregiver => _('مقدّم رعاية', 'Caregiver');
  String get patientHint =>
      _('أرتدي جهاز منجي', 'I wear the Munji device');
  String get caregiverHint =>
      _('أتابع شخصًا يرتديه', 'I follow someone who wears it');

  String get fullName => _('الاسم الكامل', 'Full name');
  String get fullNameHint => _('مثال: صفا خان', 'e.g. Safa Khan');
  String get email => _('البريد الإلكتروني', 'Email');
  String get phone => _('رقم الجوال', 'Mobile number');
  String get phoneHelp => _(
      'نرسل عليه تنبيهات القلب، فتأكّد من صحته',
      'Heart alerts are sent here, so make sure it is correct');
  String get password => _('كلمة المرور', 'Password');
  String get passwordHelp => _('٨ أحرف على الأقل', 'At least 8 characters');
  String get language => _('اللغة', 'Language');

  String get haveAccount => _('لديك حساب؟', 'Already have an account?');
  String get signIn => _('تسجيل الدخول', 'Sign in');
  String get signInTitle => _('تسجيل الدخول', 'Sign in');
  String get signInSubtitle =>
      _('أهلاً بعودتك', 'Welcome back');
  String get noAccount => _('ليس لديك حساب؟', 'No account yet?');
  String get forgotPassword => _('نسيت كلمة المرور؟', 'Forgot your password?');
  String get resetSent => _(
      'أرسلنا رابط إعادة التعيين إلى بريدك',
      'We sent a reset link to your email');
  String get enterEmailFirst =>
      _('أدخل بريدك الإلكتروني أولاً', 'Enter your email first');

  // profile
  String get profile => _('الملف الشخصي', 'Profile');
  String get editProfile => _('تعديل الملف', 'Edit profile');
  String get save => _('حفظ', 'Save');
  String get cancel => _('إلغاء', 'Cancel');
  String get saved => _('تم الحفظ', 'Saved');
  String get account => _('الحساب', 'Account');
  String get signOut => _('تسجيل الخروج', 'Sign out');
  String get signOutConfirm => _(
      'ستحتاج إلى تسجيل الدخول مرة أخرى. المراقبة تتوقف حتى تعود.',
      'You will need to sign in again. Monitoring stops until you do.');
  String get memberSince => _('عضو منذ', 'Member since');

  // shared
  String get retry => _('إعادة المحاولة', 'Try again');
  String get loading => _('جارٍ التحميل…', 'Loading…');
  String get required => _('هذا الحقل مطلوب', 'This field is required');
}
