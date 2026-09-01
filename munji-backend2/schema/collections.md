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
| `disabled` | bool | yes | server | |
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
| `activeDeviceId` | string | no | client | |

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
| `expiresAt` | timestamp | yes | server | 15 minutes |
| `used` | bool | yes | server | single use |
| `attempts` | number | yes | server | lock at 5 |

Six digits is one million combinations. If a client could query this
collection the code space would be exhaustible in minutes, so redemption
happens server-side with attempt limits — never by reading the document.

---

## `careLinks/{patientId}_{caregiverId}`

**Composite document ID, deliberately.** Rules can then fetch the link by ID
to check permissions, instead of running a query — rules cannot query cheaply.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientId` | string | yes | server, immutable | |
| `caregiverId` | string | yes | server, immutable | |
| `relation` | string | no | server | `daughter`, `son`, `spouse`, … |
| `status` | string | yes | server | `pending` \| `active` \| `revoked` |
| `priority` | number | yes | server | 1 = primary, 2 = backup |

| `createdAt` | timestamp | yes | server | |
| `activatedAt` | timestamp | no | server | |
| `revokedAt` | timestamp | no | server | |

There is no `permissions` map. Being linked is the permission: a linked
caregiver sees the patient's data and manages their alarms. Per-feature
toggles were removed because no rule consulted them, and a field that looks
like a control but isn't is worse than no field at all.

Revoking sets `status: 'revoked'` and removes the uid from `caregiverIds`.
The document is kept, never deleted — you want the history of who had access.

---

## `devices/{patientUid}`

**The document ID is the patient's uid** — one device per patient, enforced
by the database rather than by application code. Pairing a new device
overwrites the old document, so two active devices for one patient cannot
exist and no cleanup step can be forgotten.

The only collection besides `users` that the client writes, because the
phone is what talks to the device over BLE.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientId` | string | yes | client, immutable | must equal the document ID |
| `serial` | string | yes | client | changes when the patient pairs a different unit |
| `model` | string | yes | client | `munji-v1` |
| `firmware` | string | no | client | |
| `pairedAt` | timestamp | yes | client | |
| `status` | string | yes | client | `paired` \| `unpaired` |
| `battery` | number | no | client | 0–100 |
| `signalQuality` | string | no | client | `good` \| `weak` \| `leadoff` |
| `lastSeenAt` | timestamp | no | client | |

---

## `recordings/{recordingId}`

Metadata for a one-time ECG capture. The waveform itself lives in Cloud
Storage; this holds the pointer.

| Field | Type | Required | Writer | Notes |
|---|---|---|---|---|
| `patientId` | string | yes | server | |
| `startedAt` | timestamp | yes | server | |
| `durationSec` | number | yes | server | 30 \| 60 \| 180 |
| `avgHr` | number | no | server | |
| `resultClass` | string | no | server | filled once inference exists |
| `resultTier` | string | no | server | `ok` \| `warn` \| `crit` \| `tech` |
| `storagePath` | string | yes | server | `recordings/{patientId}/{id}.json.gz` |
| `pdfPath` | string | no | server | |
| `createdBy` | string | yes | server | uid |
| `modelVersion` | string | no | server | traceability — which model produced the result |

Written by the storage finalize trigger, **after** the upload completes. The
client never creates the document, so a record can never exist without its
data.

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

## Not built yet

`events`, `medAlarms`, `vitalsDaily`, `alerts` — schema is in
`MUNJI_Architecture.md`. Their deny-rules already ship, so none of them is
world-writable the day it appears.
