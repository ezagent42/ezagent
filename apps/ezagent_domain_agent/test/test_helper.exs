ExUnit.start()
{:ok, _apps} = Application.ensure_all_started(:ezagent_domain_agent)
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
