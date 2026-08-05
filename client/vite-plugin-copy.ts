/**
 * Resolving one locale's copy into the bundle, at build time.
 *
 * ## The bundle carries an object, not a lookup
 *
 * This plugin generates a virtual module holding the finished catalogue for the
 * locale being built, and `src/i18n/copy.ts` re-exports it. So a shipped bundle
 * contains one language as a plain object literal: no dictionary for another
 * language, no key lookup, no fallback branch, and nothing that could be asked
 * about a locale this build is not.
 *
 * ## Which is also what makes the development marker structurally absent
 *
 * A key the target locale has not translated renders the English string in a
 * production build and a conspicuous marker otherwise. The obvious way to write
 * that is a runtime branch on `import.meta.env.DEV`, which the bundler then
 * replaces and eliminates — but "eliminated by dead-code removal" is a property
 * of the optimiser rather than of this code, and a refactor reading the mode
 * from a variable would keep every module-level test passing while shipping the
 * marker to production.
 *
 * Here there is no branch to eliminate. The marker exists only if this file put
 * it in the generated source, and in production it never does. That makes the
 * generated source the honest thing to assert against, which is what
 * `copy.test.ts` does.
 *
 * ## English defines the key set
 *
 * Keys come from `en.json` and from nowhere else. A key the overlay adds and
 * English does not have is reported and dropped rather than rendered: a
 * translator working in a file that is not the source of truth should get told,
 * not silently obeyed, and a typo'd key would otherwise become a string only
 * one language can ever show. Reporting rather than failing is deliberate — a
 * translator's edit must never turn the build red.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { Plugin } from "vite";

export const VIRTUAL_ID = "virtual:hc-copy";

/** What resolving one locale against English produced. */
export interface Resolution {
  /** The finished catalogue: every English key, with this locale's value. */
  readonly entries: Record<string, string>;
  /** English keys this locale has not translated, sorted. */
  readonly untranslated: readonly string[];
  /** Keys the overlay names that English does not define, sorted. */
  readonly unknown: readonly string[];
}

/** How an untranslated key renders when the build is not a production one. */
export function marker(locale: string, key: string): string {
  return `⟦${locale}:${key}⟧`;
}

/**
 * Resolves one locale's catalogue against English.
 *
 * Pure, and takes both catalogues as data rather than reading them, so the
 * rules above are testable without a filesystem or a build.
 */
export function resolveCatalogue(
  english: Record<string, string>,
  overlay: Record<string, string>,
  options: { readonly locale: string; readonly production: boolean },
): Resolution {
  const entries: Record<string, string> = {};
  const untranslated: string[] = [];

  for (const [key, englishValue] of Object.entries(english)) {
    const translated = overlay[key];

    if (typeof translated === "string" && translated !== "") {
      entries[key] = translated;
    } else {
      untranslated.push(key);
      entries[key] = options.production ? englishValue : marker(options.locale, key);
    }
  }

  const unknown = Object.keys(overlay).filter((key) => !Object.hasOwn(english, key));

  return { entries, untranslated: untranslated.sort(), unknown: unknown.sort() };
}

/** Reads a flat key-to-string catalogue. */
function read(dir: string, file: string): Record<string, string> {
  return JSON.parse(readFileSync(join(dir, file), "utf8")) as Record<string, string>;
}

/**
 * Resolves the catalogue for `locale` from the JSON files in `dir`.
 *
 * The default locale is resolved against itself, so it is complete by
 * construction and reports nothing.
 */
export function resolveFromDir(
  dir: string,
  options: {
    readonly locale: string;
    readonly defaultLocale: string;
    readonly production: boolean;
  },
): Resolution {
  const english = read(dir, `${options.defaultLocale}.json`);
  const overlay =
    options.locale === options.defaultLocale
      ? english
      : read(dir, `${options.locale}.json`);

  return resolveCatalogue(english, overlay, {
    locale: options.locale,
    production: options.production,
  });
}

/**
 * Substitutes the shell's language and title.
 *
 * Pure and exported so it can be asserted directly: reaching it through the
 * plugin's `transformIndexHtml` hook means constructing a build, and the rule
 * being checked is a string substitution.
 */
export function stampShell(
  html: string,
  values: { readonly locale: string; readonly title: string },
): string {
  return html
    .replace("%HC_LOCALE%", values.locale)
    .replace("%HC_APP_TITLE%", values.title);
}

export interface CopyPluginOptions {
  /** Directory holding the per-locale JSON catalogues. */
  readonly dir: string;
  /** The locale this build produces. */
  readonly locale: string;
  /** The locale whose file defines the key set. */
  readonly defaultLocale: string;
  /** Called with what this build could not translate, for the CI report. */
  readonly onResolved?: (resolution: Resolution) => void;
}

/**
 * The Vite plugin: serves the virtual module and stamps the page shell.
 */
export function copyPlugin(options: CopyPluginOptions): Plugin {
  const resolvedId = `\0${VIRTUAL_ID}`;
  let production = false;

  return {
    name: "hc-copy",

    configResolved(config) {
      production = config.command === "build" && config.mode === "production";
    },

    resolveId(id) {
      return id === VIRTUAL_ID ? resolvedId : null;
    },

    load(id) {
      if (id !== resolvedId) return null;

      const resolution = resolveFromDir(options.dir, {
        locale: options.locale,
        defaultLocale: options.defaultLocale,
        production,
      });

      options.onResolved?.(resolution);

      return `export default ${JSON.stringify(resolution.entries)};`;
    },

    // The shell's language and title, correct on first paint. They are stamped
    // here rather than set by React because a screen reader and a browser's
    // translate prompt both read `lang` before any script runs, and a title
    // that arrives late shows the wrong one in the tab and in history.
    transformIndexHtml(html) {
      const resolution = resolveFromDir(options.dir, {
        locale: options.locale,
        defaultLocale: options.defaultLocale,
        production,
      });

      return stampShell(html, {
        locale: options.locale,
        title: resolution.entries["app.title"] ?? "",
      });
    },
  };
}
