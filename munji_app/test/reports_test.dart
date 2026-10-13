import 'package:flutter_test/flutter_test.dart';
import 'package:munji_app/services/hourly_recorder.dart';
import 'package:munji_app/services/report_data.dart';

/// Run with: flutter test
void main() {
  group('HourBucket', () {
    test('hour key is the Riyadh hour (UTC+3)', () {
      // 21:30 UTC on 11 Oct is 00:30 on 12 Oct in Riyadh
      final start = HourBucket.hourStartOf(DateTime.utc(2026, 10, 11, 21, 30));
      expect(start, DateTime.utc(2026, 10, 11, 21));
      expect(HourBucket(start).hourKey, '2026101200');
    });

    test('minutes never add up past 60', () {
      final b = HourBucket(DateTime.utc(2026, 10, 12, 6));
      for (var i = 0; i < 800; i++) {
        b.addSeconds(HourState.monitored, 5);
      }
      final d = b.toDoc();
      expect(d['monitoredMin'] + d['leadOffMin'] + d['disconnectedMin'], lessThanOrEqualTo(60));
      expect(d['monitoredMin'], 60);
    });

    test('heart rate average, min and max, ignoring impossible beats', () {
      final b = HourBucket(DateTime.utc(2026, 10, 12, 6));
      for (final v in [60.0, 70.0, 80.0, 5.0, 400.0]) {
        b.addBeat(v);
      }
      expect(b.hrAvg, 70);
      expect(b.hrMin, 60);
      expect(b.hrMax, 80);
    });

    test('an hour with no beats has null heart rate, not zero', () {
      final b = HourBucket(DateTime.utc(2026, 10, 12, 6))
        ..addSeconds(HourState.disconnected, 3600);
      final d = b.toDoc();
      expect(d['hrAvg'], isNull);
      expect(d['hrvAvg'], isNull);
      expect(d['disconnectedMin'], 60);
    });

    test('expireAt is exactly 90 days after the hour, as the rules require', () {
      final start = DateTime.utc(2026, 10, 12, 6);
      final d = HourBucket(start).toDoc();
      expect(d['dayKey'], '20261012');
      expect((d['expireAt']).toDate().toUtc(), start.add(const Duration(days: 90)));
    });
  });

  group('ReportPeriod', () {
    test('a week is seven Riyadh days ending today', () {
      // 23:00 UTC is already the next day in Riyadh
      final p = ReportPeriod.of(ReportRange.week, now: DateTime.utc(2026, 10, 12, 23));
      expect(p.last, DateTime.utc(2026, 10, 13));
      expect(p.first, DateTime.utc(2026, 10, 7));
      expect(p.days, 7);
      expect(p.hourly, isFalse);
    });

    test('three days or less is shown by the hour', () {
      expect(ReportPeriod.of(ReportRange.threeDays).hourly, isTrue);
    });

    test('the period starts at Riyadh midnight', () {
      final p = ReportPeriod(DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 12));
      expect(p.startInstant, DateTime.utc(2026, 10, 11, 21));
      expect(p.endInstant, DateTime.utc(2026, 10, 12, 21));
    });
  });

  group('ReportSummary', () {
    final p = ReportPeriod(DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 2));

    test('averages are weighted by monitored minutes, like the server', () {
      final s = ReportSummary(p, [
        ReportBucket(start: p.first, hrAvg: 60, hrMin: 50, hrMax: 90, monitoredMin: 600),
        ReportBucket(start: p.last, hrAvg: 90, hrMin: 70, hrMax: 120, monitoredMin: 200),
      ]);
      expect(s.hrAvg, 67.5);
      expect(s.hrMin, 50);
      expect(s.hrMax, 120);
    });

    test('unmonitored days do not pull the average down', () {
      final s = ReportSummary(p, [
        ReportBucket(start: p.first, hrAvg: 70, monitoredMin: 300),
        ReportBucket(start: p.last),
      ]);
      expect(s.hrAvg, 70);
    });

    test('coverage is monitored time over the whole period', () {
      final s = ReportSummary(p, [
        ReportBucket(start: p.first, monitoredMin: 1440),
        ReportBucket(start: p.last),
      ]);
      expect(s.coverage, 0.5);
    });

    test('empty when nothing was monitored or recorded', () {
      expect(ReportSummary(p, [ReportBucket(start: p.first)]).isEmpty, isTrue);
    });
  });
}
