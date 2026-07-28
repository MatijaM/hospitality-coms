/**
 * The peer channel against a real Phoenix server, over a real websocket.
 *
 * Skipped unless `HOSPITALITY_COMS_SESSION_TOKEN` and
 * `HOSPITALITY_COMS_PERSON_ID` are both set, exactly as
 * `src/socket/session-socket.integration.test.ts` is skipped without a token,
 * so `npm test` on a machine with no backend is still green.
 *
 * **It has been run, against a Postgres cluster of its own**, and all three
 * assertions passed.
 *
 * ## Why a separate cluster and not a throwaway database
 *
 * The obvious recipe — `createdb hospitality_coms_u12peers` on the machine's
 * usual cluster — is the one `CLAUDE.md`'s Database section warns about, and it
 * is worth restating because the failure lands somewhere else entirely.
 * Migrating any database grants privileges to `employer_role`; grants are
 * database-local while **roles are cluster-global**; so one grant anywhere on
 * the cluster makes `DROP ROLE employer_role` fail in `hospitality_coms_test`,
 * which `PostgresRolesTest` asserts on. A throwaway database breaks the Elixir
 * suite for as long as it exists, which is intolerable when somebody else is
 * running that suite.
 *
 * A **cluster** of its own does not, and that is the whole trick: `initdb` into
 * a temporary directory produces a postmaster with its own role namespace, so
 * `employer_role` there is a different role that happens to share a name. A
 * container image is the same idea with more moving parts; this needs no daemon
 * and the same `psql` that is already installed.
 *
 *     initdb -D /tmp/hc-peers/data -U postgres --auth=trust --locale=C
 *     LC_ALL=C pg_ctl -D /tmp/hc-peers/data -o "-p 55432" -l /tmp/hc-peers/log start
 *     createdb -h 127.0.0.1 -p 55432 -U postgres hospitality_coms_u12peers
 *
 * `LC_ALL=C` on both is not optional on macOS: without it `initdb` refuses the
 * locale outright, and the postmaster starts and then dies with "postmaster
 * became multithreaded during startup", which reads like a build problem.
 *
 * Afterwards, `pg_ctl stop` and delete the directory. Nothing needs revoking,
 * because nothing was granted anywhere that outlives it — measured, by counting
 * `pg_shdepend` rows for `employer_role` on the real cluster before and after
 * and finding the same 22, all of them `hospitality_coms_test`'s.
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
 *     export DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/hospitality_coms_u12peers
 *     export SECRET_KEY_BASE=$(mix phx.gen.secret)
 *     export MAGIC_LINK_BASE_URL=http://localhost:5173/log-in/
 *     export WEBSOCKET_ORIGINS=http://localhost:5173
 *     export PORT=4010 MIX_ENV=prod
 *     mix ecto.migrate
 *     PHX_SERVER=true mix phx.server &
 *
 *     # a person, their id, and a session token, minted directly:
 *     # `/dev/mailbox` is a dev-only route and this server is not in dev.
 *     #
 *     # The transaction is **required**, and this is the correction that
 *     # running it produced: `Accounts.register_person/2` inserts with
 *     # `mode: :savepoint`, which outside a transaction raises
 *     # `DBConnection.TransactionError: transaction is not started`. Every
 *     # ordinary caller reaches it from inside `request_magic_link/2`'s
 *     # transaction, so nothing had noticed.
 *     mix run -e '
 *       now = HospitalityComs.Clock.now()
 *       {:ok, {p, t}} = HospitalityComs.Repo.transaction(fn ->
 *         {:ok, p} = HospitalityComs.Accounts.register_person(%{email: "u12p@example.com"}, now)
 *         {p, HospitalityComs.Accounts.generate_person_session_token(p, now)}
 *       end)
 *       IO.puts(p.id)
 *       IO.puts(HospitalityComsWeb.PersonAuth.encode_token(t))'
 *
 *     HOSPITALITY_COMS_SOCKET_URL=ws://localhost:4010/socket/person \
 *       HOSPITALITY_COMS_PERSON_ID=<the first line> \
 *       HOSPITALITY_COMS_SESSION_TOKEN=<the second> npm run test:peers
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
