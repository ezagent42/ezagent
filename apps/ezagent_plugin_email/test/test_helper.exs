ExUnit.start()
# #88 PR-1 — DB-backed tests (ThreadState, Binding durability) use the
# EzagentCore.Repo sandbox. Manual mode + per-test checkout via
# EzagentCore.DataCase, matching the protocol_api plugin's harness.
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
