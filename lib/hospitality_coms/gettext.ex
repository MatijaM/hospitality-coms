defmodule HospitalityComs.Gettext do
  @moduledoc """
  The one translation backend, and it is in the context layer deliberately.

  Phoenix scaffolds this module under the web namespace, which is where it sat —
  unused — for twelve units. It is here instead because two of the three things
  this application translates on the server are owned by contexts rather than by
  the web layer: `HospitalityComs.Profiles.incompleteness_notice/0`, and the
  magic-link emails in `HospitalityComs.Accounts.PersonNotifier`. A backend
  under `HospitalityComsWeb` would make those contexts depend on the web layer,
  which nothing in `lib/hospitality_coms/` does today — the web namespace
  appears there in prose and in no line of code.

  The other direction is fine, so the web layer uses this one. One backend
  rather than two also means one set of catalogues under `priv/gettext`; two
  backends reading the same directory would compile the same `.po` files twice
  and give a future author a choice about which to call.

  ## Locale names are the identifiers in `priv/locales.json`

  The catalogue directories are `en` and `sr-Latn` — the same strings the
  domain mapping uses, the same strings the client build emits as bundle
  directory names. Gettext does not require the underscored form that is
  conventional elsewhere, and taking it would have created a second spelling of
  a locale for `HospitalityComs.Locales` to translate into, which is the defect
  this project has fixed under several other names.

  ## Setting it

  `HospitalityComsWeb.Locale` resolves a request's locale from its `Origin` and
  calls `Gettext.put_locale/1`, which is process-scoped. Everything downstream
  in that request reads it without being passed a parameter — including mail
  delivery, which is synchronous. That last part is load-bearing rather than
  incidental: moving delivery onto a job would leave the emails in the default
  locale with nothing failing.
  """

  # The pluralizer is `HospitalityComs.Gettext.Plural`, and it is named in
  # `config/config.exs` rather than here.
  #
  # `sr-Latn` is not a locale Gettext's default pluralizer knows — it derives a
  # language by splitting on an underscore, so the hyphenated form raises — and
  # the module that fixes that has to be reachable from two places: this
  # backend's compilation, and `mix gettext.merge`, which creates the catalogue
  # files. The backend accepts a `:plural_forms` option and falls back to
  # `Application.get_env(:gettext, :plural_forms)`; the mix task reads only the
  # latter. So the application setting covers both and the option here would be
  # a second statement of one choice.
  use Gettext.Backend, otp_app: :hospitality_coms
end
