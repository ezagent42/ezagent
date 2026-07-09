# Full-suite 修复(#1190,同 #1191 dealscout 根因):umbrella 根 `mix test` 单 BEAM
# 顺序跑全部套件时,排前面的 ezagent_domain_ui 套件会 `:ets.delete_all_objects/1`
# 清空 SessionViewRegistry 共享 ETS 表,kanban app 已启动不会重注册,于是本套件
# ManifestResolver 解析 "kanban_render" fail-closed。套件入口幂等重注册
# (per-app 跑法下等价 no-op)。
:ok = Ezagent.UI.SessionViewRegistry.init()
:ok = Ezagent.UI.SessionViewRegistry.register(EzagentPluginKanban.BoardView)

# :live_miro 标签默认排除（需真实网络 + miro.yaml 凭证）；显式 --include live_miro 跑。
ExUnit.start(exclude: [:live_miro])
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
