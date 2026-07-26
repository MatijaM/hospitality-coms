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
  {"lib/hospitality_coms/accounts.ex", :call_without_opaque}
]
