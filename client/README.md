# client

The React client for hospitality-coms. U12 is being built in slices — the plan's
own note says it "is the coarsest unit in the plan and will likely split during
execution once the surface count is real" — and three have landed: the
**foundation** (toolchain, typed API client, log-in), the **room surfaces**
(U7's venue and shift rooms, the composer, the revocation) and the **peer
surfaces** (U8's directory, the request state machine, 1:1 conversations,
disconnect). U9–U11's surfaces are still absent, and the table at the bottom
says what each is waiting on.

## Why a separate directory and not the asset pipeline

The backend has been API-only since U2 removed the HTML layer. There is no
`assets/`, no LiveView, no `.heex`, no esbuild or tailwind in `mix.exs`, and no
`Plug.Static`. There is nothing for a Phoenix asset pipeline to hang off, so the
client is its own project with its own toolchain and its own lockfile, and it
talks to Phoenix over HTTP like any other consumer would.

## The stack, and why each piece

Chosen to be boring. Every one of these is the default answer to its question in
2026, which matters more here than any individual merit: the next unit should
recognise the project without reading this file.

| Piece                                                    | Why                                                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Vite 8**                                               | Dev server, build, and the `/api` proxy that removes the need for CORS. One tool, three jobs.              |
| **React 19**                                             | The plan says React and names React Native as a later target.                                              |
| **TypeScript 5.9**                                       | Pinned below 7.0 deliberately — see below.                                                                 |
| **react-router 8**, declarative mode                     | Four routes. The data-router API buys loaders and actions that a four-route app has nothing to do with.    |
| **Vitest 4 + Testing Library + jsdom**                   | Vitest shares Vite's transform, so there is one config and no second build.                                |
| **ESLint 10 + typescript-eslint (strict, type-checked)** | Type-aware linting is what makes the discriminated-union rules below enforceable rather than aspirational. |
| **Prettier 3**                                           | Formatting is not a discussion. `mix format` has the same job on the other side.                           |

**TypeScript is 5.9 and not 7.0.** TypeScript 7 (the native compiler) is
released, and typescript-eslint 8 declares a peer range of `<6.1.0`. Taking 7.0
means losing type-aware linting, which is where most of this project's standards
are actually enforced. Revisit when typescript-eslint ships a 7-compatible major.

**No request-mocking library.** The API client takes its `fetch` as an argument,
so the test seam is a parameter rather than an interceptor. Nothing needs MSW,
nock, or a service worker.

**No schema-validation library, and this is where that was re-decided.** The
peer surface added eight more shapes — four rendered entities, three list
replies and a push whose instant is keyed differently from the reply's — which
is roughly triple what the rooms needed. It was still hand-written, and the
reason is the last of those: `decode.ts` has **two** message decoders, one for
`sent_at` and one for `at`, and a schema library would have made the natural
move a single schema with an optional pair of keys, which also accepts a payload
carrying neither. The decoders are where a contract this client does not own is
written down; the point is not brevity. U9 is the next place to ask, and the
number to watch is how many shapes share a decoder rather than how many exist.

**No state manager and no component library.** The room list, the open room and
the composer are three `useState`s and a store behind an interface; a store
library would be more code than the thing it manages. The peer surface is one
hook holding six pieces of state, all of them the server's answers rather than
anything derived, which is the shape a store library would have added ceremony
to and not simplified. The rooms did not need a design system either, and the
next unit to add a surface with real visual demands is the one that should
choose one.

## Running it against Phoenix

```bash
# terminal 1, in the repo root
mix ecto.setup
mix phx.server                    # :4000

# terminal 2, here
npm install
npm run dev                       # :5173
```

Then open <http://localhost:5173>, enter an address, and read the link at
<http://localhost:4000/dev/mailbox>. In development that mailbox is the only
place a magic link exists — nothing renders one, and no mail leaves the machine.

The link points at `http://localhost:4000/log-in/<token>`, which is Phoenix and
serves no page, so **paste the whole link into the box under the form**. It
takes the link or the bare token. If you set `MAGIC_LINK_BASE_URL` to
`http://localhost:5173/log-in/` the link becomes clickable and lands on
`/log-in/:linkToken`, which redeems it on arrival.

To reach a room you need its id, because nothing serves a list of them — see
"The rooms" below. `mix run` against the dev database is the way to get one:
`Venues.create_venue/2` answers with the venue and its founding grant, and
`Engagements.issue_invitation/2` then `claim_invitation/2` produce the
engagement that makes the venue room joinable.

### CORS, and why there is none

The Phoenix endpoint mounts no CORS plug — it never needed one. So the dev
server **proxies** `/api` and `/socket` (the prefix, which covers
`/socket/person` and `/socket/employer`) to `localhost:4000`
rather than making cross-origin requests: every request the browser sends is
same-origin, and no backend change is required to develop against it. The proxy
target is `VITE_DEV_API_PROXY` if you need another port.

`VITE_API_BASE_URL` is empty by default for the same reason. Serving this client
from an origin the API does not share needs CORS on the endpoint, which is a
backend change and is not made here.

## Verifying

```bash
npm install
npm run verify      # typecheck, lint, format:check, test, build
```

or individually: `npm run typecheck`, `npm run lint`, `npm run format:check`,
`npm test`, `npm run build`.

**A React test must synchronise on the fact it asserts, not on a render that
precedes it.** This project has no CI (#26), so every green suite is somebody's
local run and a one-in-ten failure is a coin flip that eventually lands on
someone with no context. One such flake has already been found and fixed:
`socket-context.test.tsx` waited for the rendered tree to say the transport was
up and then asserted a counter that an **effect** increments. React commits the
DOM and flushes passive effects as two separate steps, so `waitFor`'s
MutationObserver can fire in between — nine times in ten the scheduler got there
first. `FakeSocket.opened` and `.closed` are the fix: promises that resolve when
`connect()` and `disconnect()` are actually called, with no polling and no
timeout to lengthen. Await those. Do not raise a timeout, and note that
`act(async () => await p)` deadlocks — `act` awaits its callback before draining
the queue, so the effect that would resolve `p` never runs.

`npm test` skips `src/api/client.integration.test.ts`, which runs the whole
log-in flow against a live server and reads the magic link out of
`/dev/mailbox/json`. Run it with the server up:

```bash
npm run test:integration                                   # assumes :4000
HOSPITALITY_COMS_API_URL=http://localhost:4001 npm run test:integration
```

It is one of two tests here that check this client's idea of the API against the
API rather than against a stub this project also wrote, so run it whenever the
API changes. Nothing runs it automatically — this repository has no CI — so it
is on whoever changes `SessionController` or `ErrorEnvelope` to remember.

The other is `npm run test:socket`, which does the same for the **transport**:
the topic prefixes, the credential's route onto the connection, the shape of a
refusal, and — the one thing no fake can settle — that a refused join is not
retried, measured against `phoenix`'s own rejoin timers with a control that
watches the loop happen when nothing leaves. It found the endpoint path the
foundation had guessed wrong on its first run.

It needs a server, and a server needs a database. `CLAUDE.md` is emphatic that
migrating `hospitality_coms_dev` breaks `DROP ROLE employer_role` in
`hospitality_coms_test` — grants are database-local while roles are
cluster-global — so it runs against a **throwaway database that is dropped
afterwards**. The full recipe, including how to mint a session token without
`/dev/mailbox` (there is no dev mailbox outside dev), is in the file's own
header.

`npm run test:peers` is the third, and it is the one that **has never been run**.
It does the same job for `PeerChannel` — the topic, a topic naming somebody
else, and the three list shapes against real JSON rather than object literals —
and it was written and left opt-in because the throwaway database above breaks
the Elixir suite for as long as it exists, and the peer surfaces were built
while another unit was running that suite. Run it in a quiet window, and drop
the database and check `pg_shdepend` afterwards. Treat its assertions as
unverified until somebody has.

## How the code is arranged

```
src/api/            the four endpoints, their types, and every way they can fail
src/session/        who is logged in, where the token lives, magic-link parsing
src/socket/         the connection, the channel error envelope, the provider
src/features/rooms/ venue and shift rooms: the list, a room, the composer
src/features/peers/ the directory, requests, conversations, the disconnect
src/app/            routes and the surfaces they render
src/test-support/   fakes shared by the tests above the client and the socket
```

### The error envelope is a contract, so it is typed like one

Every error this API returns is one shape, built only by
`HospitalityComsWeb.ErrorEnvelope`:

```json
{ "error": { "code": "unauthorized", "message": "…" } }
{ "error": { "code": "unprocessable_entity", "message": "…", "fields": { "email": ["…"] } } }
```

`AGENTS.md` bans `{:error, term()}` on the Elixir side and asks for the actual
atoms traced through the function bodies. The analogue here is
`RequestFailure` in `src/api/errors.ts`: a discriminated union with no `any` and
no bare `Error` in it, and four members —

- `api_error` — the API refused and named no input.
- `api_field_error` — the API refused and named the inputs. `fields` present and
  `fields` absent are **two members rather than one optional property**, because
  the envelope's own documentation says its absence is information. A form asks
  whether it has a field error, not whether a property happened to be defined.
- `network_error` — no response at all.
- `malformed_response` — a response in a shape this client was not promised.
  Drift surfaces as a named failure instead of `undefined` in a heading.

`code` is narrowed to the status atoms these four endpoints are known to
produce, traced through `SessionController`, `PersonAuth` and `ErrorJSON`.
Anything else becomes `unrecognised` with the wire value kept in `rawCode`.

The server's `message` is **never rendered**. The envelope says it is for a
human reading a log; the user-facing copy lives in `src/app/failure-message.ts`,
keyed on `code`, and the switches are exhaustive, so adding a code fails the
build. `fields` is the exception and is shown as it arrives, because those
messages name an input the worker filled in.

Nothing in `src/api/` throws. Every call answers `{ok: true, value}` or
`{ok: false, failure}`, so a caller cannot skip the failure path by not writing
a `catch`.

### The socket, and what it deliberately does not know

`src/socket/session-socket.ts` opens a connection carrying the session token,
joins a topic somebody else names, reports what a push came back with, and
leaves. It still knows **no topic name and no event name** — those live in
`src/features/rooms/`, and nothing moved down here when U7 landed: a module that
knew `"venue_room:"` would have to know `"peer"` and `"employer_venue:"` too,
and the one property this file exists to hold is the same for all of them.

The part worth having early is the refusal behaviour. KTD8 makes `join/3` the
enforcement point and notes that the JS client auto-rejoins on `phx_error`, so
the rejoin refusal _is_ the revocation. That description cuts both ways: in
`phoenix.js` a refused join sets the channel to `errored` and schedules the
rejoin timer, and `Push.reset()` keeps `recHooks`, so the caller's error
callback fires again on every attempt. A client that waits a refusal out asks a
server that has already decided, for ever, on a backoff timer.

So a refusal **leaves the topic** on the first one — which cancels the rejoin
timer through `onClose` — and reports it exactly once. A _timeout_ is not a
refusal, so Phoenix's own retry is left alone.

`phoenix` is pinned at `^1.8.9`: earlier versions carry a Presence client crash
on keys colliding with `Object.prototype` members.

**The token goes in `authToken`, never in socket params.** An earlier version of
this file said the token travelled "in the socket params rather than the URL",
which is a false dichotomy: `Socket.endPointURL()` is
`appendParams(appendParams(endPoint, params()), {vsn})`, so **params _are_ the
query string**, and that version wrote a live fourteen-day bearer credential
into every access and proxy log that saw the connection. `authToken` is the
option that does not: a `Sec-WebSocket-Protocol` value on the websocket
transport, an `X-Phoenix-AuthToken` header on the longpoll fallback, and
`connect_info[:auth_token]` server-side. This module now sends no params at all.

**The token is captured when the socket is built, not when it connects.**
`phoenix` closes over `authToken` at construction, so a re-login needs a new
socket rather than a reconnect. `authToken` also accepts a function, which
`phoenix` calls on every connect; widening `token` to `string | (() => string)`
is the change if U7 wants a socket that outlives a token.

**The endpoint is `/socket/person`, and `/socket` was a guess that was wrong.**
The foundation recorded it as one — "the Phoenix default and what the Vite proxy
assumes" — and U7 mounts two sockets instead, `socket "/socket/person",
PersonSocket` and `socket "/socket/employer", EmployerSocket`, because KTD9
splits them so an employer session cannot be routed to a peer conversation.
There is nothing at `/socket` at all: the upgrade 404s and `phoenix` retries it
on its backoff for ever, with nothing on the client to say why. Found by
`src/socket/session-socket.integration.test.ts` on its first run against a real
server, which is the entire reason that file exists. The Vite proxy entry is a
prefix, so it already covered both.

**`src/socket/socket-context.tsx` is what connects it**, and it is the first
thing in this client to open a socket at all. One socket per session token,
because `phoenix` closes over `authToken` at construction; built in a `useMemo`
and connected in an effect, so StrictMode's double mount leaves exactly one
live connection.

### Where the token lives

`localStorage`, chosen with the consequence understood: the token is the
credential, so anything that can run script on this origin can act as the
worker. There is no cookie session to use instead, an `HttpOnly` cookie is not
readable by the `fetch` calls that must send it as a bearer header, and memory
alone would end the session on every refresh. It is behind a `TokenStore`
interface, so moving it is one file.

`TokenStore`'s three operations must not throw, and that is in the type rather
than in a convention: both callers are event handlers that `void` the promise,
so a throw becomes an unhandled rejection and a surface that never moves again.
`createBrowserTokenStore()` picks storage if the browser has it and memory if
not — private-mode Safari throws on write, storage switched off throws on
everything, and `window.localStorage` is plainly `undefined` in this project's
own test environment.

**Known gap: the `unavailable` surface keeps the token and offers no way to
drop it.** That is right for the case it was built for — a request that failed
should not log a worker out — but it means a token that is somehow unusable
without ever producing a 401 leaves the retry button as the only control on
screen. Clearing site data is the workaround. A "sign out anyway" action is the
fix and is not built, because nothing yet distinguishes the two cases.

## The rooms

`src/features/rooms/` is the venue room and the shift room: a list, one open
room, message rendering and a composer. Three behaviours are the point of it,
and each has an assertion that fails when it regresses.

### The list is local, because there is nothing to fetch

**There is no endpoint that lists rooms**, and no channel event that enumerates
them. `router.ex` still declares four API routes; U6 built
`Rooms.list_venue_rooms/1` and `list_readable_shift_rooms/1` as context
functions with no HTTP surface; and a room channel's join replies with the room
and the engagement and nothing else.

So the list is a bookmark file in this browser and a room is added by its id.
It is an **input** to a join and never an authority: everything about a room —
whether this session may read it, may write to it, or still has access at all —
comes from the server on every join and every send, which is where KTD8 puts it.
A room this session may not read is refused like any other.

**It is emptied when the session ends**, on both paths that drop the token — the
explicit log out and the 401. Hospitality is a shared-terminal industry, and
although the list is bookmarks rather than content and a re-join is refused
server-side, it still names which venues and shifts that person worked.
`SessionProvider` takes an `onSessionEnded` callback for it rather than
importing the room store, so U8's peer surface adds to the same line in
`main.tsx` without touching `src/session/`.

Keying the list per person instead — `hospitality-coms.rooms.<personId>` — was
considered and **rejected**: it would let two people share a terminal without
overwriting each other, but it does so by _retaining_ the previous worker's list
on the device, which is the exact thing clearing it is for.

Ids are normalised — trimmed and lowercased — at both entry points, the paste
box and the stored list, through one function. `Ecto.UUID.cast/1` takes either
case and Postgres stores one value, but **`Phoenix.PubSub` broadcasts on the
literal topic string**, so `venue_room:ABC…` and `venue_room:abc…` would be one
database room and two fan-outs: both sessions writing to the same table and
seeing none of each other's messages.

### A closed room is learned, not fetched

A shift room past its `closes_at` still joins and still reads — U6 keeps
readability and membership as separate questions, and KTD6b says no write
withdraws access a period already earned. Only the send is refused, `gone`.
Nothing on the wire carries `closes_at`, so the client finds out by being told
once and **remembering**, and the composer stays disabled on the next render and
after a reload. `forbidden` — off the roster — is the same shape and a different
sentence.

Remembering it is a guess about the future and it can be wrong in both
directions: an employer can move a `closes_at`, and a manager can re-roster
somebody. So the room offers a **"Check again"** that clears what was learned —
and the sentence that closed the composer, which otherwise sat above a
re-enabled input still claiming the room was refusing.

`unauthorized` on a send is deliberately **not** one of these. It says nothing
about the room and everything about whether this session is still in it, which
is a question `join/3` re-derives — so it is answered at the connection level
instead, closing the composer without persisting anything, and **re-opening the
room** asks the server again. That correction only works because re-opening
forces a remount: `RoomView`'s key carries an attempt counter, and without it
opening the room already open set the same state, React kept the mount, and
nothing re-joined. Every "open it again to check" this surface offers was a dead
end until both halves were fixed.

### The revocation event leaves the topic

`access_revoked` arrives, the topic is left, and _then_ the room is dropped from
the list — in that order, so nothing is dropped while still subscribed.
`access_suspended` leaves too but keeps the bookmark, because the person did
that themselves and can undo it (KTD18).

The leave is the part that matters and the reason is not the obvious one.
Measured against a real server: a clean `{:stop, {:shutdown, :revoked}}` sends
`phx_close` and `phoenix` does **not** rejoin, so that path never looped. What
does loop is an abnormal channel exit — `Phoenix.Socket` sends `phx_error` for
every exit reason — and a room left in the list that this surface re-joins on
the next open or reconnect. A refused join left alone produced three refusals in
six seconds against the live server; through `createSessionSocket` it produced
one in four.

### What the rooms deliberately do not have

- **No history.** A joined room shows what arrives after the join. There is no
  `"history"` event and no endpoint for `Rooms.list_venue_room_messages/2`.
- **No presence.** `RoomChannel.joined/1` pushes `"presence_state"` and the
  tracker pushes `"presence_diff"`; no handler is registered for either, so
  `phoenix` drops them. Worth rendering, not one of the three things this
  surface exists to get right.
- **One room joined at a time.** `endpoint.ex` records that KTD10's argument for
  `max_channels_per_transport` is wrong and that "clients must open shift rooms
  on demand rather than joining the list". The cost is that a revocation is
  noticed while the room is open, and on the next join otherwise — which is
  where KTD8 puts the enforcement anyway.
- **Attribution is the engagement id**, shortened, or "You" — never a person and
  never a name (KTD15b). There is no name in the employer zone to render.
- **No transport status.** `connection` tracks the session's socket, not the
  link, so a websocket that drops under a live session leaves the composer
  enabled. `phoenix` reconnects and rejoins on its own and buffers the push, so
  the usual outcome is that the message goes when the link returns; if it does
  not, the push times out after ten seconds and says so. Surfacing it properly
  means `SocketLike` growing `onOpen`/`onClose`/`onError`, which
  `session-socket.ts` deliberately does not expose. The cost is ten seconds of a
  composer that looks live, and it is recorded in `use-room.ts` rather than
  built on a guess about how a reconnect should read.

### The channel error vocabulary belongs to the surface, not the transport

`channel-failure.ts` owns the envelope and **names no codes**. Copy is an
exhaustive `switch`, so one shared list would make every surface's switch break
when any surface gained a code — and U8 puts nine events on one multiplexed
`peer:<person_id>` channel. `decodeChannelRefusal` takes the caller's vocabulary
as an argument; `features/rooms/refusal-message.ts` owns `ROOM_ERROR_CODES` and
`features/peers/refusal-message.ts` owns `PEER_ERROR_CODES`, each tracing every
code to the clause that emits it. A code outside the caller's set is
`unrecognised` with the wire value kept, which is the right answer for a peer
code reaching a room. `src/api/errors.ts` keeps one shared list because exactly
one switch consumes it.

**It paid off immediately.** The two sets overlap in four codes and differ in
three, and none of the three would have made sense in the other file:
`conflict` is peer-only and covers four distinct refusals, `gone` means "the
shift room closed" to a room and "that request expired" to a peer, and
`forbidden` means "you are off the roster" to one and "the block is against
you" to the other. A shared list would have forced a case for each into a
switch that could say nothing true about it.

## The peers

`src/features/peers/` is U8's whole surface on one channel: who this person can
see, the request state machine as a user meets it, 1:1 conversations with
history, and the disconnect. Four behaviours are the point of it, and each has
an assertion that fails when it regresses.

### One topic, and the case of the id is load-bearing

The topic is **`peer:<person_id>`** and the suffix is the session's own person —
`admitted/3` matches it against the joining scope with a repeated variable. It
was the bare string `"peer"` before U8's review, which put every person's peer
channel in the cluster into one Phoenix group; anything written against that
shape is wrong.

Every event names its conversation **in the payload and never in the topic**
(KTD10), so one channel carries every conversation, conversations are not part
of `max_channels_per_transport`, and opening a second conversation opens no
second topic. `peers.test.tsx` asserts `socket.channels` stays at one across
two open conversations.

The id is lowercased before it becomes a topic, and the consequence of not doing
it is worse here than for a room. `Ecto.UUID.cast/1` downcases, so an uppercase
suffix still matches the session's own person and the join **succeeds** — but
`Phoenix.Channel.Server` subscribes the channel to the literal string, and
`Peers.topic/1` publishes to the lowercase one. The channel would answer every
push and receive no announcement at all, for the whole session, with nothing
refused and nothing logged. A room in the wrong case loses one room's fan-out;
this loses the surface's.

### Nothing about who you know is written to this browser

There is no store, no `localStorage` key, and nothing added to
`SessionProvider`'s `onSessionEnded`. The rooms keep a bookmark file because no
endpoint or event enumerates rooms; `PeerChannel` has `list_peers`,
`list_requests` and `list_conversations`, so there is nothing this surface would
have to write down in order to render itself.

That is the answer to the question the room review raised — "if you persist
anything about peers, it clears on session end too" — arrived at from the other
end: peer data is a graph of who a worker knows, which is more sensitive than
which venue they worked at, and the reason none of it survives a log-out on a
shared terminal is that none of it was ever stored.

### An announcement is a nudge; the list is the answer

Four of the five pushes are **not** applied to local state. `peer_request`,
`peer_request_declined`, `peer_connected` and `peer_disconnected` cause the
affected list to be asked for again.

That is the only correct reading rather than a shortcut. A notice carries ids
and an instant; a request's `state` is derived **per read** from whether the
pair can see each other at that instant — `lapsed` is R14's "expired" and
nothing stores it — so this client cannot work out what a notice means for a
request's state without asking. Re-asking is also what makes the surface correct
after a reconnect, where notices were missed entirely.

`peer_message` is the exception and is applied directly, because the notice
carries the whole message. It is also the one shape where **the push and the
reply disagree about a key**: `rendered_message/1` says `sent_at` and the push
says `at`, because a push is `Peers`' announcement shape and every announcement
on that topic stamps its instant as `at`. There are two decoders and one type,
and `decode.ts` refuses each key where the other belongs — a single decoder with
a fallback would also accept a payload carrying neither.

Every action refreshes as well as listening, because `announce/2` is best effort
and logged rather than propagated. Both paths are idempotent reads, which is
what makes running both harmless rather than something to be careful about.

### A closed conversation is asked about, not remembered

This is the one real difference from the rooms. A room has to **remember**
`room_closed`, because nothing on the wire carries a shift room's `closes_at`
and the only way to learn it is to lose a message — hence `RoomStore` persisting
the bar and the "Check again" that unlearns a guess which can go stale in both
directions.

Here `list_conversations` carries `open` for every conversation. So a send
refused `conflict` re-asks and renders what comes back: nothing is inferred,
nothing is stored, and there is nothing to un-learn. A disconnect does **not**
leave the topic either — the topic is the person, not the conversation, and
leaving would take every other conversation down with it. `peers.test.tsx`
asserts `channel.leaves === 0` after a disconnect and then sends into a second
conversation on the same channel.

### What the peer surface deliberately does not decide

- **Who may ask whom.** That is `Peers.permitted/3`, read off the pair's one
  current request row, which this client does not hold and cannot reconstruct: a
  block is a column on that row, it survives new co-rostering, and it is cleared
  by an exchange this surface may never have seen. The ask is offered unless the
  client is already holding a pending approach or an open conversation, and
  `forbidden` is rendered as the sentence it is.
- **Whether a request has expired.** `lapsed` is derived server-side and can go
  back to `pending`. A lapsed incoming request keeps both buttons: accepting is
  refused `gone` with a sentence saying it can come back, and declining is
  accepted at any time, because an addressee may always say no.
- **No withdraw.** `Peers` has no `withdraw_request/2` and says why — declining
  blocks the requester by design, so a non-blocking withdrawal is a rate-limiting
  decision (issue #15). There is no event, so there is no button.
- **No profile, disclosure, or attested entries.** U9 owns those and was being
  written at the same time as this; guessing at its shapes would be a
  placeholder for a surface nobody has chosen.

## Deliberately absent, and why

Nothing below is stubbed. A placeholder for a shape nobody has chosen costs the
next unit more to find and undo than it costs to write from nothing.

| Surface                                        | Waiting on | What is missing                                   |
| ---------------------------------------------- | ---------- | ------------------------------------------------- |
| Profile, attested entries, disclosure controls | U9         | Endpoints, and the per-employer view              |
| Archived engagements, erasure                  | U10        | Endpoints                                         |
| Demo controls                                  | U11        | The control surface, which is not employer-scoped |

`lib/hospitality_coms_web/router.ex` still declares four API routes plus the dev
mailbox preview, and those four are exactly what `src/api/` covers. U5 and U6
built contexts, not endpoints: there is no HTTP surface for engagements, rooms,
messages or rosters, which is why the room list is local. U8 built no endpoint
either — the peer surface is entirely `PeerChannel`, which is why it needs no
list held in this browser.

### Things that were tempting to guess, and were not

Recorded so the next unit knows they are open questions and not settled:

- **The magic link's landing origin.** `config/config.exs` defaults
  `MAGIC_LINK_BASE_URL` to `http://localhost:4000/log-in/`, which is Phoenix and
  not this client. `/log-in/:linkToken` matches that path shape so the link works
  if the base URL is pointed here, and the paste box works if it is not. Changing
  the default is a backend decision.
- **Whether an employer session is a different client.** KTD9 splits the sockets
  so an employer session cannot be routed to a peer conversation. Whether that
  implies a separate surface, a separate route tree, or a separate build is a
  U9 question and nothing here presumes an answer.

## Known limitations

- A 404 from the router renders the error envelope in production, but
  `config/dev.exs` sets `debug_errors: true`, so in development Phoenix answers
  with its own HTML debug page. The client reports that as
  `malformed_response`, which is the correct reading — it is not the API's
  envelope — but it is a dev-only difference worth knowing about.
- There is no pagination anywhere, because there is no list that grows.
  `AGENTS.md` requires it for every list that does; the first such list arrives
  with U7.
- `npm run build` produces a static bundle with no server-side rendering and no
  deployment target. Nothing serves `dist/` yet.
