#!/usr/bin/env elixir
# Phase 2 setup — spawn admin User Kind + create acme workspace + create cs_main cc agent.
#
# Usage:
#   COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
#   elixir --name "phase2_setup@127.0.0.1" --cookie "$COOKIE" poc/phase-2/setup.exs
#
# Idempotent — safe to re-run.

runtime =
  case System.get_env("EZAGENT_RUNTIME_NODE") do
    nil -> :"ezagent_runtime_phase2@127.0.0.1"
    s -> String.to_atom(s)
  end

true = Node.connect(runtime)
IO.puts("✓ connected to #{runtime}")

# Phase 2.2 — tenant + role are now parameters, not literals. The setup
# script picks defaults to make local dev a one-liner, but every value
# is overridable so a future tenant (or test sandbox) reuses the same
# script with different env. The `acme` default below is a TEST FIXTURE
# only (see poc/fixtures/plugins/acme/souls/customer.md) — production
# operators always supply TENANT explicitly.
tenant = System.get_env("TENANT") || "acme"
role = System.get_env("ROLE") || "customer"
agent_name = System.get_env("AGENT_NAME") || "cs_main"
agent_cwd = System.get_env("AGENT_CWD") || Path.expand("~/poc-sandbox-phase2/#{tenant}")

# Soul file convention mirrors AutoService's per-tenant layout:
# `plugins/<tenant>/souls/<role>.md`. For the PoC fixture lives under
# `poc/fixtures/plugins/<tenant>/souls/<role>.md`; production operators
# point SOUL_PATH at wherever they version their soul (e.g.
# `~/.ezagent/<profile>/souls/<tenant>/<role>.md`).
soul_path =
  System.get_env("SOUL_PATH") ||
    Path.expand("../fixtures/plugins/#{tenant}/souls/#{role}.md", __DIR__)

unless File.exists?(soul_path) do
  IO.puts("⚠ SOUL_PATH not found: #{soul_path} — agent will spawn with no --append-system-prompt")
end

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

# 2. Create workspace://<tenant>
ws_r =
  case Ezagent.Workspace.create("#{tenant}", %{}) do
    {:ok, _pid} -> "workspace #{tenant} created"
    {:error, {:already_started, _}} -> "workspace #{tenant} alive"
    other -> "workspace.create UNEXPECTED: " <> inspect(other)
  end
results = results ++ [ws_r]

# 3. Create cc agent — flavor prefix produces entity://agent/<tenant>/cc_<name>
ws_uri = URI.parse("workspace://#{tenant}")
ctx = %{caller: admin_uri, caps: bootstrap_caps, reply: {:caller_inbox, self()}}

agent_r =
  case Ezagent.Workspace.create_agent(ws_uri,
         %{flavor: "cc", name: "#{agent_name}", cwd: "#{agent_cwd}", with_pty: true,
           soul_path: "#{soul_path}"},
         ctx) do
    {:ok, %{agent_uri: u}} -> "#{agent_name} created at " <> URI.to_string(u)
    {:error, {:already_exists, u}} -> "#{agent_name} alive at " <> inspect(u)
    {:error, reason} -> "#{agent_name} UNEXPECTED " <> inspect(reason)
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

IO.puts("\nAgent URI for probe: entity://agent/#{tenant}/cc_#{agent_name}")
IO.puts("cwd: #{agent_cwd}")
IO.puts("soul_path: #{soul_path}")
