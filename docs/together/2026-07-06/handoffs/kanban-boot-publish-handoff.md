# Handoff — kanban socialware 的 boot 自动发布（照 hello 做）

给 jjkysy，接在 PR #1190（kanban→完整 socialware）里。前提：#1190 已经把 kanban 做成一个真 socialware —— 有 manifest（roles/views/...）+ 一个 kanban_render 视图。本 handoff 只补最后一环：让这个 kanban socialware 在每次 boot 自动发布成 public，这样新库/新环境一起来，用户在"新建会话 → Socialware 下拉"里就能直接看到并一键装 kanban —— 跟 hello 现在一模一样。

唯一要照抄的样板：hello 的 boot 自动发布是已上线的黄金样板（#162），一比一照它做：一个"唯一真相"模块 apps/ezagent_domain_session/lib/ezagent/socialware/demo/hello.ex（Ezagent.Socialware.Demo.Hello）。manifest_attrs/1 返回 config-authored 的 manifest（字符串模块引用，ManifestResolver.resolve/1-ready）。publish/0 = ManifestResolver.resolve(manifest_attrs()) → Governance.publish_or_upgrade(definition, ctx)。发布进 workspace://system、scope: "public"，跨 workspace 可发现。admin_ctx/2 caller = Ezagent.URI.user(:system, :admin)，caps = Governance.manage_cap(name, ws, admin) + Ezagent.Capability.admin_genesis_cap()（public scope 的 admin 闸）。幂等：publish_or_upgrade/2（P0 §5）—— 未变→{:ok, :exists}（不开 CR）；改了→{:ok, :upgraded}；首发→{:ok, :published}。boot 调用点 ezagent_plugin_hello/application.ex:71 —— fail-loud（发布挂了就崩 boot），RoleSeedHook skips in test（test 环境不跑 boot 发布，ExUnit 驱动，per-run 唯一名）。

kanban 要做的（= 复制 hello，改三处数据）：name kanban/title·description 看板的；roles kanban-manager×native（注：实施按 #1190 现状与 RF-6 判定，差异上报）；views ["kanban_render"]；routing_rules：kanban-manager 是 passive，不要照抄 hello 的 always→chat 路由——大概率空或只有 #1190 的非-chat 规则；legends member_set 用 kanban 角色名；visibility_policy 照 hello（web_anon_access 按看板是否匿名决定）。publish/0/published?/0/admin_ctx 一比一照 hello 改名。

boot 调用点：kanban 插件 Application.start 加 Demo.Kanban.publish()，照 hello fail-loud+test-skip。

验收：单测 resolve 成功+幂等三态；冷起清库→不手动种→world 下拉出现 kanban→建会话→Kanban 子视图（kanban_render）→能建树/认领，agent-browser 截图；mix ezagent.socialware.check 绿。

注意/坑：别碰 cc orchestrator 5s（独立问题，kanban-manager native 秒起不受影响）；socialware 注册已改好，hello 走的就是 socialware 安装流程，kanban 照同一条路。
