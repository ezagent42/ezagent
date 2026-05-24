defmodule Ezagent.ExternalMirror.BindingRow do
  @moduledoc """
  Ecto schema for the `external_mirror_bindings` projection table
  (PR-EM-3 SPEC §7.1).

  **Pure data module.** The Session Kind's `:external_mirror` slice
  is the source of truth per P3; rows here are the durable projection
  written by `Ezagent.Behavior.ExternalMirror.invoke(:bind, ...)` and
  deleted by `:unbind`. Read at boot by `init_slice/1` (Session-side
  rehydration) AND by `Ezagent.ExternalMirror.BootReconciler`
  (cross-session safety net).

  ## Natural key

  `(session_uri, adapter_id, target_id)` — the DB-side idempotency
  contract. Concurrent `:bind` for the same triple collides on the
  unique index; the action body treats the `Repo.insert/2` error as
  the "already bound" success path (mirroring the in-memory
  PerBindingSupervisor / WorkerRegistry idempotency from PR-EM-2).

  The `:id` field is a synthetic primary key (the
  `"<adapter_id>/<target_id>"` synthetic id from the slice) so
  `Repo.get/2` works without compound-key gymnastics; the natural-key
  uniqueness is enforced via `external_mirror_bindings_natural_key_index`.

  ## opts_json

  Caller-supplied binding-time metadata (adapter-specific). Stored
  JSON-encoded because SQLite's `:map` type isn't first-class — the
  schema field is `:string`, and the `:bind` / `:unbind` paths
  encode/decode via `Jason`. Empty default `"{}"`.
  """

  use Ecto.Schema

  import Ecto.Query

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "external_mirror_bindings" do
    field(:session_uri, :string)
    field(:adapter_id, :string)
    field(:target_id, :string)
    field(:opts_json, :string, default: "{}")
    field(:bound_by, :string)
    field(:bound_at, :utc_datetime_usec)
    field(:workspace_uri, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: String.t(),
          session_uri: String.t(),
          adapter_id: String.t(),
          target_id: String.t(),
          opts_json: String.t(),
          bound_by: String.t(),
          bound_at: DateTime.t(),
          workspace_uri: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Insert a binding row. Caller passes already-derived fields; this
  function does not re-derive workspace / IDs (the action body owns
  that — see `Ezagent.Behavior.ExternalMirror.invoke(:bind, ...)`).

  Returns `{:ok, row}` on fresh insert, `{:error, changeset}` on
  natural-key collision (the action body MAPS that to `:ok` per the
  idempotency contract).
  """
  @spec insert(map()) :: {:ok, t()} | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :session_uri,
      :adapter_id,
      :target_id,
      :opts_json,
      :bound_by,
      :bound_at,
      :workspace_uri
    ])
    |> Ecto.Changeset.validate_required([
      :id,
      :session_uri,
      :adapter_id,
      :target_id,
      :bound_by,
      :bound_at,
      :workspace_uri
    ])
    |> Repo.insert()
  end

  @doc """
  Delete a binding row by its synthetic id (`"<adapter_id>/<target_id>"`).
  Returns `:ok` whether the row existed or not (idempotent — matches
  the in-memory `:unbind` semantics).
  """
  @spec delete_by_id(String.t()) :: :ok
  def delete_by_id(id) when is_binary(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        :ok

      %__MODULE__{} = row ->
        _ = Repo.delete(row)
        :ok
    end
  end

  @doc """
  List every binding row for `session_uri`. Used by
  `Ezagent.Behavior.ExternalMirror.init_slice/1` to rebuild the slice
  on Session Kind init.
  """
  @spec list_for_session(URI.t() | String.t()) :: [t()]
  def list_for_session(%URI{} = uri), do: list_for_session(URI.to_string(uri))

  def list_for_session(session_uri) when is_binary(session_uri) do
    Repo.all(
      from(r in __MODULE__,
        where: r.session_uri == ^session_uri,
        order_by: r.bound_at
      )
    )
  end

  @doc """
  List EVERY binding row across all sessions. Used by
  `Ezagent.ExternalMirror.BootReconciler` to walk the table at
  application boot (V1 single-node — multi-node sharding would
  filter by workspace_uri here).
  """
  @spec list_all() :: [t()]
  def list_all do
    Repo.all(from(r in __MODULE__, order_by: r.bound_at))
  end

  @doc """
  Reverse lookup: every session URI bound to `adapter_id`. Used by
  the `Ezagent.ExternalMirror.sessions_for_adapter/1` facade
  (replaces the PR-EM-1 stub).
  """
  @spec sessions_for_adapter(String.t()) :: [URI.t()]
  def sessions_for_adapter(adapter_id) when is_binary(adapter_id) do
    Repo.all(
      from(r in __MODULE__,
        where: r.adapter_id == ^adapter_id,
        select: r.session_uri,
        distinct: true
      )
    )
    |> Enum.map(&URI.parse/1)
  end

  @doc """
  Build the synthetic binding id from `(adapter_id, target_id)`. The
  same shape is used in the in-memory slice's `:binding_id` field
  so the row's `:id` matches the slice key.
  """
  @spec binding_id(String.t(), String.t() | term()) :: String.t()
  def binding_id(adapter_id, target_id) when is_binary(adapter_id) do
    "#{adapter_id}/#{stringify_target(target_id)}"
  end

  defp stringify_target(t) when is_binary(t), do: t
  defp stringify_target(t) when is_atom(t), do: Atom.to_string(t)
  defp stringify_target(t) when is_integer(t), do: Integer.to_string(t)
  defp stringify_target(t), do: inspect(t)
end
