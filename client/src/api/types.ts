/**
 * The values the four endpoints that exist today put on the wire.
 *
 * Nothing here is inferred from a schema or a code generator. The backend is
 * Elixir and publishes no OpenAPI document, so these types are a hand-written
 * restatement of `HospitalityComsWeb.SessionController`'s render functions and
 * are only as true as the tests that pin them.
 */

/**
 * A person, as `SessionController.render_person/1` writes them.
 *
 * `email` is nullable because erasure nulls the address and nothing else may:
 * `people.email` is nullable in the schema, its unique index is partial on
 * `WHERE erased_at IS NULL`, and two check constraints hold the two columns in
 * opposition. An erased person still has a session and still has an id, so a
 * client that types the address as a plain string is wrong about a row the
 * database can produce.
 */
export type Person = {
  readonly id: string;
  readonly email: string | null;
};

/**
 * What redeeming a magic link yields: the bearer credential and its owner.
 *
 * The token is base64url text and is the session — a row in `people_tokens`,
 * stored there as a SHA-256 digest. Deleting that row ends the session on the
 * next request, so this string is not a claim to be validated offline and
 * there is nothing in it to decode.
 */
export type Session = {
  readonly token: string;
  readonly person: Person;
};

/**
 * How much of a bounded list to ask for. The whole of this API's paging
 * vocabulary.
 *
 * The server takes a **word**, never a number: both bounds —
 * `HospitalityComs.Rooms.recent_message_limit/0` and
 * `recent_shift_room_limit/0` — live in their context, so that the unbounded
 * read is not one forgetful caller away. This client does not know what
 * `"recent"` amounts to on either route and must not try to.
 *
 * It is one declaration rather than two because `HospitalityComsWeb.Extent` is
 * one module for both callers on the server, and for issue #42's reason: two
 * declarations of one two-member union is a pair held together by nothing.
 * `features/rooms/room.ts` re-exports it as `HistoryExtent`, which is what the
 * room surface calls it.
 */
export type ListExtent = "recent" | "all";
