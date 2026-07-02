import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@mc/elements"; // registers <mc-sandbox>/<mc-terminal>/<mc-xterm>/<mc-editor>
import "@mc/elements/styles.css"; // design-system base + terminal + component chrome
import App from "./App";

const root = document.getElementById("root");

if (!root) {
  throw new Error("missing root element");
}

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
