node = :"ezagent_ccpty@127.0.0.1"
Node.set_cookie(node, :"UNKXl-7I-CIECsvuZlFMUQ")
unless Node.connect(node), do: (IO.puts("CONNECT FAILED"); System.halt(1))
IO.puts("connected to #{node}")

# Reproduce the EXACT production cold-activation readiness sequence on the live
# node, N times, proving the cc Kind's ReadyGate flips to :ready on the real
# AgentBridge bind (what claude's esr-bridge join triggers) with NO orchestrator
# LiveJoinRegistry mark. Pre-fix this sequence would time out to :failed.
code = """
defmodule ProbeRun do
  def one do
    n = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://system/agent/ccgate-\#{n}")
    uri_str = URI.to_string(agent_uri)

    # 1. Arm the gate EXACTLY as production does in CcAgent.Spawn.ensure_pty_server
    #    (spawn.ex:412) — runs inside the Kind's post_init.
    :ok = Ezagent.Agent.TransportReadiness.require_transport_join(agent_uri, timeout_ms: 30_000)

    s_armed = Ezagent.ReadyGate.status(agent_uri)              # :not_ready
    d_armed = Ezagent.Agent.TransportReadiness.defer_ready?(agent_uri)  # {:defer, 30000}
    joined0 = Ezagent.Agent.LiveJoinRegistry.joined?(agent_uri)         # false

    # 2. Run the EXACT ready-transition the Kind runs after post_init
    #    (kind/server.ex:376 -> ReadyTransition.drain_then_mark_ready) — defers on
    #    the external gate and spawns the await_transport_or_fail Task.
    parent = self()
    rt = Ezagent.Kind.ReadyTransition.drain_then_mark_ready(uri_str, parent)  # :deferred

    Process.sleep(300)
    s_waiting = Ezagent.ReadyGate.status(agent_uri)            # still :not_ready (no join yet)

    # 3. Bind the bridge EXACTLY as AgentBridge.Channel.join_bridge does when
    #    claude's esr-bridge MCP joins (channel.ex:138). A regular cc agent does
    #    NOT mark LiveJoinRegistry (only orchestrators do).
    bridge_pid = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, bridge_pid, %{bridge_flavor: "cc"})

    # 4. Wait for the await Task to observe the bind and flip ReadyGate.
    deadline = System.monotonic_time(:millisecond) + 3_000
    t0 = System.monotonic_time(:millisecond)
    flip_ms =
      Stream.repeatedly(fn -> :ok end)
      |> Enum.reduce_while(nil, fn _, _ ->
        if Ezagent.ReadyGate.status(agent_uri) == :ready do
          {:halt, System.monotonic_time(:millisecond) - t0}
        else
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, :never}
          else
            Process.sleep(10); {:cont, nil}
          end
        end
      end)

    s_final = Ezagent.ReadyGate.status(agent_uri)
    joined_final = Ezagent.Agent.LiveJoinRegistry.joined?(agent_uri)
    bound_final = match?({:ok, _}, Ezagent.AgentBridge.Registry.lookup(agent_uri))

    Process.exit(bridge_pid, :kill)
    Ezagent.AgentBridge.Registry.unbind(agent_uri)
    Ezagent.Agent.TransportReadiness.clear(agent_uri)

    %{
      agent: uri_str, armed_status: s_armed, defer: inspect(d_armed),
      joined_before: joined0, ready_transition: rt, status_while_waiting: s_waiting,
      flip_after_bind_ms: flip_ms, final_status: s_final,
      live_joined_used: joined_final, bridge_bound: bound_final
    }
  end
end

Enum.map(1..5, fn _ -> ProbeRun.one() end)
"""

{runs, _} = :erpc.call(node, Code, :eval_string, [code], 120_000)

IO.puts("=== LIVE cc ReadyGate cold-activation proof (5 runs) ===")
Enum.with_index(runs, 1)
|> Enum.each(fn {r, i} ->
  IO.puts("run #{i}: armed=#{r.armed_status} defer=#{r.defer} ready_transition=#{inspect(r.ready_transition)}")
  IO.puts("       while_waiting=#{r.status_while_waiting} (live_joined_before=#{r.joined_before})")
  IO.puts("       --> bind bridge --> flip_to_ready_after=#{inspect(r.flip_after_bind_ms)}ms  final=#{r.final_status}")
  IO.puts("       (bridge_bound=#{r.bridge_bound}  live_join_registry_used=#{r.live_joined_used})")
end)
