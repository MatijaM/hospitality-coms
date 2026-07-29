# client

The React client for hospitality-coms. U12 is being built in slices — the plan's
own note says it "is the coarsest unit in the plan and will likely split during
execution once the surface count is real" — and five have landed: the
**foundation** (toolchain, typed API client, log-in), the **room surfaces**
(U7's venue and shift rooms, the composer, the revocation), the **peer
surfaces** (U8's directory, the request state machine, 1:1 conversations,
disconnect), the **profile surface** (U9's record, per-audience disclosure,
corrections) and the **handshake** (the crude employer view's U4: the venue
picker, the venue's people, the offer, and the claim panel that redeems it).

**The profile surface is different from the other four and the difference is
not small: no channel on the server answers any of its events.** U9 settled the
shapes and deliberately added no transport, so it is built against the shapes
with the envelope written down in one place —
`src/features/profile/contract.ts`. Read that before assuming anything behind
`/profile` works against a running server. U10 and U11's surfaces are still
absent, and the table at the bottom says what each is waiting on.

The handshake is the opposite case: `/employer` and `/claim` speak to routes
that exist and are tested end to end on the server, so those two work against a
running Phoenix today.

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
precedes it.** A one-in-ten failure is a coin flip that eventually lands on
someone with no context — before #26 that was whoever ran the suite next, and
now that CI runs it is whichever pull request happens to be open. One such flake
has already been found and fixed:
`socket-context.test.tsx` waited for the rendered tree to say the transport was
up and then asserted a counter that an **effect** increments. React commits the
DOM and flushes passive effects as two separate steps, so `waitFor`'s
MutationObserver can fire in between — nine times in ten the scheduler got there
first. `FakeSocket.opened` and `.closed` are the fix: promises that resolve when
`connect()` and `disconnect()` are actually called, with no polling and no
timeout to lengthen. Await those. Do not raise a timeout, and note that
`act(async () => await p)` deadlocks — `act` awaits its callback before draining
the queue, so the effect that would resolve `p` never runs.

**A test must establish the environment it depends on, never assert what the
runner happens to provide.** CI's first run caught the one instance of this:
`token-store.test.ts` asserted `globalThis.localStorage` was `undefined` before
exercising the fallback, which held on a machine whose Node was started without
`--localstorage-file` and did not on CI's. The failing assertion was the smaller
half — the real cost was that `createBrowserTokenStore()` has two branches and
each runner could only ever reach one, so a green suite anywhere proved half a
function and read as though it proved all of it. `vi.stubGlobal` with a
`vi.unstubAllGlobals()` in `afterEach` is how both branches get a test; the same
applies to anything else ambient — `navigator`, `window.*`, the time zone, the
locale.

**Two test files whose names differ only in `.ts` versus `.tsx` are one file to
TypeScript and two to vitest.** `tsconfig.json`'s `include` expands a directory
and then deduplicates by path-without-extension, keeping `.ts` over `.tsx` — so
`profile.test.ts` beside `profile.test.tsx` meant the `.tsx` was in **neither**
`tsc --noEmit` nor `eslint`, while `vitest` ran it and reported it green. A
whole surface suite, typechecked by nothing and linted by nothing, reading as
covered. It surfaced as `eslint`'s "was not found by the project service", which
reads like a config problem and is not one; `npx tsc --noEmit --listFiles | grep
<name>` is what settles it. The fix is the naming the other two surfaces already
have by accident — `room.test.ts` beside `rooms.test.tsx`, `peer.test.ts` beside
`peers.test.tsx` — and here it is `profile.test.ts` beside
`profile-route.test.tsx`. **Do not name a `.tsx` test after a `.ts` module.**

`npm test` skips `src/api/client.integration.test.ts`, which runs the whole
log-in flow against a live server and reads the magic link out of
`/dev/mailbox/json`. Run it with the server up:

```bash
npm run test:integration                                   # assumes :4000
HOSPITALITY_COMS_API_URL=http://localhost:4001 npm run test:integration
```

It is one of two tests here that check this client's idea of the API against the
API rather than against a stub this project also wrote, so run it whenever the
API changes. Nothing runs it automatically — CI stands no server up, so the file
skips itself there — so it is on whoever changes `SessionController` or
`ErrorEnvelope` to remember.

The other is `npm run test:socket`, which does the same for the **transport**:
the topic prefixes, the credential's route onto the connection, the shape of a
refusal, and — the one thing no fake can settle — that a refused join is not
retried, measured against `phoenix`'s own rejoin timers with a control that
watches the loop happen when nothing leaves. It found the endpoint path the
foundation had guessed wrong on its first run.

`npm run test:peers` is the third, and does the same job for `PeerChannel`: the
topic, a topic naming somebody else, and the three list shapes against real JSON
rather than object literals.

### Run them against a throwaway **cluster**, not a throwaway database

This is the part that was wrong for two units and is worth reading before
running either. `CLAUDE.md` is emphatic that migrating `hospitality_coms_dev`
breaks `DROP ROLE employer_role` in `hospitality_coms_test` — grants are
database-local while roles are cluster-global — and the recipe both files
carried, "create a throwaway database and drop it afterwards", **has the same
problem**. Any migrated database on the cluster grants `employer_role`, so the
Elixir suite is broken for everyone on that machine for as long as it exists.

A throwaway **cluster** does not have the problem at all. `initdb` into a
temporary directory is a postmaster with its own role namespace, so its
`employer_role` is a different role that happens to share a name:

```bash
initdb -D /tmp/hc/data -U postgres --auth=trust --locale=C
LC_ALL=C pg_ctl -D /tmp/hc/data -o "-p 55432" -l /tmp/hc/log start
# … migrate, serve, test …
LC_ALL=C pg_ctl -D /tmp/hc/data -m immediate stop && rm -rf /tmp/hc
```

`LC_ALL=C` on both commands is not optional on macOS: without it `initdb`
refuses the locale, and the postmaster starts and immediately dies with
"postmaster became multithreaded during startup", which reads like a build
problem and is not one. A container (`docker run postgres:17`) is the same idea
and also fine; this needs no daemon.

Both files were run this way and both passed — 3 assertions for the peers, 5 for
the transport. Measured afterwards: `pg_shdepend` on the real cluster held the
same 22 rows for `employer_role` as before, all of them `hospitality_coms_test`'s.

**The token-minting snippet in both headers was also wrong**, and running it is
what found that: `Accounts.register_person/2` inserts with `mode: :savepoint`,
which outside a transaction raises `DBConnection.TransactionError: transaction
is not started`. Every ordinary caller reaches it from inside
`request_magic_link/2`'s transaction, so nothing had ever noticed. Both recipes
now wrap it.

## How the code is arranged

```
src/api/              the four endpoints, their types, and every way they can fail
src/session/          who is logged in, where the token lives, magic-link parsing
src/socket/           the connection, the channel error envelope, the topic-id rule
src/features/rooms/   venue and shift rooms: the list, a room, the composer
src/features/peers/   the directory, requests, conversations, the disconnect
src/features/profile/ the record, the disclosure ledger, corrections, a peer's record
src/features/employer/ the venue picker, the venue's people, the offer and its code
src/features/claim/   the worker's half of the handshake: one code, one engagement
src/app/              routes, the landing page that tabs three of them, and two
                      pieces of shared plumbing — `use-fetched.ts` and `session-bar.tsx`
src/test-support/     fakes shared by the tests above the client and the socket
```

`src/app/use-fetched.ts` was `features/rooms/use-room-lists.ts`'s private
`useFetched` until the employer surface became its second caller. It is React
state, so it is here rather than in `src/api/`: **nothing in `src/api/` imports
React**, and that is what lets the client and its decoders be tested with no
renderer at all.

`src/app/session-bar.tsx` is the identity line and the log-out control, moved
out of `HomeRoute` verbatim when U4 added two full pages of its own. Hospitality
is a shared-terminal industry, and a log-out that only exists on the page the
session opened on is one somebody has to navigate back to.

`src/socket/topic-id.ts` is the one rule for turning a string into a topic
suffix — 36 bytes then a uuid cast, lowercased. It was written in `room.ts` and
copied into `peer.ts`, which recorded the condition for un-duplicating it:
_"hoisting a uuid helper into `src/socket/` is the alternative, and it belongs
to whichever unit first has a third caller."_ The profile surface is the third
caller, so that is where it now lives; `normaliseRoomId` and
`normalisePersonId` are one-line delegations, because each surface's call sites
read better for its own name.

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

The server's `message` is **never rendered** — on the four session endpoints and
the three socket surfaces. The envelope says it is for a human reading a log;
the user-facing copy lives in `src/app/failure-message.ts`, keyed on `code`, and
the switches are exhaustive, so adding a code fails the build. `fields` is the
exception and is shown as it arrives, because those messages name an input the
worker filled in.

**The employer and claim surfaces are the deliberate exception, and it is a
measurement rather than a preference.** `ErrorEnvelope`'s `code` _is_ the
response's status atom, and `HospitalityComsWeb.ClaimController` answers `409`
twice with two different sentences on purpose — `:already_claimed` (the offer is
gone for good) and `:grant_not_live` (the code is unspent, and re-issuing the
authority makes it work again). Those are opposite instructions to the person
reading them, so a switch keyed on `conflict` must be wrong about one of them;
R6 asks in as many words for "a sentence that distinguishes those three". Those
controllers also write for the screen rather than the log — _"no such venue, or
it is not one you can act for"_, _"that claim code has expired"_.

So `features/employer/refusal-message.ts` and `features/claim/refusal-message.ts`
render `failure.message`, and only for the failures those routes **author**:
`unauthorized` comes from `PersonAuth` a pipeline above them and keeps local
copy, as do a network failure and a malformed body, which carry no sentence at
all. The cost is stated in both files: this client no longer controls that copy.
Each surface therefore has two tests for it — one watching a sentence arrive,
and a second sending a _different_ sentence under the same code, so a component
hard-coding a string that happens to match fails.

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
everything, and a runtime with no web storage at all leaves
`window.localStorage` `undefined`, which makes reading `.getItem` off it a
TypeError at module scope. Node is such a runtime unless it is started with
`--localstorage-file`, so the suite meets both sides of that depending on the
machine; `token-store.test.ts` stubs the global rather than inheriting it, and
tests each branch.

**Known gap: the `unavailable` surface keeps the token and offers no way to
drop it.** That is right for the case it was built for — a request that failed
should not log a worker out — but it means a token that is somehow unusable
without ever producing a 401 leaves the retry button as the only control on
screen. Clearing site data is the workaround. A "sign out anyway" action is the
fix and is not built, because nothing yet distinguishes the two cases.

## The landing page

`/` renders the three surfaces in tabs — Rooms, Peers, Profile — with the
identity block above them. It was a page of links, which meant the first thing
a worker saw after signing in was a table of contents rather than the product.

**`/rooms`, `/peers` and `/profile` are unchanged, and the tabs are a second
door.** That is what keeps every test above those three surfaces — all of which
enter through their own path — untouched by the landing page, and it is why
this was a cheap change. `app.test.tsx` asserts the three paths still serve
their surface with no tab strip on screen, so the second door cannot quietly
become the only one.

**Only the open tab is mounted, and it is a constraint rather than a saving.**
`usePeerSurface` is one hook because there is one topic (KTD10 puts the
conversation in every payload and never in the topic), so a second instance
joins `peer:<person_id>` a second time and every announcement arrives twice.
Panels kept in the tree and hidden with CSS would put that second instance
there the moment somebody looked at Rooms. Measured: rendering all three behind
`hidden` passes the aria wiring tests and fails three others.

The consequence is stated rather than hidden — **switching tabs unmounts the
panel that was showing**, so an open room leaves its channel and typing in
progress goes. That is exactly what navigating from `/rooms` to `/peers`
already did, so nothing regressed; but a tab strip reads like Slack's, where
the conversation is still there when you come back, and this one is not.

The open tab is deliberately **not** in the URL. Each surface already has one,
and `?tab=peers` disagreeing with `/peers` about which is canonical is a bug
nobody would find quickly.

**`/employer` and `/claim` are links under the panel rather than two more
tabs.** They are used by two different people in two windows at the same time,
so neither is "another surface of mine" the way the three tabs are; and the tab
strip is a keyboard widget whose wrapping is asserted over exactly three
entries, so a fourth would be a rewrite of tests about something else. The
sentence above the links is also the only place this client says out loud that
managing a venue and working at one are the same account.

**The Profile tab is shown even though nothing answers it**, with the reason on
the page rather than in this file: the record, its attested entries and the
disclosure ledger are all built server-side and no channel carries them, so
that tab renders against `features/profile/contract.ts` and waits. Hiding it
would make the product look smaller than it is.

## The rooms

`src/features/rooms/` is the venue room and the shift room: a list, one open
room, message rendering and a composer. Three behaviours are the point of it,
and each has an assertion that fails when it regresses.

### Two lists: the server's, and this browser's

**The server lists rooms now.** `GET /api/venue-rooms` answers the venue rooms
this person is in **by name**, and `GET /api/venues/:venue_id/shift-rooms`
answers the shift rooms they may read at one of them, labelled with the shift
type's name — `features/rooms/rooms-api.ts` owns the paths and the decoders.
That is the browse list, and it is where a room is _found_. Nothing in it is a
uuid prefix, which is what made the old layout read as broken.

A shift room has no name of its own, so its label is the type's name plus the
term — two Tuesdays of one shift type are otherwise two rooms with one name.
**The term names the end's day whenever the end falls on another one**, because
a late shift crossing midnight is the ordinary shape of a hospitality working
day and `9 Mar 23:00–07:00` reads as a room that closes before it opens. Which
day the end falls on is a question about the reader, so it is asked with an
`Intl.DateTimeFormat` built exactly like the ones that render the label and
therefore resolving the same timezone — not in UTC, and not in the venue's.
`room.test.ts` pins that by asking the same two instants in two timezones and
getting opposite answers.

The **local** list is kept and is not a cache of it. It holds `barred`, the one
thing on this surface that was _learned_ rather than fetched — nothing on the
wire says in advance that a shift room is past its `closes_at` — and it is what
is still open after a reload. The paste box is kept for the same reason: it is
the only way into a room the browse list does not show.

Neither is an authority: everything about a room — whether this session may read
it, may write to it, or still has access at all — comes from the server on every
join and every send, which is where KTD8 puts it. A browsed room and a pasted
one take exactly the same path into a channel, and a room this session may not
read is refused like any other.

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
withdraws access a period already earned. Only the send is refused, `gone`. So
the client finds out by being told once and **remembering**, and the composer
stays disabled on the next render and after a reload. `forbidden` — off the
roster — is the same shape and a different sentence.

The shift-room list _does_ carry `closes_at` and the browse panel prints it, and
that is not the same thing as knowing whether the room is open. **It is rendered
and never compared**: `HospitalityComs.Clock` is offsettable and the demo moves
it while this browser's clock is real, so a client-side open/closed badge would
be wrong during exactly the demo the offset exists for. Rendering it raw was a
separate mistake and is fixed — `2026-03-09T21:30:00Z` in front of a worker,
beside a term this client had already formatted.

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

- **No history _event_.** History arrives over HTTP —
  `GET /api/venue-rooms/:venue_id/messages` and
  `GET /api/shift-rooms/:id/messages` — bounded to the most recent page, with
  `complete` saying whether that is the lot and a "load the whole history"
  control that appears only when it is not. The fetch and the join are
  independent, so `mergeMessages` keys on the id. There is still no `"history"`
  event on either channel: a room's past is not a thing its stream carries.
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

### Nothing about who you know is written to this browser, and what is in memory is dropped

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

Storage was not the whole of it. **A rejoin refused `unauthorized` empties what
the hook holds**, which is a different path and needed its own answer:
`phoenix` re-joins on its own backoff after a dropped link, and a session
revoked in between is refused there. `RequireSession` still reads
`authenticated` — `GET /api/me` was answered minutes ago — so nothing else on
the page would have cleared it, and the graph would have sat on screen under an
alert saying the session was gone. The sections stay mounted and render empty,
which is deliberate: hiding them in the route as well made the clear
unfalsifiable, because no assertion through the DOM can tell "not rendered" from
"not held".

It is keyed on `unauthorized` and not on any refusal. Phoenix's own
`%{reason: "too many channels joined"}` says nothing about who is signed in, and
emptying the graph there would throw away this person's own data to report a
transport limit. There is a test for each direction.

**This is the third shared-terminal finding this client has produced** — room
bookmarks surviving log-out, a closed conversation's cache outliving the
server's own answer, and this. The backend keeps its guarantees; the pattern is
that a client-side cache quietly becomes a second, unenforced copy of something
the server is careful about.

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

A `peer_message` naming a conversation no list has mentioned **re-asks
`list_conversations`**, because every peer message is for a connection this
person is a party to and `list_conversations` returns all of them — so a
mismatch means the list is stale, and the usual cause is a `peer_connected`
announcement that was dropped, which `announce/2` explicitly permits. Without it
the conversation is invisible until a reload while its messages pile up in a
cache nothing can open.

Every action refreshes as well as listening, because `announce/2` is best effort
and logged rather than propagated. Both paths are idempotent reads, which is
what makes running both harmless rather than something to be careful about. The
tests pin **which** lists each path asks for, so an over-fetch — invisible on
screen, a round trip per event — fails rather than passing quietly.

**What the nudges do not cover is an open conversation's history.** The three
lists are re-asked on every join, so a reconnect re-derives them; a history is
not a list, and a message sent while the link was down reached no push here
because this client was not subscribed to hear it. `joinGeneration` counts
admitted joins and `ConversationView` names it in the effect that loads history,
so a rejoin backfills the open conversation — **only the open one**, because
every other cache is unreachable until it is opened and opening one re-fetches
anyway.

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

**Closing one also replaces the message cache rather than merging into it**, and
that is the second shared-terminal finding. `Peers.list_messages/2` reads the
whole conversation while it is open and, once disconnected, each party's own
messages and only their own — R15's remedy, which `peers_test.exs` asserts with
a row count as the control for nothing having been deleted. The client held a
cache from while it was open and merged the new history into it, so the
counterpart's messages stayed on screen: **the enforcement held on the wire and
not on the screen.** `loadHistory` now takes the conversation's `open` flag and
assigns rather than merges when it is false, and `ConversationView` names the
flag in its effect so the re-fetch happens the moment it flips. Merging survives
for the open case, where the reply can genuinely race a push; nothing can be
pushed to a closed conversation, so there is nothing to race.

It was invisible because every disconnect fixture answered `history` with
`{messages: []}` first — the counterpart's messages were never in the cache when
the conversation closed, so the property had nothing to fail on.

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

What it _does_ decide is what the server has already settled. "Ask to connect"
is not offered when the client is holding an open conversation with that person,
an approach they sent, or **one they have received** — everything on
`list_incoming_requests/1` is outstanding, so an entry from that peer means the
approach exists in the other direction, the server would refuse the request
`conflict`, and the button reads as though nothing has happened while somebody
waits for an answer further down the page. Accept and Decline close while an
answer is in flight, because they are the same conditional `UPDATE` server-side
and the second click of a double-click gets `:not_found` — indistinguishable
from an id that names nothing (AE1), so the surface could not explain it.

### One ordering hazard, guarded twice

`merged` orders messages by the server's instant, and comparing those instants
**as strings** was safe only by accident: every peer timestamp is `:utc_datetime`,
truncated to the second. `"…:00.5Z" < "…:00Z"` — `.` sorts before `Z` — so the
day any peer column becomes `:utc_datetime_usec` the order silently inverts
inside every second. That is not hypothetical here: U6's review moved
`roster_entries` from second to microsecond precision for a correctness reason.

Both halves are in place rather than one: `byInstant` parses with `Date.parse`
and falls back to the string comparison only for a value it cannot read at all
(`NaN` compares false against everything, which would scramble the whole list
rather than misplace one row), **and** a test carries a sub-second instant that
fails today if the parse is removed. The fix alone would be unasserted; the test
alone would leave the code wrong until somebody read the failure.

This is not the time arithmetic `peer.ts` bans. That ban is about deriving
product state — whether a request has expired — against this client's own clock,
which is why `lapsed` arrives from the server. Ordering two instants the server
stamped decides nothing.

## The profile

`src/features/profile/` is U9's worker-facing surface: the record, the ledger of
disclosure decisions, declared entries, correction requests, and one peer's
record at a time.

### It is built against a transport that does not exist, and that was a choice

**Measured at `3063e9c`, which is U9 merged:** `grep -rn 'Profiles'
lib/hospitality_coms_web/` finds nothing, the router declared four API routes,
`PeerChannel` handles nine events and none carries an entry or a disclosure, and
`EmployerVenueChannel`'s only `handle_in/3` clause is the terminal one. Issue #48
has since added four room routes and nothing profile-shaped, so only the count
in that sentence has moved. U9's issue named contexts, migrations and one test file, and its
verification is a context-level claim, so the absence is deliberate on that side.

The two honest options were to build against the shapes the contexts return and
say where the transport is missing, or to build only what an existing channel
event can feed. **The second yields the empty set** — none of the four
measurements above leaves anything to render — so "build nothing" was the only
thing it could produce, and the slice would not exist.

What made the first defensible is that the part U9 settled is the part a client
depends on: `VisibleEntry`, `VisibleCorrection`, `DeclaredEntry` and
`Disclosure` are real modules with `@enforce_keys`, `@type t()` and a moduledoc
arguing every field, and `Profiles`' `@spec`s say which function answers which.
What is _not_ settled is the envelope — the topic, the event names, the wire
casing.

So the envelope lives in **`contract.ts` and nowhere else**: the topic prefix and
all seven event names are exported constants that every other file in the
feature imports, so the contract cannot drift from what the client actually
sends. A transport author has one file to satisfy and no surface to reverse
engineer.

This is a deliberate exception to the rule three paragraphs down — "nothing is
stubbed; a placeholder for a shape nobody has chosen costs the next unit more to
find and undo than it costs to write from nothing". That rule is about a shape
**nobody has chosen**. These are chosen.

### What the contract asks for that U9 does not currently produce

Three things, and each is a finding rather than a preference.

**Three of the five shapes have no render struct.** `VisibleEntry` and
`VisibleCorrection` name their ids `attested_entry_id` and
`correction_request_id`; `DeclaredEntry`, `Disclosure` and `CorrectionRequest`
are Ecto schemas and say `id`. A channel rendering those wholesale would put
`id` on the wire for three entities beside `<entity>_id` for two, on one
surface — the defect class this project has fixed twice already (U8's
`rendered_message/1`, U9's own `venue_corrections/1`) and which issue #31 is a
third instance of. The contract asks for `declared_entry_id` and
`disclosure_id`, and `decode.ts` **refuses `id`** rather than accepting either,
because a decoder that took both is how the two spellings come to coexist.

**`request_correction/3` answers a different shape from every read of the same
entity.** Its `@spec` returns `CorrectionRequest.t()` — the schema, with `id`
and `resolution` as a `String.t()` — while `list_correction_requests/1`,
`list_visible_corrections/2`, `list_venue_corrections/1` and
`fetch_peer_profile/2` all return `VisibleCorrection`, with
`correction_request_id` and `resolution` as an atom. "Four readers, one shape"
was U9's own claim and it is true of the readers; the writer is the fifth
caller and is outside it. The contract asks the transport to render a
`VisibleCorrection`.

**The audience travels as `audience_kind` + `audience_id`, in both
directions.** `Disclosure.audience()` is `{:venue, id} | {:person, id}` and the
table spells it as two nullable columns with exactly one set. Neither is a wire
shape: the two-column form has to be validated for "exactly one" on the way in,
and a reply spelled that way beside a request spelled otherwise would be the
same defect again.

### What the profile surface cannot render, and it is not a UI shortcoming

**A worker cannot be shown who can currently see an entry.**
`attested_entry_disclosures` holds _overrides_. Both defaults are computed
server-side from periods that are already stored — an employer is hidden an
entry whose term overlapped one of theirs, a peer is shown one unless the worker
said otherwise _and_ unless a venue binding that peer would hide it — and
neither reaches any wire. So the honest rendering is "the decisions you have
taken", plus a sentence saying the rest follows a rule this screen cannot
compute, and `disclosureState` answers `"default"` where there is no row.

Answering `"shown"` there was the tempting alternative and is actively wrong,
not merely optimistic: the employer default _hides_ an entry exactly where a
worker's jobs overlapped, so the reassuring version tells somebody their second
job is disclosed to the venue it is in fact concealed from — and the decision
they then do not bother taking is the one the unit exists to give them.

**There is no audience picker, because nothing enumerates an audience.**
`VisibleEntry.venue_id` is the venue that _asserted_ the entry, not one that
might read it, and no event lists the venues a worker holds an engagement at or
the peers who can see them. So an audience is typed in as a raw id — poor, and
better than the only picker this surface could actually build, which would offer
the attesting venue: the one audience an entry is never hidden from.

**The employer read is not here at all.** `list_visible_entries/2`,
`list_visible_corrections/2`, `list_venue_corrections/1` and
`resolve_correction/3` take an `EmployerScope`, so they belong on
`EmployerVenueChannel`. Whether an employer session is a separate route tree, a
separate build, or the same one is still the open question recorded below, and
both profile scenarios issue #12 names are worker-facing.

### The one rule the render layer can defeat on its own

`Profiles.incompleteness_notice/0` is arity zero so that a worker concealing
something is indistinguishable from one with nothing to conceal. The views'
column lists are pinned server-side, and `profiles_test.exs` asserts an employer
read of a concealing worker is identical in length and key set to a read of one
who has never worked anywhere else.

**All of that is undone by a client that computes the difference back** — a
count, an ordinal, a gap where a hidden entry would sit, a different notice.
Three things hold it here:

- **`ProfileView` is the only component that renders somebody else's record, and
  its props carry no ledger and no counts.** Not "it does not use them" — it
  cannot be handed them, which a reviewer can check from the type.
- **The notice arrives on the join reply, never on a profile reply.** That is
  arity zero expressed on a transport: a join is about the session, so no
  profile read can influence one, and the same string is rendered beside a
  record with three entries and one with none. A per-profile field would be
  arity one however carefully the server computed it.
- No list is numbered and none renders its length.

`profile-route.test.tsx` asserts the first two against the DOM, and the fixture
for the first is the point of it: the viewer _is_ holding a ledger — their own —
carrying a decision keyed on the engagement the peer's visible entry names, so a
view that reached for `surface.disclosures` would have something real to render.
A fixture that is empty exactly where the property lives cannot fail, which is
the lesson `peers.test.tsx` already records.

### There are no announcements, and that is U9 rather than a gap

`usePeerSurface` handles five pushes; this handles none, because
`HospitalityComs.Profiles` broadcasts nothing at all. So the surface refreshes on
its own actions and on a rejoin, and a decision taken on another device is not
seen until one of those. Written down rather than papered over with a poll: the
fix is a broadcast on the server, and a timer here would be this client
compensating for a decision U9 has not taken.

### The fourth shared-terminal finding

A refused rejoin carrying `unauthorized` clears the record and the ledger and
leaves the session alone — `usePeerSurface`'s handling, applied to the most
sensitive thing this client has held yet. A room bookmark names a venue; a peer
graph names who somebody knows; this names every term they have served, every
venue that asserted one, every contest they have raised, and the ledger, which
is the list of what they did not want seen.

## The handshake

`src/features/employer/` and `src/features/claim/` are the two halves of flow
F1: a manager picks a venue, sees who is on it, offers somebody a job and copies
a code; in a second window a new starter with their own session pastes that code
and sees the engagement it produced.

They are two feature directories and two routes rather than one screen with a
mode. `POST /api/claims` is deliberately not under `/api/employer` — a claimant
needs no grant, no engagement and no prior relationship to the venue — and a
claim panel filed under the employer surface would say the opposite with its
directory name.

### `write` is the one verb `api/client.ts` gained

`read` was "an authenticated GET that decodes or fails". `write` is the same
sentence one verb further: it takes the method, the path, an optional body and
**the single status that counts as success**, because the callers already
disagree about it — the offer succeeds `201` with a body and U5's roster removal
succeeds `204` with none.

**The decoder is optional and that is the whole difference from `read`.**
Omitting it means the body is never read, which is what makes a bodiless `204` a
success rather than `malformed_response` — and it is exactly what a
`read`-shaped implementation gets wrong. `read` cannot have that branch: every
route it serves answers `200` with a body, so a `204` there is a drift and is
reported as one. Both directions have a test, and `fake-api`'s `write` **fails
by default** like `read` does, asserted directly in `fake-api.test.ts` so a
surface cannot be tested without a reachable failure path.

### The venue picker is a grant-based read, not the venue-room list

`GET /api/employer/venues`, not `GET /api/venue-rooms`. The two return the same
`{venue_id, name}` shape and the second needed no new route, so this was the
plan's own recommendation — and it was settled the other way, for a reason that
is a fact about the contexts rather than a preference.

`Rooms.list_venue_rooms/1` applies `unsuspended/2`;
`Engagements.fetch_grant_holding_engagement/2` never consults a suspension. So a
manager who used the person-side venue-room opt-out — their own choice, about
their own reading, at their own venue — would keep full authority over that
venue and **disappear from their own picker**, with no other way in and nothing
failing anywhere to say why, since every employer request they made by hand
would still work. That is the coupling KTD18 exists to prevent, arriving at the
transport after both tiers below it got it right. `engagements_test.exs` carries
the suspended manager who appears in the grant-based list with
`list_venue_rooms/1` answering `[]` beside them; `employer-route.test.tsx`
asserts the path, because nothing about the rendered list distinguishes the two.

### The claim code exists in exactly one place

`useOfferDesk` holds it in component state. Nothing else touches it: no store,
no `localStorage` key, no URL, and nothing added to `SessionProvider`'s
`onSessionEnded`, because there is nothing here that would survive to be
cleared. The row keeps only a SHA-256 digest and no route renders one, so
dismissing does not hide the code — it loses it, which is why the warning sits
**beside** it rather than appearing afterwards (R2).

Three tests carry that, and each reaches the positive state before asserting an
absence: dismissing hides it and a re-render does not bring it back; choosing
another venue loses it (`VenueDesk` is keyed on the venue); and logging out
takes it off the screen, which is why `SessionBar` is on this page at all.

### Nothing on the employer page names a human

`GET /api/employer/venues/:venue_id/engagements` renders `{engagement_id,
role_label, starts_at, ends_at}` and there is no name column anywhere in the
schema to omit. The client carries the fourth pin on that (the server has three):
every decoder builds its object naming fields one at a time — never a spread —
so a `person_id` that reaches this client reaches nothing past the decoder.
`features/employer/decode.test.ts` pins the key set against a literal written
out in the test file and feeds a payload carrying `person_id` and an email
through it; `employer-route.test.tsx` does the same against the DOM, with the
same fixture, because a fixture without one would make both assertions pass for
the wrong reason.

## Deliberately absent, and why

Nothing below is stubbed. A placeholder for a shape nobody has chosen costs the
next unit more to find and undo than it costs to write from nothing.

| Surface                         | Waiting on | What is missing                                                               |
| ------------------------------- | ---------- | ----------------------------------------------------------------------------- |
| The employer's read of a record | U9         | `EmployerVenueChannel` events, and the answer to the employer-client question |
| Archived engagements, erasure   | U10        | Endpoints                                                                     |
| Demo controls                   | U11        | The control surface, which is not employer-scoped                             |

The worker-facing profile surface is **built** and its transport is not; that is
`src/features/profile/contract.ts` rather than a row here, because a row saying
"waiting on U9" would be wrong in both directions — U9 has landed, and the
events still do not exist.

`lib/hospitality_coms_web/router.ex` declares the four session routes, the four
room reads issue #48 added, the three employer routes and `POST /api/claims`,
plus the dev mailbox preview. `src/api/client.ts` covers the session four as
named methods and everything else through two generic verbs, `read` and `write`;
the paths and decoders live in the feature that owns them —
`features/rooms/rooms-api.ts`, `features/employer/employer-api.ts`,
`features/claim/claim-api.ts` — which is the shape the profile surface should
copy rather than adding methods to the client.

**Shifts and the roster are the employer half that is not here yet.** The
handshake is; `GET /api/employer/venues/:id/shift-rooms` and the roster writes
are the plan's U3 on the server and U5 here.

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
