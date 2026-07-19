defmodule Ezagent.Identity.AgentTombstone do
  @moduledoc """
  Durable tombstone marker for an offboarded AGENT — the agent-side mirror
  of the `users.deleted_*` row (task #180 owned-agent authority cascade).

  Deleting a user revokes ALL authority that derives from that user. The
  owned/lineage agents' revocation is recorded HERE: one row per tombstoned
  agent URI, retained (never purged) so:

    - the spawn fence (`Ezagent.Identity.Offboarding.refute_tombstoned/1`,
      registered into `Ezagent.SpawnFence`, plus the Identity Lifecycle
      fence) refuses re-spawn/activate even if the agent's lineage row or
      snapshot is lost — the marker is the fail-closed durable record;
    - `Token.authenticate/1` rejects the agent's PATs even for a token row
      that somehow survived the cascade's revocation sweep;
    - the idempotent cascade retry can tell "already tombstoned" (re-assert
      teardown) from "never touched".

  The row carries `workspace_uri` (NOT NULL) per the Phase 9 per-tenant
  discipline (invariant #14) — derived from the agent's 3-segment entity
  URI, never caller-supplied.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:agent_uri, :string, autogenerate: false}
  schema "agent_tombstones" do
    field(:workspace_uri, :string)
    field(:tombstoned_by, :string)
    field(:tombstoned_reason, :string)
    field(:tombstoned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc """
  Record the tombstone for `agent_uri`. Idempotent — the FIRST tombstone
  wins (mirrors `Users.tombstone/3` preserving the original
  timestamp/actor on retry); a repeat call is a no-op `:ok`.

  Only an `entity://…/agent/…` URI may be tombstoned here; anything else
  returns `{:error, :invalid_agent_uri}`.
  """
  @spec tombstone(URI.t() | String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def tombstone(agent_uri, tombstoned_by, reason) do
    with {:ok, canonical} <- canonical_agent_uri(agent_uri) do
      uri_str = URI.to_string(canonical)
      workspace_uri = Ezagent.Persistence.workspace_uri_for!(canonical)
      now = DateTime.utc_now()

      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        agent_uri: uri_str,
        workspace_uri: workspace_uri,
        tombstoned_by: tombstoned_by,
        tombstoned_reason: reason,
        tombstoned_at: now,
        inserted_at: now
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:agent_uri])
      |> case do
        {:ok, _row} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Whether `agent_uri` has been tombstoned by the owner-offboarding cascade.
  Unknown agents are NOT tombstoned (`false`) — mirrors `Users.deleted?/1`'s
  "absence is not deletion" so the fence fails open only for principals
  that genuinely have no tombstone record.
  """
  @spec tombstoned?(URI.t() | String.t()) :: boolean()
  def tombstoned?(agent_uri) do
    case canonical_agent_uri(agent_uri) do
      {:ok, canonical} ->
        case Repo.get(__MODULE__, URI.to_string(canonical)) do
          %__MODULE__{} -> true
          _ -> false
        end

      :error ->
        false
    end
  end

  @doc "Fetch the tombstone row for `agent_uri` (audit reads), or `nil`."
  @spec get(URI.t() | String.t()) :: t() | nil
  def get(agent_uri) do
    case canonical_agent_uri(agent_uri) do
      {:ok, canonical} -> Repo.get(__MODULE__, URI.to_string(canonical))
      :error -> nil
    end
  end

  @doc """
  List tombstoned agent URIs scoped to a single workspace — the standard
  per-tenant read path (SPEC v3 §7.2).
  """
  @spec list_in_workspace(URI.t() | String.t()) :: [t()]
  def list_in_workspace(workspace_uri) do
    __MODULE__
    |> Ezagent.Persistence.scope_by_workspace(workspace_uri)
    |> order_by([t], t.agent_uri)
    |> Repo.all()
  end

  defp canonical_agent_uri(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      {:ok, Ezagent.URI.instance(uri)}
    else
      :error
    end
  end

  defp canonical_agent_uri(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, parsed} -> canonical_agent_uri(parsed)
      _ -> :error
    end
  end

  defp canonical_agent_uri(_), do: :error
end
