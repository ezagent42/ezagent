defmodule Ezagent.Identity.Offboarding.Reaper do
  @moduledoc """
  Honest process/snapshot cleanup after generation revocation has committed.

  Correctness does not depend on this cleanup: the principal is already inert.
  A successful return nevertheless proves both that no live Kind remains and
  that its durable snapshot has been removed.
  """

  alias Ezagent.Ecto.KindSnapshot

  @spec teardown_and_reap(URI.t()) ::
          :ok | {:error, {:teardown_incomplete, URI.t(), term()}}
  def teardown_and_reap(%URI{} = uri) do
    case Ezagent.Lifecycle.destroy(uri) do
      :ok -> verify_reaped(uri)
      {:error, reason} -> {:error, {:teardown_incomplete, uri, reason}}
    end
  rescue
    error -> {:error, {:teardown_incomplete, uri, {:reap_crashed, error}}}
  catch
    kind, reason -> {:error, {:teardown_incomplete, uri, {kind, reason}}}
  end

  defp verify_reaped(uri) do
    cond do
      live_process?(uri) ->
        {:error, {:teardown_incomplete, uri, :still_alive}}

      KindSnapshot.get(Ezagent.URI.stable_key(uri)) != nil ->
        {:error, {:teardown_incomplete, uri, :residual_snapshot}}

      true ->
        :ok
    end
  end

  defp live_process?(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) -> Process.alive?(pid)
      :error -> false
    end
  end
end
