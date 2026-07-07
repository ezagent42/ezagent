# 操作员补挂（新 gap ⑬）：socialware install 的 role-slot 模板 spawn 不把 recipe 的
# `behaviors` 捕进 agent 实例的 `:kind_base`（对照：workspace agent_create --role 路
# 走 Recipe.Compose 会捕；kanban 板 agent 就是那条路建的所以能收 caller-dispatch）。
# 这里用 **sanctioned 的 core 公开 API** `Ezagent.Kind.mount/3`（RF-2/RF-3 运行时
# per-instance behavior mount，写 `:kind_base` 持久化、冷重启幸存）操作员侧补挂 ALT
# —— 与 kanban T6/T7 的"显式 grant caps"同风格的显式操作员步骤，不改任何平台代码。
# 用法: elixir --name probe3@127.0.0.1 --cookie <cookie> mount_alt_behavior.exs <agent_uri>
[agent_uri] = System.argv()
node = :"ezagent_runtime@127.0.0.1"

code = ~S"""
uri = Ezagent.URI.new!(agent_uri)
result = Ezagent.Kind.mount(uri, Ezagent.ActionSet.DealScoutPageRefreshAlt, %{})
kb = Ezagent.Kind.get_slice(uri, :kind_base)
%{mount: result, kind_base_after: kb}
"""

case :erpc.call(node, Code, :eval_string, [code, [agent_uri: agent_uri]], 30_000) do
  {result, _} -> IO.inspect(result, limit: 30, width: 140)
  other -> IO.inspect(other, label: "unexpected")
end
