# Handoff 反馈 — 三条 socialware 实施线暴露的系统机制项（给 Allen）

> **From**: jjkysy（#1190 kanban / #1191 dealscout / #1199 world-views 实施期发现）
> **Date**: 2026-07-06 · **基线**: main `9b9bca1d`
> **格式**: 每项 = 需要什么 / 现在什么 / 什么问题。全部有 file:line 证据（详版在各 PR 的 dev-together return）。
> **不含**各 PR 自己的业务细节——那些在各自 return 里，review 时看。

## 目的：系统需要支持什么、为了什么

**总目标**：让「**agent 驱动的组合 socialware**」全自动闭环——用户装一个组合出来的 socialware（如 kanban-team：pm+dev 协作推看板；或 爬取+hello：后台爬线索、页面自动更新），**agent 自己干活、产出自动到达用户眼前，全程无人手动**。这条主线今天在三处断，对应 A 两项 + D 一项：

| 系统需要支持 | 为了达到 | 今天断在 | 条目 |
|---|---|---|---|
| **物化出的 agent 能思考**（cc agent 继承宿主登录） | 组合 socialware 里的 agent（pm/dev/爬虫）真干活，而不是空壳 | 凭证不注入，agent "Not logged in" | A② |
| **agent 的产出能到达页面**（组合 hello 时，后台 agent 信号能触发页面重渲） | "后台干完活→用户看到更新"闭环；否则只能人聊一句才刷新 | hello builder 丢弃 agent 消息 + 无可组合的 build 入口 | A① |
| **公开面消息可靠到达 agent**（user 消息按文档语义投 orchestrator） | 访客/owner 在公开面说话有人接（socialware 的对话面成立） | 无 @mention 即静默丢 | D⑦ |

**第二层目标**：**组合出来的 socialware 是可信、可维护的**——发布出去的东西 gate 真兜住、gate 不误伤：

| 系统需要支持 | 为了达到 | 今天断在 | 条目 |
|---|---|---|---|
| gate 覆盖所有已发布 Definition | 新 socialware 坏了 CI 就红，不是静默漏 | check 静默 fallback 硬编码两条 | C④ |
| arch gate 对合法形态不误伤 | 插件作者按正路写不被 gate 卡 | doc 字面例计数 / cap-only view 撞 probe | C⑤⑥ |

**第三层（抽象提案，非阻塞）**：**组合的复用性**——同一个 agent 能力换个 socialware 即插即用：协作协议与能力技能分层（G⑨）、路由硬锁的声明式表达（G⑩）。

---

## A. 最要紧的两个（都卡"agent 驱动的 socialware"主线）

### ① hello 的页面重建入口要不要对组合者开放 —— ✅ **hello 原作者认领（2026-07-06），走 (a)**
> **方案 (a)**：`from_user?` 门放行**带标记**的 agent 信号。落地后组合者的"后台 agent → 页面自动刷新"即通（我们的爬取信号 `__dealscout_update__` 已按内容协议路由到页面角色，只等门放行）。
- **需要**：组合 hello 的 socialware 里，后台 agent 干完活能让 hello 页面刷新（agent 信号 → 页面重渲）。
- **现在**：**路由层是通的**——Definition routing 规则能把 agent 的更新信号真投递到 hello builder（`{:role}` 接收）。卡在 **hello builder 的 handler 代码**：`HelloBuilder.handle_receive` 的 `from_user?` 门（`hello_builder.ex:56-63`）**收到了但丢弃 agent sender 的消息**（hello 的安全设计：只有人聊才重建页）。且 hello **没有暴露可组合调用的 dispatchable build action**——组合者自带 updater 也够不到页面生成路径。
- **问题**：组合 hello 的 socialware 无法实现"后台 agent → 页面自动更新"，且组合者自研也绕不开（入口只在带门的 handle_receive 里）。**请拍两选一**：(a) `from_user?` 门放行**带标记**的 agent 信号（小开口）；(b) 把页面重建暴露成 **dispatchable action**（组合者声明 caps 调用——更通用、组合友好）。我们没私改 hello，defer 等你。

### ② cc-flavor agent 凭证注入缺失 —— ✅ **Allen 认领（2026-07-06）**
> **Allen 方案**：按「谁在 session 中安装 socialware，物化的 agent 就继承谁的宿主登录」简单操作，理论上覆盖**所有 flavor** 的 agent。落地后我们重跑 agent 自驱的全自动 e2e 验证（kanban pm/dev 真思考闭环）。
- **需要**：materialize 出的 cc-flavor agent 用宿主已登录凭证起 TUI。
- **现在**：物化时生成的 `CLAUDE_CONFIG_DIR`（`~/.ezagent/default/cc-agents/<ws>/<uuid>`）**不注入** `.credentials.json`，TUI "Not logged in"；手动拷宿主 creds 后立即认证成功、真思考（e2e 实证：pm 真推理 47s）。
- **问题**：role×cc 的 agent 物化后无法思考——**所有用 cc agent 的 socialware 都卡这**。

## B. 与你在查的 ① 相关（供参考）

### ③ 建 session 同步物化 PTY agent 超 LiveView 预算 —— ✅ **已修（#1202，2026-07-06）**
> Allen 落了 fix(agent-spawn)：post-spawn `sandbox.update_config` 改 fire-and-forget，首装 socialware 5s 超时解除。
- **现在**：`:call` 5s 内同步物化多个 cc PTY agent，超时 UI 报错但**后端真建成**（session+agents 都在）。
- **问题**：假失败。我们 e2e 可稳定复现，供你查 ①（cc orchestrator 冷启动）参考——形态一致：物化重活挂在同步路径。

### ⑪ PtyServer invalid-UTF8 crash loop —— **cc agent 任何长回合必死**（kanban 全链路 e2e 硬阻断，新发现 2026-07-06 深夜）
- **需要**：cc-flavor agent 的 PTY 侧车能撑过一个真思考的长回合（几分钟级、大量 TUI box-art 输出）。
- **现在**：`ezagent_domain_pty/server.ex` 的 `trim_buffer_only` 用 `binary_part(buf, size-16K, 16K)` **裸字节**截断 buffer，会切在多字节 UTF-8 码点中间（claude TUI 大量 3 字节 box-art `─`）；随后每个 stdout chunk 都跑的 `scan_auth_observers`/`scan_auto_prompts` 里 `normalize_ws`（:787-795）的 `String.replace(s, ~r/\s+/u, " ")` 对 invalid UTF-8 **raise** → GenServer 死 → respawn claude → **进行中的回合整个丢失**。活跃回合几分钟就积满 64KB ⇒ 必死循环。e2e 实测 6 连崩、0 次成功回合（取证 `#1190 docs/e2e/2026-07-06/kanban-full-loop/04-pty-crash-forensics.txt`）；main HEAD 同在。
- **问题**：**所有 cc agent 的真实工作回合都过不去**——比 A② 更靠前的阻断（creds 手动拷通过了，死在干活时）。修复一行级：`normalize_ws` regex 去 `/u` 或先 scrub，或 trim 对齐码点边界。domain 代码我们没私改，等你。

## C. Gate / 工具链

### ④ bare `mix ezagent.socialware.check` 静默漏检
- **需要**：precommit gate 覆盖所有已 seed 的 Definition。
- **现在**：mix task 用 `function_exported?(DefinitionRegistry, :list_names, 1)` 枚举（`ezagent.socialware.check.ex:91-99`），**该函数不存在** → 静默 fallback 硬编码 `["chat","socialware"]`。
- **问题**：新 socialware 坏了 gate 不报。修法一行方向：给 `DefinitionRegistry` 加 `list_names/1`。（我们各自用插件内自包含 conformance 测试兜住了，不阻塞。）

### ⑤ arch scanner 把文档字面例计进冻结基线
- **现在**：`mix ezagent.arch.scan` 按行 regex 计 `{:set,...}` 站点（`ezagent.arch.scan.ex:325`），@doc/moduledoc 里的**字面示例**也算。
- **问题**：文档假命中挤占 `set_effect_sites` 冻结预算（我们改写 doc 措辞绕过，基线没动）。

### ⑥ cap probe p4 与 cap-only view ActionSet 的形态冲突（已按先例处理，请 review）
- **现在**：cap-only 的 view ActionSet（`dispatchable?→false`、手写 `cap_subjects/0`）撞 p4 probe（`cap_check_only_at_chokepoint_test.exs:287`）；宏路 `action/2` 会强制 handler+interface，违背 cap-only 形态。HelloRender 当年同款、在 allowlist。
- **处理**：给 `kanban_render.ex` 加了单文件 allowlist（test-only，同 HelloRender 先例）。**请 review 是否认可**；或考虑 probe 认可 `view_behavior` 形态豁免。

## D. 行为与文档不符

### ⑦ hello 公开面：无 @mention 的 owner 消息不投 orchestrator —— ⚠️ **疑似已被 #1208 解决（待重验）**
> #1208 把 hello 迁到标准 socialware substrate + 框架 routing table，新 orchestrator 明确"路由所有其他 sender（users 和 external agents）"。我们会做一次 e2e 重验，确认后本条结案。
- **需要**（按 `HelloOrchestrator` moduledoc）：每条 user 消息投给 orchestrator。
- **现在**：无 @mention 的 owner 消息 0 路由规则命中、无 fan-out、无回复、无 DLQ 痕迹（#1199 Stage 5 e2e 实测）；@mention 才通。
- **问题**：doc 与行为不符——doc 过时还是缺默认路由？

### ⑧ role-slot agent 的裸名 @mention 解析不到（e2e 实测）
- **需要**：成员能 `@kanban-assistant` 这样按**角色名**提到 role-slot 物化出的 agent（协作的自然写法，协议/skill 里也这么教）。
- **现在**：role-slot agent 的 display_name 是 uuid（EntityPresenter），world `conversation_data.ex` 的 `resolve_member_name` 两条路（URI 段/display_name）都不中 → `mentions: []` **静默不路由**；composer autocomplete 对真键盘输入也没弹。全 URI mention（`@entity://system/agent/<uuid>`）可用——e2e 用它 workaround。
- **问题**：role-slot 语义（#1180/#1185）到了 mention 解析层断了——role_name facet 在 session 边上有，解析器没用它。所有 role-slot socialware 的"按角色名喊人"都不通。
- **修法先例已在 main**：#1208 的 `EzagentPluginHello.Members.role_uri/2` 就是按 role_name facet 解析成员的现成查询——mention 解析器补第三条腿照它做即可。

## F. 实施更正说明（非问题，report only）

- **kanban boot-publish handoff 的 roles 示例**：示例含 `kanban-manager×native` 进 roles——实施按 RF-6（passive 不可 join，`session.ex:722`；`role_native_create_test.exs:119` 锁死）与原 kanban 模型落成：**board 不进 roles，由看板助手（pm）经 `kanban.<action>` dispatch 到 board URI 调用**；roles = 看板助手 + dev-together 两个可 join 槽。机制其余（manifest_attrs / publish_or_upgrade public / fail-loud / test-skip / 幂等三态 / E2E 验收）一比一照 hello。
- 存量环境旧 Definition body 升级：从 `seed_definition_if_absent` 迁到 `publish_or_upgrade` 后由 `:upgraded` 态自然解决。


## G. 系统抽象提案（非阻塞，实施中反复撞到的两个）

### ⑨ per-socialware「协作协议」缺常驻注入点
- **需要**：agent 的**能力技能**（recipe.skills，可移植）与**协作协议**（"在这个 socialware 里怎么跟别人配合"）分层——协议应是绑到 Definition 的薄模块，materialize 时注入成员的常驻 context。
- **现在**：常驻 context 只有 socialware-无关的 `recipe.prompt`；`Definition.prompt_templates` 是 per-delivery 临时套非常驻。协议今天只能写死进 skill 文本（我们 kanban 就是：pm skill 里单独一个可切出的 `references/kanban-team-collaboration.md`）或散配 routing_rules/legends。
- **问题**：换个 socialware 换套协议要改 skill 文本；LLM agent 能靠 skill 兜、native agent 完全没法（行为是代码）。**提案**：Definition 级常驻 team-context 薄模块（与 recipe.prompt 分层）。

### ⑩ 组合 socialware 时的 agent 配合：routing 为什么不够、我们怎么解、还差什么

**要解决的问题**：基于一个 socialware 新建另一个 socialware 时，两边的 agent 需要**定向配合**——"A 角色干完活，把结果传给 B 角色"。两个真实例：dealscout 爬取 agent 爬完 → hello 页面 agent 刷新页；kanban dev 交活 → 看板助手审核推板。这种接力有**方向性**：不只是"发给谁（to）"，还有"**谁发的才算（from）**"。

**现有 routing 为什么解不完整**：
- **to 是一等的**：receivers 用 `{:role, name}` 符号，声明期写角色名、运行期按成员边解析——✅ 没问题。
- **from 不是一等的**：matcher 的 `{:from, x}` 只吃**具体实例 URI**（字面比较，`matcher.ex:155`）。而组合 socialware 的 agent 实例 URI **声明期不存在**（materialize 时才随机 UUID），且 #1180 **禁止** Definition 里出现实例 URI（写了 conformance 拒；snapshot 回投也会带毒）。→ **"来自某角色"在配置层表达不出来**。

**我们现行的解法**：
1. **内容协议（软锁）**：接力改用**消息标记**做 condition——`text_contains("__done__")` / `text_contains("__dealscout_update__")` → `{:role, 接收角色}`；"谁在什么时候发这个标记"写进 agent 的 skill 协议模块。零 URI、conformance 过、round-trip 干净。两条线都这么落的。
2. **运行时补锁（可选、机制现成）**：session 活了之后加规则的那一刻，可以把 role 解析成该 session 成员的真实 URI 写进 `{:from, uri}` condition（orchestrator `define_rule_set_rule` / CLI `routing.add_rule` 都走这条）。

**遗留问题**：
- 软锁靠成员遵守协议——**任何成员（含人）发同样标记都会触发**（误触发/伪造）。可信 team 够用；不可信成员场景不够。
- 运行时补锁是 per-session 的后加动作，**不随 Definition 安装自动带**，且补出来的规则（含 URI）**不能 snapshot 回写**进新 Definition（撞 #1180）——加固与"拉取→改→再发布"闭环互斥。

**要做什么（2026-07-06 讨论已定论）**：
- **routing 的 condition 支持按 role 配 from**——声明层写角色符号，运行期按成员边（role_name facet）解析匹配。这是"暂时解"，落地后我们两条线各一行配置加固（kanban relay 加 from=dev-together；dealscout 更新加 from=discover）。
- **冲突场景**（多规则/多来源撞）后续经**配置 orchestrator** 或**显式声明 workflow** 进一步解——**现在不需要立项**。


---

**优先级建议**：A① A② > C④ > D⑦ > G⑨ > 其余。A 两项直接决定"agent 驱动的 socialware"能不能全自动闭环。
