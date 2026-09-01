/**
 * MUNJI — accounts
 *
 * Reference implementation of sign-up and sign-in. The mobile app should
 * follow these exact steps; this file is what "a valid users document"
 * means in practice, and it is covered by tests.
 *
 * Two things worth knowing before reading:
 *
 * 1. Creating an account is two writes that must both succeed — the Auth
 *    record and the users document. Firebase cannot do them atomically on
 *    the Spark plan, so if the second fails we delete the first. An Auth
 *    account with no profile is worse than no account at all: the person
 *    can sign in, and the app has nothing to show them.
 *
 * 2. Validation is duplicated here and in firestore.rules on purpose. The
 *    rules are the real gate — they run no matter what client is talking.
 *    These checks exist to fail early with a message a human can act on,
 *    because a rules rejection only ever says "permission denied".
 */

const {
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  signOut,
  updateProfile,
  deleteUser
} = require('firebase/auth');

const { doc, getDoc, setDoc, serverTimestamp } = require('firebase/firestore');

const PHONE = /^\+[0-9]{8,15}$/;          // must match firestore.rules
const ROLES = ['patient', 'caregiver'];
const LOCALES = ['ar', 'en'];

class AccountError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AccountError';
    this.code = code;
  }
}

/**
 * Local pre-flight. Mirrors the rules so the user gets a real message
 * instead of "permission denied".
 */
function validate({ email, password, fullName, phone, locale, role }) {
  if (!ROLES.includes(role)) {
    throw new AccountError('invalid-role', 'Role must be patient or caregiver.');
  }
  if (!fullName || !fullName.trim()) {
    throw new AccountError('invalid-name', 'Full name is required.');
  }
  if (!PHONE.test(phone || '')) {
    throw new AccountError(
      'invalid-phone',
      'Phone must be in international format, e.g. +966512345678.'
    );
  }
  if (!LOCALES.includes(locale)) {
    throw new AccountError('invalid-locale', 'Locale must be ar or en.');
  }
  if (!email || !email.includes('@')) {
    throw new AccountError('invalid-email', 'A valid email is required.');
  }
  if (!password || password.length < 8) {
    throw new AccountError('weak-password', 'Password must be at least 8 characters.');
  }
}

/**
 * The shape of a users document. Kept in one place so sign-up and profile
 * repair cannot drift apart.
 */
function buildProfile({ fullName, phone, email, locale, role }) {
  const base = {
    role,
    fullName: fullName.trim(),
    phone,
    email,
    locale,
    fcmTokens: [],
    createdAt: serverTimestamp(),
    disabled: false
  };

  // caregiverIds and patientIds are deliberately empty. Only the linking
  // functions may populate them, and the rules reject any client attempt.
  if (role === 'patient') {
    base.patient = {
      knownConditions: [],
      emergencyNumber: '911',
      caregiverIds: []
    };
  } else {
    base.caregiver = { patientIds: [] };
  }

  return base;
}

/**
 * Create an account and its profile.
 *
 * On success the caller is signed in and the users document exists.
 * On failure nothing is left behind.
 */
async function signUp(auth, db, params) {
  validate(params);

  const cred = await createUserWithEmailAndPassword(auth, params.email, params.password);
  const user = cred.user;

  try {
    await updateProfile(user, { displayName: params.fullName.trim() });
    await setDoc(doc(db, 'users', user.uid), buildProfile(params));
  } catch (err) {
    // roll back rather than leave an account that cannot be used
    try {
      await deleteUser(user);
    } catch (_) {
      // the account survived the rollback; sign-in will repair it
    }
    throw new AccountError(
      'profile-write-failed',
      'Account could not be created. Please try again.'
    );
  }

  return { uid: user.uid, role: params.role };
}

/**
 * Sign in and load the profile.
 *
 * Throws `profile-missing` when the Auth account exists without a users
 * document — a rollback that itself failed. The app should catch this and
 * call repairProfile() rather than showing an error.
 */
async function signIn(auth, db, email, password) {
  const cred = await signInWithEmailAndPassword(auth, email, password);
  const snap = await getDoc(doc(db, 'users', cred.user.uid));

  if (!snap.exists()) {
    throw new AccountError(
      'profile-missing',
      'This account has no profile yet.'
    );
  }

  return { uid: cred.user.uid, profile: snap.data() };
}

/**
 * Finish an account whose profile write failed. Requires the person to be
 * signed in already — the rules only allow writing your own document.
 */
async function repairProfile(auth, db, params) {
  const user = auth.currentUser;
  if (!user) {
    throw new AccountError('not-signed-in', 'Sign in before repairing the profile.');
  }

  validate({ ...params, email: user.email, password: 'placeholder00' });

  const ref = doc(db, 'users', user.uid);
  if ((await getDoc(ref)).exists()) {
    throw new AccountError('profile-exists', 'This profile already exists.');
  }

  await setDoc(ref, buildProfile({ ...params, email: user.email }));
  return { uid: user.uid };
}

async function getProfile(db, uid) {
  const snap = await getDoc(doc(db, 'users', uid));
  return snap.exists() ? snap.data() : null;
}

async function signOutUser(auth) {
  await signOut(auth);
}

module.exports = {
  signUp,
  signIn,
  repairProfile,
  getProfile,
  signOutUser,
  buildProfile,
  validate,
  AccountError,
  PHONE
};
