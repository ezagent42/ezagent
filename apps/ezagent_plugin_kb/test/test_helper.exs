ExUnit.start()

# The integration tests (kb-as-role create path + dispatch) need the Repo
# sandbox, mirroring the native/kanban plugin test setup. The pure Store tests
# do not touch the Repo, so this is harmless for them.
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
