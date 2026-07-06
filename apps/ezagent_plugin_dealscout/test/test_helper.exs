{:ok, _} = Application.ensure_all_started(:ezagent_plugin_dealscout)

# Full-suite 修复(#1191):`mix ci.local` → umbrella 根 `mix test` 是单 BEAM 顺序
# 跑全部 app 套件。hello 的 `PageView` 是 boot 时注册进 `SessionViewRegistry`
# 的(hello application.ex),但排在前面的 ezagent_domain_ui 套件
# (session_view_registry_test.exs 的 `:ets.delete_all_objects/1` 清场)会把这张
# 共享 ETS 表清空——hello app 此时已启动、不会重注册,于是 dealscout 的
# `ManifestResolver.resolve/1` 解析 `"hello_render"` fail-closed,11 个测试报
# `{:unknown_socialware_view_ref, "hello_render"}`。在 dealscout 套件入口把解析
# 前提重新就位(幂等 overwrite——per-app 跑法下等价 no-op;照 domain_session
# manifest_resolver_test.exs setup 的既有 init+register 模式)。
:ok = Ezagent.UI.SessionViewRegistry.init()
:ok = Ezagent.UI.SessionViewRegistry.register(EzagentPluginHello.PageView)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
