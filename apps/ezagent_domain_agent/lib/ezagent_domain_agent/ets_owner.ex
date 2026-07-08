defmodule EzagentDomainAgent.EtsOwner do
  @moduledoc """
  Owns domain-agent ETS tables.

  The flavor registry and per-instance flavor attributes are domain-agent state,
  not core state. This owner starts before the Agent supervisors so plugin
  publish hooks and Template provisioning can fail loudly if boot order drifts.
  """

  use GenServer

  @tables [
    {Ezagent.AgentFlavorRegistry, :set},
    {Ezagent.AgentFlavorAttributes, :set},
    {Ezagent.AgentPassiveAttributes, :set},
    {Ezagent.Agent.RecipeAttributes, :set},
    # role-as-data (SPEC §3): `Ezagent.Agent.RecipeRegistry`'s read-through ETS CACHE
    # (keyed `{ws, name}` → `%Ezagent.Agent.Recipe{}`). Relocated from
    # `EzagentCore.EtsOwner` with the registry itself (the registry now resolves
    # over `Ezagent.Socialware.ConfigStore`, so it lives in domain_agent which
    # deps identity — keeping core free of identity). ETS is a lazy cache, NOT
    # the authority; ConfigStore is.
    {Ezagent.Agent.RecipeRegistry, :set}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Enum.each(@tables, fn {module, type} ->
      :ets.new(module.table(), [
        :named_table,
        :public,
        type,
        read_concurrency: true,
        write_concurrency: true
      ])
    end)

    {:ok, %{}}
  end
end
