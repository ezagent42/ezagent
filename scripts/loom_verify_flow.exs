# live 链路验证:instantiate(起 OrchestratorServer+team+seed)→ 发 customer 消息
# (走 web_plug 同款 session.send dispatch)→ 轮询 MessageStore 等 loomv0 产出新 page_update。
# 用法: mix run scripts/loom_verify_flow.exs   (cc flavor,无需 key;需本地 claude 二进制)
# Ezu = Ezagent.URI(构造器);stdlib URI 仍是 URI(to_string)。
alias Ezagent.URI, as: Ezu
alias Ezagent.{Workspace, Message, Invocation, SystemPrincipal, MessageStore}
alias EzagentPluginLoom.{PageStore, Template.LoomSession}

ws = "verify"
sid = "flow#{System.unique_integer([:positive])}"
_ = Workspace.create(ws, %{})
wsuri = Ezu.workspace(ws)
suri = Ezu.session(ws, :loom, sid)

IO.puts("\n========== LOOM LIVE 链路验证 ==========")
IO.puts("session = #{URI.to_string(suri)}")

# 1) instantiate —— 起 OrchestratorServer + Team + seed 初始页
{:ok, [^suri], meta} =
  LoomSession.instantiate(
    "loom-verify",
    %{
      "class" => "session.loom",
      "session_name" => sid,
      "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
    },
    wsuri
  )

IO.puts("\n[阶段0] instantiate ok, meta=#{inspect(meta)}")

# OrchestratorServer 注册?
orch_pid = Registry.lookup(EzagentPluginLoom.OrchestratorRegistry, URI.to_string(suri))
IO.puts("[阶段0] OrchestratorServer 进程: #{inspect(orch_pid)}")

# seed 页进了 PageStore?
Process.sleep(300)
seed = PageStore.get(suri)
seed_app = is_map(seed) && Map.get(seed, "/App.jsx", "")
IO.puts("[阶段0] seed PageStore files keys=#{inspect(seed && Map.keys(seed))}")
IO.puts("[阶段0] seed /App.jsx 前 60 字: #{String.slice(to_string(seed_app), 0, 60)}")

# 2) 发 customer 消息 —— 完全复制 web_plug send_message 的 dispatch
sender = Ezu.user(ws, "admin")
text = "帮我做一个卖手冲咖啡的落地页,要有产品介绍和下单按钮"
msg = Message.new(sender, %{text: text})

inv = %Invocation{
  target: Ezu.new!("#{URI.to_string(suri)}?action=session.send"),
  mode: :cast,
  args: %{message: msg},
  ctx: %{
    caller: Ezu.new!("system://loom-customer-gateway"),
    caps: SystemPrincipal.caps("system://bootstrap"),
    reply: :ignore
  }
}

IO.puts("\n[阶段1] 发 customer 消息: #{text}")
IO.puts("[阶段1] dispatch session.send → #{inspect(Invocation.dispatch(inv))}")

# 3) 轮询等 loomv0 产出**新** page_update(区别于 seed)
loomv0 = URI.to_string(Ezu.agent(ws, "loomv0_#{sid}"))
IO.puts("\n[阶段2] 等 OrchestratorServer → V0.generate(cc/本地 claude)产出, 轮询最多 90s...")

wait = fn wait, n ->
  cur = PageStore.get(suri)
  cur_app = is_map(cur) && Map.get(cur, "/App.jsx", "")
  changed? = cur_app != seed_app and is_binary(cur_app) and cur_app != ""

  v0_spans =
    suri
    |> MessageStore.recent_in_session(50)
    |> Enum.filter(fn m ->
      URI.to_string(m.sender) == loomv0 and
        is_binary((m.body || %{})["text"]) and
        String.contains?((m.body || %{})["text"], ~s(type="page_update"))
    end)

  cond do
    changed? and length(v0_spans) >= 2 ->
      {:done, cur, v0_spans}

    n <= 0 ->
      {:timeout, cur, v0_spans}

    true ->
      Process.sleep(2000)
      wait.(wait, n - 1)
  end
end

case wait.(wait, 45) do
  {:done, cur, spans} ->
    IO.puts("\n✅ [阶段2] 验证通过 —— loomv0 产出了新 page_update")
    IO.puts("   loomv0 page_update span 数(含 seed): #{length(spans)}")
    IO.puts("   PageStore 当前页 keys: #{inspect(Map.keys(cur))}")
    IO.puts("   /App.jsx 前 200 字:\n#{String.slice(to_string(cur["/App.jsx"]), 0, 200)}")

  {:timeout, cur, spans} ->
    IO.puts("\n⚠️  [阶段2] 90s 内未检测到新 page_update(cc/claude 可能慢或失败)")
    IO.puts("   loomv0 span 数: #{length(spans)}")
    IO.puts("   PageStore 当前页 /App.jsx 前 80 字: #{String.slice(to_string(is_map(cur) && cur["/App.jsx"]), 0, 80)}")
end

IO.puts("\n========== END ==========\n")
