/**
 * Every string this application shows a person, in the language it was built
 * in.
 *
 * ## One object, resolved before the bundle existed
 *
 * `copy` is a plain object literal by the time a browser sees it. The build
 * read `en.json` and this locale's overlay, resolved one against the other, and
 * emitted the result — so there is no dictionary for another language in here,
 * no lookup, and no fallback to take at runtime. `vite-plugin-copy.ts` carries
 * the reasoning.
 *
 * ## The type comes from English, and the import that gives it is erased
 *
 * `en.json` defines the key set, so it also defines the type: a key that is not
 * in that file is a compile error at the call site rather than `undefined` on
 * screen. The import below is `import type`, which `verbatimModuleSyntax`
 * guarantees is erased — the English catalogue itself never reaches the bundle
 * of another language.
 *
 * ## Using it
 *
 * Import `copy` and index it with a literal key. Do not build a key by
 * concatenation: it defeats the typing, and it hides the string from the check
 * that keeps user-facing text out of components.
 *
 *     import { copy } from "../../i18n/copy";
 *
 *     <h1>{copy["logIn.heading"]}</h1>
 */

import type english from "./en.json";
import resolved from "virtual:hc-copy";

/** The keys every locale's catalogue is required to answer. */
export type CopyKey = keyof typeof english;

/**
 * This build's copy, one entry per key `en.json` defines.
 *
 * The generated module is declared as an open `Record<string, string>`, because
 * a `.d.ts` cannot name `en.json`'s type without restating it — and a key set
 * written down twice is one that comes to disagree. The narrowing below is
 * therefore an assertion rather than something the compiler derived.
 *
 * What backs it is not optimism. `resolveCatalogue` builds its result by
 * iterating English's own keys, so every key is present by construction, and
 * `copy.test.ts` compares the shipped object's key set against `en.json` read
 * from disk. If the plugin ever stopped answering a key, that test fails rather
 * than this assertion quietly lying.
 */
export const copy = resolved as Readonly<Record<CopyKey, string>>;
