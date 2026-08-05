/**
 * The catch-all route.
 *
 * It used to carry a sentence counting this client's surfaces and saying the
 * rest would "arrive with the units that give them something to show". That was
 * a note to a developer about the plan's progress, on the one page a worker
 * reaches by mistyping a URL — and it had gone stale besides, still saying four
 * after `/employer` and `/claim` landed. A count of what exists is a claim that
 * needs maintaining and that nobody maintains; the way back is what the page is
 * actually for.
 */

import { Link } from "react-router";

import { copy } from "../../i18n/copy";

export function NotFoundRoute() {
  return (
    <section>
      <h1>{copy["notFound.heading"]}</h1>
      <Link to="/">{copy["notFound.backLink"]}</Link>
    </section>
  );
}
