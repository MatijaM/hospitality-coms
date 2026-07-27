import { Link } from "react-router";

export function NotFoundRoute() {
  return (
    <section>
      <h1>Nothing here</h1>
      <p>
        This client has four surfaces so far. The rest arrive with the units that give
        them something to show.
      </p>
      <Link to="/">Back to the start</Link>
    </section>
  );
}
