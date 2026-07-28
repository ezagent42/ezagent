defmodule Ezagent.EntityCaps.GranteeIndex do
  @moduledoc """
  Reverse cap index — "who currently holds a cap toward target T" (URI-share A2-2).

  A **derived, read-only projection** of the cap store: rows are written at the
  single cap-store funnel `persist_entity_caps/2` (reached by absorb / grant /
  persist / store / remove) and are NEVER a source of truth for re-minting keys
  (that would be the second-truth-source trap the deleted `socialware_mounts`
  table was). Direction is strictly cap → row, never row → key.

  Revocation needs no delete: each row stamps the `key_id` (generation) of the
  cap that produced it, and `grantees_of/2` filters to the target's **current**
  active authority `key_id`. A `revoke_all_to` generation bump changes the active
  `key_id`, so every stale row drops out of reads automatically — the same
  fresh active-generation read the dispatch cap verifier applies, introducing no
  new revocation mechanism.

  This is the reverse half of `Ezagent.Cap.Visibility.caps_toward/2` (A2-1, the
  forward "what can I see" filter) and the seam a session's `:members` roster
  becomes a projection of (A4-2).
  """
  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias EzagentCore.Repo
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority

  @primary_key {:id, :string, autogenerate: false}
  schema "cap_grantee_index" do
    field(:target_uri, :string)
    field(:grantee_uri, :string)
    field(:behavior, :string)
    field(:action, :string)
    field(:key_id, :string)
    field(:granted_by, :string)
    field(:workspace_uri, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Replace `grantee`'s reverse-index rows with the concrete-target caps in `caps`.

  Called from the cap-store funnel with the grantee's full new cap set, so it
  captures both grants (rows appear) and removals (rows for caps no longer in the
  set are dropped). Caps whose `instance` is not a concrete URI (`:any` /
  scope-tuple wildcards) are not indexed — the index answers "grantees of a
  specific target". Best-effort: a failure here never breaks cap storage, since
  the index is a derived projection, not the truth.
  """
  @spec reindex(URI.t(), MapSet.t(Capability.t())) :: :ok
  def reindex(%URI{} = grantee, %MapSet{} = caps) do
    grantee_key = Ezagent.URI.stable_key(grantee)
    rows = caps |> Enum.flat_map(&row_attrs(&1, grantee_key))

    Repo.transaction(fn ->
      Repo.delete_all(from(r in __MODULE__, where: r.grantee_uri == ^grantee_key))

      Enum.each(rows, fn attrs ->
        %__MODULE__{}
        |> Ecto.Changeset.change(attrs)
        |> Repo.insert!()
      end)
    end)

    :ok
  rescue
    error ->
      Logger.warning(
        "GranteeIndex.reindex failed for #{inspect(grantee)}: #{inspect(error)} — cap store unaffected (derived index)"
      )

      :ok
  end

  @doc """
  Grantees who currently hold a valid cap toward `target`, optionally narrowed to
  a `behavior` (`:any` = every behavior).

  Filters to the target's current active authority generation, so stale rows from
  a revoked (generation-bumped) authority are excluded without being deleted.
  Returns each distinct grantee once. An unknown target (no active authority)
  yields `[]`.
  """
  @spec grantees_of(URI.t(), module() | atom()) :: [URI.t()]
  def grantees_of(%URI{} = target, behavior \\ :any) do
    target_key = Ezagent.URI.stable_key(target)

    case active_key_id(target_key) do
      nil ->
        []

      active ->
        base =
          from(r in __MODULE__,
            where: r.target_uri == ^target_key and r.key_id == ^active,
            select: r.grantee_uri
          )

        base
        |> maybe_filter_behavior(behavior)
        |> Repo.all()
        |> Enum.uniq()
        |> Enum.map(&Ezagent.URI.new!/1)
    end
  end

  defp maybe_filter_behavior(query, :any), do: query

  defp maybe_filter_behavior(query, behavior) do
    b = behavior_string(behavior)
    from(r in query, where: r.behavior == ^b)
  end

  defp active_key_id(target_key) do
    case KindCapAuthority.active(target_key) do
      %{key_id: key_id} -> key_id
      _ -> nil
    end
  end

  # Only concrete-target caps are indexed; wildcard (`:any` / scope-tuple) instances
  # have no single target to key on.
  defp row_attrs(%Capability{instance: %URI{} = instance} = cap, grantee_key) do
    target_key = Ezagent.URI.stable_key(instance)
    behavior = behavior_string(cap.behavior)
    action = to_string(cap.action)

    [
      %{
        id: row_id(target_key, grantee_key, behavior, action),
        target_uri: target_key,
        grantee_uri: grantee_key,
        behavior: behavior,
        action: action,
        key_id: cap.key_id,
        granted_by: to_string_or_nil(cap.granted_by),
        workspace_uri: uri_string(cap.workspace_uri)
      }
    ]
  end

  defp row_attrs(_non_concrete, _grantee_key), do: []

  defp row_id(target_key, grantee_key, behavior, action) do
    :crypto.hash(:sha256, Enum.join([target_key, grantee_key, behavior, action], "/"))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp behavior_string(behavior) when is_atom(behavior), do: to_string(behavior)
  defp behavior_string(behavior) when is_binary(behavior), do: behavior

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(str) when is_binary(str), do: str

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(%URI{} = uri), do: URI.to_string(uri)
  defp to_string_or_nil(other), do: to_string(other)
end
