defmodule HospitalityComs.Locales do
  @moduledoc """
  Which language a request is answered in, and the domain that decides it.

  There are two locales — `en`, the default, and `sr-Latn` — and the only thing
  that selects one is the domain the platform was reached on. There is no
  in-app switcher, no `Accept-Language` negotiation and no preference stored
  against a person, which is what makes one bundle per locale possible: the
  client is built once per language and Phoenix serves whichever bundle the
  request's host names.

  ## The mapping is an artifact, not a literal in this module

  `priv/locales.json` is read here at compile time and read again by the client
  build. That is the whole point of it being a file: the rule lives on both
  sides of the wire — the server resolves a request's locale, the build decides
  which bundle to emit — and two copies of one rule drift. `locales_test.exs`
  reads the artifact independently and requires this module to agree with it,
  so inlining the map fails the suite rather than working until somebody edits
  one copy.

  ## Compile time rather than runtime, deliberately

  The values are baked in when this module compiles, so a malformed artifact is
  a build failure rather than a page that will not load. `priv/` ships inside a
  release, so nothing here needs the file at runtime. The cost is that changing
  a host requires a recompile, which is the right trade when the client bundles
  are also built from that same file — a runtime override would let the server
  and the client disagree about which domain is which language, which is
  exactly what the artifact exists to prevent.

  ## Two readers, because a request carries the host two ways

  `for_host/1` takes a `Host` header, which is what a request for the client
  itself carries. `for_origin/1` takes an `Origin` header, which is what an API
  request carries and what a magic link must be built against. Both resolve
  through the same table; neither raises, because an unrecognised value is an
  ordinary thing for a public endpoint to receive and the default is always a
  correct answer.
  """

  alias HospitalityComs.Locales.Artifact

  @artifact_path "priv/locales.json"
  @external_resource @artifact_path

  @artifact Artifact.read!(@artifact_path)

  @default @artifact["default"]
  @all @artifact["locales"] |> Map.keys() |> Enum.sort()

  @by_host for {locale, %{"hosts" => hosts}} <- @artifact["locales"],
               host <- hosts,
               into: %{},
               do: {Artifact.normalise(host), locale}

  @doc """
  The locale used when nothing else selects one.
  """
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Every locale this application is built and served in, sorted.

  These strings are also the directory names the client build emits under
  `priv/static`, which is what lets `HospitalityComsWeb.Static` find a bundle
  from a locale without a second mapping.
  """
  @spec all() :: [String.t()]
  def all, do: @all

  @doc """
  Whether a string is one of this application's locales.
  """
  @spec known?(String.t()) :: boolean()
  def known?(locale) when is_binary(locale), do: locale in @all
  def known?(_locale), do: false

  @doc """
  The locale a `Host` names, or the default when it names none.
  """
  @spec for_host(String.t() | nil) :: String.t()
  def for_host(host) when is_binary(host) do
    Map.get(@by_host, Artifact.normalise(host), @default)
  end

  def for_host(_host), do: @default

  @doc """
  The locale an `Origin` names, or the default when it names none.

  A bare host is not an origin and answers the default: `Origin` is scheme,
  host and optional port, and treating `"app.example.rs"` as one would accept a
  header no browser sends while making the failure case harder to reason about.
  """
  @spec for_origin(String.t() | nil) :: String.t()
  def for_origin(origin) when is_binary(origin) do
    case URI.new(origin) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> for_host(host)
      _otherwise -> @default
    end
  end

  def for_origin(_origin), do: @default

  @doc """
  Checks a decoded artifact, answering `:ok` or raising with the reason.

  Delegates to the reader this module's own compile-time check runs, so the two
  cannot come to mean different things.
  """
  @spec validate!(map()) :: :ok
  defdelegate validate!(artifact), to: Artifact
end
