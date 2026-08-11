# Version 1 Plan

## Goal

Deliver one complete DOM-driven capture path from a visible web image to durable
local storage, structured CLI access, and a native Odin viewer. Version 1 must
fail explicitly when it cannot retrieve the selected source bytes.

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
- Store SQLite metadata and immutable image objects.
- Generate replaceable thumbnail-cache entries.
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

## Storage transaction

Store metadata in SQLite and original bytes in an application-managed object
directory. Address each object by SHA-256 so identical byte streams share one
immutable object.

The native host writes chunks to a uniquely named temporary file. On `commit`,
it verifies message sequence, byte count, digest, supported media type, and image
dimensions. It then installs the object and commits the SQLite row. A failed or
interrupted transfer removes its temporary file and creates no visible item.

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
   fetches `currentSrc`, validates the response and media type, decodes image
   dimensions, and calculates SHA-256.
6. **Transfer.** The extension sends versioned `begin`, bounded base64 `chunk`,
   and `commit` messages. Each carries the capture identifier and sequence
   number. The final message carries the expected byte count and digest.
7. **Commit.** The native host verifies and installs the object, commits the
   metadata row, and acknowledges the stored capture identifier. The extension
   reports success only after that acknowledgement.

## CLI

The first structured commands are:

```text
capture list
capture show <id>
capture search <text>
capture open-source <id>
capture export <id> <path>
```

List returns captures in reverse chronological order. Search covers page title,
page URL, alt text, caption, and user note. Export copies the immutable original
without re-encoding it.

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
reopen, thumbnail regeneration, and byte-identical export.

## Completion

Version 1 is complete when Chrome and Brave can select the same visible fixture
image, retrieve its exact bytes, commit its provenance through the native host,
and expose the same durable record through the CLI and Odin viewer. Candidate
boxes remain aligned at supported zoom levels, overlapping candidates require
explicit selection, unsupported content is not offered, and every interrupted
or invalid transfer leaves no valid-looking record.
