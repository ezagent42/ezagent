#!/usr/bin/env elixir
# Phase 2 setup — spawn admin User Kind + create acme workspace + create cs_main cc agent.
#
# Usage:
#   COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
#   elixir --name "phase2_setup@127.0.0.1" --cookie "$COOKIE" poc/phase-2/setup.exs
#
# Idempotent — safe to re-run.

runtime = :"ezagent_runtime_phase2@127.0.0.1"
true = Node.connect(runtime)
IO.puts("✓ connected to #{runtime}")

agent_cwd = Path.expand("~/poc-sandbox-phase2/acme")

setup_code = """
require Logger
admin_uri = Ezagent.Entity.User.admin_uri()
bootstrap_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
results = []

# 1. Spawn admin User Kind (issue #395 workaround — though #419 may have landed a fix at add_member chokepoint, not this one yet)
admin_r =
  case Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: admin_uri, initial_caps: bootstrap_caps}) do
    {:ok, _pid} -> "admin spawned"
    {:error, {:already_started, _}} -> "admin alive"
    {:error, {:already_registered, _}} -> "admin alive (already_registered)"
    other -> "admin spawn UNEXPECTED " <> inspect(other)
  end
results = results ++ [admin_r]

# 2. Create workspace://acme
ws_r =
  case Ezagent.Workspace.create("acme", %{}) do
    {:ok, _pid} -> "workspace acme created"
    {:error, {:already_started, _}} -> "workspace acme alive"
    other -> "workspace.create UNEXPECTED: " <> inspect(other)
  end
results = results ++ [ws_r]

# 3. Create cc agent — note flavor prefix produces entity://agent/acme/cc_cs_main
ws_uri = URI.parse("workspace://acme")
ctx = %{caller: admin_uri, caps: bootstrap_caps, reply: {:caller_inbox, self()}}

agent_r =
  case Ezagent.Workspace.create_agent(ws_uri,
         %{flavor: "cc", name: "cs_main", cwd: "#{agent_cwd}", with_pty: true},
         ctx) do
    {:ok, %{agent_uri: u}} -> "cs_main created at " <> URI.to_string(u)
    {:error, {:already_exists, u}} -> "cs_main alive at " <> inspect(u)
    {:error, reason} -> "cs_main UNEXPECTED " <> inspect(reason)
  end
results = results ++ [agent_r]

Enum.join(results, " | ")
"""

case :rpc.call(runtime, Code, :eval_string, [setup_code]) do
  {:badrpc, reason} ->
    IO.puts("✗ badrpc: #{inspect(reason, pretty: true, limit: :infinity)}")
    System.halt(1)

  {result, _bindings} when is_binary(result) ->
    IO.puts("\n=== setup result ===")
    IO.puts(result)

  other ->
    IO.puts("✗ unexpected RPC return: #{inspect(other, pretty: true, limit: :infinity)}")
    System.halt(1)
end

IO.puts("\nAgent URI for probe: entity://agent/acme/cc_cs_main")
IO.puts("cwd: #{agent_cwd}")
