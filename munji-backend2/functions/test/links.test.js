const {
  newCode, isCodeShape, cleanRelation, attemptState, displayName,
  ATTEMPT_LIMIT, ATTEMPT_WINDOW_MS
} = require('../src/links');

test('codes are always six digits, leading zeros kept', () => {
  for (let i = 0; i < 2000; i++) {
    const c = newCode();
    expect(c).toMatch(/^\d{6}$/);
  }
});

test('code shape check rejects anything but six digits', () => {
  expect(isCodeShape('012345')).toBe(true);
  expect(isCodeShape('12345')).toBe(false);
  expect(isCodeShape('1234567')).toBe(false);
  expect(isCodeShape('12a456')).toBe(false);
  expect(isCodeShape(123456)).toBe(false);
  expect(isCodeShape(undefined)).toBe(false);
});

test('unknown relations become null', () => {
  expect(cleanRelation('daughter')).toBe('daughter');
  expect(cleanRelation('boss')).toBeNull();
  expect(cleanRelation(undefined)).toBeNull();
});

test('first attempt is allowed and starts a window', () => {
  const s = attemptState(undefined, 1000);
  expect(s.allowed).toBe(true);
  expect(s.onFailure).toEqual({ windowStart: 1000, count: 1 });
});

test('the limit is reached after five failures in the window', () => {
  const s = attemptState({ windowStart: 0, count: ATTEMPT_LIMIT }, 60 * 1000);
  expect(s.allowed).toBe(false);
});

test('the window resets after 15 minutes', () => {
  const s = attemptState({ windowStart: 0, count: ATTEMPT_LIMIT }, ATTEMPT_WINDOW_MS + 1);
  expect(s.allowed).toBe(true);
  expect(s.onFailure).toEqual({ windowStart: ATTEMPT_WINDOW_MS + 1, count: 1 });
});

test('display names are trimmed and capped', () => {
  expect(displayName({ fullName: '  Nora  ' })).toBe('Nora');
  expect(displayName({ fullName: 'x'.repeat(200) }).length).toBe(80);
  expect(displayName({})).toBe('');
});
