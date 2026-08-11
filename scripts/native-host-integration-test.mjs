import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, copyFileSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const executable = process.argv[2];
if (!executable) throw new Error("usage: native-host-integration-test.mjs <executable>");

const temporary = mkdtempSync(join(tmpdir(), "hw-image-library-native-host-"));
const support = join(temporary, "support");
const library = join(temporary, "library");
const nativeHost = join(temporary, "hw_imageLibrary-native-host");
const environment = {
  ...process.env,
  HW_IMAGE_LIBRARY_APP_SUPPORT_DIR: support,
  HW_IMAGE_LIBRARY_ALLOW_SERVICE_STOP: "1",
};

function command(...args) {
  return JSON.parse(execFileSync(executable, args, { env: environment, encoding: "utf8" }));
}

function frame(value) {
  const body = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  return Buffer.concat([header, body]);
}

try {
  mkdirSync(support, { recursive: true });
  copyFileSync(executable, nativeHost);
  chmodSync(nativeHost, 0o755);
  assert.equal(command("library", "init-local", library).ok, true);
  const host = spawn(nativeHost, [], { env: environment, stdio: ["pipe", "pipe", "inherit"] });
  let buffered = Buffer.alloc(0);
  const pending = [];
  host.stdout.on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 4) {
      const length = buffered.readUInt32LE(0);
      if (buffered.length < length + 4) break;
      const response = JSON.parse(buffered.subarray(4, length + 4).toString("utf8"));
      buffered = buffered.subarray(length + 4);
      pending.shift()?.resolve(response);
    }
  });
  const exchange = (value) => new Promise((resolve, reject) => {
    pending.push({ resolve, reject });
    host.stdin.write(frame(value));
  });
  const transferId = "40000000-0000-4000-8000-000000000001";
  const captureId = "40000000-0000-4000-8000-000000000002";
  const common = { wire_version: 1, transfer_id: transferId, capture_id: captureId };
  const ready = await exchange({
    ...common,
    type: "capture_begin",
    sequence: 0,
    captured_at_unix_ms: 1_700_000_000_100,
    page_url: "https://example.com/page",
    page_title: "Native host integration",
    current_src: "https://example.com/image.png",
    alt_text: "fixture",
    figure_caption: "caption",
    initial_note: "",
    element_rect: { x: 1, y: 2, width: 3, height: 4 },
    viewport: { width: 100, height: 100 },
    response_media_type: "image/png",
    declared_byte_count: 68,
  });
  assert.equal(ready.type, "capture_ready");
  const chunk = await exchange({
    ...common,
    type: "capture_chunk",
    sequence: 1,
    data_base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  });
  assert.equal(chunk.next_sequence, 2);
  const stored = await exchange({
    ...common,
    type: "capture_commit",
    sequence: 2,
    total_byte_count: 68,
  });
  assert.equal(stored.ok, true);
  assert.equal(stored.type, "capture_stored");
  assert.equal(stored.object_digest, "431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460");
  host.stdin.end();
  await new Promise((resolve, reject) => {
    host.on("exit", (code) => code === 0 ? resolve() : reject(new Error(`native host exited ${code}`)));
  });
  const shown = command("capture", "show", captureId);
  assert.equal(shown.ok, true);
  assert.equal(shown.capture.page_title, "Native host integration");
  console.log("native-host integration passed");
} finally {
  try { command("library", "service-stop"); } catch {}
  rmSync(temporary, { recursive: true, force: true });
}
