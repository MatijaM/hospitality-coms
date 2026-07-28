/**
 * The peer channel against a real Phoenix server, over a real websocket.
 *
 * Skipped unless `HOSPITALITY_COMS_SESSION_TOKEN` and
 * `HOSPITALITY_COMS_PERSON_ID` are both set, exactly as
 * `src/socket/session-socket.integration.test.ts` is skipped without a token,
 * so `npm test` on a machine with no backend is still green.
 *
 * **It has not been run.** It is written and left opt-in deliberately, and the
 * reason is in `CLAUDE.md`'s Database section rather than in laziness: a server
 * needs a database, migrating one grants privileges to `employer_role`, grants
 * are database-local while **roles are cluster-global**, and one grant anywhere
 * on the cluster makes `DROP ROLE employer_role` fail in `hospitality_coms_test`
 * — which `PostgresRolesTest` asserts on. Standing a throwaway database up
 * breaks the Elixir suite for as long as it exists. Run this when nothing else
 * is running against the cluster, and drop the database afterwards.
 *
 * ## What only this file can settle
 *
 * `peers.test.tsx` drives the surface against a fake that this project also
 * wrote, so it proves the client is consistent with **this project's reading**
 * of `PeerChannel`. The reading is taken from the source and two of the key
 * sets are pinned on the other side by `peer_channel_test.exs`, but three
 * things are still only checkable here:
 *
 *   * that `peer:<person_id>` is routed by `PersonSocket` at all, and that the
 *     suffix is the person rather than anything else — the room surfaces found
 *     the endpoint path this way, and it was a guess that was wrong;
 *   * that a topic naming **somebody else's** person id is refused, which is
 *     `admitted/3`'s repeated variable doing its job;
 *   * that the three list events answer in the shapes `decode.ts` expects,
 *     against real JSON serialisation rather than against object literals —
 *     `state` in particular is an `Ecto.Enum` atom on the Elixir side and this
 *     client narrows it as a string.
 *
 * ## Getting the two variables
 *
 *     createdb -U postgres hospitality_coms_u12peers
 *     export DATABASE_URL=ecto://postgres:postgres@localhost/hospitality_coms_u12peers
 *     export SECRET_KEY_BASE=$(mix phx.gen.secret)
 *     export MAGIC_LINK_BASE_URL=http://localhost:5173/log-in/
 *     export WEBSOCKET_ORIGINS=http://localhost:5173
 *     MIX_ENV=prod mix ecto.migrate
 *     MIX_ENV=prod PHX_SERVER=true mix phx.server &
 *
 *     # a person, their id, and a session token, minted directly:
 *     # `/dev/mailbox` is a dev-only route and this server is not in dev.
 *     MIX_ENV=prod mix run -e '
 *       now = HospitalityComs.Clock.now()
 *       {:ok, p} = HospitalityComs.Accounts.register_person(%{email: "u12p@example.com"}, now)
 *       IO.puts(p.id)
 *       IO.puts(HospitalityComsWeb.PersonAuth.encode_token(
 *         HospitalityComs.Accounts.generate_person_session_token(p, now)))'
 *
 *     HOSPITALITY_COMS_PERSON_ID=<the first line> \
 *       HOSPITALITY_COMS_SESSION_TOKEN=<the second> npm run test:peers
 *
 *     # afterwards, and this part is not optional
 *     dropdb -U postgres hospitality_coms_u12peers
 *     psql -U postgres -c "select count(*) from pg_shdepend"   # and check the roles
 *
 * A person with no engagements is enough for every assertion here: the lists
 * come back empty and the shapes are still the shapes. Seeding a co-rostered
 * pair takes a venue, a grant, an invitation and a claim, none of which has an
 * HTTP surface, and `peers_test.exs` already proves what a populated list holds.
 */

import { describe, expect, it, vi } from "vitest";

import { createSessionSocket } from "../../socket/session-socket";
import { decodeChannelRefusal } from "../../socket/channel-failure";
import {
  decodeConversations,
  decodeJoinedPersonId,
  decodePeerRequests,
  decodePeers,
} from "./decode";
import { peerTopic } from "./peer";
import { PEER_ERROR_CODES } from "./refusal-message";

const socketUrl =
  process.env.HOSPITALITY_COMS_SOCKET_URL ?? "ws://localhost:4000/socket/person";
const token = process.env.HOSPITALITY_COMS_SESSION_TOKEN ?? "";
const personId = process.env.HOSPITALITY_COMS_PERSON_ID ?? "";

/** A person this session is certainly not. The refusal enumerates nothing. */
const SOMEBODY_ELSE = "0f9a1d2e-0000-4000-8000-00000000dead";

describe.skipIf(token === "" || personId === "")("against a running server", () => {
  it("joins its own peer topic and answers the three lists it renders", async () => {
    const onJoined = vi.fn();
    const onRefused = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    const peer = socket.join(peerTopic(personId), { onJoined, onRefused });

    await vi.waitFor(() => {
      expect(onJoined).toHaveBeenCalled();
    }, 10_000);

    expect(onRefused).not.toHaveBeenCalled();
    expect(decodeJoinedPersonId(onJoined.mock.calls[0]?.[0])).toBe(personId);

    const peers = await peer.push("list_peers", {});
    expect(peers.status).toBe("ok");
    expect(decodePeers(peers.status === "ok" ? peers.payload : null)).toEqual([]);

    const requests = await peer.push("list_requests", {});
    expect(requests.status).toBe("ok");
    expect(
      decodePeerRequests(requests.status === "ok" ? requests.payload : null),
    ).toEqual({
      incoming: [],
      outgoing: [],
    });

    const conversations = await peer.push("list_conversations", {});
    expect(conversations.status).toBe("ok");
    expect(
      decodeConversations(conversations.status === "ok" ? conversations.payload : null),
    ).toEqual([]);

    socket.disconnect();
  }, 30_000);

  it("is refused somebody else's peer topic, and does not retry into it", async () => {
    // `admitted/3` matches the suffix against the joining scope's own person
    // with a repeated variable, so a topic naming anybody else has no clause.
    const onRefused = vi.fn();
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    socket.join(peerTopic(SOMEBODY_ELSE), { onJoined, onRefused });

    await vi.waitFor(() => {
      expect(onRefused).toHaveBeenCalled();
    }, 10_000);

    expect(onJoined).not.toHaveBeenCalled();
    expect(decodeChannelRefusal(onRefused.mock.calls[0]?.[0], PEER_ERROR_CODES)).toEqual({
      kind: "channel_error",
      code: "unauthorized",
      rawCode: "unauthorized",
      message: expect.any(String) as string,
    });

    // Four seconds spans `phoenix`'s first two rejoin ticks (1s, 2s). The
    // margins are pinned to `rejoinAfterMs` being `[1000, 2000, 5000]`, exactly
    // as `session-socket.integration.test.ts` records.
    await new Promise((resolve) => setTimeout(resolve, 4_000));
    expect(onRefused).toHaveBeenCalledOnce();

    socket.disconnect();
  }, 30_000);

  it("answers an id that names nothing the way it answers one that is not yours", async () => {
    // AE1 at the transport, against the real `resolved/3`: a malformed id and
    // an unknown one are folded together before a context is reached, so a
    // caller cannot tell them apart by which answer they got.
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    const peer = socket.join(peerTopic(personId), { onJoined });

    await vi.waitFor(() => {
      expect(onJoined).toHaveBeenCalled();
    }, 10_000);

    const unknown = await peer.push("history", { connection_id: SOMEBODY_ELSE });
    const malformed = await peer.push("history", { connection_id: "not-a-uuid" });

    expect(unknown.status).toBe("error");
    expect(malformed.status).toBe("error");
    expect(
      decodeChannelRefusal(
        unknown.status === "error" ? unknown.payload : null,
        PEER_ERROR_CODES,
      ),
    ).toEqual(
      decodeChannelRefusal(
        malformed.status === "error" ? malformed.payload : null,
        PEER_ERROR_CODES,
      ),
    );

    socket.disconnect();
  }, 30_000);
});
