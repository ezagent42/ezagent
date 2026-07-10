# dealscout crawl_now 操作面(operator)dispatch —— 照 kanban r2 的 kanban_dispatch.exs
# 同一 invocation 机制(身份 → target URI → Invocation.dispatch),CapBAC 不绕过:
# 身份/caps 来自 Ezagent.Entity.authenticate(EZAGENT_USER_TOKEN/EZAGENT_ENTITY_URI)。
# 用法: elixir --name probe@127.0.0.1 --cookie <cookie> dealscout_dispatch.exs \
#         "session://<...>" "dealscout.crawl_now" '{}'
[target_uri, action, args_json] = System.argv()
token = System.get_env("EZAGENT_USER_TOKEN") || raise "EZAGENT_USER_TOKEN unset"
euri = System.get_env("EZAGENT_ENTITY_URI") || raise "EZAGENT_ENTITY_URI unset"
node = :"ezagent_runtime@127.0.0.1"

code = ~S"""
{:ok, caller} = Ezagent.URI.parse(euri)

case Ezagent.Entity.authenticate(caller, token) do
  {:ok, %{caps: caps}} ->
    args =
      Jason.decode!(args_json)
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    target = Ezagent.URI.new!(target_uri <> "?action=" <> action)

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}, deadline_ms: 60_000}
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, r} ->
        {:ok, r}

      :ok ->
        receive do
          {:ezagent_reply, r} -> {:ok, r}
        after
          60_000 -> {:ok, :timeout_no_reply}
        end

      err ->
        err
    end

  {:error, e} ->
    {:auth_error, e}
end
"""

binding = [euri: euri, token: token, target_uri: target_uri, action: action, args_json: args_json]

case :erpc.call(node, Code, :eval_string, [code, binding], 90_000) do
  {result, _} -> IO.inspect(result, limit: 30, width: 120, printable_limit: 4000)
  other -> IO.inspect(other, label: "unexpected")
end
