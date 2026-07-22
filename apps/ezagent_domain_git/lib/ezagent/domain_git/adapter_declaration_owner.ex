defmodule Ezagent.DomainGit.AdapterDeclarationOwner do
  @moduledoc """
  Supervised owner that registers a plugin's Git adapter declarations into
  `Ezagent.DomainGit.AdapterRegistry` from WITHIN the plugin's own supervision
  tree.

  A provider plugin lists this in its `Ezagent.Plugin` `children/0` with
  `owner:` + `adapters: [{provider_id, adapter_module}]`. The `.register` call
  runs HERE (domain code), so the plugin's own source never calls
  `AdapterRegistry.register` — the plugin-authoring contract (SPEC §3.2 /
  `:ezagent_plugin_check`) forbids a plugin from touching a `*Registry` API
  directly.

  Why an owner in `children/0` rather than domain_git's config-driven
  `BootRegistration`: `AdapterRegistry` validates `:code.is_loaded/1` (it does
  NOT auto-load — registration is pure dependency injection). domain_git boots
  BEFORE the provider plugin, so its `BootRegistration` cannot register a plugin
  adapter (the module is not loaded yet, and eager-loading a plugin module at
  domain boot would invert the layering / fail if the plugin is absent). Started
  in the PLUGIN's lifecycle, the plugin's modules are already loaded; we
  `Code.ensure_loaded/1` defensively before registering. Rows are removed on
  terminate.

  Parity note: like the pre-existing plugin registration it replaces, this is a
  one-shot register at plugin boot — it does NOT re-reconcile on an
  `AdapterRegistry` restart (only domain_git's own `BootRegistration` is wired to
  the registry's restart notification). Reconciliation for plugin-owned adapters
  is a possible future enhancement.
  """

  use GenServer

  alias Ezagent.DomainGit.AdapterRegistry

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    owner = Keyword.fetch!(opts, :owner)

    %{
      id: {__MODULE__, owner},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    adapters = Keyword.get(opts, :adapters, [])

    case register_all(adapters) do
      {:ok, owned} ->
        {:ok, %{owner: owner, owned: owned}}

      {:error, reason, owned} ->
        unregister_all(owned)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister_all(state.owned)
    :ok
  end

  defp register_all(adapters) do
    Enum.reduce_while(adapters, {:ok, []}, fn {id, module} = decl, {:ok, owned} ->
      _ = Code.ensure_loaded(module)

      case AdapterRegistry.register(id, module) do
        :ok -> {:cont, {:ok, [decl | owned]}}
        {:ok, :already_registered} -> {:cont, {:ok, owned}}
        {:error, reason} -> {:halt, {:error, {:git_adapter_registration_failed, id, reason}, owned}}
      end
    end)
  end

  defp unregister_all(owned) do
    Enum.each(owned, fn {id, module} -> AdapterRegistry.unregister(id, module) end)
  end
end
