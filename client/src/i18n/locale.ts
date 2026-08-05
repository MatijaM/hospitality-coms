/**
 * Which language this bundle was built in.
 *
 * There is exactly one, and it is decided at build time rather than resolved
 * here. `priv/locales.json` maps a domain to a locale; `vite.config.ts` reads
 * that file, picks the locale being built, and substitutes it below. Phoenix
 * then serves whichever bundle the request's host names.
 *
 * ## Why this file holds no host map
 *
 * It looks like the obvious place for one, and it would be dead weight. A
 * bundle only ever runs on the domain it was built for — the server chose it by
 * host before the browser received a byte — so resolving a host here would be
 * asking a question whose answer is already in the answer. The host map is
 * server-side, in `HospitalityComs.Locales`, and reaches this file only through
 * which value gets substituted.
 *
 * ## What can still drift, and what catches it
 *
 * The locale string below is also the directory name the build emits under
 * `priv/static`, and the server looks for a bundle by the same string. Those
 * two agreeing is the whole of what makes serving work, and nothing in the type
 * system holds it — a build emitting `sr_Latn` while the server resolves
 * `sr-Latn` produces a blank page and no error anywhere. `locale.test.ts`
 * requires this value to be a locale the artifact names, which is the half of
 * that this side can check.
 */

declare const __APP_LOCALE__: string;

/**
 * The locale this bundle was built in — one of the keys in `priv/locales.json`.
 */
export const ACTIVE_LOCALE: string = __APP_LOCALE__;
