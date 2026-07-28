/**
 * The one rule for turning a string into something this client will put in a
 * topic.
 *
 * ## Why it lives here now
 *
 * `features/rooms/room.ts` wrote it first and `features/peers/peer.ts` copied
 * it, deliberately: the rooms' file is the rooms', and duplicating twelve lines
 * was cheaper than coupling two surfaces that share nothing else. `peer.ts` said
 * where the line was — *"hoisting a uuid helper into `src/socket/` is the
 * alternative, and it belongs to whichever unit first has a third caller"* — and
 * the profile surface is that third caller, so this is that hoist rather than a
 * fourth copy.
 *
 * It sits in `src/socket/` and not in a `shared/` bucket because a topic suffix
 * is the only thing it is for. It knows no topic **name**, which is the property
 * `session-socket.ts` holds and the reason neither `"venue_room:"` nor
 * `"peer:"` nor `"profile:"` appears in this directory.
 *
 * ## The rule
 *
 * `HospitalityComsWeb.ChannelAuth.topic_id/1`'s: `byte_size(id) == 36` and then
 * `Ecto.UUID.cast/1`. The length check is load-bearing on that side rather than
 * a pre-filter — `cast/1` alone accepts sixteen raw bytes and encodes them — and
 * it is kept here so the two spell one rule.
 *
 * ## The lowercasing is load-bearing, and the cost differs per surface
 *
 * `Ecto.UUID.cast/1` accepts either case and Postgres stores one value, so a
 * suffix in the wrong case reaches the right rows and the join **succeeds**. But
 * `Phoenix.Channel.Server` subscribes a joined channel to the **literal topic
 * string**, and every `Phoenix.PubSub` broadcast in the application goes to the
 * lowercase one. So an uppercase suffix produces a channel that answers every
 * push it is asked and receives no announcement at any time, with nothing
 * refused and nothing logged.
 *
 * What that costs depends on what is behind the topic: a room in the wrong case
 * loses one room's fan-out, a `peer:` topic loses the whole peer surface's, and
 * a `profile:` topic loses nothing today because U9 has no announcement — which
 * is exactly the kind of "harmless for now" that stops being true the first time
 * somebody adds one. One rule, applied wherever a topic is built.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Whether a string is the id shape a topic suffix may carry.
 *
 * Checked here for the worker's benefit rather than the server's. The server
 * answers a malformed suffix with exactly what it answers an id that names
 * nothing, deliberately, so that a refusal enumerates nothing (AE1). That is
 * right for the server and useless to somebody who has just mistyped their own
 * paste, so this client tells them about their own input before it puts it on a
 * socket. It learns nothing by doing so: the value came from this browser.
 */
export function isTopicId(value: string): boolean {
  return value.length === 36 && UUID.test(value);
}

/** An id as this client will put it in a topic, or `null` if it is not one. */
export function normaliseTopicId(value: string): string | null {
  const trimmed = value.trim().toLowerCase();

  return isTopicId(trimmed) ? trimmed : null;
}
