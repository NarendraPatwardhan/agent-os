import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@mc/elements"; // registers <mc-sandbox>/<mc-terminal>/<mc-xterm>/<mc-editor>
import "./index.css"; // design-system reset + self-hosted faces (global)
import "@mc/elements/styles.css"; // standalone terminal + component chrome (no design-system base)
import App from "./App";
import { configureArtifactSources } from "./artifactSources";

// Resolve the current build's content-keyed kernel/image URLs before any custom
// element connects and begins booting a VM.
await configureArtifactSources();

const root = document.getElementById("root");

if (!root) {
  throw new Error("missing root element");
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
