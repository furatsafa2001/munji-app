/**
 * Day and hour keys in Asia/Riyadh. Saudi Arabia is UTC+3 all year with no
 * daylight saving, so a fixed offset is exact. Using UTC here would make
 * "today" in the app start at 3 a.m.
 */

const OFFSET_MS = 3 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

const pad = (n, w = 2) => String(n).padStart(w, '0');

function parts(ms) {
  const d = new Date(ms + OFFSET_MS);
  return {
    y: d.getUTCFullYear(),
    m: d.getUTCMonth() + 1,
    d: d.getUTCDate(),
    h: d.getUTCHours()
  };
}

/** yyyyMMdd */
function dayKey(ms) {
  const p = parts(ms);
  return `${p.y}${pad(p.m)}${pad(p.d)}`;
}

/** yyyyMMddHH */
function hourKey(ms) {
  const p = parts(ms);
  return `${p.y}${pad(p.m)}${pad(p.d)}${pad(p.h)}`;
}

/** UTC epoch ms of local midnight for a yyyyMMdd key */
function dayStartMs(key) {
  if (!/^[0-9]{8}$/.test(key)) throw new Error('bad day key');
  const y = Number(key.slice(0, 4));
  const m = Number(key.slice(4, 6));
  const d = Number(key.slice(6, 8));
  return Date.UTC(y, m - 1, d) - OFFSET_MS;
}

module.exports = { OFFSET_MS, HOUR_MS, DAY_MS, dayKey, hourKey, dayStartMs };
