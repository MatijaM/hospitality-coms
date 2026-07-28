[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  # `dev_support` is here for the reason `lib` is: it holds application code —
  # the offsettable clock, the project's Credo checks, and U11's demo controls —
  # and CI's `mix format --check-formatted` reads exactly this list. Left out, it
  # was a blind spot the formatter never entered and the check could never fail
  # on, which is worse than not running the check at all.
  inputs: ["*.{ex,exs}", "{config,dev_support,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]
