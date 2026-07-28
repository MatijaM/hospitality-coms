# Dialyzer warnings suppressed for this project.
#
# Add an entry only for a genuine false positive, and say in a comment why it
# is one. An entry without a reason is indistinguishable from a bug someone
# silenced in a hurry.
[
  # `Ecto.Multi`'s struct holds a `MapSet.t()` in its `:names` field, and
  # `MapSet.t()` is opaque. Every function that takes an `Ecto.Multi.t()` —
  # `Multi.run/3`, `Multi.insert/3`, and the rest — therefore reports
  # `call_without_opaque` at the call site, in any project, whether or not the
  # caller goes anywhere near the set. This code never touches it: it builds a
  # multi with the public API and hands it to `Repo.transaction/1`.
  #
  # Verified rather than assumed: `Multi.new()` on its own produces no warning,
  # and adding a single `Multi.run/3` with a constant-returning callback
  # produces exactly this one. There is nothing here to fix, and AGENTS.md
  # requires `Ecto.Multi` for multi-step writes, so the call cannot go away
  # either.
  {"lib/hospitality_coms/accounts.ex", :call_without_opaque},

  # The same `Ecto.Multi` / `MapSet.t()` false positive, at the venue-creation
  # multi. Confirmed to be the same one rather than assumed: the warning names
  # `%Ecto.Multi{:names => %MapSet{...}} (with opaque subterms) in the 1st
  # position` of `Ecto.Multi.insert/3`, which is the struct's own field and not
  # anything this module constructs or reads. Venue creation seeds its grant in
  # the same transaction and AGENTS.md requires `Ecto.Multi` for exactly that
  # shape, so the call cannot go away either.
  {"lib/hospitality_coms/venues.ex", :call_without_opaque},

  # The third instance of the same `Ecto.Multi` / `MapSet.t()` false positive,
  # at the claim's multi. It is reported against `Oban.insert/3` rather than
  # against an `Ecto.Multi` function this time, because that is the last call in
  # the pipeline that takes the struct — but the opaque subterm the warning
  # names is still `%Ecto.Multi{:names => %MapSet{...}}`, which this module
  # neither constructs nor reads.
  #
  # The call cannot go away: the expiry job has to be inserted inside the
  # claim's transaction, or a rolled-back claim leaves a job scheduled against
  # an engagement that was never written.
  {"lib/hospitality_coms/engagements.ex", :call_without_opaque},

  # The fourth instance of the same `Ecto.Multi` / `MapSet.t()` false positive,
  # reported four times in this file — once for each multi-step write the peer
  # graph has. Confirmed to be the same one rather than assumed: every warning
  # names `%Ecto.Multi{:names => %MapSet{...}} (with opaque subterms)` in the
  # argument position of a `Multi.run/3` or `Multi.insert/4` call, which is the
  # struct's own field and not anything this module constructs or reads.
  #
  # None of the four calls can go away. Sending a request supersedes the pair's
  # previous row and decides from what that statement returned before writing a
  # new one; accepting answers the request and opens the connection;
  # disconnecting closes the connection and writes KTD19's block on the request
  # it came from; sending a message takes the conversation under `FOR SHARE` and
  # then inserts. Each is a decision and a write that must not be able to
  # half-happen, which is exactly the shape AGENTS.md requires `Ecto.Multi` for.
  {"lib/hospitality_coms/peers.ex", :call_without_opaque}
]
