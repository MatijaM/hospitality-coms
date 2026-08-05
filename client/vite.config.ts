import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

// Which language this build produces, and where that answer comes from.
//
// `priv/locales.json` is the one place the domain-to-locale rule is written
// down. `HospitalityComs.Locales` reads it at compile time on the server; this
// reads the same file so the two cannot disagree about which locales exist or
// what they are called. That last part is load-bearing and unprotected by any
// type: the locale string below becomes the directory name under
// `priv/static`, and the server looks a bundle up by the same string, so a
// build emitting `sr_Latn` against a server resolving `sr-Latn` is a blank page
// with nothing in any log.
//
// `LOCALE` selects the build. Unset, it is the artifact's default, which is
// what makes `npm run dev` and a bare `npm run build` behave as they always
// have. A value the artifact does not name is refused here rather than
// producing a bundle nothing will ever serve.
const localesArtifact = fileURLToPath(new URL("../priv/locales.json", import.meta.url));

interface LocalesArtifact {
  readonly default: string;
  readonly locales: Record<string, { readonly hosts: readonly string[] }>;
}

function activeLocale(): string {
  const artifact = JSON.parse(readFileSync(localesArtifact, "utf8")) as LocalesArtifact;
  const requested = process.env.LOCALE ?? artifact.default;

  if (!Object.hasOwn(artifact.locales, requested)) {
    throw new Error(
      `LOCALE=${requested} is not one of ${Object.keys(artifact.locales).join(", ")} in priv/locales.json`,
    );
  }

  return requested;
}

const locale = activeLocale();

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
  // Substituted rather than read from the environment at runtime, so the
  // shipped bundle carries one language and no way to be asked about another.
  define: { __APP_LOCALE__: JSON.stringify(locale) },
  build: { outDir: `dist/${locale}` },
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
