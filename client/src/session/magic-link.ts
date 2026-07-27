/**
 * Getting the token out of whatever the worker pasted.
 *
 * A magic link is `MAGIC_LINK_BASE_URL <> encoded_token` — the base is a plain
 * string prefix in `config/runtime.exs` and the token is appended to it — so
 * the token is the last path segment and nothing has to be parsed out of a
 * query string.
 *
 * The paste box exists because in development the link points at
 * `localhost:4000`, which is Phoenix and serves no page: `/dev/mailbox` is the
 * only way to read a link, and clicking it lands on the API. Accepting the
 * whole link *or* the bare token means neither the demo nor a real mail client
 * needs the base URL to have been configured correctly first.
 */
export function tokenFromPastedValue(value: string): string | null {
  const trimmed = value.trim();
  if (trimmed === "") return null;

  const segments = pathOf(trimmed)
    .split("/")
    .filter((segment) => segment !== "");

  return segments.at(-1) ?? null;
}

function pathOf(value: string): string {
  try {
    return new URL(value).pathname;
  } catch {
    // Not a URL, so it is the token itself.
    return value;
  }
}
