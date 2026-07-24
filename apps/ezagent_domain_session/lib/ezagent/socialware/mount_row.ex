defmodule Ezagent.Socialware.MountRow do
  @moduledoc """
  Durable source-of-truth table for runtime *mounts* — the caps minted at
  runtime when a grantee (e.g. an assistant) pulls / forwards / creates a
  handle onto a data-host agent (the mount `target`).

  Historically `mint_cap/4` minted the capability but wrote no table, so a
  runtime mount had no SoT and reconcile could not see it. This table closes
  that gap: one row per `(session_uri, target_uri, grantee_uri, behavior)`
  natural key records which grantee holds which action set over which target,
  under which access mode, granted by whom (= the target's data-owner).

  ## Natural key & synthetic id

  The primary key `:id` is a session-scoped SHA256 hash of the natural key
  (see `mount_id/4`), mirroring `Ezagent.ExternalMirror.BindingRow.row_id/3`.
  Including `session_uri` in the hash means two sessions mounting the same
  target for the same grantee produce DIFFERENT ids — no cross-session key
  collision. A `unique_index` on the four natural-key columns backs the
  DB-side idempotency contract; `upsert/1` overwrites in place on conflict.

  **Pure data module** — no dispatch, no cap minting. `mint_cap` (M2) and the
  installation path (M3) call into this; this module only owns the table.

  ## actions_json

  The granted action set (e.g. `["get_tree", "export_markmap"]`) is a LIST, so
  it is JSON-encoded into the `actions_json` `:text` column (the Ecto `:map`
  type rejects a bare list). `upsert/1` accepts either an `:actions` list
  (encoded here) or a pre-encoded `:actions_json` string.

  ## scope: session vs person(㊵ 人本位前置)

  `scope` 区分两类挂载行:

    * `"session"`(默认)—— 会话挂载:自然键 `(session_uri, target_uri,
      grantee_uri, behavior)`,行为与历史完全一致;
    * `"person"` —— 人持钥匙(跨会话):`session_uri` 为 NULL,自然键
      `(target_uri, grantee_uri, behavior)`,id 由 `person_mount_id/3` 派生,
      DB 侧幂等由 partial unique index(`scope = 'person'`)兜底。

  person 行不出现在 `list_for_session/1`(session 轴为 NULL 天然不命中,查询里
  再显式按 scope 过滤兜底),消费方走 `list_person_mounts_for_grantee/1`。scope
  是挂载概念自身的维度,将来 mount 折 CompositionBinding 时列对列机械平移。
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "socialware_mounts" do
    field(:scope, :string, default: "session")
    field(:session_uri, :string)
    field(:target_uri, :string)
    field(:grantee_uri, :string)
    field(:behavior, :string)
    field(:actions_json, :string, default: "[]")
    field(:access, :string)
    field(:granted_by, :string)
    field(:workspace_uri, :string)
    field(:mounted_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @cast_fields ~w(
    id scope session_uri target_uri grantee_uri behavior actions_json
    access granted_by workspace_uri mounted_at
  )a

  # `session_uri` 不在通用 required 里 —— person 行没有 session 轴;
  # session 行由 `validate_scope/1` 补验 session_uri 必填。
  @required_fields ~w(
    id scope target_uri grantee_uri behavior actions_json
    access granted_by workspace_uri mounted_at
  )a

  @conflict_replace ~w(
    actions_json access granted_by workspace_uri mounted_at updated_at
  )a

  @doc """
  Insert or overwrite a mount row at its deterministic natural-key identity.

  Accepts URI structs or strings for the URI fields, an `:actions` list (or a
  pre-encoded `:actions_json` string), and an `:access` mode (`:read` |
  `:operate` or the string forms). On natural-key conflict the mutable columns
  are replaced in place, so a re-mount with a changed action set / access mode
  updates the single row rather than duplicating it.
  """
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    normalized = normalize(attrs)

    %__MODULE__{}
    |> Ecto.Changeset.cast(normalized, @cast_fields)
    |> Ecto.Changeset.validate_required(@required_fields)
    |> Ecto.Changeset.validate_inclusion(:scope, ["session", "person"])
    |> validate_scope()
    |> Repo.insert(
      on_conflict: {:replace, @conflict_replace},
      conflict_target: [:id],
      returning: true
    )
  end

  @doc "List every mount row for `session_uri`, oldest first."
  @spec list_for_session(URI.t() | String.t()) :: [t()]
  def list_for_session(session_uri) do
    session = uri_string(session_uri)

    Repo.all(
      from(m in __MODULE__,
        where: m.session_uri == ^session and m.scope == "session",
        order_by: [asc: m.mounted_at, asc: m.id]
      )
    )
  end

  @doc "List every person-scope mount row held by `grantee_uri`, oldest first."
  @spec list_person_mounts_for_grantee(URI.t() | String.t()) :: [t()]
  def list_person_mounts_for_grantee(grantee_uri) do
    grantee = uri_string(grantee_uri)

    Repo.all(
      from(m in __MODULE__,
        where: m.grantee_uri == ^grantee and m.scope == "person",
        order_by: [asc: m.mounted_at, asc: m.id]
      )
    )
  end

  @doc """
  List every mount row pointing at `target_uri` (across ALL sessions AND both
  scopes — session rows and person rows alike), oldest first — the reverse
  index a target (data-host) teardown needs to unmount every grantee that
  still holds keys onto it.
  """
  @spec list_for_target(URI.t() | String.t()) :: [t()]
  def list_for_target(target_uri) do
    target = uri_string(target_uri)

    Repo.all(
      from(m in __MODULE__,
        where: m.target_uri == ^target,
        order_by: [asc: m.mounted_at, asc: m.id]
      )
    )
  end

  @doc "Load one exact mount row by its natural key, or `nil`."
  @spec get(URI.t() | String.t(), URI.t() | String.t(), URI.t() | String.t(), String.t() | atom()) ::
          t() | nil
  def get(session_uri, target_uri, grantee_uri, behavior) do
    Repo.get(__MODULE__, mount_id(session_uri, target_uri, grantee_uri, behavior))
  end

  @doc "Load one exact person-scope mount row by its natural key, or `nil`."
  @spec get_person(URI.t() | String.t(), URI.t() | String.t(), String.t() | atom()) :: t() | nil
  def get_person(target_uri, grantee_uri, behavior) do
    Repo.get(__MODULE__, person_mount_id(target_uri, grantee_uri, behavior))
  end

  @doc """
  Delete a mount row by its natural key. Returns `{:ok, :deleted}` when a row
  matched and `{:ok, :not_found}` when none did (already gone / never mounted).
  """
  @spec delete_by_natural_key(
          URI.t() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t() | atom()
        ) :: {:ok, :deleted | :not_found}
  def delete_by_natural_key(session_uri, target_uri, grantee_uri, behavior) do
    id = mount_id(session_uri, target_uri, grantee_uri, behavior)

    case Repo.delete_all(from(m in __MODULE__, where: m.id == ^id)) do
      {0, _} -> {:ok, :not_found}
      {n, _} when n >= 1 -> {:ok, :deleted}
    end
  end

  @doc """
  Delete a person-scope mount row by its natural key. Returns `{:ok, :deleted}`
  when a row matched and `{:ok, :not_found}` when none did.
  """
  @spec delete_person_by_natural_key(
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t() | atom()
        ) :: {:ok, :deleted | :not_found}
  def delete_person_by_natural_key(target_uri, grantee_uri, behavior) do
    id = person_mount_id(target_uri, grantee_uri, behavior)

    case Repo.delete_all(from(m in __MODULE__, where: m.id == ^id)) do
      {0, _} -> {:ok, :not_found}
      {n, _} when n >= 1 -> {:ok, :deleted}
    end
  end

  @doc """
  删掉指向 `target_uri`(数据宿主)的**全部**挂载行(跨 session、跨 grantee,含
  session 行与 person 行)—— 纯 bookkeeping,**不撤钥匙**(cap 失效由删宿主前的
  `Ezagent.Cap.revoke_all_to/2`(cap-epoch generation bump)一次性完成;本函数只
  收尾删挂载表行)。

  逐行删:session 行(`session_uri` 非 NULL)走 `delete_by_natural_key/4`,
  person 行(`session_uri` 为 NULL)走 `delete_person_by_natural_key/3`。best-effort:
  单行删除抛异常只记 `:warning` 不牵连其余行。返回成功删除的行数。
  """
  @spec delete_all_for_target(URI.t() | String.t()) :: non_neg_integer()
  def delete_all_for_target(target_uri) do
    target_uri
    |> list_for_target()
    |> Enum.reduce(0, fn %__MODULE__{} = row, deleted ->
      try do
        case delete_row(row) do
          {:ok, :deleted} -> deleted + 1
          {:ok, :not_found} -> deleted
        end
      rescue
        error ->
          Logger.warning(
            "MountRow.delete_all_for_target/1: delete FAILED for target=" <>
              "#{row.target_uri} grantee=#{row.grantee_uri} behavior=#{row.behavior}: " <>
              "#{inspect(error.__struct__)} — skipping (other rows unaffected)."
          )

          deleted
      end
    end)
  end

  # person 行无 session 轴(`session_uri` 为 NULL)→ 走 person 自然键删;其余走 session 键删。
  defp delete_row(%__MODULE__{scope: "person"} = row) do
    delete_person_by_natural_key(row.target_uri, row.grantee_uri, row.behavior)
  end

  defp delete_row(%__MODULE__{} = row) do
    delete_by_natural_key(row.session_uri, row.target_uri, row.grantee_uri, row.behavior)
  end

  @doc """
  Deterministic, session-scoped SHA256 identity for a mount's natural key.

  Same params → same id (so concurrent inserts collide on the primary key AND
  the natural-key unique index). Because `session_uri` is part of the hashed
  tuple, changing the session yields a different id — two sessions mounting the
  same target/grantee/behavior never collide (mirrors
  `Ezagent.ExternalMirror.BindingRow.row_id/3`). Returns a 24-hex prefix.
  """
  @spec mount_id(
          URI.t() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t() | atom()
        ) :: String.t()
  def mount_id(session_uri, target_uri, grantee_uri, behavior) do
    :crypto.hash(
      :sha256,
      Enum.join(
        [
          uri_string(session_uri),
          uri_string(target_uri),
          uri_string(grantee_uri),
          behavior_string(behavior)
        ],
        "/"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  @doc """
  Deterministic identity for a person-scope mount's natural key
  `(target_uri, grantee_uri, behavior)` —— 无 session 轴。

  哈希前缀固定串 `"person"` 与 session 行的 id 域天然分离(session 行首段是
  `session://…` 完整 URI,不可能等于裸串 `"person"`)。Returns a 24-hex prefix.
  """
  @spec person_mount_id(URI.t() | String.t(), URI.t() | String.t(), String.t() | atom()) ::
          String.t()
  def person_mount_id(target_uri, grantee_uri, behavior) do
    :crypto.hash(
      :sha256,
      Enum.join(
        [
          "person",
          uri_string(target_uri),
          uri_string(grantee_uri),
          behavior_string(behavior)
        ],
        "/"
      )
    )
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end

  defp normalize(attrs) do
    scope = scope_string(attrs)
    target = uri_string(Map.fetch!(attrs, :target_uri))
    grantee = uri_string(Map.fetch!(attrs, :grantee_uri))
    behavior = behavior_string(Map.fetch!(attrs, :behavior))

    {id, session} =
      case scope do
        "person" ->
          {person_mount_id(target, grantee, behavior), nil}

        _session ->
          session = uri_string(Map.fetch!(attrs, :session_uri))
          {mount_id(session, target, grantee, behavior), session}
      end

    %{
      id: id,
      scope: scope,
      session_uri: session,
      target_uri: target,
      grantee_uri: grantee,
      behavior: behavior,
      actions_json: actions_json(attrs),
      access: access_string(attrs),
      granted_by: uri_string(Map.get(attrs, :granted_by)),
      workspace_uri: uri_string(Map.get(attrs, :workspace_uri)),
      mounted_at: Map.get(attrs, :mounted_at) || DateTime.utc_now()
    }
  end

  # session 行必须带 session_uri(person 行不带)—— changeset 级兜底,
  # 让「scope=session 却漏 session_uri」是显式错误而非静默 NULL 行。
  defp validate_scope(changeset) do
    case Ecto.Changeset.get_field(changeset, :scope) do
      "session" -> Ecto.Changeset.validate_required(changeset, [:session_uri])
      _ -> changeset
    end
  end

  defp scope_string(attrs) do
    case Map.get(attrs, :scope, "session") do
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _ -> "session"
    end
  end

  defp actions_json(attrs) do
    cond do
      is_binary(attrs[:actions_json]) -> attrs[:actions_json]
      is_list(attrs[:actions]) -> Jason.encode!(attrs[:actions])
      true -> "[]"
    end
  end

  defp access_string(attrs) do
    case Map.get(attrs, :access) do
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp behavior_string(behavior) when is_atom(behavior), do: inspect(behavior)
  defp behavior_string(behavior) when is_binary(behavior), do: behavior

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(value) when is_binary(value), do: value
  defp uri_string(nil), do: nil
  defp uri_string(value), do: to_string(value)
end
