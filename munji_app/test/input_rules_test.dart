import 'package:flutter_test/flutter_test.dart';
import 'package:munji_app/services/input_rules.dart';

void main() {
  group('phone', () {
    test('Saudi ways of writing a number all become +966', () {
      for (final raw in [
        '0551234567',
        '551234567',
        '966551234567',
        '00966551234567',
        '+966 55 123 4567',
        '+9660551234567',
        '٠٥٥١٢٣٤٥٦٧',
      ]) {
        expect(normalizePhone(raw), '+966551234567', reason: raw);
      }
    });

    test('other international numbers are kept', () {
      expect(normalizePhone('+447700900123'), '+447700900123');
      expect(phoneProblem('+447700900123', false), isNull);
    });

    test('empty, prefix only, and junk are refused', () {
      expect(phoneProblem('', false), isNotNull);
      expect(phoneProblem('+966', false), isNotNull);
      expect(phoneProblem('12', false), isNotNull);
    });
  });

  group('name', () {
    test('trimmed and single-spaced', () {
      expect(cleanName('  صفاء   خان '), 'صفاء خان');
      expect(nameProblem('  صفاء   خان ', true), isNull);
    });

    test('too short, too long, emoji', () {
      expect(nameProblem('أ', true), isNotNull);
      expect(nameProblem('ا' * (nameMax + 1), true), isNotNull);
      expect(nameProblem('صفاء ❤️', true), isNotNull);
      expect(nameProblem('Safa 😀', false), isNotNull);
    });
  });

  group('password', () {
    test('spaces only and too short are refused', () {
      expect(passwordProblem('        ', false), isNotNull);
      expect(passwordProblem('1234567', false), isNotNull);
      expect(passwordProblem('12345678', false), isNull);
    });
  });

  test('Arabic-Indic and Persian digits become ASCII', () {
    expect(asciiDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    expect(asciiDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
  });
}
