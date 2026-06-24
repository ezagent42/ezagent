# 设计 · kanban 插件当前真相（df-tech 大重构后）

> 2026-06-25 · 重构 commit `2315bf7f`(world↔kanban 解耦)后的**当前真相设计**。
> 取代一批 point-in-time 的 `mindmap-*` 旧设计(改名前 + 重构前)。带 file:line 锚点。
> 旧称 **mindmap(思维导图)→ kanban(看板)** 已全面改名；旧 `apps/ezagent_plugin_mindmap` 不再存在。

---

## 1 · 是什么

产品自举开发流程的「真相源接力链」拓扑树。一棵节点树住在一个**数据资源 Kind** 的 state 里，
ezagent 是真相源,外部工具(GitHub/Miro)是镜像/出口。

## 2 · 数据 Kind(`resource://`,自包含)

- **Kind**:`EzagentPluginKanban.Kanban`,`use Ezagent.Kind, pattern: :resource`
  (`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban.ex:16`),
  持久化 `{:snapshot, :on_change}`(`kanban.ex:33`)——节点树住单一 `:tree` key,跨重启存活。
- **寻址** = `resource://<ws>/kanban/<name>`(**不是** `session://`;kanban 是数据对象不是会话)。
- **Behavior** = `Ezagent.Behavior.Kanban`(`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`),
  `use Ezagent.Lifecycle` + `action/3` 宏,所有写经唯一 `commit/1` → `{:set, :tree, _}`(`kanban.ex:982`)。

### 节点 schema(`kanban.ex:13-19`)
```
node = %{parent_id, title, order,
         stage:  9 棒固定链 atom,
         owner:  user/agent URI | nil,           # 认领人; 既问责又是权限闸
         status: :unassigned|:claimed|:doing|:done,
         artifacts: [%{tool,kind,ref,url,content}],
         metrics:   [%{name,target,current,unit}]}
```

### 9 阶段固定接力链(`kanban.ex:37`)
`[:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]`
(旧 mindmap 设计是 6 棒 `purpose/value/module/feature/dev/ops`——**已废**)。
stage = 分类轴 + 插入校验(R1:子节点 stage 必须 ≥ 父,相邻棒推进),**不是权限边界**。

## 3 · Behavior 自包含出站 / CI / 配置(重构核心)

重构(`2315bf7f`)把出站/CI/配置全下沉进 Behavior。9 个出站动作走 `:effect_returning`
(绑结果回 dispatch,不进 `{:set}` 站点,`kanban.ex:168-237`):
`sync_github / push_pr / register_pr / attach_code_file / sync_prs / sync_miro /
set_board_config / save_github_creds / save_miro_creds`。

- **GitHub 出站** = 插件自有 `EzagentPluginKanban.Github`(REST,非 external_mirror 域)。
- **Miro 出站** = `handle_sync_miro`(`kanban.ex:834`)同步调 `MiroSync.sync_or_bind`,
  插件自有 `EzagentPluginKanban.{Miro,MiroSync}`。**不走 EM `:push` adapter**——
  EM 域 session-硬编码,resource Kind 走不通(详见已落地 `github-outbound-*` spec §2)。
  插件里**没有** `ExternalMirror.Adapter` / `MiroAdapter` / `Publisher`(grep 0)。
- **CI 评价** = `EzagentPluginKanban.Ci` 纯函数读模型(沿祖先链算 gate,出评分+评语,
  软提示无副作用),`get_tree` 给 pr 节点附 `ci` 摘要。
- **配置/凭证** = `BoardConfig`(每图 github_repo + miro 板名) + `Github/Miro.write_creds`(admin-gated)。

## 4 · world 退成纯 dispatcher

`Ezagent.World.{KanbanActions,KanbanData}`(`apps/ezagent_plugin_world/lib/ezagent/world/`)
**纯 dispatch**:经 `Ezagent.Invocation.dispatch/1` 打到 kanban Kind(P14),带登录者
`current_entity_uri`/`current_caps`,成功后 re-read + `push_event` 刷前端。
world **零直引** kanban 插件模块(`grep EzagentPluginKanban apps/ezagent_plugin_world/lib` = 0),
`mix.exs` 已删 dep。world `@stages` 同步 9 棒(`kanban_data.ex:20`)。

## 5 · spawn:after_boot 注册 resource scheme spawn fn

kanban plugin `after_boot`(`application.ex:32`)向核心 `Ezagent.SpawnRegistry.register("resource", fn)`
注册——按 type 段分流,只认 `kanban`,其它 resource 类型 reject(`application.ex:34-37`)。
world(及任何 caller)经核心 `SpawnRegistry.spawn` 起活,不直引 kanban 模块、不 `DynamicSupervisor.start_child`。
> ⚠️ resource-spawn 归属(核心正式化 vs domain-owned 注册表)是**架构决策点**,待 Allen 拍
> (见重构 handoff)。

## 6 · per-node CapBAC(在 handler 内查)

`data_owner/1` 返 `:no_owner`(per-instance 实例级 cap 收口,`kanban.ex:274`);
**per-node 授权在 handler 内**:`owner_or_admin?(ctx, node)` = caller 持 wildcard cap(admin)
或 `node.owner == caller_str(ctx)`。未认领节点任意成员可 `claim`。
不变式 `owner==nil ⟺ status==:unassigned`。agent 与 user 在这套检查里**同构**
(agent claim 后 owner=agent URI,后续编辑自然放行)。

## 7 · agent 改图 = 照抄 orchestrator 的 plugin-自带 MCP server 三件套

让 cc agent 智能编辑 kanban 的**最终范式** = 复制 orchestrator 的三件套
(`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/`):
`mcp_server.ex` + `mcp_server/tool_catalog.ex` + `cc_orchestrator_seed.ex`。
claude 进程经 MCP 工具调动作,工具内 `Invocation.dispatch` 打 `kanban.*`,caller=agent、
caps 在 session 侧重建。
> 旧 mindmap 设计推的「路 A:在 agent 上挂 `MindmapWorker` Behavior 规则化 dispatch」
> 已被此范式取代;`MindmapWorker`/`KanbanWorker` 在代码里**不存在**(grep 0)。

## 8 · 仍有效的相邻 spec(未删,path 改名留意)

- `2026-06-23-df-prd-mindmap-product-spec.md` — 产品愿景(9 棒链 + gate 语义 + drop),真相、保留。
- `2026-06-23-impl-ci.md` / `2026-06-23-impl-drop.md` — CI/drop 设计,对应 `Ci`/`handle_drop_subtree`,核心准。
- `2026-06-23-github-outbound-and-attachment-interaction.md` — GitHub=插件自有出站(非飞书式),判断与重构一致。

> 以上 spec 仍引旧 `apps/ezagent_plugin_mindmap/` 路径与 `mindmap.*` 命名(point-in-time,可接受);
> 当前真相一律以本文 + 实际 `apps/ezagent_plugin_kanban/` 代码为准。
