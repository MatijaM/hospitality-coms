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
