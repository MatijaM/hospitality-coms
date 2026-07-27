# hospitality-coms
Communications platform for hospitality businesses

The Phoenix application is the whole of this repository except `client/`, which
holds the React client and its own toolchain — the backend has been API-only
since U2 removed the HTML layer, so there is no asset pipeline for it to live
in. See [`client/README.md`](client/README.md) for the stack, how to run it
against `mix phx.server`, and what it deliberately does not cover yet.
