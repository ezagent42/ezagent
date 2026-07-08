# 经 distributed Erlang 在 server 节点内发布 kanban 的 cc flavor 变体(零代码改动,纯 runtime 发布)
node = :"ezagent_runtime@127.0.0.1"
code = """
attrs = EzagentPluginKanban.Demo.manifest_attrs(name: "kanban-loop-r2", flavor: "cc")
{:ok, defn} = Ezagent.Socialware.ManifestResolver.resolve(attrs)
ws = Ezagent.URI.workspace(:system)
admin = Ezagent.URI.user(:system, :admin)
alias Ezagent.Socialware.ConfigGovernance.Socialware, as: Governance
ctx = %{
  caller: admin,
  workspace_uri: ws,
  caps: MapSet.new([
    Governance.manage_cap("kanban-loop-r2", ws, admin),
    Ezagent.Capability.admin_genesis_cap()
  ])
}
Governance.publish_or_upgrade(defn, ctx)
"""

case :erpc.call(node, Code, :eval_string, [code], 30_000) do
  {result, _binding} -> IO.inspect(result, label: "publish")
  other -> IO.inspect(other, label: "unexpected")
end
