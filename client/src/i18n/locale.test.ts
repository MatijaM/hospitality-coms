/**
 * The build's locale, and the one thing this side can check about it.
 *
 * `ACTIVE_LOCALE` becomes the directory name the build emits under
 * `priv/static`, and `HospitalityComs.Locales` looks a bundle up by the same
 * string. Nothing in either language's type system holds those together, and
 * the failure is silent: a build emitting `sr_Latn` against a server resolving
 * `sr-Latn` serves nothing and logs nothing.
 *
 * So this file reads `priv/locales.json` directly — the same artifact the
 * server compiles against — and requires the built locale to be one of its
 * keys. That is the half of the agreement observable from here; the other half
 * is `HospitalityComs.LocalesTest`, which requires the server's table to match
 * the same file.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { ACTIVE_LOCALE } from "./locale";

interface LocalesArtifact {
  readonly default: string;
  readonly locales: Record<string, { readonly hosts: readonly string[] }>;
}

function artifact(): LocalesArtifact {
  // Resolved from the working directory rather than from `import.meta.url`:
  // vitest's transform does not give this module a `file:` URL, and the suite
  // always runs from `client/`, which is where `npm test` puts it.
  const path = resolve(process.cwd(), "../priv/locales.json");

  return JSON.parse(readFileSync(path, "utf8")) as LocalesArtifact;
}

describe("ACTIVE_LOCALE", () => {
  it("is substituted at build time rather than left undefined", () => {
    expect(typeof ACTIVE_LOCALE).toBe("string");
    expect(ACTIVE_LOCALE).not.toBe("");
  });

  it("is a locale the shared artifact names", () => {
    expect(Object.keys(artifact().locales)).toContain(ACTIVE_LOCALE);
  });

  it("is the artifact's default when the build did not ask for one", () => {
    // The suite runs without `LOCALE` set, so this pins the default path — the
    // one every `npm run dev` and bare `npm run build` takes.
    expect(ACTIVE_LOCALE).toBe(artifact().default);
  });
});

describe("the shared artifact", () => {
  it("names at least two locales, so the build has something to choose between", () => {
    expect(Object.keys(artifact().locales).length).toBeGreaterThanOrEqual(2);
  });

  it("gives every locale at least one host", () => {
    for (const [locale, entry] of Object.entries(artifact().locales)) {
      expect(entry.hosts.length, `${locale} names no host`).toBeGreaterThan(0);
    }
  });

  it("names its own default among its locales", () => {
    expect(Object.keys(artifact().locales)).toContain(artifact().default);
  });
});
