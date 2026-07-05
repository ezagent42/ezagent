{:ok, _} = Application.ensure_all_started(:ezagent_plugin_dealscout)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
