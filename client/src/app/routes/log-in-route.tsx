/**
 * Asking for a magic link, and redeeming one that was pasted back.
 *
 * Two things here are the API's behaviour rather than a design choice.
 *
 * The confirmation must not say whether the address was known. `POST
 * /api/log-in` registers an unknown address and answers 202 either way — one
 * door, and the same answer to an enumeration attempt — so a message reading
 * "welcome back" would hand back exactly what the endpoint refuses to.
 *
 * The paste box exists because in development the link points at
 * `localhost:4000`, which is Phoenix and renders nothing: `/dev/mailbox` is the
 * only way to read one. It takes the whole link or the bare token.
 */

import { Navigate } from "react-router";
import { useState } from "react";

import type { ApiFieldError, RequestFailure } from "../../api/errors";
import { tokenFromPastedValue } from "../../session/magic-link";
import { useSession } from "../../session/session-context";
import { failureMessage } from "../failure-message";

type LinkRequest =
  | { status: "idle" }
  | { status: "sending" }
  | { status: "sent" }
  | { status: "failed"; failure: RequestFailure };

export function LogInRoute() {
  const { state, api, redeem } = useSession();
  const [email, setEmail] = useState("");
  const [request, setRequest] = useState<LinkRequest>({ status: "idle" });

  if (state.status === "authenticated") return <Navigate to="/" replace />;
  if (state.status === "resolving") return <p role="status">Checking your session…</p>;

  async function submit() {
    setRequest({ status: "sending" });

    const result = await api.requestMagicLink(email);

    setRequest(
      result.ok ? { status: "sent" } : { status: "failed", failure: result.failure },
    );
  }

  return (
    <section>
      <h1>Log in</h1>
      <p>
        We will email you a link. There is no password — this application has never had
        one.
      </p>

      <form
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <label htmlFor="email">Email address</label>
        <input
          id="email"
          name="email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(event) => {
            setEmail(event.target.value);
          }}
        />
        <FieldMessages request={request} field="email" />
        <button type="submit" disabled={request.status === "sending"}>
          Send me a link
        </button>
      </form>

      <RequestOutcome request={request} />
      {request.status === "sent" && <PasteLinkForm onRedeem={redeem} />}
    </section>
  );
}

function RequestOutcome({ request }: { readonly request: LinkRequest }) {
  switch (request.status) {
    case "idle":
    case "sending":
      return null;
    case "sent":
      return (
        <p role="status">
          If that address can receive mail, a link is on its way. It is good for fifteen
          minutes.
        </p>
      );
    case "failed":
      // A per-field message is rendered against the input it names, so the
      // banner would be a second copy of the same complaint — but only for the
      // inputs this form actually has.
      if (request.failure.kind === "api_field_error") {
        return <UnattachedMessages failure={request.failure} />;
      }

      return <p role="alert">{failureMessage(request.failure)}</p>;
  }
}

/** The inputs this form renders, and can therefore attach a message to. */
const RENDERED_FIELDS = ["email"];

/**
 * Anything the server rejected that this form has nowhere to put.
 *
 * Not reachable from today's `SessionController`, which names `email` and
 * nothing else. It is here because the alternative is silence: without it a
 * 422 naming any other field renders no message anywhere, and the worker sees
 * a submit that did nothing at all.
 */
function UnattachedMessages({ failure }: { readonly failure: ApiFieldError }) {
  const messages = Object.entries(failure.fields)
    .filter(([field]) => !RENDERED_FIELDS.includes(field))
    .flatMap(([, fieldMessages]) => fieldMessages);

  if (messages.length === 0) return null;

  return <p role="alert">{messages.join(" ")}</p>;
}

function FieldMessages({
  request,
  field,
}: {
  readonly request: LinkRequest;
  readonly field: string;
}) {
  if (request.status !== "failed") return null;
  if (request.failure.kind !== "api_field_error") return null;

  return <FieldList failure={request.failure} field={field} />;
}

function FieldList({
  failure,
  field,
}: {
  readonly failure: ApiFieldError;
  readonly field: string;
}) {
  const messages = failure.fields[field] ?? [];

  return (
    <ul>
      {messages.map((message) => (
        <li key={message} role="alert">
          {message}
        </li>
      ))}
    </ul>
  );
}

function PasteLinkForm({
  onRedeem,
}: {
  readonly onRedeem: (
    linkToken: string,
  ) => Promise<{ ok: true } | { ok: false; failure: RequestFailure }>;
}) {
  const [pasted, setPasted] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const [redeeming, setRedeeming] = useState(false);

  async function submit() {
    // A link is single use. Two redemptions in flight means the second meets
    // the 401 a spent link gets, and writes "That is no longer valid" over the
    // one that succeeded.
    if (redeeming) return;

    const linkToken = tokenFromPastedValue(pasted);

    if (linkToken === null) {
      setProblem("That does not look like a log-in link.");

      return;
    }

    setRedeeming(true);
    const outcome = await onRedeem(linkToken);

    // On success this component is about to be replaced by a redirect to the
    // authenticated surface, so the button stays disabled: there is nothing
    // left to redeem and re-enabling it only offers a second attempt that
    // would fail.
    if (outcome.ok) {
      setProblem(null);

      return;
    }

    setRedeeming(false);
    setProblem(failureMessage(outcome.failure));
  }

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <label htmlFor="pasted-link">
        Paste the link from your email (in development, from /dev/mailbox)
      </label>
      <input
        id="pasted-link"
        name="pasted-link"
        type="text"
        value={pasted}
        onChange={(event) => {
          setPasted(event.target.value);
        }}
      />
      {problem !== null && <p role="alert">{problem}</p>}
      <button type="submit" disabled={redeeming}>
        Log in with this link
      </button>
    </form>
  );
}
