# hw_imageLibrary

`hw_imageLibrary` is a personal, source-aware image library for Apple Silicon
macOS. A Chromium extension selects visible images from web pages and sends the
original bytes and provenance to a native Odin application for durable local
storage, CLI access, and visual browsing.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**

## Status

The repository contains the initial Odin application and Chromium-extension
scaffolds. The capture pipeline, storage layer, CLI, and image viewer are planned
but not implemented. See [the Version 1 plan](docs/v1-plan.md) and
[project TODO](TODO.md).

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
Odin native-messaging host. The Odin application owns SQLite metadata, immutable
image objects, thumbnail caches, queries, exports, and the native interface. A
web page never receives database access or a native command channel.

Metadata will live in SQLite. Original image bytes will live in an
application-managed object directory under filenames derived from SHA-256. The
native host will verify the complete byte count and digest before it installs an
object and commits the corresponding database row.

## Development

The current Odin scaffold runs with a local Odin compiler:

```sh
odin run src
```

Build the extension from its own directory:

```sh
cd extension
npm ci
npm run build
```

After the build, load `extension/` as an unpacked extension in Chrome or Brave.
The current side panel reports scaffold status only. Native-host registration
will be added with the ingestion milestone.

The repository currently grants no software license. Public visibility permits
inspection but does not grant reuse or redistribution rights.
