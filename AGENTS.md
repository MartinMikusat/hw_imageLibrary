# Repository Guidelines

Read `README.md`, `docs/v1-plan.md`, and `TODO.md` before planning or changing
the product.

## Product boundary

- Keep the Odin application and Chromium extension in this repository.
- Treat the Odin application as the owner of durable state. The extension is a
  transient capture adapter and must not maintain a second authoritative
  library.
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
- Define every extension-to-native message in one versioned wire contract and
  enforce the same bounds and sequencing rules on both sides.
- Write incoming image data to a temporary file, verify its byte count and
  SHA-256 digest, install the immutable object, and then commit SQLite metadata.
- Make the CLI and native viewer consume the same storage procedures.
- Add only the code required by the current TODO milestone.

## Documentation

- Preserve the AI-assisted development disclosure in `README.md` and append each
  exact contributing model name without removing earlier names.
- Record bundled third-party assets with their exact version, source URL,
  checksum, and bundled license location.
- Keep application-specific work in `TODO.md` and detailed Version 1 decisions in
  `docs/v1-plan.md`.
