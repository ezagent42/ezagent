defmodule Ezagent.Cap.RevocationLedger do
  @moduledoc """
  Core-owned access to the absorbing per-capability revocation ledger.

  Reads are always workspace-scoped and return an explicit error so callers at
  authorization and persistence boundaries can fail closed.
  """

  import Ecto.Query

  alias Ezagent.Ecto.CapRevocation
  alias Ezagent.{Cap.RevocationEpoch, Capability}
  alias Ezagent.Capability.Normalize
  alias EzagentCore.Repo

  @test_seams Mix.env() == :test

  @doc "Insert an absorbing marker, returning the original marker on retries."
  @spec mark(map()) :: {:ok, CapRevocation.t()} | {:error, term()}
  def mark(attrs) when is_map(attrs) do
    grant_id = Map.get(attrs, :grant_id) || Map.get(attrs, "grant_id")

    with {:ok, _row} <-
           %CapRevocation{}
           |> CapRevocation.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :grant_id),
         %CapRevocation{} = durable <- Repo.get(CapRevocation, grant_id) do
      {:ok, durable}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :ledger_write_failed}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Return the revoked subset of a grant-id batch inside one workspace."
  @spec revoked_grant_ids(URI.t() | String.t(), [String.t()]) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def revoked_grant_ids(_workspace_uri, []), do: {:ok, MapSet.new()}

  def revoked_grant_ids(workspace_uri, grant_ids) when is_list(grant_ids) do
    with :ok <- maybe_force_read_error() do
      workspace_uri = stable_workspace_key(workspace_uri)
      grant_ids = Enum.uniq(grant_ids)

      revoked =
        from(row in CapRevocation,
          where: row.workspace_uri == ^workspace_uri and row.grant_id in ^grant_ids,
          select: row.grant_id
        )
        |> Repo.all()
        |> MapSet.new()

      {:ok, revoked}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Filter denied protocols and revoked v2 grants from a read-side batch."
  @spec filter_unrevoked(URI.t() | String.t(), [Capability.t()]) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def filter_unrevoked(workspace_uri, caps) when is_list(caps) do
    caps = Enum.map(caps, &Normalize.fill_defaults/1)

    case RevocationEpoch.status() do
      :unknown ->
        {:error, :cap_revocation_epoch_unreadable}

      state when state in [:inactive, :active] ->
        allowed = Enum.filter(caps, &RevocationEpoch.protocol_allowed?(&1, state))

        case revoked_ids_for_caps(workspace_uri, allowed) do
          {:ok, revoked} ->
            {:ok, Enum.reject(allowed, &MapSet.member?(revoked, Map.get(&1, :grant_id)))}

          {:error, _reason} ->
            {:error, :cap_revocation_ledger_unreadable}
        end
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Reject a write-side batch unless every artifact is admitted and unrevoked."
  @spec ensure_unrevoked(URI.t() | String.t(), [Capability.t()]) :: :ok | {:error, term()}
  def ensure_unrevoked(workspace_uri, caps) when is_list(caps) do
    caps = Enum.map(caps, &Normalize.fill_defaults/1)

    case RevocationEpoch.status() do
      :unknown ->
        {:error, :cap_revocation_epoch_unreadable}

      state when state in [:inactive, :active] ->
        if Enum.all?(caps, &RevocationEpoch.protocol_allowed?(&1, state)) do
          case revoked_ids_for_caps(workspace_uri, caps) do
            {:ok, revoked} ->
              case revoked |> MapSet.to_list() |> Enum.sort() do
                [] -> :ok
                grant_ids -> {:error, {:revoked_capability_grants, grant_ids}}
              end

            {:error, _reason} ->
              {:error, :cap_revocation_ledger_unreadable}
          end
        else
          {:error, :invalid_capability_protocol}
        end
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp revoked_ids_for_caps(workspace_uri, caps) do
    grant_ids =
      for %Capability{signing_version: 2, grant_id: grant_id} <- caps,
          is_binary(grant_id),
          grant_id != "",
          do: grant_id

    revoked_grant_ids(workspace_uri, grant_ids)
  end

  defp stable_workspace_key(%URI{} = workspace_uri),
    do: Ezagent.URI.stable_key(workspace_uri)

  defp stable_workspace_key(workspace_uri) when is_binary(workspace_uri),
    do: workspace_uri |> Ezagent.URI.new!() |> Ezagent.URI.stable_key()

  defp stable_workspace_key(:any),
    do: :system |> Ezagent.URI.workspace() |> Ezagent.URI.stable_key()

  if @test_seams do
    defp maybe_force_read_error do
      if Application.get_env(:ezagent_core, :cap_revocation_ledger_force_read_error, false),
        do: {:error, :forced_ledger_read_error},
        else: :ok
    end
  else
    defp maybe_force_read_error, do: :ok
  end
end
