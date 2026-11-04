const { dayKey, hourKey, dayStartMs } = require('../src/riyadh');

test('21:30 UTC is the next day in Riyadh', () => {
  const ms = Date.UTC(2026, 9, 9, 21, 30);
  expect(dayKey(ms)).toBe('20261010');
  expect(hourKey(ms)).toBe('2026101000');
});

test('20:59 UTC is still the same day', () => {
  expect(dayKey(Date.UTC(2026, 9, 9, 20, 59))).toBe('20261009');
});

test('local midnight is 21:00 UTC the day before', () => {
  expect(new Date(dayStartMs('20261010')).toISOString()).toBe('2026-10-09T21:00:00.000Z');
});

test('year boundary', () => {
  expect(dayKey(Date.UTC(2026, 11, 31, 21, 0))).toBe('20270101');
});

test('bad key throws', () => {
  expect(() => dayStartMs('2026-10-10')).toThrow();
});
