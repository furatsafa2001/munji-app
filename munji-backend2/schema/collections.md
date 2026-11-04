# Collections — field specification

Firestore does not enforce a schema. This file plus `firestore.rules` **are**
the schema: this defines the shape, the rules enforce it. If they drift apart,
the rules win, because they are what actually runs.

**Writer** column:
- `client` — the app writes it directly
- `server` — Admin SDK only; rules deny all client writes
- `immutable` — set once at creation, never changed

---

## `users/{uid}`

Document ID is the Firebase Auth UID. One document per person, patient or
caregiver.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `role` | string | yes | client, immutable | `patient` \| `caregiver` |
| `fullName` | string | yes | client | |
| `phone` | string | yes | client | E.164, `+9665…`. Required from day one — alerts depend on it |
| `email` | string | yes | client | |
| `locale` | string | yes | client | `ar` \| `en` |
| `fcmTokens` | array\<string\> | yes | client | may be empty |
| `createdAt` | timestamp | yes | client, immutable | |
| `disabled` | bool | yes | server | client may create it only as `false`; rules reject any change |
| `devicePaired` | bool | no | client | set once the patient finishes pairing; skips the pairing screen |
| `patient` | map | if patient | mixed | see below |
| `caregiver` | map | if caregiver | mixed | see below |

### `patient` map

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `dob` | timestamp | no | client | |
| `sex` | string | no | client | |
| `knownConditions` | array\<string\> | no | client | |
| `emergencyNumber` | string | yes | client | `911`. A field, not a constant, so it isn't hardcoded later |
| `caregiverIds` | array\<string\> | yes | **server** | denormalised link — the whole rules model rests on this |

### `caregiver` map

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientIds` | array\<string\> | yes | **server** | mirror of `caregiverIds` |

**Why `caregiverIds` is server-only:** it is the sole thing rules consult to
decide whether a caregiver may read a patient's data. If a client could write
it, any account could grant itself access to any patient by editing its own
document.

---

## `linkCodes/{code}`

**Document ID is the six-digit code itself.** No client read, no client write,
at any privilege level.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientId` | string | yes | server | |
| `createdAt` | timestamp | yes | server | |
| `expiresAt` | timestamp | yes | server | 10 minutes, as in the design |
| `used` | bool | yes | server | single use; also set when a newer code replaces it |
| `attempts` | number | yes | server | kept for compatibility, not used for limiting |

Six digits is one million combinations. If a client could query this
collection the code space would be exhaustible in minutes, so redemption
happens server-side (`linkCodeRedeem`), never by reading the document.

Limiting is per caregiver, in `linkAttempts/{caregiverId}`
(`windowStart`, `count`): five wrong codes in 15 minutes and that account
cannot redeem until the window passes. A counter on the code itself would
never trip, because someone guessing tries a different code each time.
A patient has at most one live code; asking for a new one retires the old.

---

## `careLinks/{patientId}_{caregiverId}`

**Composite document ID, deliberately.** Rules can then fetch the link by ID
to check permissions, instead of running a query — rules cannot query cheaply.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientId` | string | yes | server, immutable | |
| `caregiverId` | string | yes | server, immutable | |
| `patientName` | string | yes | server | snapshot at link time, so the caregiver's list needs no extra read |
| `caregiverName` | string | yes | server | snapshot; patients cannot read caregiver profiles |
| `relation` | string? | no | server | `son` `daughter` `spouse` `sibling` `parent` `friend` `other`, chosen by the caregiver |
| `status` | string | yes | server | `pending` \| `active` \| `revoked` |
| `priority` | number | yes | server | 1 = primary, 2 = backup |

| `createdAt` | timestamp | yes | server | |
| `activatedAt` | timestamp | no | server | |
| `revokedAt` | timestamp? | no | server | |
| `revokedBy` | string | no | server | uid of whoever ended it |

There is no `permissions` map. Being linked is the permission: a linked
caregiver sees the patient's data and manages their alarms. Per-feature
toggles were removed because no rule consulted them, and a field that looks
like a control but isn't is worse than no field at all.

Revoking sets `status: 'revoked'` and removes the uid from `caregiverIds`.
The document is kept, never deleted — you want the history of who had access.

---

## Patient data: `users/{patientId}/...`

Everything about one patient lives under their user document, so access and
account deletion work from one path. Full design and reasoning: the
*MUNJI Storage Design* doc. Times are UTC; hour and day keys are Asia/Riyadh.

### `device/current`

One document per patient. A new pairing overwrites it. Written by the app
every 5 seconds while connected (carrying `hr`), at once on
anything the caregiver should know (link up or down, electrode off,
charging, stabilizing, battery low, a reading appearing or disappearing,
heart rate changing by 10 bpm or more), never more than once a second, and
a 5-minute heartbeat while not connected.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `status` | string | yes | client | `paired` \| `unpaired` |
| `serial` | string | yes | client | from `0x2A25`, e.g. `MUNJI-3C84270B4F2A` |
| `model` | string | yes | client | `munji-v1` |
| `firmware` | string? | no | client | null until the firmware exposes `0x2A26` |
| `pairedAt` | timestamp | yes | client | `request.time`; changes only with `serial` |
| `connected` | bool | yes | client | phone connected to the patch now |
| `charging` | bool? | no | client | on the charger; the patch does not measure while charging |
| `worn` | bool? | no | client | from the electrode status; null when it is more than 5 minutes old |
| `stabilizing` | bool? | no | client | electrodes on, patch holding the ECG back for 30 s while contact settles |
| `battery` | int | yes | client | 0–100 |
| `hr` | number? | no | client | latest BPM, 20–300; null when no beat in the last 5 s |
| `rmssd` | number? | no | client | no longer written (v3.7). HRV is shown from the latest recording, not live. Kept in the rules so older app builds still work |
| `lastSeenAt` | timestamp | yes | client | must equal `request.time` |

Caregiver app: `lastSeenAt` older than 15 minutes means "no recent data".
`hr` is only current when `connected` is true and `lastSeenAt` is under 20
seconds old (several missed 5-second writes); otherwise the reading is
shown as not current.

### `recordings/{recordingId}`

Created by `onRecordingUploaded` only after the `.ecg` file passes
validation. File: `patients/{patientId}/recordings/{recordingId}.ecg`
(format in `functions/src/ecgFormat.js`).

| Field | Type | Writer | Notes |
|---|---|---|---|
| `kind` | string | server | `manual` (30 s) \| `event` (60 s, month 3) |
| `eventId` | string? | server | event strips only |
| `startedAt` | timestamp | server | from the file header |
| `durationSec` | number | server | 30 \| 60 |
| `sampleRateHz` | number | server | 250 |
| `uvPerLsb` | number | server | from the file header |
| `storagePath` | string | server | |
| `avgHr` | number? | server | from upload metadata |
| `rmssd` | number? | server | HRV over the recording, ms, from upload metadata. Premature beats are left out; null when too few clean beats or too many irregular ones. This is the only HRV the app shows (home screens and reports) |
| `deviceSerial`, `firmware` | string? | server | traceability |
| `resultCode`, `resultTier`, `modelVersion` | string? | server | null until inference |
| `saved` | bool | **patient** | the only field a client may change |
| `createdAt` | timestamp | server | |

Unsaved recordings are deleted 90 days after `createdAt` by
`purgeRecordingsDaily`. Deleting the file deletes the document.

### `events/{eventId}`

Server only. Structure ready, used in month 3: `type`, `tier`
(`warn`/`crit`/`tech`), `source` (`rule`/`model`), `startedAt`, `endedAt`,
`hrAtEvent`, `modelVersion`, `recordingId`, `outcome { alertSentAt, ackAt,
ackBy, escalatedAt }`.

### `hourly/{yyyyMMddHH}`

Written by the app once per finished hour, create only. TTL on `expireAt`.

| Field | Type | Notes |
|---|---|---|
| `hourStart` | timestamp | on the hour; id must be its Riyadh hour |
| `dayKey` | string | first 8 characters of the id |
| `hrAvg`, `hrMin`, `hrMax` | number? | 20–300, null when not monitored. `hrAvg` over every beat; `hrMin` and `hrMax` from one-minute averages (minutes with at least 10 beats), so one premature beat is not the hour's maximum |
| `hrvAvg` | number? | no longer written (v3.7): HRV comes from the recordings |
| `qualityPct` | number? | null until the quality gate runs on the phone |
| `monitoredMin`, `leadOffMin`, `chargingMin`, `disconnectedMin` | int | sum ≤ 60. `leadOffMin` includes the 30 s stabilizing period after the electrodes go on |
| `expireAt` | timestamp | exactly `hourStart` + 90 days |
| `createdAt` | timestamp | `request.time` |

### `daily/{yyyyMMdd}`

Server only. `onHourlyCreated` rebuilds the vitals from all of the day's
hours; recording triggers keep `recordingsCount`. Fields: `dayKey`, `date`,
the hourly fields aggregated (HR weighted by `monitoredMin`),
`hoursReported`, `recordingsCount`, `updatedAt`, `expireAt` (+2 years, TTL).

---

## `linkAttempts/{caregiverId}`

Failed redemption counter. Server only; deleted on a successful link.

---

## `auditLog/{logId}`

Append-only. No client read, no client write.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `actorId` | string | yes | server | uid, or `system` |
| `actorRole` | string | yes | server | `patient` \| `caregiver` \| `system` |
| `action` | string | yes | server | see list below |
| `targetType` | string | yes | server | collection name |
| `targetId` | string | yes | server | |
| `at` | timestamp | yes | server | |
| `meta` | map | no | server | free-form context |

Actions: `link_created`, `link_revoked`, `device_paired`, `recording_created`,
`recording_read`, `alert_sent`, `view_patient`.

---

## Retired

Top-level `devices`, `events`, `recordings`, `vitalsDaily` and `alerts` are
gone. The default deny rule covers them.
