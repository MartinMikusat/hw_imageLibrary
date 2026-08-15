import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const manifest = JSON.parse(await readFile(resolve(here, "../manifest.json"), "utf8"));

test("toolbar action opens the capture popup", () => {
  assert.equal(manifest.action.default_popup, "preview.html");
  assert.equal(manifest.side_panel, undefined);
  assert.equal(manifest.permissions.includes("sidePanel"), false);
});
