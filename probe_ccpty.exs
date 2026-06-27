node = :"ezagent_ccpty@127.0.0.1"
Node.set_cookie(node, :"UNKXl-7I-CIECsvuZlFMUQ")

unless Node.connect(node) do
  IO.puts("CONNECT FAILED to #{node}")
  System.halt(1)
end

IO.puts("connected to #{node}")

sandbox = Path.expand("~/.ezagent/cc-sandboxes/ccpty505")
creds = Path.join(sandbox, ".credentials.json")

code = """
n = System.unique_integer([:positive])
agent_uri = Ezagent.URI.new!("entity://system/agent/ccpty505-\#{n}")
ws_uri = Ezagent.URI.new!("workspace://system")

:ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc")

tmpl = %{
  "flavor" => "cc",
  "cwd" => "#{sandbox}",
  "config_dir" => "#{sandbox}",
  "credential_source" => "#{creds}"
}

spawn_res =
  try do
    Ezagent.PluginCc.Template.CcAgent.Spawn.spawn_for_local_pty(agent_uri, tmpl, ws_uri)
  rescue
    e -> {:rescued, Exception.message(e)}
  catch
    k, v -> {:caught, k, inspect(v)}
  end

t0 = System.monotonic_time(:millisecond)

trace =
  Enum.map(0..180, fn _ ->
    Process.sleep(250)
    dt = System.monotonic_time(:millisecond) - t0
    rg = Ezagent.ReadyGate.status(agent_uri)
    bound = match?({:ok, _}, Ezagent.AgentBridge.Registry.lookup(agent_uri))
    joined = Ezagent.Agent.LiveJoinRegistry.joined?(agent_uri)
    {dt, rg, bound, joined}
  end)

compressed =
  trace
  |> Enum.reduce({nil, []}, fn entry, {prev, acc} ->
    key = Tuple.delete_at(entry, 0)
    if key == prev, do: {prev, acc}, else: {key, [entry | acc]}
  end)
  |> elem(1)
  |> Enum.reverse()

%{
  agent_uri: URI.to_string(agent_uri),
  spawn_res: inspect(spawn_res),
  first: List.first(trace),
  last: List.last(trace),
  transitions: compressed
}
"""

{result, _binding} = :erpc.call(node, Code, :eval_string, [code], 200_000)

IO.puts("=== SPAWN RESULT ===")
IO.puts(result.spawn_res)
IO.puts("agent: #{result.agent_uri}")
IO.puts("=== ReadyGate trace (dt_ms, status, bridge_bound?, live_joined?) ===")
IO.puts("first: #{inspect(result.first)}")
Enum.each(result.transitions, fn t -> IO.puts(inspect(t)) end)
IO.puts("last:  #{inspect(result.last)}")
