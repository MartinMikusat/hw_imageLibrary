import type { CaptureRect, CaptureViewport, ImageCandidate } from "./capture-types.js";

export function intersectRect(a: CaptureRect, b: CaptureRect): CaptureRect | null {
  const left = Math.max(a.x, b.x);
  const top = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  if (right <= left || bottom <= top) return null;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function candidatesAtPoint(
  candidates: readonly ImageCandidate[],
  x: number,
  y: number,
): ImageCandidate[] {
  return candidates.filter(({ elementRect: rect }) =>
    x >= rect.x && x <= rect.x + rect.width &&
    y >= rect.y && y <= rect.y + rect.height
  );
}

export function rectPercent(rect: CaptureRect, viewport: CaptureViewport): CaptureRect {
  return {
    x: rect.x / viewport.width * 100,
    y: rect.y / viewport.height * 100,
    width: rect.width / viewport.width * 100,
    height: rect.height / viewport.height * 100,
  };
}
