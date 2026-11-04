import 'package:flutter/material.dart';

import '../services/account_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';
import '../widgets/vitals.dart';

/// Forgotten password, in two steps:
///   1. this screen: type the email, send
///   2. the email: its link opens a page where the new password is set
///
/// The new password is never set inside the app without that link. The
/// link is what proves the person owns the address; without it anyone who
/// knows a patient's email could take over their account and their health
/// data.
///
/// Firebase does not say whether an address is registered (email
/// enumeration protection), so the confirmation is worded to be true either
/// way.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    required this.isArabic,
    this.initialEmail = '',
  });

  final bool isArabic;
  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _service = AccountService();
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);

  bool _busy = false;
  String? _error;
  String? _sentTo;

  bool get ar => widget.isArabic;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final email = _email.text.trim();
      await _service.sendPasswordReset(email);
      if (mounted) setState(() => _sentTo = email);
    } catch (e) {
      if (mounted) setState(() => _error = authErrorMessage(e, ar));
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
              padding: const EdgeInsetsDirectional.fromSTEB(
                  MunjiSpace.sm, MunjiSpace.xs, MunjiSpace.lg, 0),
              child: DetailHeader(
                  title: ar ? 'نسيت كلمة المرور' : 'Forgot password'),
            ),
            Expanded(child: _sentTo == null ? _form() : _sent()),
          ],
        ),
      ),
    );
  }

  Widget _icon(IconData icon) => Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
              color: MunjiColors.blue50, shape: BoxShape.circle),
          child: Icon(icon, color: MunjiColors.blue, size: 30),
        ),
      );

  Widget _form() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(MunjiSpace.xl),
        children: [
          _icon(Icons.lock_reset_rounded),
          const SizedBox(height: MunjiSpace.lg),
          Text(ar ? 'إعادة تعيين كلمة المرور' : 'Reset your password',
              style: MunjiText.h2, textAlign: TextAlign.center),
          const SizedBox(height: MunjiSpace.sm),
          Text(
            ar
                ? 'اكتب بريدك الإلكتروني المسجّل، ونرسل لك رابطًا تختار منه كلمة مرور جديدة.'
                : 'Enter the email you signed up with and we will send you a link to choose a new password.',
            style: MunjiText.body.copyWith(
                color: MunjiColors.slate, fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: MunjiSpace.xl),
          MunjiField(
            label: ar ? 'البريد الإلكتروني' : 'Email',
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.ltr,
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.isEmpty) {
                return ar ? 'اكتب بريدك الإلكتروني' : 'Enter your email';
              }
              if (!t.contains('@') || !t.contains('.')) {
                return ar ? 'البريد الإلكتروني غير صحيح' : 'This email is not valid';
              }
              return null;
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: MunjiSpace.md),
            MunjiError(_error!),
          ],
          const SizedBox(height: MunjiSpace.xl),
          ElevatedButton(
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Colors.white))
                : Text(ar ? 'إرسال الرابط' : 'Send link'),
          ),
        ],
      ),
    );
  }

  Widget _sent() {
    final email = _sentTo!;
    return ListView(
      padding: const EdgeInsets.all(MunjiSpace.xl),
      children: [
        _icon(Icons.mark_email_read_outlined),
        const SizedBox(height: MunjiSpace.lg),
        Text(ar ? 'تحقق من بريدك' : 'Check your email',
            style: MunjiText.h2, textAlign: TextAlign.center),
        const SizedBox(height: MunjiSpace.sm),
        Text(
          ar
              ? 'إذا كان $email مسجّلًا في منجي، سيصلك رابط خلال دقائق. افتحه واختر كلمة مرور جديدة، ثم ارجع وسجّل الدخول بها.'
              : 'If $email has a Munji account, a link will arrive in a few minutes. Open it, choose a new password, then come back and sign in with it.',
          style: MunjiText.body.copyWith(
              color: MunjiColors.slate, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.md),
        Text(
          ar
              ? 'لم يصلك؟ تحقق من مجلد الرسائل غير المرغوبة، وتأكد أن البريد مكتوب كما سجّلت به.'
              : 'Nothing yet? Check your spam folder, and that the address is the one you signed up with.',
          style: MunjiText.small,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: MunjiSpace.xxl),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(ar ? 'العودة لتسجيل الدخول' : 'Back to sign in'),
        ),
        const SizedBox(height: MunjiSpace.sm),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _sentTo = null;
                    _error = null;
                  }),
          child: Text(ar ? 'استخدام بريد آخر أو إعادة الإرسال' : 'Use another email or resend'),
        ),
      ],
    );
  }
}
