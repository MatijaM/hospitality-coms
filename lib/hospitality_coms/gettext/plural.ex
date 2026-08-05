defmodule HospitalityComs.Gettext.Plural do
  @moduledoc """
  How many plural forms a locale has, and which one a count takes.

  ## Why this module exists at all

  `Gettext.Plural` covers most languages and does not cover `sr-Latn`. It
  derives a language from the locale string by splitting on an underscore, so
  `sr_Latn` resolves and the hyphenated form raises `UnknownLocaleError` at
  merge time.

  The cheap fix is to spell the Gettext directory `sr_Latn` and leave everything
  else alone. That was declined: the locale identifier is already three things —
  the key in `priv/locales.json`, the bundle directory the client build emits,
  and the string `HospitalityComs.Locales` resolves a host to — and a fourth
  spelling that differs by one character is the shape of defect this project has
  fixed repeatedly under other names. One identifier, and a module to make it
  work.

  ## What it buys beyond that

  Serbian's rule is now written down here rather than inherited from a table,
  and `plural_test.exs` exercises it at the boundaries. That matters more than
  it looks: a wrong plural rule produces grammatical-looking output in the wrong
  form, which no assertion about *which string came back* would ever notice. It
  is the "data, not code" hazard the plan names, made into code that can be
  tested.

  ## The rule

  Three forms, the standard CLDR rule for Serbian, Croatian, Bosnian and
  Russian-family languages:

    * **one** — counts ending in 1, except 11: 1, 21, 101
    * **few** — counts ending in 2, 3 or 4, except 12, 13, 14: 2, 3, 22, 104
    * **other** — everything else, including 0, 5–20, and the teens

  Everything that is not `sr-Latn` falls through to `Gettext.Plural`, so adding
  a locale does not mean re-deriving rules this module has no business owning.
  """

  @behaviour Gettext.Plural

  @serbian "sr-Latn"

  @impl Gettext.Plural
  def nplurals(@serbian), do: 3
  def nplurals(locale), do: Gettext.Plural.nplurals(locale)

  @impl Gettext.Plural
  def plural(@serbian, count) do
    cond do
      rem(count, 10) == 1 and rem(count, 100) != 11 -> 0
      rem(count, 10) in 2..4 and rem(count, 100) not in 12..14 -> 1
      true -> 2
    end
  end

  def plural(locale, count), do: Gettext.Plural.plural(locale, count)

  @impl Gettext.Plural
  def plural_forms_header(@serbian) do
    "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);"
  end

  def plural_forms_header(locale), do: Gettext.Plural.plural_forms_header(locale)
end
