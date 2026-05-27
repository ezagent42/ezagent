#!/usr/bin/env elixir
# EXP-C3 — query the `invocations` audit table for chat.send rows
# matching our session. RPC pattern, same as setup.exs.

runtime = :"ezagent_runtime_exp_c3@127.0.0.1"
true = Node.connect(runtime)

query_code = """
import Ecto.Query

# Best-effort: send :flush (the writer schedules its own; this nudges
# the timer). The writer's flush_interval is short (~500ms) so by the
# time this RPC returns the buffer is on disk.
send(Process.whereis(Ezagent.Audit.Writer), :flush)
Process.sleep(800)

rows =
  from(i in "invocations",
    where: like(i.target, "session://default/acme/c1?action=chat.send%"),
    order_by: [desc: i.id],
    limit: 5,
    select: %{
      id: i.id,
      caller: i.caller,
      target: i.target,
      action: i.action,
      authz: i.authz,
      workspace_uri: i.workspace_uri,
      inserted_at: i.inserted_at
    }
  )
  |> EzagentCore.Repo.all()

inspect(rows, pretty: true, limit: :infinity)
"""

case :rpc.call(runtime, Code, :eval_string, [query_code]) do
  {:badrpc, reason} ->
    IO.puts("✗ badrpc: #{inspect(reason)}")
    System.halt(1)

  {result, _bindings} when is_binary(result) ->
    IO.puts("=== invocations (most recent first) ===")
    IO.puts(result)

  other ->
    IO.puts("✗ unexpected: #{inspect(other)}")
    System.halt(1)
end
