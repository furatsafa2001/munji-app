const {
  buildRecording, validateRecording, parseHeader, expectedBytes, HEADER_BYTES
} = require('../src/ecgFormat');

const NOW = Date.UTC(2026, 9, 10, 9, 0, 0);
const samples = (n) => Array.from({ length: n }, (_, i) => Math.round(1000 * Math.sin(i / 10)));
const valid = () => buildRecording({ samples: samples(7500), startedAtMs: NOW - 60_000 });

test('a 30 s manual recording is exactly 15,032 bytes', () => {
  expect(expectedBytes(30)).toBe(15032);
  expect(valid().length).toBe(15032);
});

test('header round-trips', () => {
  const h = parseHeader(valid());
  expect(h.magic).toBe('MUNJ');
  expect(h.version).toBe(1);
  expect(h.sampleRateHz).toBe(250);
  expect(h.sampleCount).toBe(7500);
  expect(h.startedAtMs).toBe(NOW - 60_000);
  expect(h.uvPerLsb).toBeCloseTo(1.5258789, 5);
});

test('samples are signed little-endian int16', () => {
  const buf = buildRecording({ samples: [-1, 32767, -32768], startedAtMs: NOW });
  expect(buf.readInt16LE(HEADER_BYTES)).toBe(-1);
  expect(buf.readInt16LE(HEADER_BYTES + 2)).toBe(32767);
  expect(buf.readInt16LE(HEADER_BYTES + 4)).toBe(-32768);
});

test('valid manual recording passes', () => {
  const r = validateRecording({ buffer: valid(), kind: 'manual', nowMs: NOW });
  expect(r).toMatchObject({ ok: true, durationSec: 30 });
});

test.each([
  ['unknown kind', { kind: 'other' }, 'bad-kind'],
  ['manual kind with 60 s of data', { buffer: buildRecording({ samples: samples(15000), startedAtMs: NOW }) }, 'bad-sample-count'],
  ['truncated file', { buffer: valid().subarray(0, 10000) }, 'bad-size'],
  ['extra bytes', { buffer: Buffer.concat([valid(), Buffer.alloc(2)]) }, 'bad-size'],
  ['tiny file', { buffer: Buffer.alloc(8) }, 'header-missing'],
  ['start in the future', { buffer: buildRecording({ samples: samples(7500), startedAtMs: NOW + 3600_000 }) }, 'bad-start-time'],
  ['start too old', { buffer: buildRecording({ samples: samples(7500), startedAtMs: NOW - 8 * 86400_000 }) }, 'bad-start-time'],
  ['zero scale', { buffer: buildRecording({ samples: samples(7500), startedAtMs: NOW, uvPerLsb: 0 }) }, 'bad-scale']
])('rejects %s', (_, override, reason) => {
  const r = validateRecording({ buffer: valid(), kind: 'manual', nowMs: NOW, ...override });
  expect(r).toEqual({ ok: false, reason });
});

test('rejects wrong magic', () => {
  const buf = valid();
  buf.write('XXXX', 0, 'ascii');
  expect(validateRecording({ buffer: buf, kind: 'manual', nowMs: NOW }).reason).toBe('bad-magic');
});

test('rejects wrong sample rate', () => {
  const buf = valid();
  buf.writeUInt16LE(256, 6);
  expect(validateRecording({ buffer: buf, kind: 'manual', nowMs: NOW }).reason).toBe('bad-sample-rate');
});

test('event strip is 60 s', () => {
  const buf = buildRecording({ samples: samples(15000), startedAtMs: NOW });
  expect(validateRecording({ buffer: buf, kind: 'event', nowMs: NOW })).toMatchObject({ ok: true, durationSec: 60 });
});
