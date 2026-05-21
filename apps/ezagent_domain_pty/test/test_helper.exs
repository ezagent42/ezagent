ExUnit.start()

# Domain.Pty PR-B (2026-05-21 SPEC v1): enable Sandbox manual mode so
# tests that spawn Kinds with `persistence :on_terminate` (e.g.
# `Ezagent.Entity.Agent` in `Ezagent.Behavior.PtyTest`) can check out a
# DB connection via `EzagentCore.DataCase`.
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
