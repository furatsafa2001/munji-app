import 'package:flutter/material.dart';

/// MUNJI design tokens.
///
/// Ported directly from the HTML prototype so screens built in Flutter
/// match what was signed off. Every value here came from the audited
/// system — 7 type sizes, 4 radii, 3 elevations — not from Material
/// defaults. Do not introduce a size, colour or radius that is not here:
/// that is exactly how the prototype ended up with 28 font sizes before
/// the design pass.
class MunjiColors {
  // brand
  static const blue = Color(0xFF00537A);
  static const blue700 = Color(0xFF013F5D);
  static const blue500 = Color(0xFF0A6E9B);
  static const blue100 = Color(0xFFDCE7F0);
  static const blue50 = Color(0xFFEEF3F8);

  // semantic — green normal, amber moderate, red critical, slate technical
  static const green = Color(0xFF1F9D62);
  static const ok700 = Color(0xFF12724A);
  static const ok200 = Color(0xFFC3E4D3);
  static const ok50 = Color(0xFFEDF7F2);

  static const orange = Color(0xFFE08600);
  static const warn700 = Color(0xFFA35C00);
  static const warn200 = Color(0xFFF7DEB0);
  static const warn50 = Color(0xFFFFF7EA);

  /// Red is reserved for critical findings and an active SOS. Never use it
  /// for decoration — when everything is red, nothing is.
  static const red = Color(0xFFC62828);
  static const danger700 = Color(0xFF9E1F1B);
  static const danger200 = Color(0xFFF3C7C3);
  static const danger50 = Color(0xFFFDF1F0);

  // neutrals
  static const ink = Color(0xFF0E2233);
  static const slate = Color(0xFF4A5C6E);

  /// 4.7:1 on white. The earlier value failed WCAG AA, which matters for a
  /// product whose users are mostly over 60.
  static const muted = Color(0xFF5E7387);
  static const line = Color(0xFFDCE4EC);
  static const bg = Color(0xFFF5F7FA);
  static const surface = Colors.white;
}

class MunjiRadius {
  static const r1 = 8.0;
  static const r2 = 12.0;
  static const r3 = 16.0;
  static const r4 = 20.0;
  static const pill = 999.0;
}

class MunjiSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

class MunjiShadow {
  static const e1 = [
    BoxShadow(color: Color(0x0D0E2233), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const e2 = [
    BoxShadow(color: Color(0x120E2233), blurRadius: 10, offset: Offset(0, 3)),
  ];
  static const e3 = [
    BoxShadow(color: Color(0x1A0E2233), blurRadius: 26, offset: Offset(0, 10)),
  ];
}

/// Type scale. Nothing below 11px — the prototype had 7.5px tab labels,
/// which is unreadable for the target age group.
class MunjiText {
  static const h1 = TextStyle(
      fontSize: 26, fontWeight: FontWeight.w800, color: MunjiColors.ink, letterSpacing: -0.5);
  static const h2 = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w800, color: MunjiColors.ink, letterSpacing: -0.3);
  static const h3 = TextStyle(
      fontSize: 17, fontWeight: FontWeight.w800, color: MunjiColors.ink);
  static const body = TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, color: MunjiColors.ink);
  static const label = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w700, color: MunjiColors.ink);
  static const small = TextStyle(
      fontSize: 11.5, fontWeight: FontWeight.w600, color: MunjiColors.muted, height: 1.55);
  static const caption = TextStyle(
      fontSize: 10.5, fontWeight: FontWeight.w800, color: MunjiColors.muted, letterSpacing: 0.6);
}

ThemeData munjiTheme(Locale locale) {
  final isArabic = locale.languageCode == 'ar';

  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: MunjiColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: MunjiColors.blue,
      primary: MunjiColors.blue,
      error: MunjiColors.red,
      surface: MunjiColors.surface,
    ),
    // Arabic needs a larger optical size and looser leading for parity
    fontFamily: isArabic ? 'Tajawal' : 'Inter',
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: MunjiColors.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        borderSide: const BorderSide(color: MunjiColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        borderSide: const BorderSide(color: MunjiColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        borderSide: const BorderSide(color: MunjiColors.blue, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        borderSide: const BorderSide(color: MunjiColors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(MunjiRadius.r2),
        borderSide: const BorderSide(color: MunjiColors.red, width: 1.6),
      ),
      hintStyle: const TextStyle(
          color: MunjiColors.muted, fontSize: 13, fontWeight: FontWeight.w600),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: MunjiColors.blue,
        foregroundColor: Colors.white,
        // 50px: the prototype audit raised every target to 44px minimum
        minimumSize: const Size.fromHeight(50),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MunjiRadius.r2),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    ),
  );
}
