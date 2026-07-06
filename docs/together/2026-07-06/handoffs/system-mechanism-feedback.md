# Handoff 反馈 — 三条 socialware 实施线暴露的系统机制项（给 Allen）

> **From**: jjkysy（#1190 kanban / #1191 dealscout / #1199 world-views 实施期发现）
> **Date**: 2026-07-06（晚间对 main `49f0167f`（含 #1208）逐条重验后重写）
> **格式**: 每项 = 需要什么 / 现在什么 / 什么问题，全部带 file:line 证据。已解决项收进文末"已结案"。

## 目的：系统需要支持什么、为了什么

**总目标**：「**agent 驱动的组合 socialware**」全自动闭环——用户装一个组合出来的 socialware（kanban-team：pm+dev 协作推看板；爬取+hello：后台爬线索、页面自动更新），**agent 自己干活、产出自动到达用户眼前，全程无人手动**。对 `49f0167f` 重验后，这条主线还断在三处：

| 系统需要支持 | 为了达到 | 今天断在 | 条目 |
|---|---|---|---|
| **cc agent 能撑过真实工作回合** | agent 真干活（长回合必然产生大量 TUI 输出） | PTY 侧车长回合必崩，回合全丢 | **①（最高优先）** |
| **物化出的 agent 能思考**（继承宿主登录） | agent 不是空壳 | ~~凭证不注入~~ **#1209 已修，验收通过** | ②（已结案） |
| **agent 的产出能到达页面** | "后台干完活→用户看到更新"闭环 | hello builder 丢弃 agent 消息 | ③（hello 作者已认领走 a） |

**第二层**：组合出来的 socialware 可信、可用——协作的自然写法能用、gate 真兜住且不误伤（④⑤⑥⑦）。
**第三层**：组合的复用性——抽象提案，非阻塞（⑧⑨）。

---

## 待解决

### ① PtyServer invalid-UTF8 crash loop —— **cc agent 任何长回合必死（最高优先）**
- **需要**：cc-flavor agent 的 PTY 侧车撑过一个真思考的长回合（分钟级、大量 TUI box-art 输出）。
- **现在**（`49f0167f` 重验仍在）：`ezagent_domain_pty/server.ex:313`/`:816` 用 `binary_part` **裸字节**截断 buffer，会切裂多字节 UTF-8 码点（claude TUI 大量 3 字节 box-art `─`）；随后每个 stdout chunk 都跑的 `normalize_ws`（`:794`）`String.replace(s, ~r/\s+/u, " ")` 对 invalid UTF-8 **raise** → GenServer 死 → respawn claude → **进行中的回合整个丢失**。活跃回合几分钟积满 64KB ⇒ 必死循环。e2e 实测 6 连崩、0 次成功回合（取证：#1190 `docs/e2e/2026-07-06/kanban-full-loop/04-pty-crash-forensics.txt`）。
- **问题**：**所有 cc agent 的真实工作回合都过不去**——比凭证注入更靠前的阻断（creds 手动拷通过了，死在干活时）。修复一行级：regex 去 `/u` 或先 scrub，或 trim 对齐码点边界。domain 代码我们没私改。
- **旁证（r2 实证根因）**：round-2 e2e 用短回合策略（单指令一条命令、最长回合 43s，buffer 不到 64KB 截断线）跑完全链路 **0 次崩溃**——同环境同 agent 只改回合长度就零崩，反证截断线就是唯一元凶。但这只是绕，不是解。

### ② cc-flavor agent 凭证注入 —— ✅✅ **#1209 已落地，我们零手动 e2e 验收通过（2026-07-07）**
- **验收实证**（独立冷库、不拷 creds、不跑 watcher）：auto-adopt 指针 1 行→durable grant 2 行→§D6 secret-only copy（config_dir 自动出现 `.credentials.json`，sha256 与宿主逐字节一致、0600）→双 PTY banner `Claude Max`、"Not logged in" 0 次→8s 真思考回复落库；`CLAUDE_CONFIG_DIR` 隔离未破。证据：#1190 `docs/e2e/2026-07-07/a2-zero-manual-creds/`。**本条结案**。

### ③ hello 页面重建入口对组合者开放 —— ✅ **hello 作者已认领走 (a)**
- **现在**（`49f0167f` 重验）：#1208 重构了 hello 但 `hello_builder.ex:55,74` 的 `from_user?` 门未动——agent sender 的消息仍被丢弃。路由层反而更通了（#1208 后 orchestrator 路由所有其他 sender 含 agent），**builder 的门成了最后一关**。落地后 dealscout"爬完→页面自动刷新"即闭环（信号 `__dealscout_update__` 已按内容协议就位）。

### ③' native flavor 角色收不到 chat 投递 —— **③ 的前提被 live 打破（dealscout e2e 新发现，最重要）**
- **需要**：Definition routing 把消息路由给 native flavor 的角色成员时，成员的 `:receive` 行为真的会跑。
- **现在**（dealscout 发现腿 e2e 实测）：路由全通（规则命中 `$role:page`、`agent.receive` authz granted、read_marker delivered），但 **`AgentBridge deliver dropped :no_sandbox_respawn_state`**（`agent_bridge.ex:270`）——native flavor 无 bridge adapter，投递在 bridge 层丢弃，recipe 行为的 `handle_receive` 永远不跑。
- **问题**：**③（from_user? 门）单独放行也不够**——hello.builder 本身就是 native flavor，门开了消息也到不了行为层。所有"native 角色做接收方"的 socialware 组合都断在这。请裁决方向：(a) core/bridge 给 native flavor 开 in-process receive 通路（无 sidecar 直接跑 recipe 行为）；(b) 约定接收方槽必须用有 adapter 的 flavor（那 hello.builder 自身也要改）。插件自注册 flavor 的路被 `sync_result_action/1` 硬编码堵住，我们插件侧无解。
- **取证**：#1191 `docs/e2e/2026-07-07/dealscout-discover/`（04a/04b + README gap ⑧）。

### ④ role-slot agent 的裸名 @mention 解析不到
- **需要**：成员能 `@kanban-assistant` 按**角色名**提到 role-slot 物化的 agent（协作的自然写法）。
- **现在**（`49f0167f` 重验仍在）：物化 URI 仍是随机 uuid（`definition_agents.ex:350` `Ecto.UUID.generate()`），display_name 也是 uuid；world `conversation_data.ex:771-776` 的解析只走 URI 末段/display_name 两条腿 → 裸名 `mentions: []` **静默不路由**。全 URI mention 可用（e2e workaround）。
- **修法先例已在 main**：#1208 的 `EzagentPluginHello.Members.role_uri/2` 就是按 role_name facet 解析成员的现成查询——mention 解析器补第三条腿照它做即可。
- **运行时复现（r2，`49f0167f`）**：裸名发送 `mentions:[]` 静默、autocomplete 真键盘不弹、成员列表显示名=uuid——探针三件套在 #1190 `docs/e2e/2026-07-06/kanban-full-loop-r2/03a-*`。

### ②' Definition 物化的 caps 锁不到"晚建的实例"（r2 新发现，已查验）
- **需要**：socialware 里"角色 A 的 caps 该锁到共享 actor B"——而 B（如 kanban 板）是安装后 owner 才建的。
- **现在**：机制层**已有**精确解——`GrantRecipeCaps.grant_recipe_caps/4` 的 `instance_overrides`（T7g Part A，`grant_recipe_caps_board_scope_test.exs` 原文就是"pm 的 kanban caps 该锁板不锁 pm"）。断在 **Definition 物化路径**：`definition_agents.ex:303` 调 3 参版传不了 override——声明期实例 URI 不存在（与 #1180 禁实例 URI 同根）。物化铸出的 caps instance 全指向 agent 自身，owner 需逐个补 grant（kanban r2 实测）。
- **问题**：任何"角色要操作晚建共享 actor"的 socialware 都撞。方向候选：Definition caps 支持符号化 instance 引用（如 `{:created_by_role, ...}` 延迟解析），或安装后首次 grant 的钩子。不阻塞（owner 补 grant 顶得住），但和 ⑤ 同属"声明层表达不了运行期实体"一族。

### ⑤ routing condition 支持按 role 配 from（已定论待实施）
- 2026-07-06 讨论已定论：condition 里按角色符号配 from，运行期按成员边（role_name facet）解析。落地后我们两条线各一行加固（kanban relay 加 from=dev-together；dealscout 更新加 from=discover）。冲突场景后续经配置 orchestrator/显式 workflow 解，现在不立项。
- 背景论证（为什么现有 routing 解不完整、内容协议软锁怎么落的）见附录 A。

### ⑥ bare `mix ezagent.socialware.check` 静默漏检
- **现在**：mix task 用 `function_exported?(DefinitionRegistry, :list_names, 1)` 枚举，**该函数不存在** → 静默 fallback 硬编码 `["chat","socialware"]`（`ezagent.socialware.check.ex:91-99`）。新 socialware 坏了 gate 不报。修法一行方向：给 DefinitionRegistry 加 `list_names/1`。（我们用插件内自包含 conformance 兜住了，不阻塞。）

### ⑦ arch gate 对声明式形态的三处摩擦（请 review）
- **scanner 计 doc 字面例**：`ezagent.arch.scan.ex:325` 按行 regex 计 `{:set,...}`，@doc 里的示例也算，挤占冻结预算（我们改 doc 措辞绕过）。
- **cap probe p4 撞 cap-only view ActionSet**：`dispatchable?→false`+手写 `cap_subjects/0` 的 view 形态撞 probe；我们按 HelloRender 先例给 `kanban_render.ex` 加了单文件 allowlist（test-only），**请 review 是否认可**，或让 probe 原生豁免 `view_behavior` 形态。
- **duplicate-fn 的 `# arch-allow:` 行级豁免与 `mix format` 不兼容**：format 会把 `do` 行尾注释挪到上一行 → 豁免失效，黄金样板同形只能走 cap bump。若 arch-allow 也认 def 行上一行的 marker 会好用很多。

### ⑦' 安装/物化的两个可靠性小项（dealscout e2e 实测）
- **stock cc-headless 物化必崩**：core `FsResolver.Registry` 的 config-dir catalog 缺 "cc-headless" 条目（scenario-05 bug③ 同源，仍在）——凡 Definition 槽用 cc-headless 建会话即崩。
- **建会话失败的 rollback 不回收 install pointer**：同名重建会静默丢 Definition 的 routing rules（install 已存在→跳过装规则）。换名可绕，但静默丢规则很难查。

## 抽象提案（非阻塞）

### ⑧ per-socialware「协作协议」缺常驻注入点
- agent 的**能力技能**（recipe.skills，可移植）与**协作协议**（"在这个 socialware 里怎么配合"）应分层——协议应是绑到 Definition 的薄模块，materialize 时注入成员常驻 context。今天只能写死进 skill 文本（我们 kanban 是单独的 `references/kanban-team-collaboration.md` 可切出模块）；native agent 完全没法。**提案**：Definition 级常驻 team-context 薄模块。

### ⑨ 组合接力的 from 方向性（背景见附录 A）
- to 是一等的（`{:role,name}` 符号）✅；from 不是——`{:from,x}` 只吃实例 URI 字面（`matcher.ex:155`），声明期表达不出"来自某角色"。现行解法=内容协议软锁（消息标记 → `{:role}` 接收，两条线都这么落）。⑤ 落地后软锁升级为硬锁。

## 已结案（record only）

- **建 session 同步物化超 LiveView 预算** → 你的 #1202 修了（fire-and-forget post-spawn）。
- **hello 无 @mention 不投 orchestrator** → #1208 后 hello 原生会话疑似已解，**但组合会话（dealscout uses hello）实测仍零响应**：owner 零 mention 消息已落库已路由、invocations 审计零 agent.receive、40s 无响应——组合会话没有 orchestrator ensure、也无 always 规则兜底。**升回待解决观察项**（e2e 证据 #1191 dealscout-discover/05）。
- **kanban boot-publish roles 示例与 RF-6 冲突** → 实施按 RF-6 落成（board 不进 roles、助手经 dispatch 驱动），机制其余一比一照 hello，已在 #1190 return 记录。

## 附录 A：组合 socialware 的 agent 配合——routing 为什么不够、我们怎么解

**问题**：基于一个 socialware 建另一个时，agent 需要定向接力（dealscout 爬取 agent 爬完→hello 页面 agent 刷新；kanban dev 交活→助手审核推板），有方向性：不只 to，还有"谁发的才算"（from）。
**现有 routing 缺口**：from 的 `{:from,x}` 只吃实例 URI 字面比较，而组合 socialware 的实例 URI 声明期不存在（materialize 才生成）且 #1180 禁止 Definition 带实例 URI → "来自某角色"配置层表达不出。
**现行解法**：①内容协议软锁——消息标记做 condition（`text_contains("__done__")`/`text_contains("__dealscout_update__")` → `{:role,接收角色}`），"谁何时发标记"写进 skill 协议模块，零 URI、conformance 过；②运行时补锁（orchestrator `define_rule_set_rule`/CLI 可把 role 解析成真 URI 写进 from condition，但 per-session 后加、不随安装带、不能 snapshot 回写）。
**遗留**：软锁任何成员发同标记都触发（可信 team 够用）；⑤ 的 from-role condition 落地即闭口。

---

**优先级建议**：① >> ②③（已有主） > ④⑥ > ⑤ > ⑦ > ⑧⑨。① 卡所有 cc agent 的真实工作，是全自动闭环的第一块石头。
