defmodule Ezagent.AgentFlavorRegistry do
  @moduledoc """
  AgentFlavorRegistry — declarative `flavor → {kind, template_class}`
  map (SPEC §6.3, codex MEDIUM-5).

  Today the agent spawn resolver in `ezagent_domain_session` has a
  hardcoded `flavor → {kind, template_class}` map — that is why "add a
  6th agent-flavor plugin" actually requires editing a non-plugin file.
  Each agent plugin declares `agent_flavors/0` (a list of
  `t:Ezagent.Plugin.agent_flavor_decl/0`); `Ezagent.Plugin.boot/1`
  registers each entry here. PR-3 then migrates the domain_instance_message
  resolver to consult this registry — after which a new agent-flavor
  plugin truly touches only its own dir.

  PR-1 only BUILDS this registry; nothing reads it yet.

  Bare ETS, same house style as `Ezagent.TemplateRegistry`. The table
  is owned by `EzagentDomainAgent.EtsOwner` (in its `@tables` list).

  ## ETS layout

  `:ezagent_agent_flavor_registry` `:set` table. Key is the `flavor`
  string (the entity-name prefix — `"cc"`, `"curl"`, `"echo"`); value
  is `%{kind: module(), template_class: module()}`.
  """

  @table :ezagent_agent_flavor_registry
  @sealed_key {__MODULE__, :sealed?}
  @published_plugins_key {__MODULE__, :published_plugins}
  @load_all_started_key {__MODULE__, :load_all_started_after_seal?}

  @typedoc """
  The stored value — a flavor's kind + template-class wiring, plus the
  OPTIONAL per-instance behavior-set thunk (PR-6+7 curl-as-flavor) and the
  OPTIONAL CapMint cap-policy (role-foundation RF-8). The thunk is `nil` for a
  flavor backed by its own dedicated Kind (py); it is a 0-arity fn returning
  the flavor's behavior SUBSET for a flavor folded onto a SHARED Kind
  (`curl` → `Entity.Agent`), so the generic direct-spawn path threads
  `:behaviors` without the workspace domain knowing the flavor.

  `cap_policy` is `nil` for a flavor that has no role-driven cap minting; it is
  a 1-arity fn `(recipe.requested_caps -> (needed_cap -> boolean()))` — the
  flavor's fail-closed CapMint policy FACTORY. The role-driven create path
  (RF-5a) reads it here and passes `cap_policy.(recipe.requested_caps)` to
  `Ezagent.Agent.Recipe.CapMint.mint/3`, so the workspace domain selects the flavor's
  cap policy from data WITHOUT depending on the flavor plugin (the same seam as
  `instance_behaviors`).
  """
  @type decl :: %{
          kind: module(),
          template_class: module() | nil,
          instance_behaviors: (-> [module()]) | nil,
          cap_policy: ([map()] -> (map() -> boolean())) | nil
        }

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
  def register(%{flavor: flavor, kind: kind, template_class: template_class} = decl)
      when is_binary(flavor) and is_atom(kind) and is_atom(template_class) do
    # PR-6+7 — carry the OPTIONAL per-instance behavior-set thunk through.
    # Absent → nil (the common case; a flavor with its own dedicated Kind).
    instance_behaviors = validate_instance_behaviors!(Map.get(decl, :instance_behaviors))
    # RF-8 — carry the OPTIONAL CapMint cap-policy factory through. Absent →
    # nil (the common case; a flavor with no role-driven cap minting).
    cap_policy = validate_cap_policy!(Map.get(decl, :cap_policy))

    value = %{
      kind: kind,
      template_class: template_class,
      instance_behaviors: instance_behaviors,
      cap_policy: cap_policy
    }

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

  @doc """
  Resolve a flavor's Template Class module.

  Returns `{:ok, template_class}` or a distinct error for an unknown flavor vs
  a declaration without a Template Class. The SINGLE resolution helper shared
  by the recipe materializer and the #1201 host-login-adopt seam (FF-1: one
  body, not per-caller forks).
  """
  @spec template_class_for(flavor :: String.t()) :: {:ok, module()} | {:error, term()}
  def template_class_for(flavor) when is_binary(flavor) do
    case lookup(flavor) do
      {:ok, %{template_class: tc}} when is_atom(tc) -> {:ok, tc}
      {:ok, _decl} -> {:error, {:flavor_has_no_template_class, flavor}}
      :error -> {:error, {:unknown_flavor, flavor}}
    end
  end

  @doc "List every registered `{flavor, decl}` pair — for debug / admin."
  @spec list_all() :: [{String.t(), decl()}]
  def list_all, do: :ets.tab2list(@table)

  @doc """
  Mark the boot-time flavor registry as sealed.

  Sealing means the current boot's loaded flavor plugins have all published
  their declarations. It is a boot barrier for cold-restart paths that would
  otherwise instantiate agents before every folded flavor behavior set exists.
  """
  @spec seal!() :: :ok
  def seal! do
    :persistent_term.put(@sealed_key, true)
    :ok
  end

  @doc "Return whether the flavor registry has been sealed for this BEAM boot."
  @spec sealed?() :: boolean()
  def sealed?, do: :persistent_term.get(@sealed_key, false)

  @doc "Wait for the registry seal, returning `:ok` or `{:error, :timeout}`."
  @spec await_sealed(timeout()) :: :ok | {:error, :timeout}
  def await_sealed(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_sealed_until(deadline)
  end

  @doc false
  @spec note_plugin_published(module()) :: :ok
  def note_plugin_published(plugin_module) when is_atom(plugin_module) do
    if flavor_plugin?(plugin_module) do
      published =
        @published_plugins_key
        |> :persistent_term.get(MapSet.new())
        |> MapSet.put(plugin_module)

      :persistent_term.put(@published_plugins_key, published)
      maybe_seal_after_plugin_publish(published)
    end

    :ok
  end

  @doc false
  @spec reset_seal_for_test!() :: :ok
  def reset_seal_for_test! do
    :persistent_term.erase(@sealed_key)
    :persistent_term.erase(@published_plugins_key)
    :persistent_term.erase(@load_all_started_key)
    :ok
  end

  # The per-instance behavior-set thunk must be a 0-arity fn or nil. A bad
  # value is a plugin authoring bug — fail loud at register time, not at the
  # first agent spawn.
  defp validate_instance_behaviors!(nil), do: nil

  defp validate_instance_behaviors!(fun) when is_function(fun, 0), do: fun

  defp validate_instance_behaviors!(other) do
    raise ArgumentError,
          "AgentFlavorRegistry: :instance_behaviors must be a 0-arity fn or nil, " <>
            "got #{inspect(other)}."
  end

  # RF-8 — the cap-policy must be a 1-arity fn (recipe.requested_caps → the
  # per-recipe needed-cap predicate) or nil. A bad value is a plugin authoring
  # bug — fail loud at register time, not at the first role-driven create.
  defp validate_cap_policy!(nil), do: nil

  defp validate_cap_policy!(fun) when is_function(fun, 1), do: fun

  defp validate_cap_policy!(other) do
    raise ArgumentError,
          "AgentFlavorRegistry: :cap_policy must be a 1-arity fn or nil, " <>
            "got #{inspect(other)}."
  end

  defp await_sealed_until(deadline) do
    cond do
      sealed?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(10)
        await_sealed_until(deadline)
    end
  end

  defp flavor_plugin?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :agent_flavors, 0) and
      module.agent_flavors() != []
  rescue
    _ -> false
  end

  defp maybe_seal_after_plugin_publish(published) do
    expected = expected_flavor_plugins()

    if expected != [] and Enum.all?(expected, &MapSet.member?(published, &1)) do
      :ok = seal!()
      maybe_trigger_load_all_after_seal()
    end
  end

  defp expected_flavor_plugins do
    Application.loaded_applications()
    |> Enum.flat_map(fn {app, _description, _version} ->
      case Application.spec(app, :mod) do
        {module, _args} when is_atom(module) ->
          if flavor_plugin?(module), do: [module], else: []

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp maybe_trigger_load_all_after_seal do
    unless :persistent_term.get(@load_all_started_key, false) do
      :persistent_term.put(@load_all_started_key, true)

      _ =
        Task.start(fn ->
          if Code.ensure_loaded?(Ezagent.Workspace.Loader) and
               function_exported?(Ezagent.Workspace.Loader, :load_all, 0) do
            _ = apply(Ezagent.Workspace.Loader, :load_all, [])
            :ok
          else
            :ok
          end
        end)
    end

    :ok
  end
end
