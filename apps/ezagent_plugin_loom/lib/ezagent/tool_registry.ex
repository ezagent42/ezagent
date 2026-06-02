defmodule EzagentPluginLoom.ToolRegistry do
  @moduledoc """
  Boot-time registry of `EzagentPluginLoom.Tool` modules, keyed by
  `Tool.name/0`. Populated from `Application.get_env(:ezagent_plugin_loom,
  :tools, [])` during `Application.start/2` after the supervision tree
  is up. Read-mostly: lookups are hot-path (every `platform.tool(...)`
  RPC), registration is once.

  ETS-backed (`:protected`, `:read_concurrency`) so lookups are
  lock-free and parallel.

  ## Why a registry vs. just iterating config each time?

  `:tools` is config-baked; the list won't change at runtime. But the
  tool prompt block (exposed to the AI) needs args_schema + description
  per tool, which requires calling the modules. Pre-collecting these
  at boot lets `prompt_block/0` be O(1) and survive code reloads
  (registry is the cache).

  ## Public API

      ToolRegistry.lookup("echo")  → {:ok, module} | :error
      ToolRegistry.list()          → [%{name, description, args_schema}]
      ToolRegistry.prompt_block/0  → string for page_gen prompt
  """

  @table :ezagent_loom_tools

  require Logger

  @doc "Create the ETS table. Called once from EzagentPluginLoom.Application.start/2."
  def init_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :protected,
          :set,
          read_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  @doc """
  Register every module in `:ezagent_plugin_loom, :tools` config.
  Called from `EzagentPluginLoom.Application.after_boot/0` so plugins
  loaded later still have a chance (after_boot runs after Phase 2
  publish — same gate `SavedClasses.register_all_from_disk/0` uses).

  Raises on name collision (operator bug — two tools claim the same
  name). Returns the number of tools registered.
  """
  def register_all do
    init_table()
    :ets.delete_all_objects(@table)

    tools = Application.get_env(:ezagent_plugin_loom, :tools, [])

    Enum.reduce(tools, 0, fn module, acc ->
      try do
        name = module.name()

        if :ets.lookup(@table, name) != [] do
          raise "EzagentPluginLoom.ToolRegistry: tool name collision: #{inspect(name)} " <>
                  "already registered by another module"
        end

        entry = %{
          module: module,
          name: name,
          description: safe_call(module, :description, [], ""),
          args_schema: safe_call(module, :args_schema, [], %{})
        }

        :ets.insert(@table, {name, entry})
        acc + 1
      rescue
        e ->
          Logger.warning(
            "EzagentPluginLoom.ToolRegistry: skipping #{inspect(module)} — " <>
              "#{Exception.message(e)}"
          )

          acc
      end
    end)
  end

  @doc "Look up a tool by name. Returns `{:ok, module}` or `:error`."
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, %{module: module}}] -> {:ok, module}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "List every registered tool's metadata (name, description, args_schema)."
  def list do
    init_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, entry} ->
      Map.take(entry, [:name, :description, :args_schema])
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Render the available-tools block for the page-generation system
  prompt. Each tool gets a line:

      - <name>: <description>  args: <args_schema as JSON>

  Empty string if no tools configured (the prompt suppresses the
  section in that case).
  """
  def prompt_block do
    case list() do
      [] ->
        ""

      tools ->
        body =
          tools
          |> Enum.map(fn t ->
            "  - `#{t.name}`: #{t.description} args=#{Jason.encode!(t.args_schema)}"
          end)
          |> Enum.join("\n")

        """
        可用工具(通过 `await platform.tool(name, args)` 调用):
        #{body}
        """
    end
  end

  defp safe_call(module, fun, args, default) do
    apply(module, fun, args)
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
