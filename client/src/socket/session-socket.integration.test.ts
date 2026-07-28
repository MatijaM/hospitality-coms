/**
 * The socket against a real Phoenix server, over a real websocket.
 *
 * Skipped unless `HOSPITALITY_COMS_SESSION_TOKEN` is set, exactly as
 * `src/api/client.integration.test.ts` is skipped without
 * `HOSPITALITY_COMS_API_URL`, so `npm test` on a machine with no backend is
 * still green.
 *
 * It is the only test here that checks this client's idea of the **transport**
 * against the transport rather than against a fake this project also wrote —
 * the topic prefixes, the credential's route onto the connection, and the shape
 * of a refusal. Run it whenever `PersonSocket`, `ChannelAuth`, either room
 * channel or `ErrorEnvelope` changes.
 *
 * ## The one thing only this file can prove
 *
 * `rooms.test.tsx` shows the client leaves a refused topic and that the fake's
 * join count then stays at one. The fake's rejoin is a model of `phoenix`'s,
 * and a model can be wrong. Here the timer is `phoenix`'s own and the refusal
 * is a real `join/3` answering a real query, so "the callback fired once and
 * then nothing happened for four seconds" is the retry loop's absence measured
 * rather than modelled — `Channel`'s default `rejoinAfterMs` is 1s, 2s, 5s,
 * so four seconds spans two rejoins that a looping client would have made.
 *
 * **Those margins are pinned to `phoenix`'s current backoff table, and nothing
 * checks that.** `rejoinAfterMs` is `[1000, 2000, 5000]` in 1.8.9; a future
 * version that started at, say, 5s would make the four-second window span no
 * rejoin at all and the six-second control span one, and both assertions would
 * keep passing while measuring nothing. Compounding it, this file is opt-in and
 * outside `npm test`, so a `phoenix` upgrade will not trip it — the numbers
 * here are a thing to re-check when the dependency moves, not a thing that will
 * announce itself.
 *
 * ## Getting the two variables
 *
 * The server needs a database, and the repository's own `CLAUDE.md` is
 * emphatic that migrating `hospitality_coms_dev` breaks `DROP ROLE
 * employer_role` in `hospitality_coms_test` — grants are database-local while
 * roles are cluster-global.
 *
 * **A throwaway *database* is not enough**, which this file used to say it was.
 * Any migrated database on the cluster grants `employer_role` and breaks that
 * `DROP ROLE` everywhere on it for as long as the database exists. What works
 * is a throwaway **cluster**: `initdb` into a temporary directory has its own
 * role namespace, so nothing it grants is visible to the real one. The full
 * recipe, including the `LC_ALL=C` that macOS needs and the correction to the
 * token-minting snippet below, is in
 * `src/features/peers/peers.integration.test.ts`, which was run that way.
 *
 *     initdb -D /tmp/hc/data -U postgres --auth=trust --locale=C
 *     LC_ALL=C pg_ctl -D /tmp/hc/data -o "-p 55432" -l /tmp/hc/log start
 *     createdb -h 127.0.0.1 -p 55432 -U postgres hospitality_coms_u12
 *     export DATABASE_URL=ecto://postgres:postgres@127.0.0.1:55432/hospitality_coms_u12
 *     export SECRET_KEY_BASE=$(mix phx.gen.secret)
 *     export MAGIC_LINK_BASE_URL=http://localhost:5173/log-in/
 *     export WEBSOCKET_ORIGINS=http://localhost:5173
 *     export PORT=4010 MIX_ENV=prod
 *     mix ecto.migrate
 *     PHX_SERVER=true mix phx.server &
 *
 *     # a person and a session token, minted directly: `/dev/mailbox` is a
 *     # dev-only route and this server is not in dev.
 *     #
 *     # The transaction is **required** and this snippet did not have it:
 *     # `register_person/2` inserts with `mode: :savepoint`, which outside a
 *     # transaction raises `DBConnection.TransactionError`. Every ordinary
 *     # caller reaches it from inside `request_magic_link/2`'s transaction.
 *     mix run -e '
 *       now = HospitalityComs.Clock.now()
 *       {:ok, {_p, t}} = HospitalityComs.Repo.transaction(fn ->
 *         {:ok, p} = HospitalityComs.Accounts.register_person(%{email: "u12@example.com"}, now)
 *         {p, HospitalityComs.Accounts.generate_person_session_token(p, now)}
 *       end)
 *       IO.puts(HospitalityComsWeb.PersonAuth.encode_token(t))'
 *
 *     HOSPITALITY_COMS_SOCKET_URL=ws://localhost:4010/socket/person \
 *       HOSPITALITY_COMS_SESSION_TOKEN=<that> npm run test:socket
 *
 *     # afterwards, and this part is not optional
 *     LC_ALL=C pg_ctl -D /tmp/hc/data -m immediate stop && rm -rf /tmp/hc
 */

import { describe, expect, it, vi } from "vitest";
import { Socket } from "phoenix";

import { createSessionSocket } from "./session-socket";
import { decodeChannelRefusal } from "./channel-failure";
import { decodeJoinedEngagementId, decodeRoomMessage } from "../features/rooms/decode";
import { ROOM_ERROR_CODES } from "../features/rooms/refusal-message";

const socketUrl =
  process.env.HOSPITALITY_COMS_SOCKET_URL ?? "ws://localhost:4000/socket/person";
const token = process.env.HOSPITALITY_COMS_SESSION_TOKEN ?? "";

/**
 * A venue this session holds an active engagement at, if one was seeded.
 *
 * Optional, because it takes a venue, a grant, an invitation and a claim to
 * produce one and none of those has an HTTP surface. The block that uses it
 * skips without it; the refusal blocks above need nothing but a token.
 */
const venueId = process.env.HOSPITALITY_COMS_VENUE_ID ?? "";

/** A room this session is certainly not in. The refusal enumerates nothing. */
const UNREACHABLE = "0f9a1d2e-0000-4000-8000-00000000dead";

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

describe.skipIf(token === "")("against a running server", () => {
  it("puts the token on the connection and never in the URL", () => {
    // `Socket.endPointURL()` is `appendParams(appendParams(endPoint, params()),
    // {vsn})`. Asserted against the real library rather than against this
    // project's own type, because the regression it guards is a live bearer
    // credential in every access log on the path.
    const url = new Socket(socketUrl, { authToken: token }).endPointURL();

    expect(url).not.toContain(token);
    expect(url).toContain("/socket/person/websocket");
  });

  it("connects, is refused a room it is not in, and does not retry into it", async () => {
    const onRefused = vi.fn();
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    socket.join(`venue_room:${UNREACHABLE}`, { onJoined, onRefused });

    // `join/3` re-derives the session and then the membership, so the refusal
    // is two real queries rather than a routing answer.
    await vi.waitFor(() => {
      expect(onRefused).toHaveBeenCalled();
    }, 10_000);

    expect(onJoined).not.toHaveBeenCalled();
    expect(decodeChannelRefusal(onRefused.mock.calls[0]?.[0], ROOM_ERROR_CODES)).toEqual({
      kind: "channel_error",
      code: "unauthorized",
      rawCode: "unauthorized",
      message: expect.any(String) as string,
    });

    // Four seconds spans `phoenix`'s first two rejoin ticks (1s, 2s). A client
    // that waited the refusal out would have asked twice more by now and this
    // callback would have fired again each time.
    await wait(4_000);

    expect(onRefused).toHaveBeenCalledOnce();

    socket.disconnect();
  }, 20_000);

  it("control: `phoenix` really does retry a refused join, when nothing leaves it", async () => {
    // The live counterpart of `rooms.test.tsx`'s control, and the reason the
    // assertion above is worth making. Straight `phoenix`, no wrapper: the
    // rejoin timer fires at 1s, 2s and 5s, `Push.reset()` keeps `recHooks`, and
    // the same refusal is delivered again on every tick — a socket hammering a
    // server that decided once. Measured at three refusals in six seconds.
    const socket = new Socket(socketUrl, { authToken: token });
    let refusals = 0;

    socket.connect();
    socket
      .channel(`venue_room:${UNREACHABLE}`)
      .join()
      .receive("error", () => {
        refusals += 1;
      });

    await wait(6_000);

    expect(refusals).toBeGreaterThan(1);

    socket.disconnect();
  }, 20_000);

  it("routes a shift room on its own topic, refused the same way", async () => {
    // The two prefixes are separate entries in `PersonSocket`'s routing table.
    // A topic no socket routes is refused by `phoenix` with
    // `%{reason: "unmatched topic"}`, which decodes as `malformed_refusal` —
    // so this also proves the prefix is the one that exists.
    const onRefused = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    socket.join(`shift_room:${UNREACHABLE}`, { onRefused });

    await vi.waitFor(() => {
      expect(onRefused).toHaveBeenCalled();
    }, 10_000);

    expect(
      decodeChannelRefusal(onRefused.mock.calls[0]?.[0], ROOM_ERROR_CODES),
    ).toMatchObject({
      kind: "channel_error",
      code: "unauthorized",
    });

    socket.disconnect();
  }, 20_000);

  it("refuses a topic suffix that is not an id the same way it refuses an unknown room", async () => {
    // AE1 through `ChannelAuth.topic_id/1`. Before U7 added it this raised
    // `Ecto.Query.CastError` out of `join/3` and the transport reported a
    // crash, which told a caller their input was *shaped* wrong.
    const onRefused = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    socket.connect();
    socket.join("venue_room:not-an-id", { onRefused });

    await vi.waitFor(() => {
      expect(onRefused).toHaveBeenCalled();
    }, 10_000);

    expect(
      decodeChannelRefusal(onRefused.mock.calls[0]?.[0], ROOM_ERROR_CODES),
    ).toMatchObject({
      kind: "channel_error",
      code: "unauthorized",
    });

    socket.disconnect();
  }, 20_000);
});

describe.skipIf(token === "" || venueId === "")("a room this session is in", () => {
  it("joins, sends, and gets the message back on the broadcast", async () => {
    // The whole contract in one pass: the join reply's `engagement_id`, the
    // `"send"` event name, the reply, and `broadcast!/3` reaching the sender's
    // own channel — which is why `use-room.ts` keys on the message id.
    const messages: unknown[] = [];
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });

    const room = socket.join(`venue_room:${venueId}`, {
      onJoined,
      events: {
        message: (payload) => {
          messages.push(payload);
        },
      },
    });

    socket.connect();

    await vi.waitFor(() => {
      expect(onJoined).toHaveBeenCalled();
    }, 10_000);

    expect(decodeJoinedEngagementId(onJoined.mock.calls[0]?.[0])).toMatch(
      /^[0-9a-f-]{36}$/,
    );

    const outcome = await room.push("send", { body: "table four is ready" });

    expect(outcome.status).toBe("ok");
    expect(
      outcome.status === "ok" ? decodeRoomMessage(outcome.payload) : null,
    ).toMatchObject({
      body: "table four is ready",
    });

    await vi.waitFor(() => {
      expect(messages).toHaveLength(1);
    }, 5_000);

    expect(decodeRoomMessage(messages[0])).toMatchObject({ body: "table four is ready" });

    socket.disconnect();
  }, 30_000);

  it("refuses an empty body with the envelope, naming the field", async () => {
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });
    const room = socket.join(`venue_room:${venueId}`, { onJoined });

    socket.connect();

    await vi.waitFor(() => {
      expect(onJoined).toHaveBeenCalled();
    }, 10_000);

    const outcome = await room.push("send", { body: "" });

    expect(outcome.status).toBe("error");
    expect(
      decodeChannelRefusal(
        outcome.status === "error" ? outcome.payload : null,
        ROOM_ERROR_CODES,
      ),
    ).toMatchObject({
      kind: "channel_field_error",
      code: "unprocessable_entity",
      fields: { body: expect.any(Array) as string[] },
    });

    socket.disconnect();
  }, 30_000);

  it("answers an event neither channel handles, rather than crashing the channel", async () => {
    const onJoined = vi.fn();
    const socket = createSessionSocket({ endpoint: socketUrl, token });
    const room = socket.join(`venue_room:${venueId}`, { onJoined });

    socket.connect();

    await vi.waitFor(() => {
      expect(onJoined).toHaveBeenCalled();
    }, 10_000);

    const outcome = await room.push("nonsense", {});

    expect(
      decodeChannelRefusal(
        outcome.status === "error" ? outcome.payload : null,
        ROOM_ERROR_CODES,
      ),
    ).toMatchObject({ kind: "channel_error", code: "bad_request" });

    socket.disconnect();
  }, 30_000);
});
