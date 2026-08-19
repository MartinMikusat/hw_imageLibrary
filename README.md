# hw_gallery

`hw_gallery` is a personal, source-aware image gallery for Apple Silicon macOS.
A Chromium extension selects visible images from web pages and sends the
original bytes and provenance to a native Odin application for durable local
storage, CLI access, and visual browsing. The same application is expanding to
index arbitrary folders of images in place, recognize and permanently tag image
content, and search and filter across every source. The exact Version 1 disk and
native-message contracts are in
[`docs/storage-format.md`](docs/storage-format.md); the transformation plan is in
[`../TODO_hw_imageLibrary.md`](../TODO_hw_imageLibrary.md).

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**
- **deepseek-v4-flash**
- **Grok 4.6**

## Status

The Version 1 capture path, authoritative storage model, background service,
structured CLI, and native Odin viewer are implemented. Automated verification
covers the contracts, deterministic merge and purge rules, storage and SQLite
rebuilds, macOS file bridges, native-host ingestion, hidden launch policy, and
rendered Chromium fixtures. Signed iCloud-container testing and live packaged
extension runs in both Chrome and Brave remain before release; see
[the verification record](docs/verification.md).

The folder-source backend is implemented: user-selected folders are registered
with security-scoped bookmarks, scanned in place (recursive or top-level), and
reconciled against the machine-local index, with full-text search over paths
and tag columns through the `folder add|add-choose|list|scan|tag|embed|similar|duplicates|remove|images|search`
CLI family. Recognition runs Apple Vision's classify, animal, and object
requests over every untagged image behind a pluggable `Tag_Provider` seam and
writes the resulting keywords into the index's `generated_tags` column (auto-
started after a scan, or per-folder via TAG) and embeds those keywords into
the image files as IPTC/XMP. The viewer exposes these sources
through a source bar (library and folder chips, add/scan/tag/remove,
duplicates, search field), folder grids with on-demand thumbnails, and a
detail panel with open-in-Finder, copy-to-clipboard, copy-to-folder, export,
and find-similar actions. The
viewer chrome matches `hw_calendar`: a 38-point header, Iconoir close /
minimize / zoom controls, a settings gear after those controls, header drag,
double-click zoom to the screen visible frame, and 6-point edge resize. Open
Settings from the gear or `Command-,`. The
reusable [`hw_odin_imageSimilarity`](../hw_odin_imageSimilarity/README.md)
library v1 is implemented with an Apple Vision feature-print embedder, a
pure-Odin perceptual-hash prefilter, and a SIMD brute-force similarity index;
its work queue lives in its own `TODO.md`.

Remaining: the remote recognition provider and Version 1 release verification
(live Chrome/Brave packaged-extension runs, signed iCloud container, two-Mac
convergence). See the consolidated plan for the full scope and gates.

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
off-screen images, full-page capture, and generated image descriptions remain
outside the Version 1 DOM capture. The initial record keeps page-provided
alt text, an associated figure caption, and an optional user note as distinct
values.

## Architecture

The repository contains two product components:

```text
hw_gallery/
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

## Interface layout

The viewer is a single Metal window. Named rectangles come from one geometry
path used for layout, drawing, and hit testing:

| Region | Rectangle procedure | Role |
| --- | --- | --- |
| Header | `hal_ui.header_rect` / `viewer_add_header` | 38-point title bar, Iconoir window controls, settings gear, drag and double-click zoom |
| Status | `VIEWER_STATUS_HEIGHT` (26) / `viewer_add_status` | Bottom strip for scan, recognition, and keyword write-back progress |
| Source bar | `viewer_folder_bar_rect` | Library and folder chips, ADD FOLDER, SCAN/TAG/REMOVE, search field |
| Grid | `viewer_grid_layout` | Thumbnail tiles; clips incomplete rows and scrolls vertically (`grid_scroll`) |
| Detail | `viewer_detail_rect` | Metadata and actions for the selected capture or folder image |
| Modals | `viewer_add_confirmation_modal` | Type-to-confirm destructive library actions |

Folder keyword write-back is not type-to-confirm: embedding IPTC/XMP keywords
in user-owned folder files is the chosen persistence path. Library capture
objects stay byte-immutable; they are never rewritten. Capture ingest still
stores the object; if it is visually similar to indexed folder images or other
library captures, a keep-both / review modal appears. Escape and keep-both
dismiss the alert. Review lists the folder images that matched the capture
under the same near-duplicate gate. Near-duplicates are never deleted
automatically.

Find similar filters the grid through `folder.similar`. The DUPLICATES chip
loads `folder.duplicates` groups into the same grid using the search result
list. Similarity indexing runs on the idle timer after scan (`folder.embed`).

Overflow: the grid clips tiles to its rectangle and scrolls. The source bar
does not wrap; chips that exceed the bar width are clipped. The detail panel
clips its fields.

Demand-driven rendering is the default. Scan and recognition batches run on
the idle frame timer; they do not keep Metal encoding while idle.

## Development

The single-instance dev watcher builds the debug app, relaunches it when
sources change, and shuts it down on Ctrl-C. A second invocation in any
terminal reports the running watcher instead of starting another:

```sh
./dev.sh
```

This watcher is the required default for every native app in the workspace;
see the Development Watcher contract in
[`../notes/native-application-contracts.md`](../notes/native-application-contracts.md).

The watcher also stops the app's background `--service` process on each
relaunch, so a rebuilt app never talks to a stale service, and archives crash
reports plus memory diagnostics under `build/crashes/` and
`build/memory-diagnostics/`. Launch in a specific build mode with
`./dev.sh trace`, `./dev.sh asan`, or `./dev.sh release`; memory-instrumented
launches via `./dev-memory.sh <scribble|guard-edges|zombies|guard-malloc>` and
a one-shot LLDB session via `./dev-lldb.sh`.

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
`build/hw_gallery.app/Contents/Resources/extension` as an unpacked extension
in Chrome or Brave:

```sh
./scripts/install-native-host.sh
```

Sibling Odin repositories are pinned by URL and tested commit in
[`dependencies.lock`](dependencies.lock); `./build.sh` rejects a mismatched
checkout (the strict clean-tree check applies to release builds). Regenerate
the lock after validating a new commit with
`./scripts/dependencies.sh update`.

The debug build requires an explicitly selected local root. A release build
requires `HW_GALLERY_CODESIGN_IDENTITY`; its entitlements enable the
app-owned iCloud Documents container.

Bundled icons:

- Iconoir Regular 7.11.1 at commit `3497016dcb93122b5a64a2df1221598a14ecf4f3`
- Source: <https://github.com/iconoir-icons/iconoir/tree/v7.11.1/icons/regular>
- Archive SHA-256: `6a22cb1c3eaa49485a5f40cf276c0d063af0792d7bfed8b4bec4fbfc8866e5b2`
- Bundled file checksums: [dependencies.lock](dependencies.lock)
- License: [MIT](resources/icons/iconoir/LICENSE)

The repository currently grants no software license. Public visibility permits
inspection but does not grant reuse or redistribution rights.
