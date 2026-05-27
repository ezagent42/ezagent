#!/usr/bin/env elixir
# Phase 2.3 (rebased from EXP-C3) — runtime setup.
#
# Connects to the running Phase 2.3 BEAM (modules aren't loaded in this
# local elixir VM) and:
#   1. Spawns the admin User Kind (ezagent#395 workaround).
#   2. Creates workspace://acme (idempotent).
#
# Sessions are NOT pre-created here — the controller auto-creates them
# on first sight via EzagentDomainChat.create_session/3 (ezagent#408
# 3-tuple). That keeps the acceptance test "concurrent conv_id" exercise
# honest: c1 and c2 are minted lazily by the SSE controller, not
# pre-baked here.
#
# Usage:
#   elixir --name claude_helper@127.0.0.1 \
#     --cookie "$(cat ~/.ezagent/poc-phase2-c3/runtime/cookie)" \
#     poc/phase-2/3-setup.exs

runtime = :"ezagent_runtime_phase2_c3@127.0.0.1"
true = Node.connect(runtime)
IO.puts("✓ connected to #{runtime}")

setup_code = """
require Logger
admin_uri = Ezagent.Entity.User.admin_uri()
bootstrap_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
results = []

# 1. Spawn admin User Kind (ezagent#395 workaround)
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
  curl -N -X POST http://localhost:10123/api/customer/acme/chat \\
    -H 'Content-Type: application/json' \\
    -d '{"customer_id":"alice","text":"warranty?","conv_id":"c1"}'

Concurrency check (different conv_id → no cross-pollination):
  curl -N -X POST http://localhost:10123/api/customer/acme/chat \\
    -H 'Content-Type: application/json' \\
    -d '{"customer_id":"alice","text":"msg-A","conv_id":"c1"}' > /tmp/a.out &
  curl -N -X POST http://localhost:10123/api/customer/acme/chat \\
    -H 'Content-Type: application/json' \\
    -d '{"customer_id":"bob","text":"msg-B","conv_id":"c2"}' > /tmp/b.out &
  wait
  grep -c "msg-A" /tmp/a.out  # \\u2265 1
  grep -c "msg-B" /tmp/a.out  # 0
""")
