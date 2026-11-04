import 'package:flutter/material.dart';
import '../l10n/strings.dart';
import '../services/account_service.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.isArabic, required this.onLocaleChanged});
  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _service = AccountService();

  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _error = null; _notice = null; });
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    try {
      await _service.signIn(_email.text, _password.text);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = authErrorMessage(e, widget.isArabic));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Its own screen: type the email, then the emailed link sets the new
  /// password. Whatever is already in the email field comes along.
  void _reset() {
    setState(() { _error = null; _notice = null; });
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ForgotPasswordScreen(
        isArabic: widget.isArabic,
        initialEmail: _email.text.trim(),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = S(widget.isArabic);

    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => widget.onLocaleChanged(!widget.isArabic),
                  child: Text(widget.isArabic ? 'English' : 'العربية',
                      style: MunjiText.label.copyWith(color: MunjiColors.blue)),
                ),
              ),
              const SizedBox(height: 30),

              Center(
                child: Container(
                  width: 62, height: 62,
                  decoration: BoxDecoration(
                    color: MunjiColors.blue,
                    borderRadius: BorderRadius.circular(MunjiRadius.r4),
                  ),
                  child: const Icon(Icons.favorite, color: Colors.white, size: 30),
                ),
              ),
              const SizedBox(height: 20),

              Center(child: Text(s.signInTitle, style: MunjiText.h1)),
              const SizedBox(height: 6),
              Center(
                child: Text(s.signInSubtitle,
                    style: MunjiText.small.copyWith(fontSize: 13)),
              ),
              const SizedBox(height: 30),

              MunjiField(
                label: s.email,
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? s.required : null,
              ),
              const SizedBox(height: 16),

              MunjiField(
                label: s.password,
                controller: _password,
                obscure: !_showPassword,
                suffix: IconButton(
                  icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                      size: 20, color: MunjiColors.muted),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? s.required : null,
              ),

              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _busy ? null : _reset,
                  child: Text(s.forgotPassword,
                      style: MunjiText.small.copyWith(
                          fontSize: 12.5, color: MunjiColors.blue)),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                MunjiError(_error!),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    color: MunjiColors.ok50,
                    borderRadius: BorderRadius.circular(MunjiRadius.r2),
                    border: Border.all(color: MunjiColors.ok200),
                  ),
                  child: Text(_notice!,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: MunjiColors.ok700, height: 1.45)),
                ),
              ],

              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: Colors.white),
                      )
                    : Text(s.signIn),
              ),
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(s.noAccount, style: MunjiText.small.copyWith(fontSize: 13)),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => SignUpScreen(
                                  isArabic: widget.isArabic,
                                  onLocaleChanged: widget.onLocaleChanged,
                                ),
                              ),
                            ),
                    child: Text(s.createAccount,
                        style: MunjiText.label.copyWith(color: MunjiColors.blue)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
