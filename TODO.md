# hw_imageLibrary TODO

The ordered milestones implement the approved
[Version 1 plan](docs/v1-plan.md). Complete one bounded vertical slice at a time.

## Active

1. [ ] **Define repository and wire contracts.** Specify the SQLite schema,
   capture record, native-message variants, transfer limits, ownership rules,
   and deterministic fixture format. Verify that TypeScript and Odin accept and
   reject the same representative messages.
2. [ ] **Build DOM candidate collection and screenshot mapping.** Collect visible
   eligible `<img>` elements, capture the viewport, and align numbered candidate
   rectangles at the supported browser zoom levels.
3. [ ] **Complete explicit selection and byte retrieval.** Bind selection to an
   immutable candidate identifier, request selected-origin access, and retrieve
   the exact `currentSrc` bytes without URL rewriting or screenshot fallback.
4. [ ] **Build native ingestion and storage.** Add bounded chunk assembly,
   SHA-256 verification, immutable object installation, SQLite migrations, and
   atomic capture commit.
5. [ ] **Add the structured CLI.** Implement capture list, show, search,
   open-source, and byte-identical export through the shared storage package.
6. [ ] **Add the native Odin viewer.** Implement a chronological thumbnail grid,
   image detail view, source metadata, user notes, and source-page navigation on
   the established `hw_videoClips` and `hw_calendar` AppKit, Metal, shared-theme,
   typography, control-registry, settings, modal, command-palette, Flash, and
   Accessibility interface baseline.
7. [ ] **Verify Chrome and Brave.** Run the same deterministic fixture set in
   both browsers on macOS, including Retina scaling and the approved zoom matrix.

## Deferred

- [ ] Evaluate image recognition for screenshot regions that have no reliable DOM
  candidate after Version 1 failure cases are recorded.
- [ ] Generate image descriptions with an explicit local-or-remote privacy
  contract and separate generated-text provenance.
- [ ] Define reliable capture contracts for CSS backgrounds, canvases, SVG,
  video frames, child frames, and full-page documents.
- [ ] Evaluate rendered screenshot crops as an explicitly labeled secondary
  artifact rather than a silent replacement for source bytes.
- [ ] Define tags, collections, annotations, similarity search, sync, sharing,
  and editing only after the capture and provenance model is stable.
