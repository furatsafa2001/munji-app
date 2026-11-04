import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/strings.dart';
import '../services/account_service.dart';
import '../services/input_rules.dart';
import '../theme/munji_theme.dart';
import '../widgets/munji_widgets.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key, required this.isArabic, required this.onLocaleChanged});
  final bool isArabic;
  final ValueChanged<bool> onLocaleChanged;

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController(text: '+966');
  final _password = TextEditingController();

  final _service = AccountService();

  String _role = 'patient';
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);
    try {
      await _service.signUp(
        email: _email.text,
        password: _password.text,
        fullName: _name.text,
        phone: _phone.text.replaceAll(' ', ''),
        locale: widget.isArabic ? 'ar' : 'en',
        role: _role,
      );
      if (!mounted) return;
      // The auth gate in main.dart takes over from here: it shows the
      // email-verification screen until the address is confirmed.
      Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        setState(() => _error = authErrorMessage(e, widget.isArabic));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              const SizedBox(height: 4),
              Text(s.createAccount, style: MunjiText.h1),
              const SizedBox(height: 6),
              Text(s.signUpSubtitle, style: MunjiText.small.copyWith(fontSize: 13)),
              const SizedBox(height: 24),

              MunjiSectionLabel(s.iAm),
              Row(
                children: [
                  MunjiChoice(
                    title: s.patient,
                    subtitle: s.patientHint,
                    icon: Icons.favorite_outline,
                    selected: _role == 'patient',
                    onTap: () => setState(() => _role = 'patient'),
                  ),
                  const SizedBox(width: MunjiSpace.md),
                  MunjiChoice(
                    title: s.caregiver,
                    subtitle: s.caregiverHint,
                    icon: Icons.shield_outlined,
                    selected: _role == 'caregiver',
                    onTap: () => setState(() => _role = 'caregiver'),
                  ),
                ],
              ),
              const SizedBox(height: 22),

              MunjiField(
                label: s.fullName,
                hint: s.fullNameHint,
                controller: _name,
                inputFormatters: [LengthLimitingTextInputFormatter(nameMax + 10)],
                validator: (v) => nameProblem(v ?? '', widget.isArabic),
              ),
              const SizedBox(height: 16),

              MunjiField(
                label: s.email,
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return s.required;
                  if (!v.contains('@')) {
                    return widget.isArabic
                        ? 'البريد الإلكتروني غير صحيح'
                        : 'That email is not valid';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              MunjiField(
                label: s.phone,
                helper: s.phoneHelp,
                controller: _phone,
                keyboardType: TextInputType.phone,
                // always LTR: a phone number reads left to right even in
                // an Arabic interface
                textDirection: TextDirection.ltr,
                inputFormatters: [
                  const AsciiDigitsFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
                  LengthLimitingTextInputFormatter(16),
                ],
                validator: (v) => phoneProblem(v ?? '', widget.isArabic),
              ),
              const SizedBox(height: 16),

              MunjiField(
                label: s.password,
                helper: s.passwordHelp,
                controller: _password,
                obscure: !_showPassword,
                suffix: IconButton(
                  icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                      size: 20, color: MunjiColors.muted),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
                inputFormatters: [LengthLimitingTextInputFormatter(passwordMax)],
                validator: (v) => passwordProblem(v ?? '', widget.isArabic),
              ),

              if (_error != null) ...[
                const SizedBox(height: 18),
                MunjiError(_error!),
              ],

              const SizedBox(height: 26),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: Colors.white),
                      )
                    : Text(s.createAccount),
              ),
              const SizedBox(height: 18),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(s.haveAccount, style: MunjiText.small.copyWith(fontSize: 13)),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(s.signIn,
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
