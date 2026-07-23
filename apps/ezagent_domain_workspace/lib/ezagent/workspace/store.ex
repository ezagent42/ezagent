defmodule Ezagent.Workspace.Store do
  @moduledoc """
  Postgres-persisted Workspace records (Phase 4c).

  ## Schema

      id                integer pk
      name              string unique  (short name, e.g. "team-alpha")
      uri               string unique  (workspace://team-alpha)
      member_uris       text   (Jason-encoded [String.t()])
      session_templates text   (Jason-encoded map)       -- DEPRECATED, see below
      routing_rules     text   (Jason-encoded [map])
      created_by        string (URI of creator)
      timestamps        utc_datetime_usec

  ## DEPRECATED: `session_templates` field (G-12, audit 2026-05-23)

  Despite the name, this column stores **spawn-template REGISTRATIONS**
  (`cc.agent`, `py.agent` template-class instances written by
  `Ezagent.Workspace.add_template/3`) — NOT Phase-7 `SessionTemplate`
  Kinds. The naming predates Phase-7 and is misleading.

  Phase-7's `SessionTemplate` Kind (`Ezagent.Entity.SessionTemplate`)
  is a separate construct living in `kind_snapshots`, exposed via the
  `/admin/templates` LV. The two are not interchangeable; the legacy
  field stays because it's still actively written by the
  `AgentNewLive` create-agent flow.

  Future work (V2): retire `session_templates` once `add_template/3`
  also writes a real Template Kind, then drop this column.

  ## Why JSON-text columns

  These columns hold Jason-encoded JSON in plain `text` fields rather than a
  structured / `jsonb` column. Text + Jason round-trip keeps the schema simple
  and gives us flexible inner shapes (session template structure evolves; we
  don't need a migration per change). Read path always decodes via `decode_*`
  helpers before handing back.

  ## API

  - `create(name, attrs)` — insert + return decoded struct
  - `get_by_name(name)` — fetch single row by name
  - `list_all/0` — for the Loader on app start
  - `update_members(name, [URI])` / `update_templates(name, map)` /
    `update_routing_rules(name, [map])` — mutation paths called by
    `Ezagent.Workspace` facade after a successful Kind dispatch
  - `delete(name)` — destructive, used by `mix ezagent.workspace.delete`
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "workspaces" do
    field(:name, :string)
    field(:uri, :string)
    field(:member_uris, :string)
    field(:session_templates, :string)
    field(:routing_rules, :string)
    field(:created_by, :string)
    # SPEC 2026-05-27-workspace-cap-based-visibility — the `:visible`
    # boolean was DELETED here. Visibility is now cap-derived via
    # `Ezagent.Workspace.list_workspaces_for/2`. Operator stops phx +
    # runs `mix ecto.migrate` (HUMAN-REQUIRED) after merge; the
    # schema/column mismatch is the structural reminder.
    timestamps(type: :utc_datetime_usec)
  end

  @type decoded :: %{
          id: integer() | nil,
          name: String.t(),
          uri: URI.t(),
          members: [URI.t()],
          session_templates: map(),
          routing_rules: [map()],
          created_by: URI.t() | nil
        }

  # --- write paths ----------------------------------------------------

  @doc """
  Insert a new Workspace row. `attrs` keys (all optional except handled
  by defaults):
  - `:members` — `[URI.t() | String.t()]`
  - `:session_templates` — `map()`
  - `:routing_rules` — `[map()]`
  - `:created_by` — `URI.t() | nil`
  """
  @spec create(String.t(), map()) ::
          {:ok, decoded()} | {:exists, decoded()} | {:error, term()}
  def create(name, attrs \\ %{}) when is_binary(name) and name != "" do
    uri_str = name |> Ezagent.URI.workspace() |> URI.to_string()

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        name: name,
        uri: uri_str,
        member_uris: encode_uris(Map.get(attrs, :members, [])),
        session_templates: Jason.encode!(Map.get(attrs, :session_templates, %{})),
        routing_rules: Jason.encode!(Map.get(attrs, :routing_rules, [])),
        created_by: uri_to_string_or_nil(Map.get(attrs, :created_by))
      })
      |> Ecto.Changeset.unique_constraint(:name, name: :workspaces_name_index)
      |> Ecto.Changeset.unique_constraint(:uri, name: :workspaces_uri_index)

    # `mode: :savepoint` wraps the INSERT in a SAVEPOINT so a unique-constraint
    # violation rolls back to the savepoint instead of aborting the ENCLOSING
    # transaction (`Ezagent.Workspace.create/2` runs this inside a
    # `Repo.transaction`). Without it, an "already exists" conflict aborts the
    # txn (Postgres 25P02) and the `Repo.get_by/2` below — plus every later
    # command sharing the transaction (e.g. the Ecto sandbox) — raises
    # `in_failed_sql_transaction`. This is exactly the scenario Ecto documents
    # (`Ecto.Repo` insert/2 `:mode`). The savepoint is a no-op cost on the
    # fresh-insert success path; the conflict path now cleanly returns
    # `{:exists, decoded}` (the create-vs-adopt signal `create/2` maps to
    # `{:error, :workspace_exists}`).
    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, inserted} ->
        # Fresh row — Workspace is :ephemeral (no kind_snapshots marker), so
        # this unique INSERT IS its create-vs-adopt freshness signal (#533
        # 5a §3.10.2, the ephemeral analog of Lifecycle.fresh_create?).
        {:ok, decode(inserted)}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        # A unique-constraint conflict means the workspace already exists.
        # Return the EXISTING decoded row as `:exists` so the create-entry
        # (5d) can adopt it, instead of forwarding the raw changeset error.
        if Keyword.has_key?(errors, :name) or Keyword.has_key?(errors, :uri) do
          case Repo.get_by(__MODULE__, name: name) do
            nil -> {:error, cs}
            existing -> {:exists, decode(existing)}
          end
        else
          {:error, cs}
        end
    end
  end

  @spec update_members(String.t(), [URI.t() | String.t()]) ::
          {:ok, decoded()} | {:error, term()}
  def update_members(name, members) when is_binary(name) and is_list(members) do
    update_field(name, :member_uris, encode_uris(members))
  end

  @spec update_templates(String.t(), map()) :: {:ok, decoded()} | {:error, term()}
  def update_templates(name, templates) when is_binary(name) and is_map(templates) do
    update_field(name, :session_templates, Jason.encode!(templates))
  end

  @spec update_routing_rules(String.t(), [map()]) :: {:ok, decoded()} | {:error, term()}
  def update_routing_rules(name, rules) when is_binary(name) and is_list(rules) do
    update_field(name, :routing_rules, Jason.encode!(rules))
  end

  @doc false
  @spec transfer_owner(String.t(), URI.t()) :: {:ok, decoded()} | {:error, term()}
  def transfer_owner(name, %URI{} = new_owner) when is_binary(name) do
    update_field(name, :created_by, URI.to_string(new_owner))
  end

  defp update_field(name, field, value) do
    case Repo.get_by(__MODULE__, name: name) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Ecto.Changeset.change(%{field => value})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, decode(updated)}
          err -> err
        end
    end
  end

  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    case Repo.get_by(__MODULE__, name: name) do
      nil ->
        :ok

      row ->
        case Repo.delete(row) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  # --- read paths ----------------------------------------------------

  @spec get_by_name(String.t()) :: decoded() | nil
  def get_by_name(name) when is_binary(name) do
    case Repo.get_by(__MODULE__, name: name) do
      nil -> nil
      row -> decode(row)
    end
  end

  @doc """
  List every persisted workspace, sorted by name. System-internal
  callers only (Loader rehydration, agent-flavor resolution, mix
  audit tasks, invariant tests).

  Operator-facing surfaces MUST use `Ezagent.Workspace.list_workspaces_for/2`
  (SPEC 2026-05-27-workspace-cap-based-visibility). The former
  `list_visible/0` field-based filter is deleted; visibility is now
  cap-derived.
  """
  @spec list_all() :: [decoded()]
  def list_all do
    Repo.all(from(w in __MODULE__, order_by: w.name))
    |> Enum.map(&decode/1)
  end

  # --- encoding helpers ----------------------------------------------

  defp encode_uris(uris) do
    uris
    |> Enum.map(&uri_to_string/1)
    |> Jason.encode!()
  end

  defp uri_to_string(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string(s) when is_binary(s), do: s

  defp uri_to_string_or_nil(nil), do: nil
  defp uri_to_string_or_nil(other), do: uri_to_string(other)

  defp decode(%__MODULE__{} = row) do
    %{
      id: row.id,
      name: row.name,
      uri: Ezagent.URI.new!(row.uri),
      members: row.member_uris |> Jason.decode!() |> Enum.map(&Ezagent.URI.new!/1),
      session_templates: Jason.decode!(row.session_templates),
      routing_rules: Jason.decode!(row.routing_rules),
      created_by: parse_uri_or_nil(row.created_by)
    }
  end

  defp parse_uri_or_nil(nil), do: nil
  defp parse_uri_or_nil(s) when is_binary(s), do: Ezagent.URI.new!(s)
end
