/**
 * The shape of the module `vite-plugin-copy.ts` generates.
 *
 * Typed loosely on purpose: the precise key type comes from `en.json` in
 * `copy.ts`, which is the file that decides what a key is. Declaring the exact
 * shape twice would let the two disagree, and the one that matters is the one
 * the call sites see.
 */
declare module "virtual:hc-copy" {
  const entries: Record<string, string>;
  export default entries;
}
