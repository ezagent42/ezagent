# kanban rework 段4 — 真浏览器全流程 e2e 证据（2026-07-09）

替换段3 删掉的 40 件旧证据。证明本分支两项重构后 kanban 全流程行为不变：

1. **world 插件页面注册表化** —— `/plugins/kanban`（列表/详情/动作准入）从 world 硬编码改查 `Ezagent.World.PluginPageRegistry`；
2. **`EzagentPluginKanban.Demo` 溶解** —— manifest YAML（`apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml`）是唯一真相源，经部署级 seed 车道（`SocialwareSeed.seed!` + `ManifestSeed.scan_dir!`）发布，插件 boot 零自发布。

## 流程与证据索引

```
发布(deploy-seed 车道) → 安装(world 新建会话×socialware 向导) → 会话(成员/规则)
      │                                                              │
      └→ /plugins/kanban 列表页(注册表 index route) → 建板(RF-5a role-create)
              → 详情页(注册表 detail route) → 板上动作(add_node/claim/set_stage)
                      → relay-back 路由(__done__ × from_role dev-together → kanban-assistant)
```

| # | 步骤 | 证据 | 结果 |
|---|---|---|---|
| 00 | 环境：ecto.reset + world_e2e_seed + `mix phx.server`(PID 精确管理) + `_health` 200 | `00-env-and-health.txt` | ✅ |
| 01 | world 登录（admin@ezagent.chat / \$ADMIN_PW，见 docs/guide/world-e2e-seed.md） | `01a-login-page.png` `01b-logged-in-sessions.png` | ✅ |
| 02 | **发布**：deploy-seed 拷贝（`socialware deploy-seed: kanban → $EZAGENT_HOME/default/socialware/kanban`）+ server 节点内 `ManifestSeed.scan_dir!` → `kanban (deploy) → published`；DB `socialware_config_pointers` 落 `socialware:kanban` | `02-publish-deploy-lane.txt` | ✅ |
| 03 | **安装**：新建会话「应用」下拉出现 *Kanban 看板团队*（manifest 描述原文可见）→ 向导展示两个 role 槽（kanban-assistant / dev-together × cc-headless，Fresh）→ 创建 `session://system/socialware-install-kanban/kanban-rework-e2e`：3 成员（两 agent + Admin）、已装 Socialware=1 | `03a-install-wizard-kanban-selected.png` `03b-session-created-list.png` `03c-session-open-members.png` `03d-members-panel.png` `03e-routing-relay-rule.png` | ✅（UI 有已知 5s create_session 超时红条，后台实际创建成功，见 Blockers 1） |
| 04 | **列表页（注册表 index route）**：`/plugins/kanban` 渲染「看板 · 配置」（Miro 凭证配置面）——即 `PluginPageRegistry` 的 `{"/plugins/kanban", :index}` + `KanbanData.state_for` + React 注册表 map 全链 | `04a-plugins-kanban-list.png` | ✅ |
| 05 | **建板**：kanban-as-role —— `Workspace.create_agent`（flavor native × role kanban-manager，RF-5a）建 `entity://system/agent/e2e-board`，`RecipeResolver.list_by_recipe("kanban-manager")` 枚举到它 | `05a-new-agent-board-form.png` `05b-board-agent-created.png` | ✅（经 dispatch；UI New Agent 的 role 字段有既有缺口，见 Blockers 2） |
| 06 | **详情页 + 板上动作（注册表 detail route + action 白名单）**：`/plugins/kanban/entity%3A%2F%2F.../e2e-board` 渲染画布；UI 依次 `kanban.add_node`（建根+加子）→ `kanban.claim_node` → `kanban.set_stage`（定位→北极星），全部 `data-last-dispatch=ok`；`kanban.get_tree` dispatch 回读 `:kanban` slice 持久化数据 | `06a-kanban-detail-empty.png` `06b-root-node-added.png` `06c-child-node-added.png` `06d-child-claimed.png` `06e-stage-advanced.png` `06f-get-tree-persistence.txt` | ✅ |
| 07 | **relay-back 路由**：manifest 的 `and(text_contains "__done__", from_role dev-together) → kanban-assistant` 规则装入路由表（DB routing_rules id=2，与 YAML 逐字一致）；dev-together 身份发 `__done__` 消息 → `routing_traces` 命中 rule 2 送达 kanban-assistant（其 sidecar 随即回消息 = 送达闭环）；两条负路径（dev-together 无标记 / **admin 发含 `__done__` 字面量的消息**）均不触发 | `07a-mention-dev-together-typed.png` `07b-message-sent.png` `07c-dev-together-replied.png` `07d-relay-transcript.png` `07e-relay-routing-audit.txt` | ✅（路由层实证；真脑 401，见下） |

## 真脑 vs 路由层标注（如实）

- **真脑不可用**：cc-headless OAuth 过期（环境已知）。两个 agent 的 SDK sidecar 正常 spawn、正常收消息，但脑回复均为 `Not logged in · Please run /login`（截图 07c/07d）。
- **因此 07 的 relay 用路由层证明**：`__done__` 消息以 **dev-together 槽位成员身份**（`message.from` = 其 entity URI）走与 UI chat.send 同构的真 `Invocation.dispatch`（`:cast`）注入——**caps 为管理注入（admin genesis），非该 agent 自持 caps；消息非真脑自发**。路由证据是真的：真会话、真规则（materialize 装入）、真 Resolver、真送达（kanban-assistant sidecar 被触发回包）、真审计行（`routing_traces`）。
- mention 门控（admin @dev-together → 消息到达 dev-together 并触发其 sidecar）是**真键盘 autocomplete + 真 UI 发送**。

## Blockers / 既有缺口（均非本分支回归，不在本 PR 修）

1. **create_session 5s dispatch 超时（已知，docs/guide/world-e2e-seed.md §3）**：cc-headless 材料化慢（Python SDK sidecar 首次要下依赖），UI 报 `{:create_session_exit, {:timeout, ...}}` 红条，但后台创建成功（成员/规则/快照齐全）。刷新即见会话。
2. **world「New agent」表单的 native role 字段静默丢失**：表单把 role 放进 `config_fields`（string key `"role"`），`agent_actions.ex:75` `Map.merge(config_fields)` 后 `agent_create.ex:84` 只读 atom `:role` → role 掉地，建出的 agent 无 recipe 标记（`{:unknown_action, :add_node}`）。本分支未触碰这两个文件（`git log origin/main..HEAD` 为空），为 main 既有缺口。本次改用与 K3 验收测试同路径的 `Workspace.create_agent`（atom `:role`）dispatch 建板。候选 issue。
3. **会话内「看板」子视图切换不生效**：`session.view.switch` dispatch ok、`world:state` 推送 `active_view`，但 Conversation 岛主区不切（`Conversation.tsx` 只有 chat 渲染分支，无 mode 渲染腿）。`Conversation.tsx`/`conversation_actions.ex` 本分支未触碰，非注册表化回归。板操作面走 `/plugins/kanban`（本 e2e 覆盖），子视图渲染缺腿候选 issue。
4. **整目录 `scan_all!` 在 autoservice 处 fail-loud**：本库 `recipe:autoservice-agent` 不存在（`{:unknown_agent_recipe, "autoservice-agent"}`），按字母序先于 kanban 中断扫描。与 kanban 无关；kanban 用只含它的目录（symlink 指向部署目录真实包）单独扫，`(deploy) → published` 证据不受影响。
5. **dev 关 boot scan**（`config/config.exs:33` prod-only，设计如此）：发布用 erpc 在运行中的 server 节点显式驱动同一晚扫描车道（全插件 boot 后扫部署目录，语义与 prod boot 扫描一致）。

## 复现要点

按 `docs/guide/world-e2e-seed.md`（PG → reset/seed → seed-then-start）；发布段照 `00`/`02` 两个 txt；浏览器交互坑（React 受控 input 用 native setter、mention 必须真键盘 autocomplete、`world.localhost`）见 `docs/e2e/guide.md` §8.2。
