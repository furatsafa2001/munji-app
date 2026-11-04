/**
 * Daily vitals from the hourly documents of one day. Pure function: the
 * trigger feeds it every hour of the day and writes the whole result, so a
 * retried trigger or hours arriving out of order cannot skew the result.
 */

const round1 = (x) => Math.round(x * 10) / 10;

function weightedMean(hours, field) {
  let sum = 0;
  let weight = 0;
  for (const h of hours) {
    const v = h[field];
    const w = h.monitoredMin || 0;
    if (v === null || v === undefined || w <= 0) continue;
    sum += v * w;
    weight += w;
  }
  return weight > 0 ? round1(sum / weight) : null;
}

function extreme(hours, field, pick) {
  let out = null;
  for (const h of hours) {
    const v = h[field];
    if (v === null || v === undefined) continue;
    out = out === null ? v : pick(out, v);
  }
  return out;
}

const total = (hours, field) => hours.reduce((s, h) => s + (h[field] || 0), 0);

function computeDailyVitals(hours) {
  return {
    hrAvg: weightedMean(hours, 'hrAvg'),
    hrMin: extreme(hours, 'hrMin', Math.min),
    hrMax: extreme(hours, 'hrMax', Math.max),
    hrvAvg: weightedMean(hours, 'hrvAvg'),
    qualityPct: weightedMean(hours, 'qualityPct'),
    monitoredMin: total(hours, 'monitoredMin'),
    leadOffMin: total(hours, 'leadOffMin'),
    chargingMin: total(hours, 'chargingMin'),
    disconnectedMin: total(hours, 'disconnectedMin'),
    hoursReported: hours.length
  };
}

module.exports = { computeDailyVitals };
