import type {
  CandidateBatch,
  ImageCandidate,
  PanelRequest,
  PanelResponse,
} from "./capture-types.js";
import {
  collectDocumentCandidates,
  type CollectedDocument,
} from "./candidate-collector.js";
import {
  LIBRARY_MAX_OBJECT_BYTES,
  NATIVE_WIRE_RAW_CHUNK_BYTES,
  NATIVE_WIRE_VERSION,
  type NativeWireMessage,
} from "./wire-contract.js";

const NATIVE_HOST = "com.halwayland.hw_imagelibrary";
const NATIVE_RESPONSE_TIMEOUT_MS = 30_000;

interface NativeResponse {
  wire_version: number;
  ok: boolean;
  type: string;
  transfer_id?: string;
  capture_id?: string;
  next_sequence?: number;
  object_digest?: string;
  error_code?: string;
  message?: string;
}

chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });

function errorResponse(errorCode: string, message: string): PanelResponse {
  return { ok: false, errorCode, message };
}

async function activeTab(): Promise<chrome.tabs.Tab> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id || tab.windowId === undefined) throw new Error("No active web tab is available.");
  if (!tab.url?.startsWith("http://") && !tab.url?.startsWith("https://")) {
    throw new Error("The active tab is not an HTTP or HTTPS page.");
  }
  return tab;
}

async function collectCandidates(): Promise<PanelResponse> {
  try {
    const tab = await activeTab();
    const results = await chrome.scripting.executeScript({
      target: { tabId: tab.id! },
      func: collectDocumentCandidates,
    });
    const collected = results[0]?.result as CollectedDocument | undefined;
    if (!collected) return errorResponse("collection", "The page did not return an image candidate set.");
    const screenshotDataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
    const stableResults = await chrome.scripting.executeScript({
      target: { tabId: tab.id! },
      func: (expectedToken: string, expectedScrollX: number, expectedScrollY: number) => {
        const currentToken = (window as Window & { __hwImageLibraryDocumentToken?: string }).__hwImageLibraryDocumentToken;
        return currentToken === expectedToken && window.scrollX === expectedScrollX && window.scrollY === expectedScrollY;
      },
      args: [collected.documentToken, collected.scrollX, collected.scrollY],
    });
    if (stableResults[0]?.result !== true) {
      return errorResponse("viewport_changed", "The page moved while the viewport screenshot was captured. Collect again.");
    }
    const batch: CandidateBatch = {
      tabId: tab.id!,
      windowId: tab.windowId,
      documentToken: collected.documentToken,
      pageUrl: collected.pageUrl,
      pageTitle: collected.pageTitle,
      capturedAtUnixMs: Date.now(),
      viewport: collected.viewport,
      screenshotDataUrl,
      candidates: collected.candidates,
    };
    return { ok: true, type: "candidate_batch", batch };
  } catch (error) {
    return errorResponse("collection", error instanceof Error ? error.message : "Candidate collection failed.");
  }
}

async function documentStillMatches(batch: CandidateBatch): Promise<boolean> {
  const results = await chrome.scripting.executeScript({
    target: { tabId: batch.tabId },
    func: (expectedToken: string) =>
      (window as Window & { __hwImageLibraryDocumentToken?: string }).__hwImageLibraryDocumentToken === expectedToken,
    args: [batch.documentToken],
  });
  return results[0]?.result === true;
}

function originPermission(urlText: string): string {
  const url = new URL(urlText);
  return `${url.origin}/*`;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 32 * 1024) {
    const end = Math.min(offset + 32 * 1024, bytes.length);
    for (let index = offset; index < end; index += 1) binary += String.fromCharCode(bytes[index]!);
  }
  return btoa(binary);
}

function nativeExchange(port: chrome.runtime.Port, message: NativeWireMessage): Promise<NativeResponse> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("The native host did not respond."));
    }, NATIVE_RESPONSE_TIMEOUT_MS);
    const onMessage = (response: unknown) => {
      cleanup();
      resolve(response as NativeResponse);
    };
    const onDisconnect = () => {
      const detail = chrome.runtime.lastError?.message ?? "The native host disconnected.";
      cleanup();
      reject(new Error(detail));
    };
    const cleanup = () => {
      clearTimeout(timeout);
      port.onMessage.removeListener(onMessage);
      port.onDisconnect.removeListener(onDisconnect);
    };
    port.onMessage.addListener(onMessage);
    port.onDisconnect.addListener(onDisconnect);
    port.postMessage(message);
  });
}

function requireNativeSuccess(response: NativeResponse): NativeResponse {
  if (response.wire_version !== NATIVE_WIRE_VERSION || !response.ok) {
    throw new Error(response.message ?? response.error_code ?? "The native host rejected the capture.");
  }
  return response;
}

async function captureCandidate(batch: CandidateBatch, candidateId: string): Promise<PanelResponse> {
  const candidate = batch.candidates.find((value) => value.candidateId === candidateId);
  if (!candidate) return errorResponse("candidate", "The selected image candidate no longer exists.");
  let port: chrome.runtime.Port | undefined;
  let sequence = 1;
  let transferBegun = false;
  const transferId = crypto.randomUUID();
  const captureId = crypto.randomUUID();
  try {
    const permission = originPermission(candidate.currentSrc);
    const granted = await chrome.permissions.contains({ origins: [permission] });
    if (!granted) return errorResponse("permission", "Image-origin access was not granted.");
    const tab = await chrome.tabs.get(batch.tabId);
    if (tab.windowId !== batch.windowId || !(await documentStillMatches(batch))) {
      return errorResponse("document_changed", "The page navigated after candidate collection. Collect candidates again.");
    }
    const response = await fetch(candidate.currentSrc, { credentials: "include", cache: "no-store" });
    if (!response.ok || !response.body) {
      return errorResponse("fetch", `The image request failed with HTTP ${response.status}.`);
    }
    const declaredText = response.headers.get("content-length");
    const declaredByteCount = declaredText && /^\d+$/.test(declaredText) ? Number(declaredText) : 0;
    if (!Number.isSafeInteger(declaredByteCount) || declaredByteCount > LIBRARY_MAX_OBJECT_BYTES) {
      return errorResponse("byte_count", "The image response exceeds the 512 MiB object bound.");
    }
    port = chrome.runtime.connectNative(NATIVE_HOST);
    const begin = requireNativeSuccess(await nativeExchange(port, {
      wire_version: NATIVE_WIRE_VERSION,
      type: "capture_begin",
      transfer_id: transferId,
      capture_id: captureId,
      sequence: 0,
      captured_at_unix_ms: batch.capturedAtUnixMs,
      page_url: batch.pageUrl,
      page_title: batch.pageTitle,
      current_src: candidate.currentSrc,
      alt_text: candidate.altText,
      figure_caption: candidate.figureCaption,
      initial_note: "",
      element_rect: candidate.elementRect,
      viewport: batch.viewport,
      response_media_type: response.headers.get("content-type") ?? "",
      declared_byte_count: declaredByteCount,
    }));
    if (begin.type === "capture_stored") {
      return {
        ok: true,
        type: "capture_stored",
        captureId,
        objectDigest: begin.object_digest ?? "",
      };
    }
    transferBegun = true;
    let totalByteCount = 0;
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      for (let offset = 0; offset < value.byteLength; offset += NATIVE_WIRE_RAW_CHUNK_BYTES) {
        const chunk = value.subarray(offset, Math.min(offset + NATIVE_WIRE_RAW_CHUNK_BYTES, value.byteLength));
        totalByteCount += chunk.byteLength;
        if (totalByteCount > LIBRARY_MAX_OBJECT_BYTES) throw new Error("The image response exceeds 512 MiB.");
        const ack = requireNativeSuccess(await nativeExchange(port, {
          wire_version: NATIVE_WIRE_VERSION,
          type: "capture_chunk",
          transfer_id: transferId,
          capture_id: captureId,
          sequence,
          data_base64: bytesToBase64(chunk),
        }));
        sequence += 1;
        if (ack.next_sequence !== sequence) throw new Error("The native host returned an invalid chunk acknowledgement.");
      }
    }
    const stored = requireNativeSuccess(await nativeExchange(port, {
      wire_version: NATIVE_WIRE_VERSION,
      type: "capture_commit",
      transfer_id: transferId,
      capture_id: captureId,
      sequence,
      total_byte_count: totalByteCount,
    }));
    transferBegun = false;
    if (stored.type !== "capture_stored" || !stored.object_digest) {
      throw new Error("The native host did not confirm durable capture storage.");
    }
    return { ok: true, type: "capture_stored", captureId, objectDigest: stored.object_digest };
  } catch (error) {
    if (port && transferBegun) {
      try {
        await nativeExchange(port, {
          wire_version: NATIVE_WIRE_VERSION,
          type: "capture_cancel",
          transfer_id: transferId,
          capture_id: captureId,
          sequence,
          reason: error instanceof Error ? error.message.slice(0, 2048) : "Capture cancelled.",
        });
      } catch {
        // The service removes stale machine-local staging after a disconnected host.
      }
    }
    return errorResponse("capture", error instanceof Error ? error.message : "Capture failed.");
  } finally {
    port?.disconnect();
  }
}

chrome.runtime.onMessage.addListener(
  (request: PanelRequest, _sender, sendResponse: (response: PanelResponse) => void) => {
    const operation = request.type === "collect_candidates"
      ? collectCandidates()
      : request.type === "capture_candidate"
        ? captureCandidate(request.batch, request.candidateId)
        : Promise.resolve(errorResponse("request", "Unknown panel request."));
    operation.then(sendResponse);
    return true;
  },
);
