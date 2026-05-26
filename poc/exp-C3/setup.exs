#!/usr/bin/env elixir
# EXP-C3 — runtime setup. Like Phase 0, this is a single RPC
# Code.eval_string against the running ezagent BEAM (modules aren't
# loaded in this local elixir VM).
#
# Usage:
#   elixir --name claude_helper@127.0.0.1 \
#     --cookie "$(cat ~/.ezagent/poc-exp-c3/runtime/cookie)" \
#     poc/exp-C3/setup.exs
#
# What it does:
#   1. Spawns the admin User Kind (issue #395 workaround).
#   2. Creates workspace://acme (idempotent).
#   3. Creates session://default/acme/c1 with admin as creator.
#
# Note: no cc agent. EXP-C3 uses a synthetic agent reply via
# Phoenix.PubSub injection — see CustomerChatController moduledoc.
# A session with no member agents is fine: chat.send still persists
# + broadcasts, which is all the SSE stream cares about.

runtime = :"ezagent_runtime_exp_c3@127.0.0.1"
true = Node.connect(runtime)
IO.puts("✓ connected to #{runtime}")

setup_code = """
require Logger
admin_uri = Ezagent.Entity.User.admin_uri()
bootstrap_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
results = []

# 1. Spawn admin User Kind (issue #395 workaround)
admin_r =
  case Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: admin_uri, initial_caps: bootstrap_caps}) do
    {:ok, _pid} -> "admin spawned"
    {:error, {:already_started, _}} -> "admin alive"
    other -> "admin spawn FAILED " <> inspect(other)
  end
results = results ++ [admin_r]

# 2. Create workspace://acme
ws_r =
  case Ezagent.Workspace.create("acme", %{}) do
    {:ok, _pid} -> "workspace acme created"
    {:error, {:already_started, _}} -> "workspace acme alive"
    other -> "workspace.create: " <> inspect(other)
  end
results = results ++ [ws_r]

# 3. Create session://default/acme/c1 with admin as creator
sess_r =
  case EzagentDomainChat.create_session("c1", admin_uri,
         workspace_uri: URI.parse("workspace://acme"),
         template_name: "default") do
    {:ok, session_uri} -> "session " <> URI.to_string(session_uri) <> " ready"
    other -> "session FAILED " <> inspect(other)
  end
results = results ++ [sess_r]

# 4. Create a second session for the concurrency test
sess2_r =
  case EzagentDomainChat.create_session("c2", admin_uri,
         workspace_uri: URI.parse("workspace://acme"),
         template_name: "default") do
    {:ok, session_uri} -> "session " <> URI.to_string(session_uri) <> " ready"
    other -> "session FAILED " <> inspect(other)
  end
results = results ++ [sess2_r]

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

IO.puts("""

Now try:
  curl -N -X POST http://localhost:10203/api/customer/acme/chat \\
    -H 'Content-Type: application/json' \\
    -d '{"customer_id":"alice","text":"warranty?","conv_id":"c1"}'
""")
