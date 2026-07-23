defmodule Ezagent.Routing.RuleStore do
  @moduledoc """
  Postgres-persisted routing rules (per P3-D10).

  Admin-created rules survive BEAM restart. Boot-time bootstrap
  inserts system-default rules idempotently (chat plugin's
  `bootstrap_default_rules/0` checks emptiness before inserting).

  ## Schema

  ```
  id            integer primary key
  table_name    string  (e.g. "EzagentDomainInstanceMessage.Routing.MentionRouting")
  matcher_data  text    (Jason-encoded matcher AST per Ezagent.Routing.Matcher.to_json/1)
  receivers     text    (Jason-encoded [String.t()] of receiver URIs)
  created_by    string  (URI of admin who added; nil for system-default)
  created_at    utc_datetime_usec
  ```

  ## API

  - `add(table_name_atom, matcher_tuple, receivers_list, created_by_uri)`
  - `list(table_name_atom) :: [rule_map()]`
  - `delete(id)`
  - `load_into_registry(table_name_atom)` — on boot, reads persisted rules
    and puts them into the live `RoutingRegistry` ETS table

  Resolver reads the **ETS table** (not Postgres directly) — RuleStore
  is the persistence layer that hydrates ETS at boot.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "routing_rules" do
    field :table_name, :string
    field :matcher_data, :map
    field :receivers, {:array, :string}
    field :created_by, :string
    field :created_at, :utc_datetime_usec
    # Phase 4-completion PR 9: source distinguishes system_default from admin
    field :source, :string, default: "admin"
    field :enabled, :boolean, default: true
    # Phase 6 PR 5: per-rule sender filter. Stored as JSON-encoded list
    # of URI strings; loaded into `applies_to_users` field via helper.
    # Empty list = applies to every sender.
    field :applies_to_users_json, :string, source: :applies_to_users, default: "[]"
    # Phase 6 PR 8: per-rule workspace scope. nil = applies globally.
    field :workspace_uri, :string
    # team-routing-unification §3.3: rule-set membership + ordering + the
    # named prompt template applied at delivery to this rule's receiver.
    # All nullable/defaulted → existing rows unaffected.
    field :rule_set, :string
    field :position, :integer, default: 0
    field :prompt_template_ref, :string
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          table_name: String.t(),
          matcher_data: map(),
          receivers: [String.t()],
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          source: String.t(),
          enabled: boolean(),
          applies_to_users_json: String.t(),
          workspace_uri: String.t() | nil,
          rule_set: String.t() | nil,
          position: integer(),
          prompt_template_ref: String.t() | nil
        }

  @system_default "system_default"
  @admin "admin"

  def system_default_source, do: @system_default
  def admin_source, do: @admin

  @doc """
  Insert a new rule. `matcher_tuple` is `Ezagent.Routing.Matcher.matcher()`.
  Default source is "admin" — pass `source: "system_default"` for
  plugin-bootstrapped rules (per Phase 4-completion PR 9 §C).
  """
  @spec add(
          atom(),
          Ezagent.Routing.Matcher.matcher(),
          [URI.t() | String.t()],
          URI.t() | nil,
          keyword()
        ) :: {:ok, t()} | {:error, term()}
  def add(table_name_atom, matcher_tuple, receivers, created_by, opts \\ [])
      when is_atom(table_name_atom) do
    receivers_str = Enum.map(receivers, &receiver_to_store/1)
    source = Keyword.get(opts, :source, @admin)
    applies_to_users = Keyword.get(opts, :applies_to_users, []) |> Enum.map(&uri_to_string/1)
    workspace_uri = Keyword.get(opts, :workspace_uri) |> uri_to_string_or_nil()
    rule_set = Keyword.get(opts, :rule_set)
    position = Keyword.get(opts, :position, 0)
    prompt_template_ref = Keyword.get(opts, :prompt_template_ref)

    # team-routing-unification §3.3: a rule in a NAMED rule-set must be
    # single-receiver (multi-receiver fan-out is expressed as multiple
    # rules / an explicit broadcast rule). Standalone rules (rule_set nil)
    # keep the multi-receiver capability.
    if not is_nil(rule_set) and length(receivers_str) != 1 do
      {:error, :rule_set_requires_single_receiver}
    else
      rule = %__MODULE__{
        table_name: Atom.to_string(table_name_atom),
        matcher_data: Ezagent.Routing.Matcher.to_json(matcher_tuple),
        receivers: receivers_str,
        created_by: uri_to_string_or_nil(created_by),
        created_at: DateTime.utc_now(),
        source: source,
        enabled: true,
        applies_to_users_json: Jason.encode!(applies_to_users),
        workspace_uri: workspace_uri,
        rule_set: rule_set,
        position: position,
        prompt_template_ref: prompt_template_ref
      }

      Repo.insert(rule)
    end
  end

  @doc """
  Decode the JSON-stored applies_to_users field back into a list of
  URI strings. Empty list means "applies to every sender".
  """
  @spec applies_to_users(t()) :: [String.t()]
  def applies_to_users(%__MODULE__{applies_to_users_json: nil}), do: []

  def applies_to_users(%__MODULE__{applies_to_users_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  @doc "List all rules for a given table (as Ecto schema rows)."
  @spec list(atom()) :: [t()]
  def list(table_name_atom) when is_atom(table_name_atom) do
    table_str = Atom.to_string(table_name_atom)

    from(r in __MODULE__,
      where: r.table_name == ^table_str,
      order_by: [asc: r.id]
    )
    |> Repo.all()
  end

  @doc """
  Bulk-load all rules for a table into the live `RoutingRegistry`.

  Called at boot by the owning plugin **and** at runtime by the
  `routing_admin` Behavior on every add/delete/disable/enable —
  the live registry now reflects whatever the DB says, no phx
  restart needed (PR #127 fix; previously runtime adds silently
  no-op'd from non-owner LV processes).

  Each row's matcher gets parsed back via `Matcher.from_json/1`.
  Bad rows are logged and skipped (don't crash plugin boot for
  one bad rule).
  """
  @spec load_into_registry(atom()) :: :ok
  def load_into_registry(table_name_atom) when is_atom(table_name_atom) do
    # Phase 4-completion PR 9: only load `enabled` rows. Admin can
    # disable a system_default rule without deleting it (system_defaults
    # are protected from delete by delete/1).
    entries =
      list(table_name_atom)
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(fn row ->
        case Ezagent.Routing.Matcher.from_json(row.matcher_data) do
          {:ok, matcher_tuple} ->
            # Phase 6 PR 5: wrap receivers in a map with the applies_to_users
            # filter. Resolver pattern-matches on the map shape. Legacy ETS
            # entries written directly via RoutingRegistry.put (tests, old
            # call sites) stay as plain lists — Resolver falls back to "no
            # user filter" for those.
            value = %{
              receivers:
                Enum.map(row.receivers || [], &Ezagent.Routing.Receiver.decode_from_store/1),
              applies_to_users: applies_to_users(row),
              workspace_uri: row.workspace_uri,
              # team-routing-unification §3.3/§3.5: carry rule identity +
              # the prompt-template ref so the Resolver can return them as
              # matched-rule context (the next PR threads ctx → delivery).
              rule_id: row.id,
              rule_set: row.rule_set,
              prompt_template_ref: row.prompt_template_ref
            }

            [{matcher_tuple, value}]

          {:error, reason} ->
            require Logger

            Logger.error(
              "RuleStore: skipping rule id=#{row.id} — bad matcher: #{inspect(reason)}"
            )

            []
        end
      end)

    # PR #127: use replace_table_contents/2 so this works from any
    # caller process (the routing_admin Behavior runs in the LV
    # process, not the table-owner plugin Application process).
    # Also fixes the stale-entry-on-delete bug — clearing + repopulating
    # surfaces row deletions atomically.
    Ezagent.RoutingRegistry.replace_table_contents(table_name_atom, entries)
  end

  @doc """
  Check if any system_default rule exists in this table. Used by
  DefaultRules.bootstrap to decide whether to seed (per PR 9 §C: was
  "table empty?", now "no system_default rules?" — so admin's
  delete-then-restart doesn't get re-seeded).
  """
  @spec has_system_default?(atom()) :: boolean()
  def has_system_default?(table_name_atom) when is_atom(table_name_atom) do
    table_str = Atom.to_string(table_name_atom)

    from(r in __MODULE__,
      where: r.table_name == ^table_str and r.source == ^@system_default,
      limit: 1
    )
    |> Repo.exists?()
  end

  @doc """
  Delete a rule by id. Phase 4-completion PR 9 §C: system_default
  rules are protected — admin can `disable/1` them but not `delete/1`.
  Force-delete still possible via `delete/2` with `force: true`.
  """
  @spec delete(integer()) :: :ok | {:error, term()}
  def delete(id), do: delete(id, force: false)

  @spec delete(integer(), keyword()) :: :ok | {:error, term()}
  def delete(id, opts) when is_integer(id) do
    force = Keyword.get(opts, :force, false)

    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      %__MODULE__{source: @system_default} when not force ->
        {:error, :cannot_delete_system_default}

      rule ->
        case Repo.delete(rule) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  @doc """
  Disable an enabled rule (set enabled=false). System_defaults that admin
  doesn't want can be disabled without deleting; reload picks this up.
  """
  @spec disable(integer()) :: :ok | {:error, term()}
  def disable(id) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      rule ->
        rule
        |> Ecto.Changeset.change(%{enabled: false})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  @doc """
  Replace a rule's receivers + set its `enabled` flag in place.

  Used by the mention-gated-routing migration
  (`EzagentDomainInstanceMessage.DefaultRules`) to migrate an existing persisted
  `system_default` row's receivers without deleting + re-seeding it
  (which would lose the row id and its `created_at`).

  `receivers` is a list of URI strings / magic tokens. `enabled` is
  written as given — the caller decides (the migration preserves the
  pre-existing flag, applying disabled-wins on duplicates).
  """
  @spec update_receivers(integer(), [String.t()], boolean()) ::
          :ok | {:error, term()}
  def update_receivers(id, receivers, enabled)
      when is_integer(id) and is_list(receivers) and is_boolean(enabled) do
    receivers_str = Enum.map(receivers, &receiver_to_store/1)

    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      %__MODULE__{rule_set: rs} when not is_nil(rs) and length(receivers_str) != 1 ->
        # team-routing-unification §3.3 (codex 2026-06-01 LOW): the
        # single-receiver invariant for a NAMED rule-set rule holds at the
        # mutation boundary too, not just on insert — `update_receivers/3`
        # must not widen a rule-set rule to multi-receiver.
        {:error, :rule_set_requires_single_receiver}

      rule ->
        rule
        |> Ecto.Changeset.change(%{receivers: receivers_str, enabled: enabled})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  @spec enable(integer()) :: :ok | {:error, term()}
  def enable(id) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      rule ->
        rule
        |> Ecto.Changeset.change(%{enabled: true})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  @doc """
  Find a rule by its session-materialization identity:
  `(table, created_by, rule_set, position)`.

  team-routing-unification §3.7 / codex MAJOR #4 — SessionTemplate
  materialization stamps each installed rule with `created_by =
  <session_uri>` (the session whose materialization created it) so a
  repeated repair / re-materialize of the SAME session can reconcile
  (install only MISSING rules) rather than blind-`add` duplicates. The
  `(created_by, rule_set, position)` triple is the per-session rule
  identity. Returns the existing row or `nil`.
  """
  @spec find_by_identity(atom(), URI.t() | String.t() | nil, String.t() | nil, integer()) ::
          t() | nil
  def find_by_identity(table_name_atom, created_by, rule_set, position)
      when is_atom(table_name_atom) and is_integer(position) do
    table_str = Atom.to_string(table_name_atom)
    created_by_str = uri_to_string_or_nil(created_by)

    base =
      from(r in __MODULE__,
        where:
          r.table_name == ^table_str and r.created_by == ^created_by_str and
            r.position == ^position,
        limit: 1
      )

    # SQL `= NULL` never matches — use `is_nil` for a nil rule_set so a
    # standalone (rule_set-less) materialized rule still reconciles.
    query =
      if is_nil(rule_set) do
        from(r in base, where: is_nil(r.rule_set))
      else
        from(r in base, where: r.rule_set == ^rule_set)
      end

    Repo.one(query)
  end

  defp uri_to_string(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string(s) when is_binary(s), do: s

  defp receiver_to_store(receiver), do: Ezagent.Routing.Receiver.encode_for_store(receiver)

  defp uri_to_string_or_nil(nil), do: nil
  defp uri_to_string_or_nil(u), do: uri_to_string(u)
end
