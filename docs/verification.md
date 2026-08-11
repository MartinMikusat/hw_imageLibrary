# Verification record

The repository currently passes `./test.sh`, which runs 28 Odin tests, the
TypeScript wire and geometry tests, the development launch-policy checks, a full
Odin build, a framed native-messaging capture through the background service,
and `git diff --check`.

`npm run test:browser --prefix extension` passes 13 rendered fixtures in the
Chromium headless shell at display scales 1 and 2. The fixtures cover plain,
`picture`/`srcset`, dynamically assigned, duplicate, clipped, object-fit,
overlapping, and cross-origin images, plus explicit exclusion of CSS backgrounds,
canvas, inline SVG, child-frame images, and off-screen images. Separate geometry
tests exercise the 80%, 100%, 125%, and 200% scale matrix.

The debug app bundle builds and completes a configured hidden-launch smoke test
with `HW_IMAGE_LIBRARY_ACTIVATE_ON_LAUNCH=0` and
`HW_IMAGE_LIBRARY_VISIBLE_ON_LAUNCH=0`; the viewer produces no diagnostic output
and the background service can be stopped through its test-only command.

Release sign-off still requires:

- Load the packaged extension in installed Chrome and Brave and execute the
  fixture selection and exact-byte capture path through each browser.
- Exercise the navigation-during-capture fixture interactively because it
  depends on the extension's two injections around `captureVisibleTab`.
- Sign the app, verify the default ubiquity container and bookmark recovery, and
  converge one synchronized root on two physical Macs.
- Create real iCloud file conflict versions and verify identical-version
  resolution plus mismatched-object refusal.
