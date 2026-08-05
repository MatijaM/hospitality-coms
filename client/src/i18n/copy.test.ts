/**
 * How a locale's catalogue is resolved, and what a production build cannot
 * contain.
 *
 * Two things here are worth knowing before reading the assertions.
 *
 * **No fixture shares a string between locales.** Every English value below
 * differs from its translation and neither is a substring of the other. A
 * fixture where the two agree makes "the Serbian build renders Serbian", "the
 * English build renders English", and both fallback rows pass against a
 * resolver that ignores the locale entirely — all four green against a build
 * that does nothing. That is the failure this file is most exposed to.
 *
 * **The marker's absence is asserted against the generated source.** There is
 * no runtime branch to eliminate: `resolveCatalogue` either put a marker in the
 * object or it did not. So asserting on what it produced is asserting on what
 * the bundle contains, rather than on an optimiser's willingness to drop a
 * branch.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { marker, resolveCatalogue, stampShell } from "../../vite-plugin-copy";
import { copy } from "./copy";

const english = {
  greeting: "Good evening",
  farewell: "Goodnight",
  solo: "Only in English",
};
const serbian = { greeting: "Dobro veče", farewell: "Laku noć" };

function resolveSerbian(production: boolean) {
  return resolveCatalogue(english, serbian, { locale: "sr-Latn", production });
}

describe("resolving a locale against English", () => {
  it("takes the target locale's string when it has one", () => {
    expect(resolveSerbian(true).entries.greeting).toBe("Dobro veče");
  });

  it("takes English when the build is English", () => {
    const resolved = resolveCatalogue(english, english, {
      locale: "en",
      production: true,
    });

    expect(resolved.entries.greeting).toBe("Good evening");
    expect(resolved.untranslated).toEqual([]);
  });

  it("falls back to English for an untranslated key in a production build", () => {
    expect(resolveSerbian(true).entries.solo).toBe("Only in English");
  });

  it("renders a marker for the same key when the build is not production", () => {
    expect(resolveSerbian(false).entries.solo).toBe(marker("sr-Latn", "solo"));
  });

  it("names the untranslated key either way", () => {
    expect(resolveSerbian(true).untranslated).toEqual(["solo"]);
    expect(resolveSerbian(false).untranslated).toEqual(["solo"]);
  });

  it("treats an empty translation as untranslated rather than as an empty string", () => {
    const resolved = resolveCatalogue(
      english,
      { ...serbian, solo: "" },
      {
        locale: "sr-Latn",
        production: true,
      },
    );

    expect(resolved.entries.solo).toBe("Only in English");
    expect(resolved.untranslated).toEqual(["solo"]);
  });
});

describe("the production build cannot contain a marker", () => {
  it("puts no marker in any value", () => {
    const values = Object.values(resolveSerbian(true).entries);

    expect(values.some((value) => value.includes("⟦"))).toBe(false);
  });

  // The control. Without it, a resolver that returned an empty object would
  // satisfy the assertion above, and so would one that crashed before writing
  // anything.
  it("but a development build does, which is what makes that assertion mean something", () => {
    const values = Object.values(resolveSerbian(false).entries);

    expect(values.some((value) => value.includes("⟦"))).toBe(true);
  });
});

describe("English defines the key set", () => {
  it("drops a key the overlay adds and English does not define", () => {
    const resolved = resolveCatalogue(
      english,
      { ...serbian, invented: "Izmišljeno" },
      {
        locale: "sr-Latn",
        production: true,
      },
    );

    expect(Object.keys(resolved.entries)).not.toContain("invented");
  });

  it("reports that key rather than failing, so a translator cannot redden the build", () => {
    const resolved = resolveCatalogue(
      english,
      { ...serbian, invented: "Izmišljeno" },
      {
        locale: "sr-Latn",
        production: true,
      },
    );

    expect(resolved.unknown).toEqual(["invented"]);
  });

  it("answers every English key even when the overlay is empty", () => {
    const resolved = resolveCatalogue(
      english,
      {},
      { locale: "sr-Latn", production: true },
    );

    expect(Object.keys(resolved.entries).sort()).toEqual(Object.keys(english).sort());
    expect(resolved.untranslated).toEqual(Object.keys(english).sort());
  });
});

describe("the page shell", () => {
  const shell = `<html lang="%HC_LOCALE%"><title>%HC_APP_TITLE%</title></html>`;

  it("carries the built locale and title", () => {
    expect(
      stampShell(shell, { locale: "sr-Latn", title: "Ugostiteljske komunikacije" }),
    ).toBe(`<html lang="sr-Latn"><title>Ugostiteljske komunikacije</title></html>`);
  });

  it("carries a different locale and title for a different build", () => {
    expect(stampShell(shell, { locale: "en", title: "Hospitality Coms" })).toBe(
      `<html lang="en"><title>Hospitality Coms</title></html>`,
    );
  });

  it("leaves no placeholder behind", () => {
    const stamped = stampShell(shell, { locale: "en", title: "Hospitality Coms" });

    expect(stamped).not.toContain("%HC_");
  });
});

describe("the catalogue this build actually received", () => {
  // Proves the plugin is wired into the build rather than only being a
  // well-tested function nothing calls.
  it("is populated", () => {
    expect(Object.keys(copy).length).toBeGreaterThan(0);
  });

  it("answers every key the English catalogue defines", () => {
    const path = resolve(process.cwd(), "src/i18n/en.json");
    const source = JSON.parse(readFileSync(path, "utf8")) as Record<string, string>;

    expect(Object.keys(copy).sort()).toEqual(Object.keys(source).sort());
  });
});
