/**
 * How much of a uuid is put in front of a person, when something has to be.
 *
 * ## Why it is here and not in a feature directory
 *
 * `features/peers/peer.ts` and `features/profile/profile.ts` each declared this
 * with the same body and the same docstring, which is the duplication
 * `src/app/instant.ts` and `src/app/shift-room.ts` exist to have paid off —
 * *"the entity moved on its second caller and the first delegates"*. It was
 * already at two callers when the rooms surface became the third, so it moved
 * here and both delegate. Those re-exports are shims and not a second home: a
 * new caller imports from here.
 *
 * ## What it is for, which is not the same in all three places
 *
 * In `peers` and `profile` there is **no name on the wire** at all, so eight
 * characters is the whole of what a row can be called. On the rooms surface
 * there usually is one, and this is the last resort for the row that has none —
 * see `roomFallbackLabel`.
 *
 * Eight characters is not an identifier and must not be treated as one. It is
 * short enough to read aloud and long enough to tell two rows apart, which is
 * the only job it has; nothing casts it back to a uuid and nothing looks a row
 * up by it.
 */
export function shortId(id: string): string {
  return id.slice(0, 8);
}
