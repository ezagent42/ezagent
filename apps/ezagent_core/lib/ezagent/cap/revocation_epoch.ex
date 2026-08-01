defmodule Ezagent.Cap.RevocationEpoch do
  @moduledoc """
  Durable three-state epoch for the per-cap revocation protocol.

  The row is monotone: absence is definitively `:inactive`, presence is
  `:active`, and an unreadable store is `:unknown`. Authorization-relevant
  callers must deny when the result is `:unknown`.
  """

  alias Ezagent.Ecto.CapRevocationEpoch
  alias Ezagent.{Cap.Signing, Capability}
  alias EzagentCore.Repo

  @singleton_id "per_cap"
  @pt_key {__MODULE__, :active}
  @test_seams Mix.env() == :test

  @doc "Resolve the durable epoch as `:inactive`, `:active`, or `:unknown`."
  @spec status() :: :inactive | :active | :unknown
  def status, do: override_or_runtime_status()

  @doc "Return true only when the epoch is definitively active."
  @spec active?() :: boolean()
  def active?, do: status() == :active

  @doc "Whether an artifact's signed protocol is admitted by the current epoch."
  @spec protocol_allowed?(Capability.t()) :: boolean()
  def protocol_allowed?(%Capability{} = cap), do: protocol_allowed?(cap, status())

  @doc false
  @spec protocol_allowed?(Capability.t(), :inactive | :active | :unknown) :: boolean()
  def protocol_allowed?(%Capability{} = cap, :inactive), do: Signing.valid_protocol?(cap)

  def protocol_allowed?(%Capability{signing_version: 2} = cap, :active),
    do: Signing.valid_protocol?(cap)

  def protocol_allowed?(%Capability{}, state) when state in [:active, :unknown], do: false

  if @test_seams do
    defp override_or_runtime_status do
      case Application.get_env(:ezagent_core, :cap_revocation_epoch_override, :unset) do
        state when state in [:inactive, :active, :unknown] -> state
        :unset -> runtime_status()
      end
    end
  else
    defp override_or_runtime_status, do: runtime_status()
  end

  defp runtime_status do
    case :persistent_term.get(@pt_key, :unset) do
      :active -> :active
      :unset -> db_status()
    end
  end

  defp db_status do
    case fetch_row() do
      {:ok, %CapRevocationEpoch{}} ->
        maybe_promote()
        :active

      {:ok, nil} ->
        :inactive

      :error ->
        :unknown
    end
  end

  if @test_seams do
    defp fetch_row do
      if Application.get_env(:ezagent_core, :cap_revocation_epoch_force_read_error, false) do
        :error
      else
        real_fetch_row()
      end
    end
  else
    defp fetch_row, do: real_fetch_row()
  end

  defp real_fetch_row do
    {:ok, Repo.get(CapRevocationEpoch, @singleton_id)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc "Idempotently activate the monotone epoch."
  @spec activate() :: :ok | {:error, term()}
  def activate do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %CapRevocationEpoch{}
    |> Ecto.Changeset.change(id: @singleton_id, activated_at: now)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :id)
    |> case do
      {:ok, _row} ->
        maybe_promote()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Prime the monotone active cache during application boot."
  @spec prime() :: :ok
  def prime do
    if persistent_cache_enabled?(), do: _ = db_status()
    :ok
  end

  defp maybe_promote do
    if persistent_cache_enabled?(), do: :persistent_term.put(@pt_key, :active)
    :ok
  end

  defp persistent_cache_enabled?, do: not @test_seams
end
