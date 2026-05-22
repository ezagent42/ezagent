defmodule Ezagent.AgentFlavorRegistry do
  @moduledoc """
  AgentFlavorRegistry — declarative `flavor → {kind, template_class}`
  map (SPEC §6.3, codex MEDIUM-5).

  Today the agent spawn resolver in `ezagent_domain_chat` has a
  hardcoded `flavor → {kind, template_class}` map — that is why "add a
  6th agent-flavor plugin" actually requires editing a non-plugin file.
  Each agent plugin declares `agent_flavors/0` (a list of
  `t:Ezagent.Plugin.agent_flavor_decl/0`); `Ezagent.Plugin.boot/1`
  registers each entry here. PR-3 then migrates the domain_chat
  resolver to consult this registry — after which a new agent-flavor
  plugin truly touches only its own dir.

  PR-1 only BUILDS this registry; nothing reads it yet.

  Bare ETS, same house style as `Ezagent.TemplateRegistry`. The table
  is owned by `EzagentCore.EtsOwner` (in its `@tables` list).

  ## ETS layout

  `:ezagent_agent_flavor_registry` `:set` table. Key is the `flavor`
  string (the entity-name prefix — `"cc"`, `"curl"`, `"echo"`); value
  is `%{kind: module(), template_class: module()}`.
  """

  @table :ezagent_agent_flavor_registry

  @typedoc "The stored value — a flavor's kind + template-class wiring."
  @type decl :: %{kind: module(), template_class: module()}

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register an agent flavor from a `t:Ezagent.Plugin.agent_flavor_decl/0`.

  Idempotent for an identical declaration. A different
  `{kind, template_class}` pair under an already-registered `flavor`
  is a real bug — raises `ArgumentError`.
  """
  @spec register(Ezagent.Plugin.agent_flavor_decl()) :: :ok
  def register(%{flavor: flavor, kind: kind, template_class: template_class})
      when is_binary(flavor) and is_atom(kind) and is_atom(template_class) do
    value = %{kind: kind, template_class: template_class}

    case :ets.lookup(@table, flavor) do
      [{^flavor, ^value}] ->
        :ok

      [{^flavor, existing}] ->
        raise ArgumentError,
              "AgentFlavorRegistry: flavor #{inspect(flavor)} already registered as " <>
                "#{inspect(existing)}; cannot re-register as #{inspect(value)}. " <>
                "Two plugins must not claim the same agent flavor."

      [] ->
        :ets.insert(@table, {flavor, value})
        :ok
    end
  end

  @doc """
  Look up the `{kind, template_class}` wiring for a flavor.

  Returns `{:ok, decl}` or `:error`.
  """
  @spec lookup(flavor :: String.t()) :: {:ok, decl()} | :error
  def lookup(flavor) when is_binary(flavor) do
    case :ets.lookup(@table, flavor) do
      [{^flavor, decl}] -> {:ok, decl}
      [] -> :error
    end
  end

  @doc "List every registered `{flavor, decl}` pair — for debug / admin."
  @spec list_all() :: [{String.t(), decl()}]
  def list_all, do: :ets.tab2list(@table)
end
