export const NATIVE_WIRE_VERSION = 1;
export const NATIVE_WIRE_RAW_CHUNK_BYTES = 192 * 1024;
export const NATIVE_WIRE_BASE64_CHUNK_BYTES = 256 * 1024;
export const LIBRARY_MAX_OBJECT_BYTES = 512 * 1024 * 1024;

const MAX_URL_BYTES = 8 * 1024;
const MAX_TITLE_BYTES = 2 * 1024;
const MAX_ALT_BYTES = 16 * 1024;
const MAX_CAPTION_BYTES = 16 * 1024;
const MAX_NOTE_BYTES = 64 * 1024;
const MAX_MEDIA_TYPE_BYTES = 256;
const MAX_REASON_BYTES = 2 * 1024;

export interface WireRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WireViewport {
  width: number;
  height: number;
}

export interface CaptureBeginMessage {
  wire_version: 1;
  type: "capture_begin";
  transfer_id: string;
  capture_id: string;
  sequence: 0;
  captured_at_unix_ms: number;
  page_url: string;
  page_title: string;
  current_src: string;
  alt_text: string;
  figure_caption: string;
  initial_note: string;
  element_rect: WireRect;
  viewport: WireViewport;
  response_media_type: string;
  declared_byte_count: number;
}

export interface CaptureChunkMessage {
  wire_version: 1;
  type: "capture_chunk";
  transfer_id: string;
  capture_id: string;
  sequence: number;
  data_base64: string;
}

export interface CaptureCommitMessage {
  wire_version: 1;
  type: "capture_commit";
  transfer_id: string;
  capture_id: string;
  sequence: number;
  total_byte_count: number;
}

export interface CaptureCancelMessage {
  wire_version: 1;
  type: "capture_cancel";
  transfer_id: string;
  capture_id: string;
  sequence: number;
  reason: string;
}

export type NativeWireMessage =
  | CaptureBeginMessage
  | CaptureChunkMessage
  | CaptureCommitMessage
  | CaptureCancelMessage;

const encoder = new TextEncoder();

function byteLength(value: string): number {
  return encoder.encode(value).byteLength;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Object.keys(value).every((key) => allowed.has(key));
}

function isSafeInteger(value: unknown, minimum = 0, maximum = Number.MAX_SAFE_INTEGER): value is number {
  return Number.isSafeInteger(value) && (value as number) >= minimum && (value as number) <= maximum;
}

function isBoundedString(value: unknown, maximumBytes: number): value is string {
  return typeof value === "string" && !value.includes("\0") && byteLength(value) <= maximumBytes;
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}

function isHttpUrl(value: unknown): value is string {
  return isBoundedString(value, MAX_URL_BYTES) &&
    (value.startsWith("https://") || value.startsWith("http://")) &&
    !/[\n\r\t]/.test(value);
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isRect(value: unknown): value is WireRect {
  if (!isRecord(value) || !hasOnlyKeys(value, ["x", "y", "width", "height"])) return false;
  return isFiniteNumber(value.x) && value.x >= 0 &&
    isFiniteNumber(value.y) && value.y >= 0 &&
    isFiniteNumber(value.width) && value.width > 0 &&
    isFiniteNumber(value.height) && value.height > 0;
}

function isViewport(value: unknown): value is WireViewport {
  if (!isRecord(value) || !hasOnlyKeys(value, ["width", "height"])) return false;
  return isFiniteNumber(value.width) && value.width > 0 && value.width <= 100_000 &&
    isFiniteNumber(value.height) && value.height > 0 && value.height <= 100_000;
}

function hasCommonFields(value: Record<string, unknown>): boolean {
  return value.wire_version === NATIVE_WIRE_VERSION &&
    isUuid(value.transfer_id) && isUuid(value.capture_id);
}

function isBegin(value: Record<string, unknown>): boolean {
  const keys = [
    "wire_version", "type", "transfer_id", "capture_id", "sequence",
    "captured_at_unix_ms", "page_url", "page_title", "current_src", "alt_text",
    "figure_caption", "initial_note", "element_rect", "viewport",
    "response_media_type", "declared_byte_count",
  ];
  if (!hasOnlyKeys(value, keys) || value.sequence !== 0 ||
      !isSafeInteger(value.captured_at_unix_ms, 1) ||
      !isHttpUrl(value.page_url) || !isHttpUrl(value.current_src) ||
      !isBoundedString(value.page_title, MAX_TITLE_BYTES) ||
      !isBoundedString(value.alt_text, MAX_ALT_BYTES) ||
      !isBoundedString(value.figure_caption, MAX_CAPTION_BYTES) ||
      !isBoundedString(value.initial_note, MAX_NOTE_BYTES) ||
      !isBoundedString(value.response_media_type, MAX_MEDIA_TYPE_BYTES) ||
      !isSafeInteger(value.declared_byte_count, 0, LIBRARY_MAX_OBJECT_BYTES) ||
      !isRect(value.element_rect) || !isViewport(value.viewport)) return false;
  const rect = value.element_rect;
  const viewport = value.viewport;
  return rect.x <= viewport.width && rect.y <= viewport.height &&
    rect.width <= viewport.width * 4 && rect.height <= viewport.height * 4;
}

function isChunk(value: Record<string, unknown>): boolean {
  return hasOnlyKeys(value, ["wire_version", "type", "transfer_id", "capture_id", "sequence", "data_base64"]) &&
    isSafeInteger(value.sequence, 1) &&
    typeof value.data_base64 === "string" && value.data_base64.length > 0 &&
    byteLength(value.data_base64) <= NATIVE_WIRE_BASE64_CHUNK_BYTES;
}

function isCommit(value: Record<string, unknown>): boolean {
  return hasOnlyKeys(value, ["wire_version", "type", "transfer_id", "capture_id", "sequence", "total_byte_count"]) &&
    isSafeInteger(value.sequence, 1) &&
    isSafeInteger(value.total_byte_count, 1, LIBRARY_MAX_OBJECT_BYTES);
}

function isCancel(value: Record<string, unknown>): boolean {
  return hasOnlyKeys(value, ["wire_version", "type", "transfer_id", "capture_id", "sequence", "reason"]) &&
    isSafeInteger(value.sequence, 1) && isBoundedString(value.reason, MAX_REASON_BYTES);
}

export function validateNativeWireMessage(value: unknown): value is NativeWireMessage {
  if (!isRecord(value) || !hasCommonFields(value) || typeof value.type !== "string") return false;
  switch (value.type) {
    case "capture_begin": return isBegin(value);
    case "capture_chunk": return isChunk(value);
    case "capture_commit": return isCommit(value);
    case "capture_cancel": return isCancel(value);
    default: return false;
  }
}
