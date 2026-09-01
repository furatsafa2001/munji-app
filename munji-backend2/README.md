# MUNJI Backend

Firestore schema, security rules, and emulator tooling.

Two-person team. Everything here exists because it does work — nothing is
here as ceremony.

---

## Environments

**Emulator** — where you actually work. Instant, free, wiped every run.

**`munji-dev`** — one cloud project. Exists because a phone doing BLE pairing
can't reach `localhost` on your laptop, so the mobile app needs a real
endpoint.

That's it for now. Production comes later and goes to `me-central2` (Dammam)
through CNTXT — **a Firestore location is permanent**, so that project gets
created deliberately, not by accident.

---

## Getting started

```bash
npm install
npm install -g firebase-tools

npm run emu          # emulators + UI on :4000
npm run seed         # second terminal
npm run test:rules   # rules suite against the emulator
```

Seeded accounts, password `Test1234!`:

```
safa.khan@email.com    patient    linked to Nora, device dev_4F2A
ahmed.khan@email.com   patient    linked to Nora, device dev_7B11
nora.khan@email.com    caregiver  linked to both
```

Live pairing code: `482913`, expires 15 minutes after seeding.

---

## Collections

Built now — the spine everything else hangs off:

| Collection | Purpose |
|---|---|
| `users` | patient and caregiver profiles |
| `linkCodes` | 6-digit pairing code, server-only |
| `careLinks` | patient ↔ caregiver relationship |
| `devices` | paired device, battery, signal state |
| `recordings` | ECG capture metadata + storage path |
| `auditLog` | append-only trail |

Schema known, not built yet:

| Collection | Blocked on |
|---|---|
| `events` | inference service |
| `medAlarms` | mobile alarm screens wiring up |
| `vitalsDaily` | rollup functions |
| `alerts` | notification layer |

**Their deny-rules ship now anyway.** A collection with no rule is writable
by anyone the moment it's created. Deny first, open later — it costs nothing
today and closes a hole you'd never think to look for.

---

## Build order

1. Rules + emulator + seed **← done**
2. Auth and account creation **← done** (`src/accounts.js`)
3. `linkCode_generate` / `linkCode_redeem`, `careLinks`, App Check
4. Signed upload/download URLs, finalize trigger writes `recordings`

---

## Accounts

`src/accounts.js` is the reference implementation. The mobile app follows
these steps exactly; this file defines what a valid `users` document is.

```
signUp(auth, db, params)      create account + profile, roll back on failure
signIn(auth, db, email, pw)   sign in, return the profile
repairProfile(auth, db, p)    finish an account whose profile write failed
getProfile(db, uid)
signOutUser(auth)
```

**Why rollback.** Creating an account is two writes — the Auth record and
the `users` document — and Firebase cannot make them atomic on the Spark
plan. If the second fails we delete the first, because an Auth account with
no profile is worse than no account: the person can sign in and the app has
nothing to show. If the rollback itself fails, `signIn` throws
`profile-missing` and the app calls `repairProfile`.

**Why validation is duplicated.** `validate()` mirrors `firestore.rules`.
The rules are the real gate — they run whatever client is talking. The local
checks exist so the user sees "Phone must be in international format"
instead of "permission denied".

Run with the emulator up:

```bash
npx jest tests/accounts.test.js --runInBand
```

Step 4 is the first point where the mobile app stores something real.

---

## Indexes

Two, because two queries need them. Firestore errors on a missing composite
index and prints the exact index to add, so there's no reason to guess ahead
of a real query — speculative indexes just cost write throughput on every
document you touch.

---

## Rules: two invariants

**Clients never write clinical data.** `events`, `recordings`, `alerts` and
`vitalsDaily` are server-written. A client that can write an event can
fabricate a cardiac emergency, or hide a real one.

**The care relationship is server-written.** `caregiverIds` is denormalised
onto the patient document so rules can check membership without a query, and
only `linkCode_redeem` and `link_revoke` may touch it.

**Being linked is the permission.** There are no per-feature toggles. A
caregiver the patient has linked can see their data and manage their
medication alarms — setting a parent's reminders is the ordinary case, not
an elevated one. `permissions` was removed from `careLinks` because no rule
consulted it: a field that looks like a control but isn't is worse than no
field at all.

**No duplicate medicines.** A `medAlarms` document ID is
`{patientUid}_{medKey}`, where `medKey` is the medicine name normalised —
lowercased, spaces stripped, Arabic letter variants folded. So "Aspirin 100
mg" added by the patient and "aspirin 100mg" added by the caregiver resolve
to the same ID, and the second write is rejected instead of producing two
reminders for one dose. This is enforced by the database, not by a warning
message, so there is no timing window where both writes succeed.

**Revocation.** Removing the caregiver's uid from `caregiverIds` is what
ends access — every rule reads that list, so the effect is immediate across
profile, device, alarms and recordings. The `careLink` document stays,
marked `revoked`, because who had access and when is worth keeping.

**One device per patient.** The `devices` document ID *is* the patient's
uid, so pairing a new device overwrites the old one. Two active devices for
one patient are impossible by construction rather than by a check somebody
has to remember to write.

The test suite covers both — every rule has an allow case and a deny case. A
rule with only a positive test proves nothing; a wide-open rule passes it too.

---

## Why `auditLog` this early

Not for compliance. For debugging.

When an alert doesn't reach a caregiver, you need to know whether the event
fired, whether the SMS was queued, whether the provider accepted it, and
whether the call connected. Reconstructing that from logs after the fact is
miserable. Writing it down as it happens is cheap.

It becomes a compliance artifact later. Right now it's a debugging tool.

---

## Decisions, and when to revisit them

| Decision | Why | Revisit |
|---|---|---|
| Direct Firestore + callable functions, no REST | Caregiver dashboard runs on realtime listeners; REST would force polling | — |
| `me-central1` (Doha) for dev | Nearest low-latency region, self-serve, test data only | before real patients |
| No production project yet | Firestore location is permanent | before real patients |
| Email + password auth | Phone OTP means paying for a second SMS route before the Unifonic sender ID is live | once Unifonic is set up |
| Cloud inference | Fine while data is synthetic; on real patients a network gap becomes a monitoring gap | before real patients |
| Firebase | Fastest path for two people; exit cost is real and accepted | if KSA residency becomes hard |
