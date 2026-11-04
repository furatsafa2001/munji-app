/**
 * The .ecg file format. The app writes it, the finalize trigger reads it.
 * Keep this file and the Dart writer in step: a change here is a format
 * version bump.
 *
 *   offset  field         type      value
 *   0       magic         4 bytes   "MUNJ"
 *   4       version       uint16    1
 *   6       sampleRateHz  uint16    250
 *   8       uvPerLsb      float32   1.5258789 (firmware constant)
 *   12      sampleCount   uint32    durationSec x 250
 *   16      startedAtMs   int64     first sample, UTC epoch ms
 *   24      reserved      8 bytes   zero
 *   32      samples       int16 LE  raw device values, unprocessed
 */

const HEADER_BYTES = 32;
const MAGIC = 'MUNJ';
const FORMAT_VERSION = 1;
const SAMPLE_RATE_HZ = 250;
const DURATION_BY_KIND = Object.freeze({ manual: 30, event: 60 });

const MAX_FUTURE_MS = 5 * 60 * 1000;          // phone clock drift we tolerate
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;   // offline upload queue limit

function expectedBytes(durationSec) {
  return HEADER_BYTES + durationSec * SAMPLE_RATE_HZ * 2;
}

function parseHeader(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < HEADER_BYTES) return null;
  return {
    magic: buf.toString('ascii', 0, 4),
    version: buf.readUInt16LE(4),
    sampleRateHz: buf.readUInt16LE(6),
    uvPerLsb: buf.readFloatLE(8),
    sampleCount: buf.readUInt32LE(12),
    startedAtMs: Number(buf.readBigInt64LE(16))
  };
}

/**
 * Returns { ok: true, durationSec } or { ok: false, reason }.
 * `reason` is a fixed code, safe to log: it never contains signal data.
 */
function validateRecording({ buffer, kind, nowMs }) {
  const durationSec = DURATION_BY_KIND[kind];
  if (!durationSec) return { ok: false, reason: 'bad-kind' };

  const h = parseHeader(buffer);
  if (!h) return { ok: false, reason: 'header-missing' };
  if (h.magic !== MAGIC) return { ok: false, reason: 'bad-magic' };
  if (h.version !== FORMAT_VERSION) return { ok: false, reason: 'bad-version' };
  if (h.sampleRateHz !== SAMPLE_RATE_HZ) return { ok: false, reason: 'bad-sample-rate' };
  if (!(h.uvPerLsb > 0 && h.uvPerLsb < 100)) return { ok: false, reason: 'bad-scale' };
  if (h.sampleCount !== durationSec * SAMPLE_RATE_HZ) return { ok: false, reason: 'bad-sample-count' };
  if (buffer.length !== expectedBytes(durationSec)) return { ok: false, reason: 'bad-size' };
  if (h.startedAtMs > nowMs + MAX_FUTURE_MS || h.startedAtMs < nowMs - MAX_AGE_MS) {
    return { ok: false, reason: 'bad-start-time' };
  }
  return { ok: true, durationSec, header: h };
}

/** Builds a file. Used by tests and the seed script; the app has its own Dart writer. */
function buildRecording({ samples, startedAtMs, uvPerLsb = 1.5258789 }) {
  const buf = Buffer.alloc(HEADER_BYTES + samples.length * 2);
  buf.write(MAGIC, 0, 'ascii');
  buf.writeUInt16LE(FORMAT_VERSION, 4);
  buf.writeUInt16LE(SAMPLE_RATE_HZ, 6);
  buf.writeFloatLE(uvPerLsb, 8);
  buf.writeUInt32LE(samples.length, 12);
  buf.writeBigInt64LE(BigInt(startedAtMs), 16);
  samples.forEach((s, i) => buf.writeInt16LE(s, HEADER_BYTES + i * 2));
  return buf;
}

module.exports = {
  HEADER_BYTES,
  MAGIC,
  FORMAT_VERSION,
  SAMPLE_RATE_HZ,
  DURATION_BY_KIND,
  expectedBytes,
  parseHeader,
  validateRecording,
  buildRecording
};
