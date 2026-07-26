defmodule HospitalityComs.UnreachableMailerAdapter do
  @moduledoc """
  A Swoosh adapter that is always down.

  A mail provider outage is the one failure the log-in path cannot avoid and
  must not turn into a 500, so there has to be a way to have one on demand.
  The reason it returns is deliberately adapter-shaped and unbounded — that is
  what the notifier collapses into a single enumerated atom.
  """

  use Swoosh.Adapter

  @doc """
  Fails the delivery the way a refused connection to a provider would.
  """
  @impl Swoosh.Adapter
  @spec deliver(Swoosh.Email.t(), keyword()) :: {:error, {:network_error, :econnrefused}}
  def deliver(_email, _config), do: {:error, {:network_error, :econnrefused}}

  @doc """
  Fails a batch the same way.
  """
  @impl Swoosh.Adapter
  @spec deliver_many([Swoosh.Email.t()], keyword()) :: {:error, {:network_error, :econnrefused}}
  def deliver_many(_emails, _config), do: {:error, {:network_error, :econnrefused}}
end
