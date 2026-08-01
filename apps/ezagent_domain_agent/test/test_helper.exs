ExUnit.start()
{:ok, _apps} = Application.ensure_all_started(:ezagent_domain_agent)
Ezagent.UriQuery.init()

:ets.insert(
  Ezagent.UriQuery.table(),
  {:flavor,
   fn agent_uri ->
     case Ezagent.AgentFlavorAttributes.get(agent_uri) do
       {:ok, _flavor} = ok -> ok
       :none -> Ezagent.AgentFlavorResolver.flavor_from_durable_snapshot(agent_uri)
     end
   end}
)

Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
