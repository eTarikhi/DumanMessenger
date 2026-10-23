import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Sandboxed previews (Arena's live preview, Gitpod, Codespaces, ...) proxy the
// dev server under a generated host name that Vite's DNS-rebinding guard
// rejects with "403 Blocked request. This host is not allowed". Opt in with
// ALLOW_ANY_DEV_HOST=1, which also binds all interfaces so the proxy can reach
// the server. Plain `npm run dev` keeps the localhost-only default.
const sandboxed = process.env.ALLOW_ANY_DEV_HOST === "1";

export default defineConfig({
  plugins: [react()],
  server: {
    host: sandboxed ? "0.0.0.0" : undefined,
    allowedHosts: sandboxed ? true : undefined,
  },
});
