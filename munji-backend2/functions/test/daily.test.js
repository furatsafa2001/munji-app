const { computeDailyVitals } = require('../src/daily');

const hour = (o) => ({
  hrAvg: null, hrMin: null, hrMax: null, hrvAvg: null, qualityPct: null,
  monitoredMin: 0, leadOffMin: 0, chargingMin: 0, disconnectedMin: 0, ...o
});

test('heart rate is weighted by monitored minutes', () => {
  const d = computeDailyVitals([
    hour({ hrAvg: 60, hrMin: 55, hrMax: 70, monitoredMin: 60 }),
    hour({ hrAvg: 90, hrMin: 80, hrMax: 120, monitoredMin: 20, chargingMin: 40 })
  ]);
  expect(d.hrAvg).toBe(67.5);
  expect(d.hrMin).toBe(55);
  expect(d.hrMax).toBe(120);
  expect(d.monitoredMin).toBe(80);
  expect(d.chargingMin).toBe(40);
  expect(d.hoursReported).toBe(2);
});

test('hours without monitoring do not pull the average', () => {
  const d = computeDailyVitals([
    hour({ hrAvg: 70, monitoredMin: 30 }),
    hour({ hrAvg: null, monitoredMin: 0, disconnectedMin: 60 })
  ]);
  expect(d.hrAvg).toBe(70);
  expect(d.disconnectedMin).toBe(60);
});

test('no data gives nulls, not zeros', () => {
  const d = computeDailyVitals([]);
  expect(d.hrAvg).toBeNull();
  expect(d.hrMin).toBeNull();
  expect(d.hrvAvg).toBeNull();
  expect(d.monitoredMin).toBe(0);
  expect(d.hoursReported).toBe(0);
});

test('order of hours does not matter', () => {
  const hs = [hour({ hrAvg: 61, monitoredMin: 10 }), hour({ hrAvg: 99, monitoredMin: 50 }), hour({ hrAvg: 75, monitoredMin: 33 })];
  expect(computeDailyVitals(hs)).toEqual(computeDailyVitals([...hs].reverse()));
});
