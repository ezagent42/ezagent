ExUnit.start()
Ezagent.UriQuery.init()

:ets.insert(
  Ezagent.UriQuery.table(),
  {:flavor, &Ezagent.AgentFlavorAttributes.get/1}
)

Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
