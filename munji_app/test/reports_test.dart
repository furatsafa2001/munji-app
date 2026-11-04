import 'package:flutter_test/flutter_test.dart';
import 'package:munji_app/services/history_data.dart';
import 'package:munji_app/services/hourly_recorder.dart';
import 'package:munji_app/services/report_data.dart';
import 'package:munji_app/widgets/vitals.dart';

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
      b.addSeconds(HourState.charging, 600);
      final d = b.toDoc();
      expect(
          d['monitoredMin'] + d['chargingMin'] + d['leadOffMin'] + d['disconnectedMin'],
          lessThanOrEqualTo(60));
      expect(d['monitoredMin'], 60);
      expect(d['chargingMin'], 0);
    });

    test('time on the charger is charging, not disconnected', () {
      final b = HourBucket(DateTime.utc(2026, 10, 12, 6))
        ..addSeconds(HourState.charging, 1200)
        ..addSeconds(HourState.monitored, 2400);
      final d = b.toDoc();
      expect(d['chargingMin'], 20);
      expect(d['monitoredMin'], 40);
      expect(d['disconnectedMin'], 0);
    });

    test('average uses every beat, ignoring impossible ones', () {
      final b = HourBucket(DateTime.utc(2026, 10, 12, 6));
      for (final v in [60.0, 70.0, 80.0, 5.0, 400.0]) {
        b.addBeat(v);
      }
      expect(b.hrAvg, 70);
      // no beat carried a time, so there are no minute averages
      expect(b.hrMin, isNull);
      expect(b.hrMax, isNull);
    });

    test('min and max are one-minute averages, not single beats', () {
      final start = DateTime.utc(2026, 10, 12, 6);
      final b = HourBucket(start);
      // minute 0: 59 beats at 60 and one premature beat read as 200
      for (var i = 0; i < 59; i++) {
        b.addBeat(60, at: start.add(Duration(seconds: i)));
      }
      b.addBeat(200, at: start.add(const Duration(seconds: 59)));
      // minute 1: steady 80
      for (var i = 0; i < 60; i++) {
        b.addBeat(80, at: start.add(Duration(minutes: 1, seconds: i)));
      }
      // minute 2: only 3 beats (a reconnect), too few to count
      for (var i = 0; i < 3; i++) {
        b.addBeat(150, at: start.add(Duration(minutes: 2, seconds: i)));
      }
      expect(b.hrMax, 80);          // the 200 beat does not become the max
      expect(b.hrMin, 62.3);        // (59 x 60 + 200) / 60, rounded
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

  group('HRV from recordings', () {
    test('each recording lands in its Riyadh day, and every one counts once', () {
      // four days: long enough for daily buckets (three days or fewer are hourly)
      final p = ReportPeriod(DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 4));
      final buckets = [
        for (var i = 0; i < p.days; i++) ReportBucket(start: p.first.add(Duration(days: i))),
      ];
      ReportRepository.placeHrv(p, buckets, [
        (DateTime.utc(2026, 10, 1, 6), 30.0),  // 09:00 on 1 Oct
        (DateTime.utc(2026, 10, 1, 7), 40.0),
        (DateTime.utc(2026, 10, 1, 22), 50.0), // 01:00 on 2 Oct in Riyadh
      ]);
      expect(buckets[0].hrvAvg, 35);
      expect(buckets[0].hrvCount, 2);
      expect(buckets[1].hrvAvg, 50);
      final s = ReportSummary(p, buckets);
      expect(s.hrvAvg, 40);       // (30 + 40 + 50) / 3, not the mean of days
      expect(s.hrvCount, 3);
    });

    test('short periods put HRV in its hour', () {
      final p = ReportPeriod(DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 1));
      final buckets = [for (var i = 0; i < 24; i++) ReportBucket(start: p.startInstant.add(Duration(hours: i)))];
      ReportRepository.placeHrv(p, buckets, [(p.startInstant.add(const Duration(hours: 9, minutes: 20)), 33.0)]);
      expect(buckets[9].hrvAvg, 33);
      expect(buckets.where((b) => b.hrvCount > 0).length, 1);
    });

    test('no recordings, no HRV', () {
      final p = ReportPeriod(DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 1));
      expect(ReportSummary(p, [ReportBucket(start: p.first)]).hrvAvg, isNull);
    });
  });

  group('HRV on the home screens', () {
    Recording rec(String id, DateTime at, {double? rmssd, String kind = 'manual'}) =>
        Recording(
          id: id, startedAt: at, durationSec: 30, storagePath: 'x', avgHr: 70,
          rmssd: rmssd, saved: false, kind: kind, deviceSerial: null,
        );

    test('the newest manual recording that has a value is used', () {
      final now = DateTime.utc(2026, 10, 12, 9);
      final r = HistoryRepository.latestWithHrv([
        rec('a', now, rmssd: null),                     // too few clean beats
        rec('b', now, rmssd: 25, kind: 'event'),        // alert strip
        rec('c', now.subtract(const Duration(days: 1)), rmssd: 31),
        rec('d', now.subtract(const Duration(days: 2)), rmssd: 40),
      ]);
      expect(r?.id, 'c');
    });

    test('measured time reads as today, yesterday or days ago (Riyadh)', () {
      final now = DateTime.utc(2026, 10, 12, 9);        // 12:00 Riyadh
      expect(measuredText(DateTime.utc(2026, 10, 12, 6, 15), false, now: now), 'Today 09:15');
      expect(measuredText(DateTime.utc(2026, 10, 11, 6), false, now: now), 'Yesterday');
      expect(measuredText(DateTime.utc(2026, 10, 9, 6), false, now: now), '3 days ago');
    });

    test('an old value is shown faded, a missing one asks for a recording', () {
      final now = DateTime.utc(2026, 10, 12, 9);
      final fresh = hrvStat(ar: false, rmssd: 31, measuredAt: now, now: now);
      expect(fresh.value, '31');
      expect(fresh.dim, isFalse);
      final old = hrvStat(
          ar: false, rmssd: 31, measuredAt: now.subtract(const Duration(days: 5)), now: now);
      expect(old.dim, isTrue);
      final none = hrvStat(ar: false, rmssd: null, measuredAt: null, now: now);
      expect(none.value, '--');
      expect(none.note, 'Record to measure');
    });
  });
}
