defmodule Ezagent.RoutingRegistry do
  @moduledoc """
  RoutingRegistry — `external_key → URI(s)` table family for routing
  decisions (Decision #28 / #37 / #65; per ARCHITECTURE.md §5.4).

  Phase 3 落地 Decision #28:plugin-declared tables,owner-only-write.
  Used by `Ezagent.Routing.Resolver` to derive recipients from a Message
  + current Session context.

  ## How this differs from Ezagent.BehaviorRegistry and Ezagent.KindRegistry

  All three are "registry" abstractions but serve different runtime
  patterns:

  | Registry          | Purpose                  | Write timing       | Owner check |
  |-------------------|--------------------------|--------------------|-------------|
  | `KindRegistry`    | URI → pid                | runtime (Kind boot)| stdlib Registry semantics |
  | `BehaviorRegistry`| `{Kind, action} → behavior` | boot only (plugin Application.start) | none (boot-time only, last-writer-wins OK) |
  | `RoutingRegistry` | named table family, plugin-declared | **runtime** (admin runs `mix ezagent.routing.add_rule`) | **per-table owner pid** (declared at boot) — prevents plugin X from writing to plugin Y's table |

  The owner-pid check matters because Phase 3 introduces runtime
  routing rule edits (admin creates rules after boot). Without owner
  check, any plugin could `RoutingRegistry.put(OtherPluginTable, ...)`
  and silently stomp routing logic that plugin didn't own. Boot-time
  tables (`BehaviorRegistry`) don't have this risk — `register/3`
  runs once per plugin in known order, last-writer-wins is fine.

  ## Table declaration

      Ezagent.RoutingRegistry.declare_table(MyPlugin.ChatRouting,
        key_uniqueness: :unique,    # :unique → put_new (default) | :duplicate → put
        reverse_index: false)       # true → maintain value→[keys] reverse map

  ## Write/Read API

      # write (owner-pid only):
      Ezagent.RoutingRegistry.put_new(MyPlugin.ChatRouting, key, value)
      Ezagent.RoutingRegistry.put(MyPlugin.ChatRouting, key, value)

      # read (any process):
      Ezagent.RoutingRegistry.lookup(MyPlugin.ChatRouting, key)
      Ezagent.RoutingRegistry.lookup_all(MyPlugin.ChatRouting, key)
      Ezagent.RoutingRegistry.list_all(MyPlugin.ChatRouting)
      Ezagent.RoutingRegistry.reverse_index(MyPlugin.ChatRouting, value)

  ## ETS layout

  - `@meta_table` (`:ezagent_routing_registry_meta`): table_name → %{owner_pid, opts, reverse_index_table?}
  - per-table ETS named `{:routing, table_name}` (`:set` for unique, `:bag` for duplicate)
  - if reverse_index enabled, per-table reverse ETS `{:routing_reverse, table_name}` (`:bag`)
  """

  @meta_table :ezagent_routing_registry_meta

  def table, do: @meta_table

  @type table_name :: atom()
  @type opts :: [key_uniqueness: :unique | :duplicate, reverse_index: boolean()]

  @doc """
  Declare a routing table. Caller pid becomes the owner — only this
  pid (or processes it allows via separate API later) can write to
  the table. Idempotent: re-declaring with same caller is a no-op;
  with a different caller it crashes (let-it-crash on owner conflict).
  """
  @spec declare_table(table_name(), opts()) :: :ok
  def declare_table(name, opts \\ []) when is_atom(name) do
    uniqueness = Keyword.get(opts, :key_uniqueness, :unique)
    reverse? = Keyword.get(opts, :reverse_index, false)
    owner = self()

    case :ets.lookup(@meta_table, name) do
      [{^name, %{owner_pid: ^owner}}] ->
        :ok

      [{^name, %{owner_pid: other}}] ->
        raise ArgumentError,
              "RoutingRegistry table #{inspect(name)} already declared by #{inspect(other)}"

      [] ->
        data_type = if uniqueness == :unique, do: :set, else: :bag
        :ets.new(data_table(name), [data_type, :public, :named_table, read_concurrency: true])

        if reverse? do
          :ets.new(reverse_table(name), [:bag, :public, :named_table, read_concurrency: true])
        end

        :ets.insert(@meta_table, {
          name,
          %{owner_pid: owner, opts: opts, reverse_index?: reverse?}
        })

        :ok
    end
  end

  @doc """
  Write `{key, value}` to the table. Caller must be the table's owner.

  For `:unique` tables, fails with `{:error, :already_set}` if key
  exists. For `:duplicate` tables, appends.
  """
  @spec put_new(table_name(), term(), term()) :: :ok | {:error, term()}
  def put_new(name, key, value) do
    with :ok <- assert_owner(name),
         meta <- get_meta(name),
         :unique <- meta.opts |> Keyword.get(:key_uniqueness, :unique) do
      case :ets.insert_new(data_table(name), {key, value}) do
        true ->
          maybe_reverse_insert(name, key, value, meta)
          :ok

        false ->
          {:error, :already_set}
      end
    else
      :duplicate ->
        raise ArgumentError, "put_new requires :unique table; use put/3 for :duplicate"

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Write `{key, value}` to the table. For `:unique` tables, overwrites.
  For `:duplicate` tables, appends (preferred entry point for these).
  """
  @spec put(table_name(), term(), term()) :: :ok
  def put(name, key, value) do
    with :ok <- assert_owner(name),
         meta <- get_meta(name) do
      :ets.insert(data_table(name), {key, value})
      maybe_reverse_insert(name, key, value, meta)
      :ok
    end
  end

  @doc """
  Lookup a single value for `key`. Returns `{:ok, value}` or `:error`.
  Use on `:unique` tables. On `:duplicate` tables, returns the first
  match (use `lookup_all/2` for the list).
  """
  @spec lookup(table_name(), term()) :: {:ok, term()} | :error
  def lookup(name, key) do
    case :ets.lookup(data_table(name), key) do
      [{^key, value} | _] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Lookup all values for `key`. Returns a list (possibly empty).
  Use on `:duplicate` tables where one key maps to many values.
  """
  @spec lookup_all(table_name(), term()) :: [term()]
  def lookup_all(name, key) do
    :ets.lookup(data_table(name), key) |> Enum.map(fn {_, v} -> v end)
  end

  @doc """
  Return all `{key, value}` pairs in the table — for admin/debug +
  `Ezagent.Routing.Resolver` iteration. O(n).
  """
  @spec list_all(table_name()) :: [{term(), term()}]
  def list_all(name), do: :ets.tab2list(data_table(name))

  @doc """
  Reverse lookup: given a value, return the keys that map to it.
  Requires `reverse_index: true` at declare time; raises otherwise.
  """
  @spec reverse_index(table_name(), term()) :: [term()]
  def reverse_index(name, value) do
    meta = get_meta(name)

    unless meta.reverse_index? do
      raise ArgumentError,
            "table #{inspect(name)} has no reverse_index (declare with reverse_index: true)"
    end

    :ets.lookup(reverse_table(name), value) |> Enum.map(fn {_, k} -> k end)
  end

  @doc """
  Replace **all** entries in `name` with `entries` (`[{key, value}]`).

  Atomic from the reader's perspective: deletes everything then
  re-inserts in a single ETS pass. Used by `Ezagent.Routing.RuleStore.load_into_registry/1`
  to reflect the current persisted ruleset (including deletions, which
  the original boot-only `put/3` pattern missed — Phase 7 PR #127).

  **Bypasses `assert_owner/1`** intentionally. The owner-pid check on
  `put/3` exists to prevent cross-plugin stomping; this function's
  sole legitimate caller is `RuleStore` (in core), which already
  gates writes upstream via CapBAC on the `routing_admin` Behavior
  (admin-only). The earlier strict check made admin-triggered runtime
  rule edits silently no-op when dispatched from a non-owner LV
  process — exactly the bug PR #127 fixes.

  ## Semantics

  - For `:set` tables (unique): each key appears at most once.
  - For `:bag` tables (duplicate): the same key can repeat in
    `entries` with different values; all rows persist.

  Reverse index (if enabled) is rebuilt from the new entries.
  """
  @spec replace_table_contents(table_name(), [{term(), term()}]) :: :ok
  def replace_table_contents(name, entries) when is_atom(name) and is_list(entries) do
    meta = get_meta(name)

    :ets.delete_all_objects(data_table(name))

    if meta.reverse_index? do
      :ets.delete_all_objects(reverse_table(name))
    end

    for {key, value} <- entries do
      :ets.insert(data_table(name), {key, value})
      maybe_reverse_insert(name, key, value, meta)
    end

    :ok
  end

  @doc """
  Undeclare a routing table — the reverse of `declare_table/2`, used by
  the plugin-package UNLOAD path (handoff piece 4). Deletes the data
  table, the reverse table (if any), and the meta entry.

  Deliberately does NOT assert owner (same carve-out as
  `replace_table_contents/2`): an unload runs in the operator's process,
  not the plugin's original boot process. Idempotent — a table that was
  never declared (or already undeclared) is a no-op.
  """
  @spec undeclare_table(table_name()) :: :ok
  def undeclare_table(name) when is_atom(name) do
    case :ets.lookup(@meta_table, name) do
      [{^name, _meta}] ->
        # :ets.delete/1 on a named table is a no-op if the table is gone
        # (a restart could have already reaped it). Wrap to stay idempotent.
        try do
          :ets.delete(data_table(name))
        rescue
          ArgumentError -> :ok
        end

        try do
          :ets.delete(reverse_table(name))
        rescue
          ArgumentError -> :ok
        end

        :ets.delete(@meta_table, name)
        :ok

      [] ->
        :ok
    end
  end

  # --- Internals --------------------------------------------------------

  defp data_table(name), do: :"ezagent_routing_#{name}"
  defp reverse_table(name), do: :"ezagent_routing_reverse_#{name}"

  defp get_meta(name) do
    case :ets.lookup(@meta_table, name) do
      [{^name, meta}] -> meta
      [] -> raise ArgumentError, "RoutingRegistry table #{inspect(name)} not declared"
    end
  end

  defp assert_owner(name) do
    meta = get_meta(name)

    if meta.owner_pid == self() do
      :ok
    else
      {:error, {:not_owner, expected: meta.owner_pid, got: self()}}
    end
  end

  defp maybe_reverse_insert(name, key, value, %{reverse_index?: true}) do
    :ets.insert(reverse_table(name), {value, key})
  end

  defp maybe_reverse_insert(_name, _key, _value, _meta), do: :ok
end
