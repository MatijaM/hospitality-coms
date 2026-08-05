defmodule HospitalityComs.Locales.Artifact do
  @moduledoc """
  Reading and checking `priv/locales.json`, the one place the domain-to-locale
  rule is written down.

  This module exists for a compile-time reason rather than a conceptual one.
  `HospitalityComs.Locales` bakes the artifact's contents in at compile time, so
  the check that the artifact can be honoured has to run while that module's
  body is being evaluated — which is before that module exists and therefore
  before any function it defines can be called. Splitting the reader out is what
  lets the compile-time check and `HospitalityComs.Locales.validate!/1` be the
  same code rather than two statements of one rule.

  The rule itself is small and each clause is a failure somebody would otherwise
  meet at runtime, in production, as a page that will not load:

    * at least one locale, because an empty map makes every host resolve to a
      default that names nothing;
    * a default that is one of the locales, for the same reason;
    * every locale naming at least one host, because a locale no host reaches is
      a bundle nothing can ever be served from;
    * no host claimed twice, because the answer would then depend on map
      ordering, which is not a thing a reader should have to reason about.
  """

  @type t() :: %{String.t() => [String.t()]}

  @doc """
  Reads the artifact at `path`, checks it, and answers the decoded map.

  Raises rather than returning an error tuple: the only caller is a module body,
  where an error tuple would become a confusing match failure with no mention of
  the file that caused it.
  """
  @spec read!(Path.t()) :: map()
  def read!(path) do
    decoded =
      case path |> File.read!() |> Jason.decode() do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          raise ArgumentError, "#{path} is not valid JSON: #{Exception.message(reason)}"
      end

    :ok = validate!(decoded)

    decoded
  end

  @doc """
  Checks a decoded artifact, answering `:ok` or raising with the reason.

  Public because it is the same check `HospitalityComs.Locales` runs at compile
  time, and a rule enforced by a copy of itself is the defect this project has
  fixed under several other names.
  """
  @spec validate!(map()) :: :ok
  def validate!(%{"default" => default, "locales" => locales})
      when is_binary(default) and is_map(locales) do
    :ok = validate_non_empty!(locales)
    :ok = validate_default!(default, locales)
    :ok = validate_hosts!(locales)

    :ok
  end

  def validate!(other) do
    raise ArgumentError,
          ~s|a locales artifact needs a string "default" and a map of "locales", got: | <>
            inspect(other)
  end

  @spec validate_non_empty!(map()) :: :ok
  defp validate_non_empty!(locales) when map_size(locales) == 0 do
    raise ArgumentError, "a locales artifact must name at least one locale"
  end

  defp validate_non_empty!(_locales), do: :ok

  @spec validate_default!(String.t(), map()) :: :ok
  defp validate_default!(default, locales) do
    if Map.has_key?(locales, default) do
      :ok
    else
      raise ArgumentError,
            "the default locale #{inspect(default)} is not one of " <>
              inspect(Map.keys(locales))
    end
  end

  @spec validate_hosts!(map()) :: :ok
  defp validate_hosts!(locales) do
    Enum.each(locales, fn {locale, entry} ->
      case entry do
        %{"hosts" => [_ | _]} -> :ok
        _ -> raise ArgumentError, "locale #{inspect(locale)} names no host"
      end
    end)

    validate_hosts_unique!(locales)
  end

  @spec validate_hosts_unique!(map()) :: :ok
  defp validate_hosts_unique!(locales) do
    duplicates =
      locales
      |> Enum.flat_map(fn {_locale, %{"hosts" => hosts}} -> Enum.map(hosts, &normalise/1) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_host, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates == [] do
      :ok
    else
      raise ArgumentError,
            "these hosts are claimed by more than one locale: #{inspect(Enum.sort(duplicates))}"
    end
  end

  @doc """
  The comparable form of a host: lower-cased, with any port removed.

  Exported because `HospitalityComs.Locales` has to normalise an incoming host
  the same way this module normalised the artifact's, and two spellings of
  "the same host" is how a mapping comes to answer differently for `Example.com`
  and `example.com`.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> hd()
  end
end
