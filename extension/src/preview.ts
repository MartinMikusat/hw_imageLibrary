import type { CandidateBatch, ImageCandidate, PanelRequest, PanelResponse } from "./capture-types.js";
import { candidatesAtPoint, rectPercent } from "./geometry.js";

const collectButton = document.querySelector<HTMLButtonElement>("#collect")!;
const status = document.querySelector<HTMLParagraphElement>("#status")!;
const preview = document.querySelector<HTMLDivElement>("#preview")!;
const screenshot = document.querySelector<HTMLImageElement>("#screenshot")!;
const overlays = document.querySelector<HTMLDivElement>("#overlays")!;
const choices = document.querySelector<HTMLDivElement>("#choices")!;

let batch: CandidateBatch | undefined;
let busy = false;

function setStatus(message: string, error = false): void {
  status.textContent = message;
  status.classList.toggle("error", error);
}

async function send(request: PanelRequest): Promise<PanelResponse> {
  return chrome.runtime.sendMessage(request) as Promise<PanelResponse>;
}

function candidateLabel(candidate: ImageCandidate, index: number): string {
  const name = candidate.altText || candidate.figureCaption || new URL(candidate.currentSrc).pathname.split("/").pop() || "image";
  return `${index + 1}. ${name} — ${candidate.naturalWidth}×${candidate.naturalHeight}`;
}

function clearChoices(): void {
  choices.replaceChildren();
  choices.hidden = true;
}

async function storeCandidate(candidate: ImageCandidate): Promise<void> {
  if (!batch || busy) return;
  busy = true;
  clearChoices();
  const permission = `${new URL(candidate.currentSrc).origin}/*`;
  let granted = false;
  try {
    granted = await chrome.permissions.request({ origins: [permission] });
  } catch (error) {
    busy = false;
    setStatus(error instanceof Error ? error.message : "Image-origin permission failed.", true);
    return;
  }
  if (!granted) {
    busy = false;
    setStatus("Image-origin access was not granted.", true);
    return;
  }
  setStatus("Retrieving and validating the original bytes…");
  const captureBatch = { ...batch, screenshotDataUrl: "" };
  const response = await send({ type: "capture_candidate", batch: captureBatch, candidateId: candidate.candidateId });
  busy = false;
  if (!response.ok) {
    setStatus(response.message, true);
    return;
  }
  if (response.type !== "capture_stored") {
    setStatus("The background worker returned an unexpected response.", true);
    return;
  }
  setStatus(`Stored ${response.captureId.slice(0, 8)} · ${response.objectDigest.slice(0, 12)}`);
}

function showChoices(candidates: ImageCandidate[]): void {
  if (!batch) return;
  clearChoices();
  const heading = document.createElement("p");
  heading.textContent = candidates.length > 1 ? "Choose one overlapping image" : "Confirm image";
  choices.append(heading);
  for (const candidate of candidates) {
    const index = batch.candidates.indexOf(candidate);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "choice";
    button.textContent = candidateLabel(candidate, index);
    button.addEventListener("click", () => void storeCandidate(candidate));
    choices.append(button);
  }
  choices.hidden = false;
}

function renderBatch(nextBatch: CandidateBatch): void {
  batch = nextBatch;
  screenshot.src = nextBatch.screenshotDataUrl;
  overlays.replaceChildren();
  clearChoices();
  nextBatch.candidates.forEach((candidate, index) => {
    const percent = rectPercent(candidate.elementRect, nextBatch.viewport);
    const box = document.createElement("button");
    box.type = "button";
    box.className = "candidate-box";
    box.style.left = `${percent.x}%`;
    box.style.top = `${percent.y}%`;
    box.style.width = `${percent.width}%`;
    box.style.height = `${percent.height}%`;
    box.textContent = String(index + 1);
    box.setAttribute("aria-label", candidateLabel(candidate, index));
    overlays.append(box);
  });
  preview.hidden = false;
  setStatus(nextBatch.candidates.length === 0
    ? "No supported visible images were found."
    : `Choose one of ${nextBatch.candidates.length} visible images.`);
}

collectButton.addEventListener("click", async () => {
  if (busy) return;
  busy = true;
  collectButton.disabled = true;
  clearChoices();
  setStatus("Collecting visible images and freezing the viewport…");
  const response = await send({ type: "collect_candidates" });
  busy = false;
  collectButton.disabled = false;
  if (!response.ok) {
    setStatus(response.message, true);
    return;
  }
  if (response.type !== "candidate_batch") {
    setStatus("The background worker returned an unexpected response.", true);
    return;
  }
  renderBatch(response.batch);
});

overlays.addEventListener("click", (event) => {
  if (!batch) return;
  const bounds = overlays.getBoundingClientRect();
  const viewportX = (event.clientX - bounds.left) / bounds.width * batch.viewport.width;
  const viewportY = (event.clientY - bounds.top) / bounds.height * batch.viewport.height;
  showChoices(candidatesAtPoint(batch.candidates, viewportX, viewportY));
});
