# Repository Guidelines

Read `README.md`, `docs/v1-plan.md`, and `TODO.md` before planning or changing
the product.

## Product boundary

- Keep the Odin application and Chromium extension in this repository.
- Treat the Odin application as the owner of durable state. The extension is a
  transient capture adapter and must not maintain a second authoritative
  library.
- Keep every authoritative library file under one user-selected library root.
  Prefer the application's iCloud ubiquity container on first launch and offer
  an explicit local-folder fallback when iCloud is unavailable.
- Treat immutable object, capture-record, and event files as authoritative.
  Keep SQLite and thumbnails as machine-local, replaceable indexes and caches
  that can be rebuilt from the library root.
- Support concurrent use of one synchronized library root from multiple Macs.
  Do not add a writer-owner marker, cross-device lock file, mutable shared
  manifest, or CloudKit lease. Publish uniquely named immutable records and
  events, accept them in any arrival order, and make local index import
  idempotent.
- Sequence capture records and events in one per-device operation stream. Admit a
  later device only after an active device publishes its join authorization, so
  acknowledgement frontiers and physical-purge proofs cannot omit an unseen
  writer.
- Support eventual physical purge through immutable device-membership,
  acknowledgement-frontier, tombstone, device-retirement, and purge events.
  Never remove an authoritative object until every referencing capture is
  tombstoned, the recovery interval has elapsed, every active device has
  acknowledged the required frontier, and a purge event has been published.
- Keep Version 1 DOM-driven. Do not add image detection, generated descriptions,
  CSS-background capture, canvas capture, full-page stitching, or source-URL
  rewriting without an approved plan update.
- Save the exact selected `currentSrc` or report failure. Do not silently replace
  it with a screenshot crop or guessed higher-resolution URL.
- Keep page-provided alt text, captions, user notes, and future generated
  descriptions as separate fields with explicit provenance.

## Implementation

- Put native Odin application, storage, viewer, and CLI code under `src/`.
- Put the Manifest V3 TypeScript extension under `extension/`.
- Call AppKit, Foundation, Metal, and other macOS frameworks directly from Odin
  through the Objective-C runtime conventions established by `hw_calendar` and
  `hw_videoClips`. Register delegates and protocol-conforming classes from Odin,
  and represent Objective-C blocks with the existing Odin ABI pattern. Do not
  add Swift, Objective-C, Objective-C++, or C application logic or helper
  targets for macOS integration without an approved plan update.
- Define every extension-to-native message in one versioned wire contract and
  enforce the same bounds and sequencing rules on both sides.
- Write incoming image data to machine-local staging, verify its byte count and
  SHA-256 digest, copy it to a verified temporary sibling in the final directory,
  install the immutable object by coordinated atomic rename, atomically publish its immutable
  capture record, and then update the replaceable local SQLite index.
- Treat synchronized files as untrusted until their schema, bounds, identifiers,
  referenced object availability, byte count, and digest have been validated.
  Keep incomplete records pending rather than exposing valid-looking captures.
- Treat device retirement as destructive coordination. Require explicit user
  confirmation, record the retired device's accepted sequence cutoff, reject
  later events from that identity, and require a returning device to attach with
  a new identity before it can write.
- Make the CLI and native viewer consume the same storage procedures.
- Add only the code required by the current TODO milestone.

## Documentation

- Preserve the AI-assisted development disclosure in `README.md` and append each
  exact contributing model name without removing earlier names.
- Record bundled third-party assets with their exact version, source URL,
  checksum, and bundled license location.
- Keep application-specific work in `TODO.md` and detailed Version 1 decisions in
  `docs/v1-plan.md`.
