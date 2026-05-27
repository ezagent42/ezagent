#!/usr/bin/env elixir
# Phase 2.0 — MCP-init-trigger probe. Writes a configurable input
# to cs_main's PTY then waits and reports whether the esr-bridge
# MCP child spawned (its log file appears).
#
# Usage:
#   COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
#   elixir --name "probe@127.0.0.1" --cookie "$COOKIE" \
#     poc/phase-2/probe_trigger.exs "T1: bare CR" "\\r" 5
#
# Args:
#   1. label (string for output)
#   2. input bytes (escape sequences like \r, \n allowed)
#   3. wait_seconds after writing input before checking

[label, input_raw, wait_str] = case System.argv() do
  [l, i, w] -> [l, i, w]
  _ -> IO.puts("usage: probe_trigger.exs <label> <input> <wait_seconds>"); System.halt(1)
end

# Manually decode common escapes (since shell may not pass them through).
input = input_raw
  |> String.replace("\\r", "\r")
  |> String.replace("\\n", "\n")
  |> String.replace("\\t", "\t")

wait_s = String.to_integer(wait_str)

runtime =
  case System.get_env("EZAGENT_RUNTIME_NODE") do
    nil -> :"ezagent_runtime_phase2@127.0.0.1"
    s -> String.to_atom(s)
  end

true = Node.connect(runtime)

# Phase 2.2 — tenant + agent name parameterized via env (default acme/cs_main
# matches the local-dev fixture in poc/fixtures/plugins/acme/souls/).
tenant = System.get_env("TENANT") || "acme"
agent_name = System.get_env("AGENT_NAME") || "cs_main"
agent_uri = URI.parse("entity://agent/#{tenant}/cc_#{agent_name}")

# 1. Lookup PtyServer pid
{:ok, pty_pid} = :rpc.call(runtime, Ezagent.Domain.Pty, :lookup, [agent_uri])

# 2. Write input via Server.write_input/2
res = :rpc.call(runtime, Ezagent.Domain.Pty.Server, :write_input, [pty_pid, input])
IO.puts("=== #{label} ===")
IO.puts("input bytes (escaped): #{inspect(input)}")
IO.puts("write_input result: #{inspect(res)}")
IO.puts("waiting #{wait_s}s...")

# 3. Poll up to wait_s for log file appearing
log_dir = Path.expand("~/.ezagent/poc-phase2/logs/")
log_pattern = Path.join(log_dir, "cc-bridge-*.log")

start_t = System.monotonic_time(:millisecond)
deadline = start_t + wait_s * 1000

result = Stream.repeatedly(fn ->
  matches = Path.wildcard(log_pattern)
  if matches == [] do
    Process.sleep(500)
    nil
  else
    matches
  end
end)
|> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
|> Enum.find(fn matches -> matches != nil end)

case result do
  nil ->
    IO.puts("✗ NO bridge log appeared within #{wait_s}s — TRIGGER FAILED")
  [path | _] ->
    elapsed = System.monotonic_time(:millisecond) - start_t
    sz = File.stat!(path).size
    IO.puts("✓ bridge log appeared after #{elapsed}ms: #{path} (#{sz} bytes) — TRIGGER WORKED")
end

# 4. Always report PtyServer state + claude children at end
state = :rpc.call(runtime, :sys, :get_state, [pty_pid])
os_pid = Map.get(state, :os_pid)
IO.puts("\nclaude os_pid=#{os_pid}, pty_buffer_bytes=#{byte_size(Map.get(state, :pty_buffer, ""))}")
children_out = :os.cmd(~c'ps -o pid,comm -ax | awk -v p=#{os_pid} \'$2 != "" && system("ps -o ppid= -p " $1) == 0 \'')
IO.puts("(use shell `ps -axo pid,ppid,comm | awk -v p=#{os_pid} \\'$2==p\\'` to inspect children)")
