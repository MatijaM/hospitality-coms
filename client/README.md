# client

The React client for hospitality-coms. This is the **foundation** of U12, not
U12: the plan's own note says U12 "is the coarsest unit in the plan and will
likely split during execution once the surface count is real", and this is that
split. What is here is everything that does not depend on U7–U11.

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

**No schema-validation library.** There are three response shapes. Hand-written
decoders in `src/api/decode.ts` are shorter than the dependency and produce
better failures. When U8–U11 land their surfaces this is the decision to
revisit, not the file to extend indefinitely.

**No state manager, no component library, no design system.** There is one form
and one list. The unit that builds the rooms should choose these knowing what it
is styling.

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

### CORS, and why there is none

The Phoenix endpoint mounts no CORS plug — it never needed one. So the dev
server **proxies** `/api` (and `/socket`, for when it exists) to `localhost:4000`
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

`npm test` skips `src/api/client.integration.test.ts`, which runs the whole
log-in flow against a live server and reads the magic link out of
`/dev/mailbox/json`. Run it with the server up:

```bash
HOSPITALITY_COMS_API_URL=http://localhost:4000 npm test
```

It is the only test here that checks this client's idea of the API against the
API rather than against a stub this project also wrote, so run it whenever the
API changes.

## How the code is arranged

```
src/api/          the four endpoints, their types, and every way they can fail
src/session/      who is logged in, where the token lives, magic-link parsing
src/socket/       the Phoenix socket connection — no topics, see below
src/app/          routes and the surfaces they render
src/test-support/ fakes shared by the tests above the API client
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
joins a topic somebody else names, and leaves. It knows **no topic name, no
event name and no payload shape**, because U7 was deciding all three while this
was written.

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

**Nothing connects the socket.** There is no topic to join, so wiring it into
the app would be a guess. Two values are configuration with a conventional
default for U7 to set: the endpoint path (`/socket`) and the name of the params
key the token travels under (`token`).

### Where the token lives

`localStorage`, chosen with the consequence understood: the token is the
credential, so anything that can run script on this origin can act as the
worker. There is no cookie session to use instead, an `HttpOnly` cookie is not
readable by the `fetch` calls that must send it as a bearer header, and memory
alone would end the session on every refresh. It is behind a `TokenStore`
interface, so moving it is one file.

## Deliberately absent, and why

Nothing below is stubbed. A placeholder for a shape nobody has chosen costs the
next unit more to find and undo than it costs to write from nothing.

| Surface                                            | Waiting on | What is missing                                      |
| -------------------------------------------------- | ---------- | ---------------------------------------------------- |
| Shift and venue rooms, composer, closed-room state | U7         | Channel topics, event names, payloads                |
| Peer directory, requests, peer conversations       | U8         | Endpoints and the multiplexed person channel (KTD10) |
| Profile, attested entries, disclosure controls     | U9         | Endpoints, and the per-employer view                 |
| Archived engagements, erasure                      | U10        | Endpoints                                            |
| Demo controls                                      | U11        | The control surface, which is not employer-scoped    |

`lib/hospitality_coms_web/router.ex` declares four API routes plus the dev
mailbox preview, and those four are exactly what `src/api/` covers. U5 and U6
built contexts, not endpoints: there is no HTTP surface for engagements, rooms,
messages or rosters yet, so there is nothing here for them either.

### Things that were tempting to guess, and were not

Recorded so the next unit knows they are open questions and not settled:

- **The socket mount path.** `/socket` is the Phoenix default and is what the
  Vite proxy assumes. `HospitalityComsWeb.Endpoint` currently declares no socket
  at all; U7 adds `PersonSocket` and `EmployerSocket` (KTD9).
- **The socket's token parameter.** `token` is the convention; the key that
  matters is whatever `connect/3` pattern matches on, and it has not been
  written. Configurable in one place.
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
