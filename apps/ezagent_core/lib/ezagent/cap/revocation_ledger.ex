defmodule Ezagent.Cap.RevocationLedger do
  @moduledoc """
  Core-owned access to the absorbing per-capability revocation ledger.

  Reads are always workspace-scoped and return an explicit error so callers at
  authorization and persistence boundaries can fail closed.
  """

  import Ecto.Query

  alias Ezagent.Ecto.CapRevocation
  alias EzagentCore.Repo

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
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp stable_workspace_key(%URI{} = workspace_uri),
    do: Ezagent.URI.stable_key(workspace_uri)

  defp stable_workspace_key(workspace_uri) when is_binary(workspace_uri),
    do: workspace_uri |> Ezagent.URI.new!() |> Ezagent.URI.stable_key()
end
