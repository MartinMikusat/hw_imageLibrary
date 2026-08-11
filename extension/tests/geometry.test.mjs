import assert from "node:assert/strict";
import test from "node:test";

import { candidatesAtPoint, intersectRect, rectPercent } from "../dist/geometry.js";

test("rectangle clipping and screenshot percentages", () => {
  assert.deepEqual(
    intersectRect(
      { x: -10, y: 20, width: 50, height: 40 },
      { x: 0, y: 0, width: 100, height: 100 },
    ),
    { x: 0, y: 20, width: 40, height: 40 },
  );
  assert.deepEqual(
    rectPercent({ x: 100, y: 50, width: 200, height: 100 }, { width: 1000, height: 500 }),
    { x: 10, y: 10, width: 20, height: 20 },
  );
});

test("overlap selection returns every candidate under the pointer", () => {
  const candidates = [
    { candidateId: "a", elementRect: { x: 0, y: 0, width: 50, height: 50 } },
    { candidateId: "b", elementRect: { x: 25, y: 25, width: 50, height: 50 } },
  ];
  assert.deepEqual(candidatesAtPoint(candidates, 30, 30).map((value) => value.candidateId), ["a", "b"]);
});

test("viewport percentages stay stable across the supported zoom and display scales", () => {
  const rect = { x: 96, y: 48, width: 320, height: 180 };
  const viewport = { width: 1280, height: 720 };
  const expected = { x: 7.5, y: 6.666666666666667, width: 25, height: 25 };
  for (const zoom of [0.8, 1, 1.25, 2]) {
    for (const displayScale of [1, 2]) {
      const actual = rectPercent(
        Object.fromEntries(Object.entries(rect).map(([key, value]) => [key, value * zoom * displayScale])),
        { width: viewport.width * zoom * displayScale, height: viewport.height * zoom * displayScale },
      );
      for (const key of Object.keys(expected)) {
        assert.ok(Math.abs(actual[key] - expected[key]) < 1e-12);
      }
    }
  }
});
