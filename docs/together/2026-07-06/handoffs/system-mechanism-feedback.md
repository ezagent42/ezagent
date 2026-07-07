# Handoff 反馈 — 三条 socialware 实施线暴露的系统机制项（给 Allen）

> **From**: jjkysy（#1190 kanban / #1191 dealscout / #1199 world-views 实施与 e2e 发现）
> **Date**: 2026-07-07 · **基线**: main `03136e44`（含 #1208/#1209），每项都在此基线重验过
> **格式**: 每项 = 需要什么 / 现在什么 / 什么问题，带 file:line 与 e2e 取证指引。

## 目的：系统需要支持什么、为了什么

**总目标**：「**agent 驱动的组合 socialware**」全自动闭环——用户装一个组合出来的 socialware（kanban-team：pm+dev 协作推看板；dealscout：后台爬线索、hello 页面自动更新），**agent 自己干活、产出自动到达用户眼前，全程无人手动**。主线今天断在两处硬的：

| 系统需要支持 | 为了达到 | 今天断在 | 条目 |
|---|---|---|---|
| **cc agent 能撑过真实工作回合** | agent 真干活（长回合大量 TUI 输出） | PTY 侧车长回合必崩，回合全丢 | **①** |
| **消息真能到达 native 角色的行为层** | 路由到的角色真的会动作 | bridge 层丢弃，receive 永不跑 | **②** |

凭证注入（原 A②）你的 #1209 已落地、我们零手动 e2e 验收通过——已结案，证明这条清单是收敛的。

---

## 待解决（按优先级）

### ① PtyServer invalid-UTF8 crash loop —— cc agent 任何长回合必死
- **需要**：cc-flavor agent 的 PTY 侧车撑过一个真思考的长回合（分钟级、大量 TUI box-art 输出）。
- **现在**：`ezagent_domain_pty/server.ex:313`/`:816` 用 `binary_part` **裸字节**截断 buffer，切裂多字节 UTF-8 码点（claude TUI 的 3 字节 box-art `─`）；随后每个 stdout chunk 都跑的 `normalize_ws`（`:794`）`String.replace(s, ~r/\s+/u, " ")` 对 invalid UTF-8 **raise** → GenServer 死 → respawn → **进行中的回合整个丢失**。活跃回合几分钟积满 64KB ⇒ 必死循环。
- **证据**：round-1 e2e 6 连崩 0 成功回合（#1190 `kanban-full-loop/04-pty-crash-forensics.txt`）；round-2 **根因反证**——同环境只把回合改短（不碰 64KB 截断线）就 0 崩溃跑完全链路。
- **问题**：所有 cc agent 的真实工作回合都过不去。修复一行级（regex 去 `/u` 或先 scrub / trim 对齐码点边界），domain 代码我们没私改。

### ② native flavor 角色收不到 chat 投递 —— 路由通、行为层永远不跑
- **需要**：Definition routing 把消息路由给 native flavor 角色成员时，成员 recipe 行为的 `:receive` 真的执行。
- **现在**（dealscout e2e 实测）：路由全通（规则命中 `$role:page`、`agent.receive` authz granted、read_marker delivered），但 **`AgentBridge deliver dropped :no_sandbox_respawn_state`**（`agent_bridge.ex:270`）——native 无 bridge adapter，投递在 bridge 层丢弃。插件自注册 flavor 的路被 `sync_result_action/1` 硬编码堵住，插件侧无解。
- **已证的替代模式（重要，降低本条紧迫度）**：**caller-dispatch 不经 bridge、直接跑实例行为 handler**——kanban 生产已证（pm dispatch 板动作）+ dealscout v2 e2e 再证（crawl 完成 dispatch `refresh_page` → handler 真跑 → 页面重建，`dealscout-refresh-v2/`）。
- **问题收窄为设计澄清**：native 角色的"chat 投递"语义到底该不该存在？若答案是"接收方本就该暴露 dispatchable action（kanban 模式）"，本条变成文档/约定问题 + ③ 应走 (b)；若 chat 投递该通，则需给 native 开 in-process receive。请拍。
- **证据**：断点 #1191 `dealscout-discover/`（04a/04b）；通路 `dealscout-refresh-v2/`（README 有 v2 vs v1 对照）。

### ③ hello 页面重建入口对组合者开放 —— ✅ hello 作者已认领走 (a)，**与 ② 需一起看**
- **现在**：#1208 重构了 hello 但 `hello_builder.ex:55,74` 的 `from_user?` 门未动——agent sender 消息仍被丢弃。且 ② 表明：即便门放行，消息也到不了 native builder 的行为层。
- **建议改走 (b)**：我们已用 (b) 模式自证——v2 把"页面刷新"做成 dispatchable action 后全链真通（爬完自动 dispatch → handler → Generator → 浏览器渲出重建页）。**hello 直接暴露 dispatchable rebuild action（原 (b) 案）优于开门 (a)**：(a) 即便落地仍撞 ② 的 bridge 丢弃。
- **我们的过渡**：dealscout 的显式 ALT（`DealScoutPageRefreshAlt` v2 dispatch 式），hello (b) 落地后整删、一行改调 hello 的 action。

### ④ role-slot agent 的裸名 @mention 解析不到
- **需要**：成员能 `@kanban-assistant` 按角色名提到 role-slot 物化的 agent（协作的自然写法）。
- **现在**：物化 URI 是随机 uuid（`definition_agents.ex:350`），display_name 也是 uuid；world `conversation_data.ex:771-776` 只走 URI 末段/display_name 两条腿 → 裸名 `mentions: []` **静默不路由**。运行时复现（r2 探针三件套：#1190 `kanban-full-loop-r2/03a-*`）。全 URI mention 可用（workaround）。
- **修法先例已在 main**：#1208 的 `EzagentPluginHello.Members.role_uri/2` 就是按 role_name facet 解析成员的现成查询——解析器补第三条腿照它做即可。

### ⑤ Definition 物化的 caps 锁不到"晚建的实例"
- **需要**：角色的 caps 能锁到共享 actor（如 kanban 板）——而它是安装后 owner 才建的。
- **现在**：机制层已有精确解——`GrantRecipeCaps/4` 的 `instance_overrides`（T7g，`grant_recipe_caps_board_scope_test.exs`：pm 的 kanban caps 该锁板不锁 pm）。断在 **Definition 物化路径**：`definition_agents.ex:303` 调 3 参版传不了 override（声明期实例 URI 不存在，与 #1180 同根）。物化铸的 caps instance 全指向 agent 自身，owner 需逐个补 grant（kanban e2e 实测）。
- **方向候选**：Definition caps 支持符号化 instance 引用（延迟解析），或安装后首次 grant 钩子。不阻塞（补 grant 顶得住），与 ⑥ 同属"声明层表达不了运行期实体"一族。

### ⑥ routing condition 支持按 role 配 from（已定论待实施）
- 2026-07-06 讨论定论：condition 按角色符号配 from，运行期按成员边（role_name facet）解析。落地后我们两条线各一行加固（kanban relay 加 from=dev-together；dealscout 更新加 from=discover）。冲突场景后续经配置 orchestrator/显式 workflow 解，不立项。背景论证见附录 A。

### ⑦ 组合会话里 owner 普通消息没有任何响应者
- **现在**（dealscout e2e 实测）：owner 零 mention 消息已落库已路由，invocations 审计零 `agent.receive`、40s 无响应——组合会话（dealscout uses hello）没有 orchestrator ensure、也无 always 规则兜底（我们不配 always 是对的红线）。#1208 只救了 hello 原生会话。顺带：公开面对**已登录 owner** 也禁言。
- **问题**：组合出来的 socialware 对话面不成立——说话没人接。可能与 ② 同解（native 收得到之后由角色接），或组合会话也给 orchestrator ensure。

### ⑧ bare `mix ezagent.socialware.check` 静默漏检
- `function_exported?(DefinitionRegistry, :list_names, 1)` 该函数不存在 → 静默 fallback 硬编码 `["chat","socialware"]`（`ezagent.socialware.check.ex:91-99`）。新 socialware 坏了 gate 不报。修法一行：加 `list_names/1`。（我们用自包含 conformance 兜住，不阻塞。）

### ⑨ 安装/物化可靠性两小项（dealscout e2e 实测）
- **stock cc-headless 物化必崩**：core `FsResolver.Registry` config-dir catalog 缺 "cc-headless"（scenario-05 bug③ 同源仍在）——Definition 槽用 cc-headless 建会话即崩。
- **建会话失败 rollback 不回收 install pointer**：同名重建**静默丢** Definition 的 routing rules（install 已存在→跳过装规则）。换名可绕，但静默丢很难查。

### ⑩ arch gate 对声明式形态的三处摩擦（请 review）
- scanner 计 @doc 字面例（`ezagent.arch.scan.ex:325`），挤占冻结预算；
- cap probe p4 撞 cap-only view 形态——已按 HelloRender 先例给 `kanban_render.ex` 加单文件 allowlist（test-only），请 review 或让 probe 原生豁免 `view_behavior` 形态；
- duplicate-fn 的 `# arch-allow:` 与 `mix format` 不兼容（尾注释被挪离 `do` 行→豁免失效），黄金样板同形只能 cap bump——若 marker 也认 def 上一行会好用很多。

### ⑬ role-slot 模板 spawn 不捕 recipe behaviors —— dispatch 面残缺（v2 e2e 新发现，已查验）
- **需要**：Definition 角色槽物化出的 agent，其 recipe 声明的 `behaviors` 真挂在实例上（否则对它 dispatch 任何 recipe 动作都 `:unknown_action`）。
- **现在**：两条物化路不对称——`agent_create --role` 路走 `Recipe.Compose`（`compose.ex:9-10`：role behaviors ∪ flavor behaviors 折进 spawn `:behaviors`，`agent_create.ex:47`）；**socialware 模板路**（`template_team.ex`→TemplateSpawn）**没有这步**，探针实锤 `:kind_base` `behaviors: nil`。caps 有 grant、行为无捕获。首次 dispatch fail-loud `{:unknown_action, :refresh_page}`。
- **过渡**：sanctioned 公开 API `Ezagent.Kind.mount/3` 操作员侧补挂（持久化，v2 e2e 用它闭环）。**收编**：spawn 时穿 behaviors（照 Compose）或 install 后自动 mount，任一落地即零手工。
- **证据**：#1191 `dealscout-refresh-v2/`（探针 + mount 补挂记录）。

## 抽象提案（非阻塞）

### ⑪ per-socialware「协作协议」缺常驻注入点
- 能力技能（recipe.skills，可移植）与协作协议（"这个 socialware 里怎么配合"）应分层——协议应是绑 Definition 的薄模块，materialize 时注入成员常驻 context。今天只能写死 skill 文本（kanban 的 `references/kanban-team-collaboration.md` 是可切出模块）；native agent 完全没法。

### ⑫ 组合接力的 from 方向性（背景见附录 A）
- to 一等（`{:role,name}`）✅；from 只吃实例 URI 字面（`matcher.ex:155`）。现行解=内容协议软锁（消息标记→`{:role}`，两条线都这么落）；⑥ 落地后升硬锁。

## 已结案（record only）

- **凭证注入（原 A②）** → **#1209 落地，零手动 e2e 验收通过**：auto-adopt→durable grant→§D6 secret-only copy（sha256 与宿主逐字节一致）→双 PTY `Claude Max`→真思考落库；隔离未破。证据 #1190 `docs/e2e/2026-07-07/a2-zero-manual-creds/`。
- **建 session 同步物化超 LiveView 预算** → #1202 修了（残留：UI 5s timeout 仍误报"失败"而后台成功，体验项）。
- **kanban boot-publish roles 示例与 RF-6 冲突** → 实施按 RF-6 落成，#1190 return 记录。

## 附录 A：组合 socialware 的 agent 配合——routing 为什么不够、我们怎么解

**问题**：基于一个 socialware 建另一个时，agent 定向接力（爬取→页面刷新；dev 交活→助手推板）有方向性：不只 to，还有"谁发的才算"（from）。
**缺口**：`{:from,x}` 只吃实例 URI 字面，而实例 URI 声明期不存在（materialize 才生成）且 #1180 禁 Definition 带实例 URI → "来自某角色"配置层表达不出。
**现行解**：内容协议软锁（`text_contains("__done__")`/`("__dealscout_update__")` → `{:role,接收角色}`，"谁何时发标记"在 skill 协议模块，零 URI、conformance 过）；运行时补锁机制现成但 per-session 后加、不随安装带、不能 snapshot 回写。
**遗留**：软锁任何成员发同标记都触发（可信 team 够用）；⑥ 落地即闭口。

---

**优先级建议**：① >> ⑬②③（三条同族：role-slot 的 dispatch/投递面——⑬ 是硬缺、②③ 是设计澄清+建议走 (b)） > ④⑦⑧⑨ > ⑤⑥ > ⑩ > ⑪⑫。① 仍是"agent 真干活"的第一块石头；⑬ 修了之后 role-slot socialware 的 dispatch 闭环零手工。
