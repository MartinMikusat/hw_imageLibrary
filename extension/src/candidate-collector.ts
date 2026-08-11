import type { ImageCandidate } from "./capture-types.js";

export interface CollectedDocument {
  documentToken: string;
  pageUrl: string;
  pageTitle: string;
  viewport: { width: number; height: number };
  scrollX: number;
  scrollY: number;
  candidates: ImageCandidate[];
}

export function collectDocumentCandidates(): CollectedDocument {
  type MutableWindow = Window & { __hwImageLibraryDocumentToken?: string };
  const mutableWindow = window as MutableWindow;
  mutableWindow.__hwImageLibraryDocumentToken ??= crypto.randomUUID();
  const viewport = { width: window.innerWidth, height: window.innerHeight };
  const viewportRect = { x: 0, y: 0, width: viewport.width, height: viewport.height };

  function intersect(
    a: { x: number; y: number; width: number; height: number },
    b: { x: number; y: number; width: number; height: number },
  ) {
    const x = Math.max(a.x, b.x);
    const y = Math.max(a.y, b.y);
    const right = Math.min(a.x + a.width, b.x + b.width);
    const bottom = Math.min(a.y + a.height, b.y + b.height);
    return right > x && bottom > y
      ? { x, y, width: right - x, height: bottom - y }
      : null;
  }

  function visibleRect(image: HTMLImageElement) {
    if (!image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0) return null;
    const style = getComputedStyle(image);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) <= 0) return null;
    const bounds = image.getBoundingClientRect();
    let clipped = intersect(
      { x: bounds.left, y: bounds.top, width: bounds.width, height: bounds.height },
      viewportRect,
    );
    if (!clipped) return null;
    for (let ancestor = image.parentElement; ancestor; ancestor = ancestor.parentElement) {
      const ancestorStyle = getComputedStyle(ancestor);
      if (ancestorStyle.display === "none" || ancestorStyle.visibility === "hidden" ||
          Number(ancestorStyle.opacity) <= 0) return null;
      const clipsX = ["hidden", "clip", "scroll", "auto"].includes(ancestorStyle.overflowX);
      const clipsY = ["hidden", "clip", "scroll", "auto"].includes(ancestorStyle.overflowY);
      if (!clipsX && !clipsY) continue;
      const ancestorBounds = ancestor.getBoundingClientRect();
      const clipBounds = {
        x: clipsX ? ancestorBounds.left : 0,
        y: clipsY ? ancestorBounds.top : 0,
        width: clipsX ? ancestorBounds.width : viewport.width,
        height: clipsY ? ancestorBounds.height : viewport.height,
      };
      clipped = intersect(clipped, clipBounds);
      if (!clipped) return null;
    }
    return clipped;
  }

  const candidates: ImageCandidate[] = [];
  for (const image of document.images) {
    const rect = visibleRect(image);
    const currentSrc = image.currentSrc;
    if (!rect || !/^https?:\/\//.test(currentSrc)) continue;
    const figure = image.closest("figure");
    const caption = figure?.querySelector(":scope > figcaption")?.textContent?.trim() ?? "";
    candidates.push({
      candidateId: crypto.randomUUID(),
      currentSrc,
      altText: image.alt,
      figureCaption: caption,
      naturalWidth: image.naturalWidth,
      naturalHeight: image.naturalHeight,
      elementRect: rect,
    });
  }
  return {
    documentToken: mutableWindow.__hwImageLibraryDocumentToken,
    pageUrl: location.href,
    pageTitle: document.title,
    viewport,
    scrollX: window.scrollX,
    scrollY: window.scrollY,
    candidates,
  };
}
