window.addEventListener("load", () => {
  try {
    document.querySelector("#result").textContent = JSON.stringify(window.collectDocumentCandidates());
    document.documentElement.dataset.fixtureReady = "true";
  } catch (error) {
    document.querySelector("#result").textContent = JSON.stringify({ driverError: String(error?.stack ?? error) });
  }
});
