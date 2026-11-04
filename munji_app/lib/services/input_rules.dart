import 'package:flutter/services.dart';

/// What people may type into Munji's forms, in one place, so sign-up,
/// profile editing and the account service always agree.
///
/// Pure functions, tested in test/input_rules_test.dart.

/// Name length after trimming. 60 fits a full four-part Arabic name; the
/// rules allow up to 100 so older accounts are never locked out.
const int nameMin = 2;
const int nameMax = 60;

const int passwordMin = 8;
const int passwordMax = 128;

final _emoji = RegExp(r'\p{Extended_Pictographic}', unicode: true);
final _control = RegExp(r'[\u0000-\u001F\u007F]');
final _spaces = RegExp(r'\s+');

/// Arabic-Indic (٠١٢) and Persian (۰۱۲) digits to 0-9. Phones with an
/// Arabic keyboard type these, and they must not vanish from the field.
String asciiDigits(String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    if (c >= 0x0660 && c <= 0x0669) {
      out.writeCharCode(0x30 + c - 0x0660);
    } else if (c >= 0x06F0 && c <= 0x06F9) {
      out.writeCharCode(0x30 + c - 0x06F0);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// The phone as the rules want it (+ and 8 to 15 digits), from the ways
/// people in Saudi Arabia actually write it:
///   0551234567, 551234567, 966551234567, 00966551234567, +966 55 123 4567
/// Anything else is returned cleaned but unchanged, for the format check.
String normalizePhone(String raw) {
  var p = asciiDigits(raw).replaceAll(RegExp(r'[\s\-()]'), '');
  if (p.startsWith('00')) p = '+${p.substring(2)}';
  // the field starts with +966 and people then type their 05 number
  if (RegExp(r'^\+9660\d{9}$').hasMatch(p)) return '+966${p.substring(5)}';
  if (RegExp(r'^05\d{8}$').hasMatch(p)) return '+966${p.substring(1)}';
  if (RegExp(r'^5\d{8}$').hasMatch(p)) return '+966$p';
  if (RegExp(r'^966\d{9}$').hasMatch(p)) return '+$p';
  return p;
}

final phonePattern = RegExp(r'^\+[0-9]{8,15}$');

String? phoneProblem(String raw, bool ar) {
  final p = normalizePhone(raw);
  if (p.isEmpty || p == '+966') return ar ? 'هذا الحقل مطلوب' : 'This field is required';
  if (!phonePattern.hasMatch(p)) {
    return ar
        ? 'رقم الجوال غير صحيح، مثال: 0551234567'
        : 'That number is not valid, e.g. 0551234567';
  }
  return null;
}

/// Spaces trimmed and runs of spaces made one.
String cleanName(String raw) => raw.trim().replaceAll(_spaces, ' ');

String? nameProblem(String raw, bool ar) {
  final n = cleanName(raw);
  if (n.isEmpty) return ar ? 'هذا الحقل مطلوب' : 'This field is required';
  if (n.runes.length < nameMin) {
    return ar ? 'الاسم قصير جدًا' : 'That name is too short';
  }
  if (n.runes.length > nameMax) {
    return ar ? 'الاسم أطول من $nameMax حرفًا' : 'Keep the name under $nameMax characters';
  }
  if (_emoji.hasMatch(n) || _control.hasMatch(n)) {
    return ar ? 'استخدم حروفًا فقط، بدون رموز تعبيرية' : 'Use letters only, no emoji';
  }
  return null;
}

String? passwordProblem(String pw, bool ar) {
  if (pw.isEmpty) return ar ? 'هذا الحقل مطلوب' : 'This field is required';
  if (pw.trim().isEmpty) {
    return ar ? 'كلمة المرور لا يمكن أن تكون مسافات فقط' : 'A password cannot be only spaces';
  }
  if (pw.length < passwordMin) {
    return ar ? '$passwordMin أحرف على الأقل' : 'At least $passwordMin characters';
  }
  if (pw.length > passwordMax) {
    return ar ? 'كلمة المرور طويلة جدًا' : 'That password is too long';
  }
  return null;
}

/// Keeps Arabic-Indic digits instead of dropping them. Goes before any
/// digits-only filter.
class AsciiDigitsFormatter extends TextInputFormatter {
  const AsciiDigitsFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = asciiDigits(newValue.text);
    if (text == newValue.text) return newValue;
    // one character in, one out, so the cursor stays where it was
    return newValue.copyWith(text: text);
  }
}
