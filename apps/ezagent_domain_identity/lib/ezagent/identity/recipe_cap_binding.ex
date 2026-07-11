defmodule Ezagent.Identity.RecipeCapBinding do
  @moduledoc """
  Durable, identity-tier home for pre-issued recipe capabilities.

  A materializer resolves a recipe before an agent exists, asks `Ezagent.Cap`
  to issue every proposed artifact under the recorded authority, and only then
  commits the complete set here. The keyed agent later reads the artifacts from
  its own Identity lifecycle hooks; persistence never dispatches a cap write to
  the grantee.

  Bindings are keyed by `Ezagent.URI.instance/1`. Repeating the same logical
  recipe is idempotent even though `Cap.issue/3` stamps a fresh `granted_at` on
  every attempt. Reusing the URI for changed content, or reviving a tombstoned
  binding, advances a monotonic version.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  @primary_key {:agent_uri, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "recipe_cap_bindings" do
    field(:workspace_uri, :string)
    field(:recipe_name, :string)
    field(:issuer_uri, :string)
    field(:artifacts, :map)
    field(:content_hash, :string)
    field(:version, :integer, default: 1)
    field(:tombstoned_at, :utc_datetime_usec)
    field(:gc_pruned_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}
  @type fetched :: %{
          caps: [Capability.t()],
          version: pos_integer(),
          recipe_name: String.t(),
          issuer_uri: URI.t()
        }

  @doc """
  Fully authorize `proposals`, then atomically insert or update their binding.

  ISSUE is deliberately completed before `Repo.transaction/1` begins. No
  caller-supplied authority set is accepted: `Cap.issue/3` loads the issuer's
  held caps through its configured durable authority loader.
  """
  @spec issue_and_upsert(URI.t(), String.t(), URI.t(), [Capability.t()]) ::
          {:ok, fetched()} | {:error, term()}
  def issue_and_upsert(%URI{} = agent_uri, recipe_name, %URI{} = issuer_uri, proposals)
      when is_binary(recipe_name) and recipe_name != "" and is_list(proposals) do
    agent_uri = Ezagent.URI.instance(agent_uri)
    issuer_uri = Ezagent.URI.instance(issuer_uri)

    with {:ok, workspace_uri} <- validate_binding_uris(agent_uri, issuer_uri),
         {:ok, issued} <- issue_all(agent_uri, issuer_uri, proposals),
         :ok <- validate_issued_set(issued, agent_uri, workspace_uri, issuer_uri) do
      persist_issued(agent_uri, workspace_uri, recipe_name, issuer_uri, issued)
    end
  end

  @doc """
  Fetch an active binding by canonical agent instance.

  Tombstoned, malformed, corrupted, or structurally invalid rows fail closed as
  `:not_found`. The Identity `create/1` and `activate/2` lifecycle homes apply
  `Cap.verify/1` immediately before these artifacts enter the `:caps` slice.
  """
  @spec fetch(URI.t()) :: {:ok, fetched()} | :not_found
  def fetch(%URI{} = agent_uri) do
    canonical = agent_uri |> Ezagent.URI.instance() |> URI.to_string()

    case Repo.get(__MODULE__, canonical) do
      %__MODULE__{tombstoned_at: nil} = binding -> decode_binding(binding)
      _ -> :not_found
    end
  end

  @doc """
  Tombstone the active binding only when its version still matches.

  This lets materialization compensate a definitive failure without deleting a
  newer concurrent rematerialization of the same URI.
  """
  @spec tombstone_if_version(URI.t(), pos_integer()) ::
          :ok | {:error, :version_mismatch}
  def tombstone_if_version(%URI{} = agent_uri, version)
      when is_integer(version) and version > 0 do
    canonical = agent_uri |> Ezagent.URI.instance() |> URI.to_string()
    now = DateTime.utc_now()

    from(binding in __MODULE__,
      where:
        binding.agent_uri == ^canonical and binding.version == ^version and
          is_nil(binding.tombstoned_at)
    )
    |> Repo.update_all(set: [tombstoned_at: now, updated_at: now])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :version_mismatch}
    end
  end

  @doc """
  GC tombstoned artifact payloads at or before `cutoff`; returns the row count.

  The canonical key + version ledger is deliberately retained. Physically
  deleting it would create an ABA hole: a recreated URI could restart at
  version 1 and be tombstoned by a stale version-1 compensation token.
  """
  @spec prune_tombstoned(DateTime.t()) :: non_neg_integer()
  def prune_tombstoned(%DateTime{} = cutoff) do
    now = DateTime.utc_now()

    from(binding in __MODULE__,
      where:
        not is_nil(binding.tombstoned_at) and binding.tombstoned_at <= ^cutoff and
          is_nil(binding.gc_pruned_at)
    )
    |> Repo.update_all(
      set: [
        artifacts: %{"caps" => []},
        content_hash: "gc-pruned",
        gc_pruned_at: now,
        updated_at: now
      ]
    )
    |> elem(0)
  end

  defp issue_all(agent_uri, issuer_uri, proposals) do
    proposals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%Capability{} = proposal, index}, {:ok, issued} ->
        case Ezagent.Cap.issue({:admin, issuer_uri}, agent_uri, proposal) do
          {:ok, artifact} -> {:cont, {:ok, [artifact | issued]}}
          {:error, reason} -> {:halt, {:error, {:issue_failed, index, reason}}}
        end

      {proposal, index}, {:ok, _issued} ->
        {:halt, {:error, {:invalid_proposal, index, proposal}}}
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_binding_uris(agent_uri, issuer_uri) do
    with true <- agent_uri.scheme == "entity" and Ezagent.URI.type?(agent_uri, :agent),
         %URI{scheme: "workspace"} = workspace_uri <- Ezagent.URI.workspace_of(agent_uri),
         true <- issuer_uri.scheme == "entity" do
      {:ok, workspace_uri}
    else
      _ -> {:error, :invalid_binding_uri}
    end
  end

  defp persist_issued(agent_uri, workspace_uri, recipe_name, issuer_uri, issued) do
    caps = canonical_caps(issued)
    attrs = binding_attrs(agent_uri, workspace_uri, recipe_name, issuer_uri, caps)

    Repo.transaction(fn -> upsert_locked(attrs, caps) end)
    |> unwrap_transaction()
  end

  defp validate_issued_set(caps, agent_uri, workspace_uri, issuer_uri) do
    caps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {cap, index}, :ok ->
      case validate_artifact(cap, agent_uri, workspace_uri, issuer_uri) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_artifact, index, reason}}}
      end
    end)
  end

  defp validate_artifact(%Capability{} = cap, agent_uri, workspace_uri, issuer_uri) do
    cond do
      not same_uri?(cap.granted_by, issuer_uri) -> {:error, :issuer_mismatch}
      cap.kind != :agent -> {:error, :kind_mismatch}
      not same_uri?(cap.instance, agent_uri) -> {:error, :target_mismatch}
      not same_uri?(cap.workspace_uri, workspace_uri) -> {:error, :workspace_mismatch}
      true -> :ok
    end
  end

  defp validate_artifact(_cap, _agent_uri, _workspace_uri, _issuer_uri),
    do: {:error, :invalid_shape}

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(left)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(right))
  end

  defp same_uri?(_left, _right), do: false

  defp canonical_caps(caps) do
    caps
    |> Enum.reduce(%{}, fn cap, by_identity ->
      Map.put_new(by_identity, artifact_identity(cap), cap)
    end)
    |> Map.values()
    |> Enum.sort_by(&artifact_identity/1)
  end

  defp artifact_identity(%Capability{} = cap) do
    cap
    |> Capability.to_map()
    |> Map.drop(["granted_at"])
    |> :erlang.term_to_binary([:deterministic])
  end

  defp binding_attrs(agent_uri, workspace_uri, recipe_name, issuer_uri, caps) do
    attrs = %{
      agent_uri: URI.to_string(agent_uri),
      workspace_uri: URI.to_string(workspace_uri),
      recipe_name: recipe_name,
      issuer_uri: URI.to_string(issuer_uri),
      artifacts: %{"caps" => Enum.map(caps, &Capability.to_map/1)}
    }

    Map.put(attrs, :content_hash, content_hash(attrs, caps))
  end

  defp content_hash(attrs, caps) do
    logical_content = {
      attrs.agent_uri,
      attrs.workspace_uri,
      attrs.recipe_name,
      attrs.issuer_uri,
      Enum.map(caps, &artifact_identity/1)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(logical_content, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp upsert_locked(attrs, caps) do
    seed = Map.put(attrs, :version, 1)

    %__MODULE__{}
    |> changeset(seed)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :agent_uri)
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end

    current =
      from(binding in __MODULE__,
        where: binding.agent_uri == ^attrs.agent_uri,
        lock: "FOR UPDATE"
      )
      |> Repo.one!()

    if current.content_hash == attrs.content_hash and is_nil(current.tombstoned_at) do
      case decode_binding(current) do
        {:ok, fetched} -> fetched
        :not_found -> Repo.rollback(:invalid_existing_binding)
      end
    else
      updated_attrs =
        attrs
        |> Map.put(:version, current.version + 1)
        |> Map.put(:tombstoned_at, nil)
        |> Map.put(:gc_pruned_at, nil)

      current
      |> changeset(updated_attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> fetched(updated, caps)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :agent_uri,
      :workspace_uri,
      :recipe_name,
      :issuer_uri,
      :artifacts,
      :content_hash,
      :version,
      :tombstoned_at,
      :gc_pruned_at
    ])
    |> validate_required([
      :agent_uri,
      :workspace_uri,
      :recipe_name,
      :issuer_uri,
      :artifacts,
      :content_hash,
      :version
    ])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:agent_uri, name: :recipe_cap_bindings_pkey)
  end

  defp decode_binding(%__MODULE__{} = binding) do
    with {:ok, agent_uri} <- parse_uri(binding.agent_uri),
         {:ok, workspace_uri} <- parse_uri(binding.workspace_uri),
         {:ok, issuer_uri} <- parse_uri(binding.issuer_uri),
         {:ok, expected_workspace_uri} <- validate_binding_uris(agent_uri, issuer_uri),
         true <- same_uri?(workspace_uri, expected_workspace_uri),
         true <- binding.version > 0 and binding.recipe_name != "",
         {:ok, caps} <- decode_caps(binding.artifacts),
         :ok <- validate_issued_set(caps, agent_uri, workspace_uri, issuer_uri),
         true <- canonical_caps(caps) == caps,
         expected_attrs = %{
           agent_uri: binding.agent_uri,
           workspace_uri: binding.workspace_uri,
           recipe_name: binding.recipe_name,
           issuer_uri: binding.issuer_uri
         },
         true <- content_hash(expected_attrs, caps) == binding.content_hash do
      {:ok, fetched(binding, caps)}
    else
      _ -> :not_found
    end
  end

  defp decode_caps(%{"caps" => serialized}) when is_list(serialized) do
    {:ok, Enum.map(serialized, &Capability.from_map/1)}
  rescue
    _ -> {:error, :invalid_artifacts}
  end

  defp decode_caps(_artifacts), do: {:error, :invalid_artifacts}

  defp parse_uri(value) when is_binary(value) do
    {:ok, Ezagent.URI.new!(value)}
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end

  defp fetched(binding, caps) do
    %{
      caps: caps,
      version: binding.version,
      recipe_name: binding.recipe_name,
      issuer_uri: Ezagent.URI.new!(binding.issuer_uri)
    }
  end

  defp unwrap_transaction({:ok, fetched}), do: {:ok, fetched}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
