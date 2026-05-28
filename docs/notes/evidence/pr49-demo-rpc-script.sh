#!/bin/bash
# PR 49 e2e demo — drive the running ezagent_runtime via :erpc.
#
# Slow-paced (1.5s between steps) so agent-browser recording captures
# the LV updating in response to each dispatch.
#
# ARCHIVED (2026-05-27): this script references schemes deleted by
# PR #141 (`user://` → `entity://user/...`) and 2-segment template
# shapes deleted by Phase 9 PR-7 (`template://agent/<name>` →
# `template://agent/<workspace>/<name>`). It will NOT run as-is.
# Retained for the captured-recording context (agent-browser session
# at the time-of-recording). URI constructors below were migrated to
# `Ezagent.URI.parse!/1` per SPEC 2026-05-27-uri-canonicalization §9.3
# r3 to keep the historical example aligned with current canonical
# form; the shape strings are otherwise unchanged.

set -e
cd "$(dirname "$0")/../Workspace/esr-ng" 2>/dev/null || cd /Users/h2oslabs/Workspace/esr-ng

COOKIE=$(cat $HOME/.ezagent/default/runtime/cookie)
TARGET='ezagent_runtime@127.0.0.1'

# Use a short-lived elixir node to RPC into the live runtime.
elixir \
  --name "pr49_demo_$(date +%s)@127.0.0.1" \
  --cookie "$COOKIE" \
  -e "
Node.connect(:'$TARGET') || (IO.puts('cannot connect'); System.halt(1))

:erpc.call(:'$TARGET', fn ->
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Orchestrator.Tools

  IO.puts(\"\")
  IO.puts(\"=== PR 49 e2e demo ===\")
  Process.sleep(1500)

  template_name = \"demo-team-#{System.unique_integer([:positive])}\"
  seed_slice = %{
    name: template_name,
    description: \"PR 49 demo seed\",
    agent_slots: [],
    orchestrator_template_uri: Ezagent.URI.parse!(\"template://agent/cc-orchestrator\"),
    routing_rules: [],
    default_workspace_uri: Ezagent.URI.parse!(\"workspace://pr49-demo\")
  }
  seed_hash = SessionTemplate.compute_version_hash(seed_slice)
  seed_uri = SessionTemplate.build_uri(template_name, seed_hash)
  {:ok, _} = Ezagent.SpawnRegistry.spawn(seed_uri)
  IO.puts(\"[1/6] Seeded SessionTemplate #{URI.to_string(seed_uri)}\")
  Process.sleep(1500)

  owner = Ezagent.URI.parse!(\"user://admin\")
  {:ok, %{session_uri: s1, orchestrator_uri: orch1}} =
    Session.spawn_from_template(seed_uri, owner)
  IO.puts(\"[2/6] Generator spawned session #{URI.to_string(s1)} + orchestrator #{URI.to_string(orch1)}\")
  Process.sleep(1500)

  workspace_uri = Ezagent.URI.parse!(\"workspace://pr49-demo\")
  add_opts = [workspace_uri: workspace_uri, owner: owner]

  {:ok, backend_agent} =
    Tools.add_agent_slot(\"demo-backend-dev\", Ezagent.URI.parse!(\"template://agent/cc-orchestrator\"), nil, add_opts)
  IO.puts(\"[3/6] add_agent_slot(:backend-dev) -> #{URI.to_string(backend_agent)}\")
  Process.sleep(1500)

  {:ok, reviewer_agent} =
    Tools.add_agent_slot(\"demo-reviewer\", Ezagent.URI.parse!(\"template://agent/cc-orchestrator\"), nil, add_opts)
  IO.puts(\"[4/6] add_agent_slot(:reviewer) -> #{URI.to_string(reviewer_agent)}\")
  Process.sleep(1500)

  {:ok, new_template_uri} =
    Tools.save_template_as(\"code-review-team-#{System.unique_integer([:positive])}\",
      session_uri: s1, workspace_uri: workspace_uri, caller: orch1, parent_template_uri: seed_uri)
  IO.puts(\"[5/6] save_template_as -> #{URI.to_string(new_template_uri)}\")
  Process.sleep(1500)

  {:ok, _} = Ezagent.SpawnRegistry.spawn(new_template_uri)
  {:ok, %{session_uri: s2, orchestrator_uri: orch2}} =
    Session.spawn_from_template(new_template_uri, owner)
  IO.puts(\"[6/6] Re-instantiate -> session #{URI.to_string(s2)} + orchestrator #{URI.to_string(orch2)}\")
  Process.sleep(2000)

  IO.puts(\"\")
  IO.puts(\"=== Verification: agents in workspace://pr49-demo ===\")
  Ezagent.WorkspaceRegistry.list_all()
  |> Enum.filter(fn {_, ws} -> ws == \"workspace://pr49-demo\" end)
  |> Enum.each(fn {member, _} -> IO.puts(\"  #{member}\") end)
end)
"
