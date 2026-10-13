import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

/// Days and hours in Asia/Riyadh. Saudi Arabia is UTC+3 all year, so a
/// fixed offset is exact, and matches functions/src/riyadh.js.
class Riyadh {
  static const offset = Duration(hours: 3);

  /// The Riyadh calendar date of [t], as a UTC DateTime at 00:00 with the
  /// same y/m/d (handy for display and arithmetic).
  static DateTime dateOf(DateTime t) {
    final r = t.toUtc().add(offset);
    return DateTime.utc(r.year, r.month, r.day);
  }

  /// The instant Riyadh midnight of [date] happens.
  static DateTime midnight(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).subtract(offset);

  static String dayKey(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}${two(date.month)}${two(date.day)}';
  }
}

enum ReportRange { threeDays, week, month, custom }

/// A whole number of Riyadh days, [first] to [last] inclusive.
class ReportPeriod {
  ReportPeriod(this.first, this.last)
      : assert(!last.isBefore(first), 'period ends before it starts');

  /// The last [days] days including today.
  factory ReportPeriod.lastDays(int days, {DateTime? now}) {
    final today = Riyadh.dateOf(now ?? DateTime.now());
    return ReportPeriod(today.subtract(Duration(days: days - 1)), today);
  }

  factory ReportPeriod.of(ReportRange r, {DateTime? now}) {
    switch (r) {
      case ReportRange.threeDays:
        return ReportPeriod.lastDays(3, now: now);
      case ReportRange.week:
        return ReportPeriod.lastDays(7, now: now);
      case ReportRange.month:
        return ReportPeriod.lastDays(30, now: now);
      case ReportRange.custom:
        return ReportPeriod.lastDays(7, now: now);
    }
  }

  final DateTime first;
  final DateTime last;

  int get days => last.difference(first).inDays + 1;

  /// Short periods are shown hour by hour, longer ones day by day. Hourly
  /// documents are kept 90 days, daily ones two years.
  bool get hourly => days <= 3;

  DateTime get startInstant => Riyadh.midnight(first);
  DateTime get endInstant => Riyadh.midnight(last.add(const Duration(days: 1)));
}

/// One point on the charts: an hour or a day.
class ReportBucket {
  ReportBucket({
    required this.start,
    this.hrAvg,
    this.hrMin,
    this.hrMax,
    this.hrvAvg,
    this.monitoredMin = 0,
    this.leadOffMin = 0,
    this.disconnectedMin = 0,
    this.recordings = 0,
  });

  factory ReportBucket.fromDoc(DateTime start, Map<String, dynamic> d) => ReportBucket(
        start: start,
        hrAvg: (d['hrAvg'] as num?)?.toDouble(),
        hrMin: (d['hrMin'] as num?)?.toDouble(),
        hrMax: (d['hrMax'] as num?)?.toDouble(),
        hrvAvg: (d['hrvAvg'] as num?)?.toDouble(),
        monitoredMin: (d['monitoredMin'] as num?)?.toInt() ?? 0,
        leadOffMin: (d['leadOffMin'] as num?)?.toInt() ?? 0,
        disconnectedMin: (d['disconnectedMin'] as num?)?.toInt() ?? 0,
        recordings: (d['recordingsCount'] as num?)?.toInt() ?? 0,
      );

  /// Riyadh date (daily) or the hour's start instant (hourly).
  final DateTime start;
  final double? hrAvg;
  final double? hrMin;
  final double? hrMax;
  final double? hrvAvg;
  final int monitoredMin;
  final int leadOffMin;
  final int disconnectedMin;
  int recordings;

  bool get hasData => hrAvg != null || monitoredMin > 0;
}

/// The period's numbers, aggregated the same way the server builds a day:
/// averages weighted by monitored minutes, extremes over all buckets.
class ReportSummary {
  ReportSummary(this.period, this.buckets);

  final ReportPeriod period;
  final List<ReportBucket> buckets;

  double? _weighted(double? Function(ReportBucket) f) {
    var sum = 0.0;
    var w = 0;
    for (final b in buckets) {
      final v = f(b);
      if (v == null || b.monitoredMin <= 0) continue;
      sum += v * b.monitoredMin;
      w += b.monitoredMin;
    }
    return w == 0 ? null : (sum / w * 10).round() / 10;
  }

  double? _extreme(double? Function(ReportBucket) f, double Function(double, double) pick) {
    double? out;
    for (final b in buckets) {
      final v = f(b);
      if (v == null) continue;
      out = out == null ? v : pick(out, v);
    }
    return out;
  }

  double? get hrAvg => _weighted((b) => b.hrAvg);
  double? get hrMin => _extreme((b) => b.hrMin, math.min);
  double? get hrMax => _extreme((b) => b.hrMax, math.max);
  double? get hrvAvg => _weighted((b) => b.hrvAvg);

  int get monitoredMin => buckets.fold(0, (s, b) => s + b.monitoredMin);
  int get leadOffMin => buckets.fold(0, (s, b) => s + b.leadOffMin);
  int get recordings => buckets.fold(0, (s, b) => s + b.recordings);

  /// Share of the whole period that was actually monitored.
  double get coverage {
    final total = period.days * 24 * 60;
    return total == 0 ? 0 : (monitoredMin / total).clamp(0, 1).toDouble();
  }

  bool get isEmpty => buckets.every((b) => !b.hasData) && recordings == 0;
}

/// Reads hourly or daily documents for a period, and fills the gaps with
/// empty buckets so charts have a point for every hour or day.
class ReportRepository {
  ReportRepository({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<ReportSummary> load(String uid, ReportPeriod p) async {
    final user = _db.collection('users').doc(uid);

    final dailySnap = await user
        .collection('daily')
        .where('dayKey', isGreaterThanOrEqualTo: Riyadh.dayKey(p.first))
        .where('dayKey', isLessThanOrEqualTo: Riyadh.dayKey(p.last))
        .orderBy('dayKey')
        .get();
    final daily = {for (final d in dailySnap.docs) d.id: d.data()};

    if (!p.hourly) {
      final buckets = <ReportBucket>[];
      for (var i = 0; i < p.days; i++) {
        final date = p.first.add(Duration(days: i));
        final d = daily[Riyadh.dayKey(date)];
        buckets.add(d == null ? ReportBucket(start: date) : ReportBucket.fromDoc(date, d));
      }
      return ReportSummary(p, buckets);
    }

    final hourlySnap = await user
        .collection('hourly')
        .where('hourStart', isGreaterThanOrEqualTo: Timestamp.fromDate(p.startInstant))
        .where('hourStart', isLessThan: Timestamp.fromDate(p.endInstant))
        .orderBy('hourStart')
        .get();
    final byStart = {
      for (final d in hourlySnap.docs)
        (d.data()['hourStart'] as Timestamp).millisecondsSinceEpoch: d.data()
    };

    final buckets = <ReportBucket>[];
    final hours = p.days * 24;
    for (var i = 0; i < hours; i++) {
      final start = p.startInstant.add(Duration(hours: i));
      final d = byStart[start.millisecondsSinceEpoch];
      buckets.add(d == null ? ReportBucket(start: start) : ReportBucket.fromDoc(start, d));
    }
    // recordings are only counted per day; put each day's count on its
    // first hour so the period total is right
    for (var day = 0; day < p.days; day++) {
      final key = Riyadh.dayKey(p.first.add(Duration(days: day)));
      final n = (daily[key]?['recordingsCount'] as num?)?.toInt() ?? 0;
      buckets[day * 24].recordings += n;
    }
    return ReportSummary(p, buckets);
  }
}
