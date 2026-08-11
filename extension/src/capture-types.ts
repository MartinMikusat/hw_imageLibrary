export interface CaptureRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface CaptureViewport {
  width: number;
  height: number;
}

export interface ImageCandidate {
  candidateId: string;
  currentSrc: string;
  altText: string;
  figureCaption: string;
  naturalWidth: number;
  naturalHeight: number;
  elementRect: CaptureRect;
}

export interface CandidateBatch {
  tabId: number;
  windowId: number;
  documentToken: string;
  pageUrl: string;
  pageTitle: string;
  capturedAtUnixMs: number;
  viewport: CaptureViewport;
  screenshotDataUrl: string;
  candidates: ImageCandidate[];
}

export type PanelRequest =
  | { type: "collect_candidates" }
  | { type: "capture_candidate"; batch: CandidateBatch; candidateId: string };

export type PanelResponse =
  | { ok: true; type: "candidate_batch"; batch: CandidateBatch }
  | { ok: true; type: "capture_stored"; captureId: string; objectDigest: string }
  | { ok: false; errorCode: string; message: string };
