import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// The API lives on a different origin during development: Phoenix on 4000,
// this client on 5173. The endpoint mounts no CORS plug — it never needed one,
// because until now nothing but tests spoke to it — so the dev server proxies
// `/api` instead of the client asking the browser to make a cross-origin
// request that Phoenix would answer without the headers to permit it.
//
// The consequence is that `VITE_API_BASE_URL` is empty in development and every
// request is same-origin. A deployment that serves the client from another
// origin has to set that variable *and* the backend has to grow CORS; that is
// a backend change, so it is not made here.
const apiProxyTarget = process.env.VITE_DEV_API_PROXY ?? "http://localhost:4000";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": { target: apiProxyTarget, changeOrigin: false },
      // U7 mounts two sockets under this prefix — `/socket/person` and
      // `/socket/employer` (KTD9) — and nothing at `/socket` itself. The
      // prefix covers both. `ws: true` is what makes the upgrade proxy rather
      // than 404 on the handshake.
      "/socket": { target: apiProxyTarget, changeOrigin: false, ws: true },
    },
  },
  test: {
    environment: "jsdom",
    globals: false,
    setupFiles: ["./vitest.setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
