# kanban rework 收口 e2e — 全链路真浏览器证据（2026-07-10）

**取代** `docs/e2e/2026-07-09/kanban-rework/`（07-09 原始 24 件 + 03x/05x 两层追记的拼盘）。
本套是以当下代码（分支 = main cb53a6b49 基底，含 #1294）为准、一次连贯跑完的全链路证据。

证明本分支两项重构后 kanban 全流程行为不变：

1. **world 插件页面注册表化** —— `/plugins/kanban`（列表/详情/动作准入）从 world 硬编码改查
   `Ezagent.World.PluginPageRegistry`；
2. **`EzagentPluginKanban.Demo` 溶解** —— manifest YAML
   （`apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml`）是唯一真相源，经部署级
   seed 车道（`SocialwareSeed.seed!` + `ManifestSeed.scan_dir!`）发布，插件 boot 零自发布。

## 流程与证据索引

```
发布(deploy-seed 车道) → 安装(world 新建会话×socialware 向导) → 会话(成员/规则)
      │                                                              │
      └→ /plugins/kanban 列表页(注册表 index route) → 建板(RF-5a role-create)
              → 详情页(注册表 detail route) → 板上动作(add_node/claim/set_stage → get_tree)
                      → relay-back 路由(__done__ × from_role dev-together → kanban-assistant)
                              → cc 真脑现状(#1309)
```

| # | 步骤 | 证据 | 结论 |
|---|---|---|---|
| 00 | 环境：ecto.reset + core seeds + world_e2e_seed → `mix phx.server`（beam PID 72503，精确 kill）→ `_health` 200 | `00-env-and-health.txt` | ✓ |
| 01 | world 登录（admin@ezagent.chat / $ADMIN_PW，见 docs/guide/world-e2e-seed.md） | `01a` `01b` | ✓ |
| 02 | **发布**：deploy-seed 拷贝（本分支 manifest 逐字节落部署目录）+ erpc 在 server 节点跑 `ManifestSeed.scan_dir!` → `result: :published`；DB `socialware_config_pointers` 落 `socialware:kanban` | `02-publish-deploy-lane.txt` | ✓ |
| 03 | **安装**：新建会话向导「应用」选 *Kanban 看板团队*（manifest 描述原文可见，两 role 槽 cc-headless×Fresh）→ 创建 `session://system/socialware-install-kanban/kanban-final-0710`：**无红条，~1.91s 同步建成**（DB invocations duration_us=1910575，#1294 后现实）；3 成员即时在线（data-online=true×2 + Admin），已装 Socialware=1，relay-back 规则装入（DB routing_rules id=2，与 YAML 逐字一致） | `03a`-`03d` 截图 + `03e-install-db-notes.txt` | ✓ |
| 04 | **列表页（注册表 index route）**：`/plugins/kanban` 渲染「看板 · 配置」（Miro 凭证配置面）——`PluginPageRegistry` `{"/plugins/kanban", :index}` + React 注册表 map 全链 | `04a` | ✓ |
| 05 | **建板（RF-5a role-create）**：`Workspace.create_agent`（flavor native × role kanban-manager，真 dispatch，DB invocation authz=granted）建 `entity://system/agent/e2e-board`；`RecipeResolver.list_by_recipe("kanban-manager")` 枚举到它，KindRegistry 有活 pid；Agents 页可见 | `05a-board-agent-created-rf5a.txt` `05b` | ✓ |
| 06 | **详情页 + 板上动作**：`/plugins/kanban/entity%3A%2F%2F…%2Fe2e-board`（注册表 detail route）渲染画布；UI 依次 `kanban.add_node`（建根「kanban rework 收口验证」+ 加子「登录表单模块」）→ `kanban.claim_node`（@admin）→ `kanban.set_stage`(定位→北极星)，全部 `data-last-dispatch=ok`；`kanban.get_tree` dispatch 回读 `:kanban` slice 持久化数据逐项核对 | `06a`-`06e` 截图 + `06f-get-tree-persistence.txt` | ✓ |
| 07 | **relay-back 路由**：dev-together 身份 `__done__` 消息 → routing_traces 命中 rule 2 送达 kanban-assistant（其 sidecar 19s 回包 = 送达闭环）；双负路径（admin 真键盘发含 `__done__` 字面量→rule 2 不触发；dev-together 发无标记→rule 2 不触发）均实证 | `07a`-`07d` 截图 + `07e-relay-routing-audit.txt` | ✓（测法注记见下） |
| 08 | **cc 真脑现状**：真键盘 @kanban-assistant → sidecar ~2s 回包，内容 `Not logged in · Please run /login` | `08a` + `08b-cc-brain-probe-notes.txt` | ✗ 被 #1309 挡住 |

## 结论（分层口径）

### 看板本体（board agent，kanban-manager × native）——真通

它设计上就是被动数据角色（不可 @、不收聊天），不需要大脑。证据口径：真指令
add_node / claim_node / set_stage → ok → get_tree 读回核对持久化，**全链零 mock**（步骤 05/06）。

### 协作 agent（kanban-assistant / dev-together，cc-headless）——分三层

- **送达层 = 真测通过**：真键盘 @ → 消息送达 → 进程被拉起并回包（07c 23s 首包 / 08a ~2s 热包）。
  **回 401 本身证明管道全通，死的只是登录一环。**
- **路由层 = 真测通过，但注明测法**：__done__ 回传规则的验证是测试以 dev-together 成员身份
  注入消息（与聊天同一真实通道，`Invocation.dispatch` :cast 同构路径），routing_traces 证明
  命中 + 双负路径（07e）；**这条消息是测试造的，不是 agent 自主产生**。
- **大脑层 = 未通，被 #1309 挡住**：assistant 自主推卡、dev-together 自主发 __done__ 未曾
  端到端发生过。根因 = cc-headless 漏 `host_login_dir` delegate（issue #1309，cc 插件一行
  修复，与本 PR 无关）。本次全新库复核铁证见 `08b`（宿主凭证有效余量 5.2h、物化 config_dir
  无 .credentials.json、三张 credential 表全空）。

### 总结

**kanban 通了 = 看板功能全通 + 团队协作整条管道全通；agent 自主协作闭环尚未端到端发生过
一次——差的一环在 cc 插件（#1309），修复后应再跑一次真脑闭环 e2e 才算数，不在本 PR 范围。**

## 环境注记（既有缺口，均非本分支回归、不在本 PR 修）

1. **world「New agent」表单 native role 字段静默丢失**（表单 string key "role" 进 config_fields，
   agent_create 只读 atom :role）——main 既有缺口，故步骤 05 走同一后端 `Workspace.create_agent`
   dispatch（与 K3 验收测试同路径）。候选 issue。
2. **会话内「看板」子视图切换不生效**（Conversation.tsx 无 mode 渲染腿）——板操作面走
   `/plugins/kanban`（本 e2e 覆盖）。候选 issue。
3. **整目录 `scan_all!` 在 autoservice 处 fail-loud**（本库无 `recipe:autoservice-agent`，按字母
   序先于 kanban）——与 kanban 无关，发布用只含 kanban 包的目录（symlink 指部署目录真实包）单独扫。
4. **dev 关 boot scan**（config/config.exs prod-only，设计如此）——发布用 erpc 在运行中的 server
   节点显式驱动同一晚扫描车道，语义与 prod boot 扫描一致。
5. **会话右栏「高级规则 0」是预期显示**：该列表只呈现 matcher 直接锚定本会话的规则，
   relay-back 属 rule_set 规则不在其列（见 `03e`）。

## 复现要点

按 `docs/guide/world-e2e-seed.md`（PG → reset/seed → seed-then-start）；发布段照 `00`/`02` 两个
txt；浏览器交互坑（React 受控 input 用 native setter、mention 必须真键盘 autocomplete +
listbox 真实 click（onMouseDown，页内 JS click 无效）、加子走原生 prompt 用 `dialog accept`、
「创建」按钮用页内 JS click、`world.localhost`）见 `docs/e2e/guide.md` §8.2。
