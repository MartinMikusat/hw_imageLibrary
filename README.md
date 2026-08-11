# hw_imageLibrary

`hw_imageLibrary` is a personal, source-aware image library for Apple Silicon
macOS. A Chromium extension selects visible images from web pages and sends the
original bytes and provenance to a native Odin application for durable local
storage, CLI access, and visual browsing. The exact Version 1 disk and
native-message contracts are in
[`docs/storage-format.md`](docs/storage-format.md).

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**

## Status

The Version 1 capture path, authoritative storage model, background service,
structured CLI, and native Odin viewer are implemented. Automated verification
covers the contracts, deterministic merge and purge rules, storage and SQLite
rebuilds, macOS file bridges, native-host ingestion, hidden launch policy, and
rendered Chromium fixtures. Signed iCloud-container testing and live packaged
extension runs in both Chrome and Brave remain before release; see
[the verification record](docs/verification.md).

## Version 1 product boundary

Version 1 uses the rendered DOM rather than image recognition. It captures
loaded `<img>` elements, including images selected by `<picture>`, when they are
visible in the current viewport and expose an HTTP or HTTPS `currentSrc`.

The extension freezes the visible tab into a screenshot preview, draws boxes
from the corresponding DOM rectangles, and binds the user's selection to an
immutable candidate record. It retrieves the exact `currentSrc` resource and
fails visibly when those bytes cannot be obtained. It does not silently replace
the selected resource with a screenshot crop.

CSS backgrounds, canvases, SVG artwork, video frames, child-frame images,
off-screen images, full-page capture, image recognition, and generated image
descriptions remain outside Version 1. The initial record keeps page-provided
alt text, an associated figure caption, and an optional user note as distinct
values.

## Architecture

The repository contains two product components:

```text
hw_imageLibrary/
  src/                  Native Odin application, storage, viewer, and CLI
  extension/            Manifest V3 Chromium extension written in TypeScript
  docs/v1-plan.md       Version 1 architecture and implementation sequence
  TODO.md               Project-local work
```

The extension reads transient browser state and sends one bounded capture to an
Odin native-messaging host. The Odin application owns the authoritative library,
replaceable local indexes and caches, queries, exports, and the native interface.
A web page never receives library access or a native command channel.

All authoritative files live under one user-selected library root. The
first launch prefers an app-owned iCloud ubiquity container and offers a local
folder when iCloud is unavailable. Original bytes use immutable SHA-256-derived
object paths. Immutable capture records and subsequent event files preserve the
metadata required to rebuild a machine-local SQLite query index. Thumbnail files
are also replaceable machine-local cache entries.

The root starts with an immutable `library.json` genesis record. Capture records
and events share one monotonic sequence per device, so acknowledgement frontiers
cover every authoritative operation rather than edits alone. Incoming transfer
staging stays in machine-local Application Support; only a verified temporary
sibling enters the root immediately before its coordinated atomic rename.

Multiple Macs may use the same synchronized root concurrently. Each installation
publishes uniquely identified immutable records and events, while every Mac
imports the synchronized set into its own SQLite index without depending on file
arrival order. Independent captures merge directly. Concurrent edits to one note
remain visible as a conflict, and deletion tombstones take precedence without
removing the underlying immutable history.

The initial Mac is a member in the genesis record. A later Mac requests entry and
an existing active Mac authorizes it with an immutable join event before it may
write. This prevents a previously unseen writer from racing a physical purge.

Deletion first hides a capture through an immutable tombstone. Physical object
purge occurs only after the fixed 30-day recovery interval expires, every active
device has acknowledged the tombstones for every reference, and an immutable
purge event is durable. A lost device can be explicitly retired with a sequence
cutoff; if it returns, it must attach under a new identity before publishing more
events.

The native host verifies the complete byte count and digest before it installs
an object and atomically publishes the corresponding capture record. The native
application calls AppKit, Foundation, and iCloud document APIs directly from
Odin through the Objective-C runtime pattern used by `hw_calendar` and
`hw_videoClips`; it does not add a separate Swift or Objective-C helper layer.
The design does not require a cross-device lock service or CloudKit database.

## Development

Build the debug app without launching it:

```sh
./build.sh debug
```

Run the Odin, TypeScript, launch-policy, and native-host integration tests:

```sh
./test.sh
```

Run the rendered candidate fixtures in an installed Chrome or the local Chromium
headless shell with normal and Retina display scales:

```sh
npm run test:browser --prefix extension
```

After `./build.sh debug`, register the native host and load
`build/hw_imageLibrary.app/Contents/Resources/extension` as an unpacked extension
in Chrome or Brave:

```sh
./scripts/install-native-host.sh
```

The debug build requires an explicitly selected local root. A release build
requires `HW_IMAGE_LIBRARY_CODESIGN_IDENTITY`; its entitlements enable the
app-owned iCloud Documents container.

The repository currently grants no software license. Public visibility permits
inspection but does not grant reuse or redistribution rights.
