# Version 1 Plan

The executable storage and native-message contracts are fixed in
[`storage-format.md`](storage-format.md).

## Goal

Deliver one complete DOM-driven capture path from a visible web image to one
user-selected durable library root, structured CLI access, and a native Odin
viewer. Version 1 must fail explicitly when it cannot retrieve the selected
source bytes.

## Product boundary

The extension captures the visible viewport only. It includes loaded `<img>`
elements, including the `<img>` selected by a `<picture>` element, when they
intersect the viewport and expose an HTTP or HTTPS `currentSrc`.

Version 1 excludes CSS backgrounds, canvases, inline SVG artwork, video frames,
child-frame images, off-screen images, stitched full-page screenshots, image
recognition, generated descriptions, CDN URL rewriting, unrendered `srcset`
alternatives, and inferred full-size links.

The saved record keeps page-provided alt text, a directly associated figure
caption, and an optional user note as separate fields. It saves the resource
identified by `currentSrc` or reports retrieval failure. It does not silently
substitute a screenshot crop.

## Component ownership

The Manifest V3 TypeScript extension owns transient browser operations:

- Read eligible candidates from the rendered DOM.
- Capture the visible-tab screenshot.
- Display the frozen preview and DOM-derived boxes.
- Bind an explicit selection to one immutable candidate record.
- Retrieve the selected bytes with user-granted origin access.
- Transfer one bounded capture through native messaging.

The Odin application owns durable and local operations:

- Validate the native-message sequence and payload bounds.
- Assemble and verify incoming bytes.
- Publish immutable image objects, capture records, and subsequent events under
  the selected authoritative library root.
- Build a replaceable machine-local SQLite query index from those records and
  events.
- Generate replaceable machine-local thumbnail-cache entries.
- Serve the structured CLI and native image viewer.

## Capture record

The first persisted record contains:

- Capture identifier and timestamp.
- SHA-256 digest, relative object path, media type, byte count, pixel width, and
  pixel height.
- Source page URL and title.
- Selected `currentSrc` URL.
- Page-provided alt text, associated figure caption, and optional user note.
- Selected element rectangle and viewport dimensions for diagnostics.

The record does not persist a DOM selector as a durable locator. Page structure
can change immediately, while the selected URL, captured bytes, digest, and
source page remain useful provenance.

## Library location

Keep every authoritative file beneath one library root selected by the user.
On first launch, prefer an `hw_imageLibrary` directory in the application's
iCloud ubiquity container. If iCloud storage is unavailable, require the user to
choose a local directory rather than silently selecting a different durable
location. Settings exposes the same directory chooser for an explicit library
move.

Use `NSOpenPanel` for folder selection and persist the selected URL as bookmark
data. Resolve the bookmark on each launch and report stale, missing, evicted, or
inaccessible locations explicitly. Obtain the default iCloud location with
`NSFileManager`'s ubiquity-container API; do not hard-code the private on-disk
iCloud Drive path.

A physical root move is allowed only when this Mac is the sole active device.
The user must retire every other active identity first, then confirm the exact
new path. The service stops file presentation, coordinates the directory move,
validates the moved genesis, commits a new machine-local bookmark, restarts file
presentation, and rebuilds the local index. This prevents two active Macs from
continuing against different physical roots.

The authoritative root has this logical layout:

```text
hw_imageLibrary/
  library.json
  objects/sha256/<first-two-hex>/<sha256>
  join-requests/<device-id>.json
  records/<device-id>/<sequence>-<capture-id>.json
  events/<device-id>/<sequence>-<event-id>.json
```

`library.json` is an immutable genesis record containing format version, library
identifier, creation time, recovery interval, and initial device identity. The
format version is `1`, and Version 1 fixes the soft-delete recovery interval at
30 days. Object, capture-record, and event files are immutable after publication.
A note edit, deletion, or other mutable operation publishes a new uniquely
identified event instead of rewriting a synchronized record.

Capture records and events share one monotonic sequence namespace per device.
The sequence is encoded in both the document and filename, so an acknowledgement
frontier covers captures and mutations together and a receiver can detect a
missing operation even when iCloud delivers the two directories out of order.
Reusing one sequence for different files is a device-stream fault. Device
identifiers, capture and event identifiers, and explicit predecessor revisions
make event replay deterministic and allow concurrent changes to be detected
rather than silently discarded.

Store the SQLite query index and thumbnail cache in the machine-local Application
Support directory. They are not authoritative library files and never enter
iCloud synchronization. The application must be able to delete and rebuild both
from the selected root without losing a capture, provenance field, note, or
deletion.

## Multi-Mac merge

Version 1 supports concurrent use of one synchronized library root from multiple
Macs. It does not elect one writer or publish a mutable owner, lease, lock, or
shared manifest. A local process lock may serialize the GUI, CLI, and native-host
modes on one Mac, but it must not participate in the cross-device data model.

The first installation creates the initial random device identity and records it
in `library.json`. A subsequent installation creates a join request, but it does
not become a writer until an existing active device publishes a device-join event
naming that identity. This authorization handshake prevents an unseen new writer
from invalidating a purge proof. Recovery when no active device remains is an
explicit destructive operation that retires the unreachable active set before it
admits the replacement identity.

Capture and event identifiers must remain globally unique; the per-device
directory and monotonic sequence make gaps, duplicates, and replays observable
without treating wall-clock order as causality. A second Mac using the default
app-owned iCloud container discovers the same root. For a custom synchronized
root, the user selects that folder independently on each Mac because access
bookmarks are machine-local application state.

Import records and events transactionally and idempotently into each Mac's local
SQLite index. Enumerate the authoritative directories during discovery and
rebuild, but do not depend on directory enumeration order or iCloud delivery
order.
When a record arrives before its referenced object is locally available, retain
it as pending and request or await the object; expose it as a valid capture only
after validating the object byte count and SHA-256 digest. Reject malformed or
out-of-bounds synchronized files without mutating the authoritative root.

Independent captures and edits to different fields merge without conflict.
Events for one mutable field name their predecessor revision. If two note events
name the same predecessor, retain both branches and expose an unresolved note
conflict instead of choosing by timestamp. A deletion tombstone takes precedence
over concurrent or later-arriving edits in the materialized view, while the
immutable record and event history remains available for explicit recovery.

Two Macs may concurrently install the same `objects/<sha256>` path. Treat the
operation as idempotent only after every available version validates to that
digest. Resolve identical iCloud file versions to the canonical path; quarantine
the path and report corruption if any version does not match its name.

## Device lifecycle and physical purge

Each device publishes immutable acknowledgement events containing the complete
per-device sequence frontier it has validated and materialized across capture
records and events. An acknowledgement is usable only when every operation at or
below every named sequence is present and valid. Authorized device join and
retirement are also immutable events. The active device set is the genesis
identity plus authorized joined identities that have not been retired in the
materialized event graph; it is not a mutable registry file.

Deleting a capture publishes a tombstone and immediately removes that capture
from the normal materialized view. Restoring it publishes an event that names the
tombstone being reversed. Original bytes remain available throughout the
recovery interval.

An object becomes purge-eligible only when all of these conditions hold:

- Every capture record referencing its digest has an effective tombstone.
- The format-defined recovery interval has elapsed for every required tombstone.
- Every active device has acknowledged a frontier containing those tombstones.
- No accepted event at those acknowledged frontiers restores or otherwise
  references the object.

Any active device may then publish an immutable purge event containing the
object digest, required tombstone identifiers, active-device set, and the
acknowledgement frontiers used as its proof. The purge event is the durable
visibility boundary for intentional object absence. After publishing it, a
device coordinates removal of the object; other devices treat deletion as
idempotent and never report a purged object as corruption merely because the
physical deletion arrives before or after the purge event.

Physical deletion uses a two-phase barrier. The first device publishes a
`purge_propose` event after the conditions above hold. Each active device either
rejects it after finding a live reference or publishes a `purge_ack` with its
complete frontier and temporarily blocks ordinary writes. An `object_purge`
commit must name the proposal and one acknowledgement from every active device;
any rejection prevents it. This closes the acknowledgement-to-deletion race in
which a device could otherwise create a new reference after acknowledging the
tombstones. Any active device may finish a fully acknowledged proposal.

An offline active device blocks purge. The user may explicitly retire a lost or
discarded device after a destructive-action warning. Retirement records that
device's final accepted sequence cutoff; events above that cutoff are rejected.
If the device returns, it must discard unpublished stale operations, rescan the
current library, and join under a new identity before it can write. Purge never
deletes capture records, event history, or its own proof records.

## macOS interop boundary

Implement folder selection, bookmark creation and resolution, ubiquity-container
lookup, file coordination, file presentation, and download-state inspection in
Odin. Follow the existing `hw_calendar` and `hw_videoClips` interop conventions:
load `objc_msgSend`, declare precisely typed send wrappers, register delegate and
protocol-conforming classes with `objc_allocateClassPair`, `class_addMethod`, and
`class_addProtocol`, and represent callback blocks with the Objective-C block ABI
from Odin.

`NSFilePresenter` notifications feed typed storage events back into the Odin
storage layer. `NSFileCoordinator` wraps authoritative reads, atomic publication,
moves, and deletions so the application and the iCloud daemon do not mutate the
same item concurrently. These APIs form an Odin source module, not another
process or a Swift, Objective-C, Objective-C++, or C helper layer. A native helper
or non-Odin application-logic exception requires an explicit plan update.
File coordination is local filesystem coordination, not a cross-Mac lock; the
immutable merge rules above provide cross-device concurrency. No CloudKit data or
lease service participates in the Version 1 library.

The shipping artifact is one Odin executable with GUI, service, CLI, and native
host modes. The app bundle installs alternate helper names for the same binary;
the helper basename selects native-host or background-service mode before AppKit
initialization. The native host and CLI connect to the service over a
machine-local Unix-domain socket. If the service is absent, they start it without
activating the application. The service owns the local SQLite connection,
operation sequence allocator, filesystem presenter, ingestion transactions, and
cache jobs; other modes do not mutate machine-local library state directly.

Development launch policy matches `hw_videoClips`: the first scripted launch is
ordered behind the active application, a background rebuild stays hidden, and a
rebuild returns to the front only when the previous instance was frontmost.
Automated tests use service or CLI modes and never activate the GUI.

The bundle identifier is `com.halwayland.hw-imagelibrary`, its iCloud container
is `iCloud.com.halwayland.hw-imagelibrary`, and its native-messaging host name is
`com.halwayland.hw_imagelibrary`. Signed builds enable the iCloud Documents
service and ubiquity-container entitlement. Unsigned development builds require
an explicitly selected local test root and must not pretend that the default
iCloud container is available.

## Storage transaction

Address each original object by SHA-256 so identical byte streams share one
immutable object. The native host writes chunks into machine-local Application
Support staging. On `commit`, it verifies message sequence, byte count,
supported media type, and image dimensions. The Odin service calculates the
digest while streaming rather than trusting a browser-provided value. It then
copies the verified bytes to
a unique ignored temporary sibling in the final object directory, flushes and
revalidates that file, and coordinates an atomic rename to the digest path. This
keeps transfer staging out of iCloud while preserving same-volume atomic
publication at the final boundary.

After verification, coordinate and atomically install the immutable object, then
write and atomically publish its immutable capture record. A record becomes the
visibility boundary: an installed object without a record is an unreachable
orphan. An immutable orphan-candidate event establishes its recovery interval;
after that interval expires, every active device must publish a targeted purge
acknowledgement after a complete reference scan. Delaying the barrier until the
interval expires leaves time for an interrupted record publication to retry.
The acknowledgement then activates the ordinary-write barrier until an
orphan-purge commit or rejection resolves the candidate. The commit names one
acknowledgement per active device and is invalid if any capture record references
the digest. A locally published record must never reference a missing or
unverified object; a synchronized record that arrives before its object remains
pending as defined above. Update the local SQLite index only after the record is
durable. An index failure does not invalidate the authoritative capture; mark
the index unavailable and rebuild it before serving queries. A failed or
interrupted transfer removes its staging files and creates no visible record.

## Capture transaction

1. **Start.** The toolbar action assigns a capture identifier and records the
   active tab, top-level document, page URL, title, and capture time.
2. **Collect.** The content script emits an immutable record for each eligible
   `<img>` with its `currentSrc`, natural dimensions, source text, and viewport
   rectangle. It excludes unloaded, zero-area, hidden, fully transparent, and
   viewport-external elements.
3. **Freeze.** The service worker captures the visible tab. The preview derives
   horizontal and vertical bitmap scale from actual screenshot and viewport
   dimensions rather than assuming CSS pixels equal device pixels.
4. **Select.** Numbered rectangles identify candidate records. When rectangles
   overlap, the preview lists every candidate under the pointer and requires an
   explicit choice.
5. **Retrieve.** The service worker requests optional access to the image origin,
   fetches `currentSrc`, validates the response, and streams the exact response
   body. The Odin service validates the media type, decodes dimensions, and
   calculates SHA-256 while assembling the bounded transfer.
6. **Transfer.** The extension sends versioned `begin`, bounded base64 `chunk`,
   and `commit` messages over one native-messaging port. Each carries the capture
   identifier and sequence number, and each chunk waits for acknowledgement
   before the next one is sent. The final message carries the observed byte
   count; the Odin service returns the verified digest.
7. **Commit.** The native host verifies and installs the object, atomically
   publishes the immutable capture record, updates or schedules rebuilding of
   the local SQLite index, and acknowledges the stored capture identifier. The
   extension reports success only after the authoritative record is durable.

## CLI

The first structured commands are:

```text
capture list
capture show <id>
capture search <text>
capture open-source <id>
capture export <id> <path>
capture delete <id>
capture restore <id>
capture note-set <id> <text>
capture thumbnail <id> <maximum-pixels>
library devices
library ack
library device-authorize <device-id>
library device-retire <device-id>
library purge-status
library purge <digest> <exact-digest-confirmation>
library move <absolute-path> <exact-path-confirmation>
library rebuild
```

`library rebind-folder` replaces a stale or inaccessible machine-local bookmark
only after the selected root's immutable library identifier matches the existing
settings. It does not move or switch the authoritative library.

List returns captures in reverse chronological order. Search covers page title,
page URL, alt text, caption, and user note. Export copies the immutable original
without re-encoding it. Delete and restore publish immutable events. Purge reports
blocked devices and retention conditions before it publishes purge events and
removes eligible object bytes.

## Native viewer

The first Odin viewer displays a chronological thumbnail grid and one item-detail
view. The detail view displays the original image, source fields, and user note,
and can open the recorded source page. Thumbnail files form a replaceable cache;
they do not enter the provenance record.

### Native interface baseline

Use the established `hw_videoClips` and `hw_calendar` Odin interfaces as the
default native application baseline. Build the viewer with the same thin AppKit
shell, borderless custom window, Metal-backed immediate-mode rendering, and
shared `hw_odin_ui_*` packages. Reuse the shared HW Light and HW Dark palettes,
AppKit system monospaced font, measured body/label/heading typography, window
controls, settings patterns, modal backdrop and dismissal behavior, command
palette, Flash navigation, and unified control registry for pointer, keyboard,
Accessibility, and command dispatch.

Adapt that interface to the image-library workflow rather than inventing a
separate application style. The chronological thumbnail grid is the primary
library surface, and selection drives a focused detail view with the original
image, provenance fields, user note, export action, and source-page action.
Project-specific image viewing and thumbnail behavior may differ, but changes to
the shared styling or interaction conventions require an explicit plan update.
The viewer exposes soft deletion and restoration. Library settings show device
acknowledgement state, allow explicitly confirmed device retirement, report why
an object is not yet purge-eligible, and require confirmation before physical
purge.

## Verification fixtures

Keep deterministic local pages for a plain image, `<picture>` with `srcset`, a
lazy-loaded image after it becomes visible, two elements sharing one URL, a
clipped image, an `object-fit` image, overlapping images, a cross-origin image,
and a page that navigates during capture.

Keep explicit unsupported fixtures for a CSS background, canvas, inline SVG,
child-frame image, and off-screen image. These fixtures verify that Version 1
does not offer a misleading partial capture.

Verify candidate alignment in Chrome and Brave on macOS with Retina scaling and
80%, 100%, 125%, and 200% browser zoom. Verify retrieval failure, invalid media
types, redirects, interrupted transfers, missing or reordered chunks, duplicate
chunks, oversized input, digest mismatch, repeated identical bytes, database
reopen, deletion and complete rebuild of the local SQLite index, thumbnail
regeneration, and byte-identical export. Verify iCloud-unavailable fallback,
bookmark resolution, stale and inaccessible roots, coordinated publication,
incoming immutable records and events, deterministic event replay, concurrent
event detection, and orphan detection without deleting authoritative objects.

Run the same synchronized-root fixtures from two Macs or two isolated simulated
device states. Verify simultaneous distinct captures, repeated identical bytes,
record-before-object and event-before-record delivery, duplicate replay, missing
per-device sequence numbers, concurrent note edits, delete-versus-edit ordering,
identical object conflict-version resolution, corrupt object quarantine, index
convergence after every delivery permutation, and continued read-only visibility
while an object is unavailable locally.

Verify purge with multiple references to one digest, an offline active device,
out-of-order acknowledgement and tombstone delivery, restoration before purge,
simultaneous duplicate purge events, physical deletion arriving before its purge
event, explicit device retirement and cutoff enforcement, a retired device
returning with stale events, orphan retention, and rebuild after object removal.
No delivery permutation may purge a referenced object or classify an authorized
purge as corruption.

## Completion

Version 1 is complete when Chrome and Brave can select the same visible fixture
image, retrieve its exact bytes, commit its provenance through the native host,
publish the same durable record under the selected library root, and expose it
through a rebuilt local SQLite index, the CLI, and the Odin viewer. Candidate
boxes remain aligned at supported zoom levels, overlapping candidates require
explicit selection, unsupported content is not offered, and every interrupted
or invalid transfer leaves no valid-looking record. Two Macs importing the same
complete authoritative file set must converge on the same materialized captures,
deletions, and conflict states without a cross-device writer lock.
Every eligible physical purge must converge on intentional object absence, while
an offline active device, live reference, restoration, or unexpired recovery
interval must prevent that purge.
