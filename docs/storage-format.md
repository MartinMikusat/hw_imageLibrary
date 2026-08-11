# Storage and wire contracts

This document fixes the Version 1 disk and local-index formats. Readers must
reject a document whose `schema_version`, identifier syntax, bounds, path
identity, or required fields do not match this contract. Unknown schema versions
remain on disk and do not enter the materialized view.

## Authoritative root

```text
hw_imageLibrary/
  library.json
  objects/sha256/ab/abcdef...64-lowercase-hex
  join-requests/<device-uuid>.json
  records/<device-uuid>/<20-digit-sequence>-<capture-uuid>.json
  events/<device-uuid>/<20-digit-sequence>-<event-uuid>.json
```

Every UUID uses lowercase canonical `8-4-4-4-12` text. Every SHA-256 digest uses
64 lowercase hexadecimal characters. JSON files are UTF-8 and at most 256 KiB.
Object files are at most 512 MiB. The path device, sequence, identifier, and
digest must equal the corresponding document fields.

`library.json` is an immutable Version 1 genesis document:

```json
{
  "schema_version": 1,
  "library_id": "<uuid>",
  "created_at_unix_ms": 0,
  "recovery_interval_seconds": 2592000,
  "initial_device_id": "<uuid>"
}
```

The initial device starts as the sole authorized writer. A later identity may
publish one immutable join request but may write no operation until an authorized
device publishes a `device_join` event for it. Pending join requests are not
active devices and do not block purge.

## Operation streams

Capture records and events consume one monotonic sequence per author device.
Sequence 1 is the first operation. A receiver materializes only the contiguous
prefix; a missing sequence keeps later operations pending, while two different
documents at one sequence fault that stream at the collision. Byte-identical
duplicate discovery is idempotent. A reused capture or event UUID faults every
document with that identifier instead of choosing one by arrival time.

The local service allocates the next sequence and publishes one operation at a
time. It never edits a published file. Cross-device causality is represented by
named predecessor revisions, frontiers, and proof event identifiers rather than
wall-clock order.

## Capture records

`Library_Capture_Record` in `src/library_contract.odin` is the executable schema.
It stores library, capture, author, and sequence identity; capture time; object
digest; verified media type, byte count, and pixel dimensions; page URL and
title; exact `currentSrc`; separate alt, figure-caption, and initial-note fields;
and the selected rectangle and viewport. HTTP and HTTPS are the only source URL
schemes. Version 1 accepts AVIF, GIF, JPEG, PNG, and WebP objects.

`reinstates_purge_event_id` is empty for an ordinary capture. A capture of bytes
whose digest has already been purged names the latest accepted purge event and
publishes the fully verified object before its record. This creates a new live
reference without rewriting or erasing the historical purge proof.

## Events

`Library_Event` in `src/library_contract.odin` is the executable event envelope.
Every unused variant field must be empty. UUID arrays and frontier entries are
strictly sorted and duplicate-free.

- `device_join` authorizes `target_device_id`.
- `device_ack` records the complete validated operation frontier and includes
  its own sequence.
- `device_retire` rejects target operations above `target_device_sequence` and
  removes that identity from the active set.
- `note_set` names one capture and one or more predecessor revision UUIDs. Two
  children of one predecessor remain separate visible heads until a later event
  names both heads.
- `capture_delete` creates a tombstone. `capture_restore` names the exact
  tombstone it reverses; any other effective tombstone still hides the capture.
- `purge_propose`, `purge_ack`, `purge_reject`, and `object_purge` execute the
  physical-purge barrier described below.
- `orphan_candidate` starts the retention interval for a verified object that has
  no capture record. After the recovery interval expires, every active device
  must answer it with a targeted `purge_ack` after a complete reference scan,
  which activates the same write barrier as referenced-object purge.
  `orphan_purge` names those acknowledgements and authorizes removal only while
  no capture record references the digest.

## Physical-purge barrier

A service may propose purge only after every reference has an effective
tombstone, 30 days have elapsed, and every active device has acknowledged the
capture and tombstone sequences. `purge_propose` freezes one digest, the required
tombstones, and the active device set.

Each active device rescans its contiguous operation set. It publishes
`purge_reject` if it finds a live or restored reference. Otherwise it publishes
`purge_ack` and its complete frontier, then its local service blocks capture,
join, note, delete, and restore operations until the proposal resolves. Device
retirement and refreshed purge proof operations remain available so a lost
device cannot deadlock maintenance.

`object_purge` is valid only when it names the proposal, exact tombstone set,
exact active set, one accepted purge acknowledgement from every active device,
and the proof frontier. Any rejection prevents the commit. Any active device may
publish the commit after collecting the proof. The commit releases the barrier
and authorizes coordinated idempotent removal of the object path. This two-phase
barrier prevents a device from publishing a concurrent reference after its
acknowledgement and before physical deletion.

## Publication

Native-message chunks assemble in machine-local Application Support. The service
hashes and decodes the completed file, validates byte count, media type, and
dimensions, then copies it to an ignored unique temporary sibling in the final
object directory. It flushes and revalidates that sibling before a coordinated
exclusive rename installs the digest path. It publishes the capture record last
through the same temporary-sibling and exclusive-rename procedure. Temporary
siblings never enter discovery and interrupted ones are cleaned after their
retention window.

## Machine-local SQLite index

The service is the sole writer of `index-v1.sqlite3` in Application Support. WAL
and every sidecar stay local. The database contains imported document identity
and validation status, device prefixes and cutoffs, materialized captures and
note heads, effective tombstones, object availability and integrity, purge
state, and an FTS5 table over page title, page URL, alt text, caption, and note.
Each rebuild validates the authoritative documents and objects, materializes a
complete snapshot, and replaces the query tables in one SQLite transaction.
Deleting the database and replaying a complete root must reproduce the same rows
and query order.

## Native messaging

`src/native_wire.odin`, `extension/src/wire-contract.ts`, and
`contracts/native-message-fixtures.json` define one wire version. The extension
opens one `connectNative` port, sends `capture_begin`, then stop-and-wait
`capture_chunk` messages containing at most 192 KiB raw bytes, and finally sends
`capture_commit` with the observed byte count. The service computes SHA-256 and
image properties while streaming; the extension never buffers an entire object
to calculate a second digest. A cancellation or failed sequence removes local
staging and creates no record.
