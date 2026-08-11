# hw_imageLibrary TODO

The ordered milestones implement the approved
[Version 1 plan](docs/v1-plan.md). Complete one bounded vertical slice at a time.

## Active

1. [x] **Define repository and wire contracts.** Specify the authoritative
   library-root layout, immutable capture-record and event schemas, rebuildable
   SQLite index schema, native-message variants, transfer limits, ownership
   rules, multi-Mac merge and conflict rules, event replay rules, and
   device lifecycle, acknowledgement-frontier, retention, restoration, and purge
   rules, authorized device-join and recovery rules, plus the deterministic
   fixture format. Verify that TypeScript and Odin accept and reject the same
   representative messages, and that isolated Odin device states rebuild the
   same index from every permutation of the same record and event set.
2. [x] **Build DOM candidate collection and screenshot mapping.** Collect visible
   eligible `<img>` elements, capture the viewport, and align numbered candidate
   rectangles at the supported browser zoom levels.
3. [x] **Complete explicit selection and byte retrieval.** Bind selection to an
   immutable candidate identifier, request selected-origin access, and retrieve
   the exact `currentSrc` bytes without URL rewriting or screenshot fallback.
4. [x] **Build native ingestion and storage.** Add the Odin-native macOS interop
   for iCloud location, folder selection, bookmarks, file coordination, and file
   presentation; then add bounded chunk assembly, SHA-256 verification,
   immutable object and record publication, idempotent out-of-order import,
   deterministic event replay and conflict materialization, local SQLite index
   rebuilds, device acknowledgements, tombstones, restoration, retirement cutoff
   enforcement, proof-bearing purge events, and orphan-safe capture commit.
   Run the local SQLite index and filesystem ingestion through one background
   Odin service reached by the GUI, CLI, and native-host proxy over a local Unix
   socket; only that service may mutate machine-local library state.
5. [x] **Add the structured CLI.** Implement capture list, show, search,
   open-source, byte-identical export, delete, and restore plus library device,
   retirement, purge-status, and purge commands through the shared storage
   package.
6. [x] **Add the native Odin viewer.** Implement a chronological thumbnail grid,
   image detail view, source metadata, user notes, and source-page navigation on
   the established `hw_videoClips` and `hw_calendar` AppKit, Metal, shared-theme,
   typography, control-registry, settings, modal, command-palette, Flash, and
   Accessibility interface baseline. Settings must show the active library root
   and device acknowledgement state, perform an explicitly confirmed coordinated
   move to a chosen folder, retire a device only after a destructive-action
   warning, and explain or execute physical purge.
7. [ ] **Verify browsers and multi-Mac convergence.** Run the same deterministic
   capture fixtures in Chrome and Brave on macOS, including Retina scaling and
   the approved zoom matrix. Replay synchronized records, objects, and events
   through isolated device states in every relevant delivery order and verify
   identical materialized indexes, conflicts, pending states, and corruption
   handling. Verify that physical purge requires expired retention, tombstones
   for every reference, acknowledgement from every active device, and a durable
   purge proof; verify restoration, device retirement, stale-device rejection,
   and object-deletion ordering.

   The automated Chromium rendering fixtures pass at normal and Retina display
   scales, and isolated-state merge and purge tests pass. Remaining release
   verification requires live packaged-extension runs in Chrome and Brave, a
   signed iCloud container on two Macs, and real iCloud conflict-version cases.

## Deferred

- [ ] Evaluate image recognition for screenshot regions that have no reliable DOM
  candidate after Version 1 failure cases are recorded.
- [ ] Generate image descriptions with an explicit local-or-remote privacy
  contract and separate generated-text provenance.
- [ ] Define reliable capture contracts for CSS backgrounds, canvases, SVG,
  video frames, child frames, and full-page documents.
- [ ] Evaluate rendered screenshot crops as an explicitly labeled secondary
  artifact rather than a silent replacement for source bytes.
- [ ] Define tags, collections, annotations, similarity search, sharing, and
  pixel editing only after the capture and provenance model is stable.
