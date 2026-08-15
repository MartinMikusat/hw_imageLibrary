import assert from "node:assert/strict";
import { access, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const extensionRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function assetServer() {
  return http.createServer((request, response) => {
    if (request.url === "/asset.png" || request.url === "/asset-wide.png") {
      response.writeHead(200, { "content-type": "image/png", "content-length": png.length });
      response.end(png);
      return;
    }
    response.writeHead(404).end();
  });
}

function fixtureServer(crossOrigin) {
  return http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://fixture.invalid");
      if (url.pathname === "/asset.png" || url.pathname === "/asset-wide.png") {
        response.writeHead(200, { "content-type": "image/png", "content-length": png.length });
        response.end(png);
        return;
      }
      if (url.pathname === "/load-gate.css") {
        setTimeout(() => response.writeHead(200, { "content-type": "text/css" }).end(""), 250);
        return;
      }
      if (url.pathname === "/candidate-collector-classic.js") {
        const moduleText = await readFile(path.join(extensionRoot, "dist", "candidate-collector.js"), "utf8");
        const classicText = moduleText.replace(
          "export function collectDocumentCandidates",
          "window.collectDocumentCandidates = function collectDocumentCandidates",
        );
        response.writeHead(200, { "content-type": "text/javascript; charset=utf-8" });
        response.end(classicText);
        return;
      }
      const relative = url.pathname === "/" ? "fixtures/plain.html" : url.pathname.slice(1);
      const resolved = path.resolve(extensionRoot, relative);
      if (!resolved.startsWith(`${extensionRoot}${path.sep}`)) throw new Error("invalid path");
      let bytes = await readFile(resolved);
      if (resolved.endsWith("cross-origin.html")) {
        bytes = Buffer.from(bytes.toString("utf8").replace("__CROSS_ORIGIN__", crossOrigin));
      }
      if (resolved.endsWith(".html")) {
        bytes = Buffer.from(bytes.toString("utf8").replace(
          "</title>",
          "</title><link rel=\"stylesheet\" href=\"/load-gate.css\">",
        ));
      }
      const type = resolved.endsWith(".html") ? "text/html; charset=utf-8"
        : resolved.endsWith(".js") ? "text/javascript; charset=utf-8"
          : "application/octet-stream";
      response.writeHead(200, { "content-type": type, "content-length": bytes.length });
      response.end(bytes);
    } catch {
      response.writeHead(404).end();
    }
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function run(binary, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { stdio: ["ignore", "pipe", "pipe"] });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${binary} did not finish its headless fixture within 15 seconds`));
    }, 15_000);
    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(`${binary} exited ${code}: ${Buffer.concat(stderr).toString("utf8")}`));
        return;
      }
      resolve(Buffer.concat(stdout).toString("utf8"));
    });
  });
}

function parseResult(html) {
  const match = html.match(/<pre id="result">([^<]+)<\/pre>/);
  assert.ok(match, "fixture did not emit a candidate result");
  if (match[1] === "pending") throw new Error(`fixture script remained pending:\n${html}`);
  return JSON.parse(match[1].replaceAll("&amp;", "&"));
}

const fixtures = [
  ["plain.html", (value) => {
    assert.equal(value.candidates.length, 1);
    assert.equal(value.candidates[0].altText, "plain fixture");
    assert.equal(value.candidates[0].figureCaption, "Plain caption");
  }],
  ["picture.html", (value) => {
    assert.equal(value.candidates.length, 1);
    assert.match(value.candidates[0].currentSrc, /\/asset-wide\.png$/);
  }],
  ["lazy.html", (value) => assert.equal(value.candidates.length, 1)],
  ["duplicates.html", (value) => {
    assert.equal(value.candidates.length, 2);
    assert.equal(value.candidates[0].currentSrc, value.candidates[1].currentSrc);
  }],
  ["clipped.html", (value) => {
    assert.equal(value.candidates.length, 1);
    assert.equal(value.candidates[0].elementRect.width, 80);
    assert.equal(value.candidates[0].elementRect.height, 60);
  }],
  ["object-fit.html", (value) => {
    assert.equal(value.candidates.length, 1);
    assert.equal(value.candidates[0].elementRect.width, 240);
    assert.equal(value.candidates[0].elementRect.height, 120);
  }],
  ["overlap.html", (value) => assert.equal(value.candidates.length, 2)],
  ["cross-origin.html", (value) => {
    assert.equal(value.candidates.length, 1);
    assert.notEqual(new URL(value.candidates[0].currentSrc).origin, new URL(value.pageUrl).origin);
  }],
  ["css-background.html", (value) => assert.equal(value.candidates.length, 0)],
  ["canvas.html", (value) => assert.equal(value.candidates.length, 0)],
  ["inline-svg.html", (value) => assert.equal(value.candidates.length, 0)],
  ["child-frame.html", (value) => assert.equal(value.candidates.length, 0)],
  ["offscreen.html", (value) => assert.equal(value.candidates.length, 0)],
];

const candidates = [["Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]];
try {
  const cacheRoot = path.join(os.homedir(), "Library", "Caches", "ms-playwright");
  const releases = (await readdir(cacheRoot))
    .filter((entry) => entry.startsWith("chromium_headless_shell-"))
    .sort()
    .reverse();
  if (releases.length > 0) {
    candidates.push([
      "Chromium headless shell",
      path.join(cacheRoot, releases[0], "chrome-headless-shell-mac-arm64", "chrome-headless-shell"),
    ]);
  }
} catch {}
if (process.env.HW_GALLERY_TEST_BRAVE === "1") {
  candidates.push(["Brave", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]);
}
const browsers = [];
for (const candidate of candidates) {
  try {
    await access(candidate[1]);
    browsers.push(candidate);
  } catch {}
}
if (browsers.length === 0) throw new Error("Chrome or Brave is required for browser fixtures");

const assets = assetServer();
const assetPort = await listen(assets);
const server = fixtureServer(`http://127.0.0.1:${assetPort}`);
const port = await listen(server);
try {
  for (const [name, binary] of browsers) {
    for (const scale of [1, 2]) {
      for (const [fixture, verify] of fixtures) {
        const profile = await mkdtemp(path.join(os.tmpdir(), "hw-image-library-browser-"));
        try {
          const html = await run(binary, [
            "--headless=new",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-sync",
            "--no-first-run",
            "--no-default-browser-check",
            `--force-device-scale-factor=${scale}`,
            "--window-size=800,600",
            "--virtual-time-budget=750",
            `--user-data-dir=${profile}`,
            "--dump-dom",
            `http://127.0.0.1:${port}/fixtures/${fixture}`,
          ]);
          verify(parseResult(html));
        } finally {
          await rm(profile, { recursive: true, force: true, maxRetries: 8, retryDelay: 100 });
        }
      }
      process.stdout.write(`${name}: ${fixtures.length} fixtures passed at scale ${scale}\n`);
    }
  }
} finally {
  await close(server);
  await close(assets);
}
