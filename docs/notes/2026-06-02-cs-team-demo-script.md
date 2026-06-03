# 电商 AI 客服台 — Demo 录制脚本 / PRD（no-code · 原语优先）

> **日期**：2026-06-02
> **作者**：daiming（FatNine）
> **依据**：`cs-team-orchestrator-playbook.md`（领导下发）+ `docs/superpowers/specs/2026-06-01-team-routing-unification(.zh_cn).md` + 当前 `Ezagent.Orchestrator.McpServer`/`Tools` 代码（main `151e1fb4`）
> **形态**：双栏 operator runbook（左=镜头内动作+旁白/字幕，右=后端机制 tool→Behavior→effect），既是录制脚本也是 PRD。
> **状态**：rev 5（**完整 live demo 跑通**:operator 搭团队 + 客户→AI 回答,带字幕,见 §3.5 + `evidence/2026-06-03-cs-demo-full-flow.{webm,gif}`)。链路:① 真根因 = macOS Keychain 登录跨不过 PtyServer headless spawn → claude 未认证(本地跑 demo 用 `CLAUDE_CODE_OAUTH_TOKEN` env harness;**生产凭证按 Allen 方向 = domain.agent 的 login-once-persist-inherit**,见 PR #538 评论);② `structuredContent` string→record 真 bug 已修;③ **G-worker(customer→AI)在 rebase 到 main #539 后已通**——PR-DR `deliver_ensuring` 重启消失的 bridge。**剩余**:多 gap 仍归 domain.agent + #533(产品侧推进,地基提意见等 Allen)。

---

## 0. 一句话故事线

> 店主（operator）**只靠对一个编排器 agent 说话**，就搭起一个「售前 L1 + 售后 L2」的电商客服台：AI 自动答咨询、店主对话改 AI 话术、复杂问题升级到售后，最后把整套客服台存成模板给下一家店复用。途中尝试 `@转人工` 接管时**当场撞墙**——把后端拒绝拍进镜头。**全程尽量不写代码**；做不到的地方（装技能、建 session、定向到人类、sticky 人工模式）当场打字幕标成 gap，汇总到结尾。

---

## 1. PRD 头

### 1.1 目标与非目标

**目标**
- 验证：客服这一类「多角色 + 路由 + 人工 handoff + 复用」的需求，**今天靠对话调 8 个 orchestrator 工具能走多远**。
- 证明系统的承重论点：**渠道只是 transport，所有行为落在 Behavior 上**（P12/P13）——脚本刻意把渠道写成次要的。
- 把实现中「不顺手 / 必须填的 gap」**诚实**地标出来，喂给后续 spec（creation-unification #533 + `domain.agent`）。

**非目标**
- 不追求 AI 回答质量（leaf agent 的 Q&A 不是本 demo 的验证对象——见 §1.8 设计备注）。
- 不写新工具、不 hack；遇到对话做不到的，标 gap，不绕过。
- 不演前端美观度；用 Web 后台（LiveView chat）单面录制即可。

### 1.2 读者
R&D（看 gap → 写 spec）、Allen（裁决架构）、未来接手实现的工程师。

### 1.3 录制环境
- `mix ecto.migrate && iex -S mix phx.server`，Web 后台 `http://100.64.0.27:<port>`（Tailscale，非 localhost）。
- 一个已就绪的 cc 客服 AgentTemplate（带基础客服话术的 `claude_config_dir`）。无则在幕 0 现场建。
- 截图/录屏用 headless Chrome（agent-browser），不靠肉眼复述。

### 1.4 角色阵容（cast）

| 角色 | 是什么 | URI / 来源 |
|---|---|---|
| **客户** | human user，在 LV chat 提问 | `entity://user/<ws>/customer-1`（真人，**不**从 template spawn） |
| **AI 售前（L1）** | worker agent，`add_managed_member` spawn 的通用答疑坐席 | `role_name: presale` |
| **AI 售后（L2）** | worker agent，退换货/订单专员 | `role_name: aftersale` |
| **人工客服 Alice** | human user，接管时 join 进来 | `entity://user/<ws>/cs-alice`（GAP #4：对话无法定向到这个人——见幕 4） |
| **Orchestrator（编排器）** | cc 编排器 agent，operator 对它说话、它调 8 工具 | session 内，`role:"orchestrator"` |
| **Operator（店主）** | 人类 owner，做非对话的 LV/mix setup + 对编排器说话 | session owner |

### 1.5 术语映射（客服概念 → ESR 原语）

| 客服概念 | ESR 原语 | 工具 / 标记 |
|---|---|---|
| AI 客服坐席 | managed member（从 AgentTemplate spawn 的 worker） | `add_managed_member` |
| 售前/售后分组 | legend 折叠团队 + 触发其 rule-set | `define_legend` |
| 「@售前」自动转给售前 | entry rule `{:mention,"售前"} -> presale` | `define_rule_set_rule` |
| 复杂问题升级售后 | 成员间路由 `{:from, presale-uri} -> aftersale` | `define_rule_set_rule` |
| 改 AI 回答话术/口吻 | per-hop prompt template（投递时渲染，不改 worker 本体） | `define_prompt_template` + `prompt_template_ref` |
| **给 AI 装新技能（查订单/库存）** | ❌ 系统**无此 operation**（与权限/admin 无关；skills 是 template-time `claude_config_dir`） | **GAP #1（核心）** |
| 转人工（定向到某个人） | ❌ 对话**指不到具体人类成员**（role_name 无面可设 + URI receiver 被 M1 堵） | **GAP #4** |
| **sticky「人工模式」** | ⚠️ 引擎已支持 per-user+enabled，但工具面没暴露、且无 remove/disable 工具 → 对话切不干净 | **GAP #5** |
| 客服台存成模板复用 | SessionTemplate 快照（members+legends+templates+rules，无消息历史） | `save_template_as` / `update_template` |
| **给新店复制一套 + 拉人进来** | ❌ orchestrator 无 create_session / 加人工具 | **GAP #2 / #3** |

### 1.6 8 个 orchestrator 工具速查（`McpServer.tool_schemas/0`）

> 注：模块 moduledoc 仍写「7 tools」，是 team-routing-unification 落地前的 stale 计数；`tool_schemas/0` 实际是 8 个。

`add_managed_member(source_agent_template_uri, role_name, in_session_template=true)` ·
`remove_member(role_name)` ·
`define_rule_set_rule(matcher_ast, receiver_role_name, rule_set, position=0, prompt_template_ref?)` ·
`define_prompt_template(name, template)` ·
`define_legend(legend_name, member_role_names, bound_rule_set, fold=true)` ·
`update_template()` · `save_template_as(new_name)` · `list_templates(name_filter?)`

**matcher_ast（JSON）**：`{"type":"mention","arg":"售前"}`、`{"type":"from","arg":"<member-uri>"}`、`{"type":"text_matches","arg":"退|换|退款"}`、`{"type":"and","items":[...]}`（matcher 全集见 §3.4 事实订正）。

### 1.7 三条承重约束（必须在脚本里尊重，来自 playbook）

1. `add_managed_member` **永远 SPAWN** 一个新 worker，**不能邀请已有实体**（人类或已存在 agent）——没有「invite existing」工具。
2. 路由按 `role_name`/member URI。**角色必须先存在（成员先加）规则才能指它**；`{:from,X}` 携带 `add_managed_member` 返回的 member URI。
3. cc-agent 的技能来自其 AgentTemplate 的 `claude_config_dir`（spawn 时按 agent 复制）。**唯一**由 orchestrator 驱动的技能复制是硬编码的 `ezagent-session-orchestrator`（gated on `role:"orchestrator"`）。**没有工具能挂任意技能**。

### 1.8 设计备注（为什么是 2 个 AI，而非 1 或 N）

2 是**验证多成员原语的最小非退化阵容**，不是容量上限：1 个 AI 时 `define_legend`（折叠**团队**）与 `{:from,X}->Y`（成员间升级/relay）都退化得无意义。把 2 个做成**分层一对 + 升级边**（L1 售前 → L2 售后），就用最小 cast 跑满 `legend 折叠 / entry rule / 成员间升级 / prompt template / 人工 handoff / 快照复用`。
> 业界参照：本 demo 的拓扑对应 **CCaaS 技能路由 + 人工升级**（Intercom Fin、Zendesk AI agents + handoff）与**多 agent handoff 框架**（OpenAI Agents SDK 的 `handoff` 原语）——**不是** Claude Code。CC ≈ 一个带工具的客服坐席（leaf）；orchestrator ≈ 它外面那层路由。我们的 handoff 是**路由表**式（静态 `{from→to}`），不是模型自决——正是 team-routing spec §1 的论点。

---

## 2. 运行手册（双栏分镜）

> 约定：**左栏** = 镜头里发生什么（operator 动作 / 对编排器说的话 / 旁白）；**右栏** = 后端机制（哪个 tool → 哪个 Behavior → 改了什么 slice/routing）。**`🔴 GAP 字幕`** = 当场打在画面上的字幕，同时进结尾统计。

### 幕 0 — 舞台搭建（镜头内，operator 在 LV/CLI，**非对话**）

| 左：镜头 / 操作 / 旁白 | 右：后端机制 |
|---|---|
| 旁白：「真正的编排从幕 1 起全是对话；这一幕是非对话前置。」 | — |
| operator 在 LV 表单（或 `mix esr.agent_template.create`）确认/创建一个 cc 客服 AgentTemplate，指向带基础客服话术的 `claude_config_dir`。 | AgentTemplate 预先存在（承重约束 1：成员只能从已有 template spawn）。**🔴 GAP #7 字幕**：「没有建 AgentTemplate 的 orchestrator 工具——模板靠 LV/mix 预先存在。」 |
| operator `create_session("XX店客服台", template_name: ...)`。镜头：session 建好，成员列表已含 owner + 编排器。 | `EzagentDomainChat.create_session/3` 实例化并 auto-join `[owner, orchestrator]`（人类 owner 自动在内）。**🔴 GAP #2 字幕**：「create_session 是 operator/LV/API 动作——orchestrator **没有**建/fork session 的工具（`tools.ex:78` 显式设计锁）。」 |

### 幕 1 — 搭客服团队（对话）

| 左：对编排器说 / 旁白 | 右：后端机制 |
|---|---|
| operator → 编排器：「列一下我能用的客服模板。」 | `list_templates(name_filter?)` → 按 cap 过滤返回 AgentTemplate/SessionTemplate URI。operator 拿到要 spawn 的 `template://agent/<ws>/<name>`。 |
| 「加两个 AI 坐席：一个售前 L1、一个售后 L2。」 | `add_managed_member(tmpl, "presale", true)` 与 `add_managed_member(tmpl, "aftersale", true)`。每次 **SPAWN** 一个 worker（承重约束 1），返回各自 member URI（升级边要用）。`in_session_template:true` → 进快照。**🔴 GAP 字幕**：「无 bulk spawn N，一次一个。」 |
| 「把售前的 @ 入口和分组做好。」 | `define_rule_set_rule({"type":"mention","arg":"售前"}, "presale", rule_set:"presale", position:0)` + `define_legend("售前", ["presale"], "presale", true)`。售后同理（rule_set/legend `"售后"`→`aftersale`）。右栏旁白：legend = 用户把手，折叠团队并触发 rule-set entry rule。 |
| 「售前答不了退换货时，接力给售后。」 | `define_rule_set_rule({"type":"from","arg":"<presale member URI>"}, "aftersale", rule_set:"escalate", position:0)`。成员间 relay 原语（playbook §1），**已实测成立**（§3.3 item 2）。**🔴 GAP 字幕（已确认，§3.3）**：「多规则命中同消息 = **扇出 union，position 不抑制**——售前**每条**发言都抄给售后；`and(mention,text_matches)` 这类条件升级也只会 fan-out，**做不到『仅退货才升级、且抑制掉 general entry』**。要可抑制/单选需新原语。」 |

### 幕 2 — AI 自动回答（对话 → 运行时）

| 左：镜头 | 右：后端机制 |
|---|---|
| operator 把客户拉进 session（LV chat 里 join `entity://user/<ws>/customer-1`）。 | `chat.join`（LV 动作）。**🔴 GAP #3 字幕**：「把客户（人类）加进来是 LV `chat.join` + `entity://user/...` URI——**不是** orchestrator 工具（人类不从 template spawn）。」 |
| 客户：「**@售前** 这件大衣有 XL 现货吗？」镜头：售前 AI 自动回答。 | mention 解析 → `presale` entry rule 命中 → `Behavior.Chat.handle_send` → `Resolver.resolve`（命中规则）→ `AgentBridge` 投递给 presale worker → worker 回 → 回到群。**全程渠道无关：换飞书/external-mirror 不改这条路径。** |
| 客户：「**@售后** 我上周买的鞋能退吗？」镜头：售后 AI 自动回答。 | 同理走 `售后` legend → `aftersale` entry rule → aftersale worker。 |

### 幕 3 — 编辑 AI 客服行为（对话）

| 左：对编排器说 / 镜头 | 右：后端机制 |
|---|---|
| 「让售前回答时先报价、附当前优惠。」 | `define_prompt_template("presale_tone", "【报价优先】{body}（当前满200减30）")` + 给售前 entry rule 设 `prompt_template_ref:"presale_tone"`（重发 `define_rule_set_rule` 或 update）。右栏：投递接缝 `render_for_recipient/3` 按命中规则渲染，**不改 worker 本体**；`{body}` 必含（写模板时校验）。 |
| 客户再问 → 镜头：售前口吻变了（先报价 + 优惠）。**证明「对话改行为」。** | per-hop 渲染生效（team-routing spec §3.4 路径 A）。 |
| 「给售后**临时装一个『查订单物流』技能**，让它能查真实单号。」 | **🔴 GAP #1 字幕（全片核心）**：「❌ 对话装不了技能。Skills 是 template-time 的 `claude_config_dir`；**没有**运行时挂技能的工具；member 重生 `update_member_template` 被**显式推迟**（`tools.ex:57-66`）。」右栏 workaround：作者写 skill 文件 → 建/fork AgentTemplate 指向它 → 再 `add_managed_member`（operator+模板作者，非纯对话）。弱化版：`define_prompt_template` 注入「优先用查单话术」——**只导行为，装不了技能**。 |

### 幕 4 — 人工接管（**当场演失败**：诚实拍出 wall）

> 这一幕**故意**让编排器去试、当场撞墙，把后端的拒绝拍进镜头——比假装能用更有价值。

| 左：镜头 / 对编排器说 | 右：后端机制 |
|---|---|
| operator 把人工客服 Alice 拉进 session（LV `chat.join`，`entity://user/<ws>/cs-alice`）。Alice 出现在成员列表。 | `chat.join`（LV 动作）。注：`handle_join` 其实**接受** `:role_name` facet（`chat.ex:698-724`），但 LV/web/mix **没有任何人类 join 面传它**——所以 Alice 没有 role_name。 |
| 「做一个 `@转人工`，转给 Alice。」镜头：**编排器调用，后端返回错误**。 | `define_rule_set_rule({"type":"mention","arg":"转人工"}, "<Alice URI 或 alias>", ...)` → `resolve_role_receiver`（`tools.ex:450-460`）：receiver 必须是**当前成员的 role_name** 或 magic token；Alice 无 role_name，URI 字符串又被 **M1 codex 修复**堵死（不再把 URI 形字符串当具体 receiver）→ 返回 **`{:unknown_member_role}`**。**🔴 GAP #4 字幕**：「对话**指不到具体人类成员**：role_name 无面可设（`chat.ex:956-960` 只认 meta.role_name），具体 URI receiver 被 M1 堵。比 playbook『只能用 URI』更糟——那条路已封。」 |
| 旁白：「想做 sticky『人工模式』也一样卡。」 | **🔴 GAP #5 字幕**：「引擎**已支持** per-user(`applies_to_users`)+`enabled`（`rule_store.ex:45/49`，`resolver.ex:268-270` 真的按 sender 过滤），但 `define_rule_set_rule` **不暴露**这两列（`tools.ex:402-415`），且**无** remove/disable-rule 工具 → 进人工能加规则，**退人工切不掉**。不是不能，是缺一个 toggle/remove-rule 原语 + 暴露已有列；现状只能堆覆盖规则，不稳定。」 |
| 旁白收束：「人工接管 = 一等公民人类成员 + sticky 模式，是 §3.2 area 3 要补的设计。」 | — |

### 幕 5 — 沉淀复用（对话）

| 左：对编排器说 / 镜头 | 右：后端机制 |
|---|---|
| 「把这套客服台存成可复用模板。」 | `save_template_as("电商客服台")`（或 `update_template()` 给父模板出新版）。右栏：SessionTemplate 快照 = members(`in_session_template:true`) + legends + prompt_templates + rule-set rules，**无消息历史**（不变式 #10：fork = config only）。 |
| 「给我新开的第二家店也复制一套。」 | **🔴 GAP #2 字幕（再现）**：「❌ orchestrator 不能实例化 session；`create_session(template_name:"电商客服台")` 是 operator/LV/API 动作。它会重 spawn 团队并 auto-join `[owner, orchestrator]`。」 |

---

## 3. GAP 统计

### 3.1 全片 GAP 清单

| # | 出现幕次 | 一句话 | 对应 playbook §「Summary of capability gaps」 |
|---|---|---|---|
| **#1** | 幕 3 | 对话装不了技能（template-time `claude_config_dir`；`update_member_template` 推迟）— **核心** | gap 1 |
| **#2** | 幕 0 / 幕 5 | orchestrator 无 create/fork/实例化 session 工具 | gap 2 |
| **#3** | 幕 2 | orchestrator 无「加人类/已有实体为成员」工具（靠 LV `chat.join`） | gap 3 |
| **#4** | 幕 4 | 对话**指不到具体人类成员**（role_name 无面可设 + URI receiver 被 M1 堵）——比 playbook §4「只能用 URI」更糟 | gap 4（**已封死，加重**） |
| **#5** | 幕 4 | sticky 人工模式：**引擎已支持** per-user+enabled，但工具面未暴露 + 无 remove/disable 工具 → 对话切不干净 | gap 5（**降级：小改即可，非新原语**） |
| **#6** | （隐含） | 单 receiver 规则，无团队级 multicast（只有整 session `$session_members`） | gap 6 |
| **#7** | 幕 0 | 无建 AgentTemplate 的工具（LV/mix 预先存在） | gap 7 |
| **G-a** | 幕 1 | 无 bulk「spawn N」；一次一个 | （playbook §1 备注，非编号 gap） |
| **G-live** | 幕 0/2（live） | cc agent sandbox 缺 onboarding 状态 → claude 卡首次运行主题屏。**纯 config 可修（已验证）**:sandbox 写 `.claude.json`(`hasCompletedOnboarding:true`…)。应进 cc seed | 新发现（= PoC G1，§3.5 第1层；config 修复已验证） |
| **G-chan** | 幕 1+（live） | ~~承重墙~~ **已修复(订正:不是版本漂移)**:真因是 **macOS Keychain 登录读不到 → ESR headless claude 未认证 → channel ignored**;修法 = `CLAUDE_CODE_OAUTH_TOKEN`(`setup-token`)。修后编排器真 live 回复+调工具+spawn worker | 新发现 → **已修复**(§3.5;运维向:headless agent 认证须用 token 不能靠 Keychain) |
| **G-mcp** | 幕 1（live） | `add_managed_member` 返回 URI → MCP `structuredContent` 是 string 应为 record(`expected record, received string`)→ 编排器误报错误(成员其实 spawn 成功) | 新发现 → **已修复**(`mcp_server.ex` `as_struct_content/1` 包成 `%{result: …}`) |
| **G-worker** | 幕 2+（live） | ~~worker 收到 `chat.receive` 但不回复~~ → **已解(订正:不是新 gap)**:我们之前跑在不带 #539 的 base 上;**rebase 到 main(#539)后,fresh worker 一上来就真回答**(PR-DR `deliver_ensuring` 重启消失的 bridge)。完整 customer→AI 流程跑通 | 新发现 → **#539 已解**;customer→AI 全流程 live OK |
| **G-ui** | 幕 0（live） | LV「+New」创建 session 的模板下拉**错填**（只列 agent 模板 `cc.agent.cc_funk`，正确的 `default` SessionTemplate 不在列）→ `session_template_not_found` | 新发现（强化 #2） |
| **G-stale** | （env） | dev `default` profile DB 与 current main **stale-不兼容**:真 agent 快照 `:respawn_template_data` KeyError、crash-loop。需 fresh profile 或迁移 | 新发现（env，§3.5） |

### 3.2 按 playbook「Recommended path forward」3 设计域分组

1. **运行时能力/技能管理（#1, #7, G-a）— 最大缺口。** 需要：技能的 authoring/registering、挂到 agent/template、以及 **member 重生**（推迟的 `update_member_template`）。`domain.agent` 抽象的自然归属（per-agent 身份 + 文件系统/技能隔离作为不变式）。
2. **orchestrator 侧 session 生命周期（#2, #3）。** orchestrator 驱动的 create/fork/实例化 + 加已有实体（人类）为成员。归 **creation-unification spec #533**（一个授权 chokepoint 统一所有 Kind 创建），而非新 ad-hoc `:fork`/`create_session` 工具（今天显式锁掉）。
3. **人类成员 + handoff 建模（#4, #5）。** 一等公民人类成员（带 `role_name`）+ sticky/per-user 人工模式。**读代码后这块比 playbook 想的小**：(a) #4——`handle_join` 已接受 `:role_name` facet、resolver 已有 per-user 过滤，缺的是「人类 join 面暴露 role_name」或「放回校验过的具体成员-URI receiver」；(b) #5——`enabled`/`applies_to_users` 列已存在且 resolver 生效，缺的是把它们暴露到 `define_rule_set_rule` + 一个 remove/disable-rule 工具。**多为『暴露已有能力』而非从零设计新原语**——但仍要走 #533/`domain.agent` 统一设计，别又散着加。
4. **未归域：#6 团队级 multicast。** playbook 把它列为 gap 6 但未分配到上述 3 域；它是路由原语，建议并入 area 3 的路由/handoff 建模一并设计。

### 3.3 后端彩排结论（rev 2 — Tools+Resolver 层 ExUnit 实测，不需 claude login/浏览器/录屏）

> 复现：`mix test apps/ezagent_domain_chat/test/integration/cs_demo_backend_rehearsal_test.exs`
> （+ item 2 由 `.../orchestrator_member_team_test.exs` 既有用例覆盖）。全绿。

- [x] **item 2 — `{:from, presale}->aftersale` 成员间 receiver 正常。** worker（有 role_name）做 receiver 时 `{:from, cc}->codex` 确定性路由到目标成员（既有用例「relay chain ... {:from, role→uri}」）。⟹ 升级边对**成员**成立。
- [x] **GAP #4 — 一个已 join 的人类成员仍指不到。** `define_rule_set_rule` 用 Alice 的 URI 字符串做 receiver → **`{:unknown_member_role}`**；MCP 对话层映射为 `error.code = "unknown_member_role"`；同 session 里真成员的 role_name 正常（对照）。⟹ 坐实「joined human 也够不到」，比 playbook §4「只能用 URI」更糟。
- [x] **position 语义 = 扇出 union，不抑制。** general entry（`always->售前`,pos 1）+ 条件升级（`text_matches("退\|换\|退款")->售后`,pos 0）同时命中「我要退货」→ **售前与售后都收到**；非退货消息只给售前。⟹ **「仅退货才升级」做不到**——条件升级会 fan-out，不能抑制掉 general entry（`position`/`rule_id` 只用于同一 recipient 的 ctx tie-break，不抑制路由本身）。这正式把幕 1 的「GAP 候选」转成确认结论。
- [x] **applies_to_users — Resolver 真的按 sender 做 per-user 过滤。** `applies_to_users:[A]` 的规则对 A 生效、对 B 静默跳过（`resolver.ex:268-270`）。⟹ 坐实 GAP #5「引擎已支持 per-user 隔离」；缺的只是工具面暴露 + remove/disable。

**仍需真 agent / 浏览器的项（留待 claude login 后的 live run）：**
- [ ] prompt_template 改售前 entry rule 后，升级到售后那条 `{:from}` 是否被意外渲染（需真投递）。
- [ ] `define_legend(fold:false/true)` 的 UI 可见差异（需浏览器截图）。
- [ ] 换渠道：客户从飞书 inbound 进来是否零改动跑通（印证 P13，需 live transport）。

### 3.4 对 playbook 的事实订正与结构性发现（读代码确认，附 file:line）

写脚本时为答三个问题读了代码，结论改写了若干 gap 的性质——记录在此供写 spec 用。

**(订正 A) matcher 比 playbook 丰富。** playbook 暗示只有 `mention`/`from`；`Ezagent.Routing.Matcher` 实际支持 `mention / from / in_session / text_contains / text_matches / always` + 组合子 `and / or / not`，全部能走 JSON（`from_json/1`）。⟹「基于内容的路由」**不是 gap，是现成能力**（`and(mention, text_matches) -> X`）。唯一未定的是多规则命中时的**优先级/抑制/扇出语义**——见 §3.3。

**(发现 B / GAP #1) 装 skill 是「无此 operation」，与权限无关。** 技能 = `claude_config_dir/skills/` 下的模板期文件（`agent_template.ex:51`）。全仓库唯一拷 skill 的代码是 `apply_orchestrator_role_bootstrap/2`（`cc_agent.ex:486-532`），**硬编码**只拷 `ezagent-session-orchestrator`、gated on `role:"orchestrator"`、注释明说「SKILL is UX, not load-bearing」。`grep def *skill` 无任何 install/attach/add。⟹ admin 权限再大也**没有可授权的 operation**；给 agent 加技能只能「写文件 → 建/fork 模板 → spawn 新成员」，且不是「给已存在 agent 装」。

**(发现 C / GAP #4 加重) 对话指不到具体人类成员，且 URI 路已封。** `define_rule_set_rule` 的 receiver 从对话进来是字符串，`resolve_role_receiver`（`tools.ex:450-460`）要求**成员 role_name** 或 magic token；M1 codex 修复**特意关掉**「URI 形字符串当具体 receiver」。`role_name_to_uri`（`chat.ex:956-960`）只认 `meta.role_name`。`handle_join` 接受 `:role_name`（`chat.ex:698-724`）但**只有** `add_managed_member`（spawn worker）喂它，**人类 join 面（LV/web/mix）都不传**。⟹ Alice：无 role_name、URI 被堵、magic token 指全体 → **对话定向不到她**。比 playbook §4「只能用 URI」**更糟**（那条已封）。

**(发现 D / GAP #5 降级) sticky 模式：引擎已支持，缺工具面 + toggle。** `enabled`(默认 true,`rule_store.ex:45`) 与 `applies_to_users`(`rule_store.ex:49`) 列**已存在**，resolver **真的按 sender 过滤**（`resolver.ex:268-270`）。但 `define_rule_set_rule` 的 `add_opts`（`tools.ex:402-415`）**不传**这两列，且 8 工具里**无** remove/disable-rule。⟹ 进人工能加规则、退人工切不掉 → **不是不能，是缺『暴露已有列 + 一个 disable/remove-rule 工具』**，非从零新原语。playbook「no applies_to_users-style matcher」不准确。

### 3.5 Live run 实跑状态与新发现 gap（2026-06-02，真 agent live demo 尝试）

按"全量真多 agent live demo"启动后，基础设施**部分跑通**，但撞到一个**真 agent 起不来**的承重 gap，记录如下（用户指示参考 PR #512 并入 gap）。

**跑通的：** dev server（`mix phx.server` @ `:10042`）、admin 登录、Playwright 驱动 LiveView（截图 + `.webm` 录屏链路全通，已出图）、标准库 `claude` CLI 已认证（Keychain，`claude -p` 回 `PONG`，网络可达 Anthropic）。

**G-live（承重，= PoC G1）— spawn 的 cc agent 卡 onboarding、不 JOIN esr-bridge。** 现象（`phx.log`）：
```
PtyServer[...] stderr:  Choose the text style that looks best with your terminal
   1. Auto   ❯ 2. Dark mode ✔  3. Light mode ...
[error] Session.ensure_orchestrator: orchestrator cc_orchestrator-main did NOT join
        its live MCP bridge within 90000ms — killing the PTY + Kind and failing loud
[warning] AdminLive.ensure_main_session failed: {:orchestrator_not_ready_within, 90000}
```
根因：每 agent 的 sandbox `CLAUDE_CONFIG_DIR` 是**未完成 onboarding** 的新配置 → spawn 的 `claude` 落到首次运行主题选择屏、阻塞在 stdin → 永不进 MCP bridge 握手 → 90s 被杀（并反复 respawn）。所以 UI 里 orchestrator 乐观显示 "alive"，但**没有任何消息能投递、没有 agent 真回答**（我看到的 cc_funk 回答是 08:31 **历史数据**，非我触发的 live 回复）。附带还有一个 Logger formatter 在 onboarding 的制表符输出上 crash。
- **已知修复存在但未合并：** PR **#512 `EzagentPluginCc.EagerBridge`**（`ensure_bound!/2`：等 PTY auto-prompts 触发完 → 写裸 `\r` 触发 MCP init → 轮询 `AgentBridge.Registry` 直到绑定）正是这条 G1 的修复，但它在 PoC stack（`poc/phase-2`）里、**`mergedAt: null` 未进 main**。current main 因此缺这条 bring-up 原语。设计上 operator-facing 流"人打开终端页第一次按键自然触发 MCP init"——即手动在 agent Terminal 页敲一下 Enter 也能 unstick，但当前是无人值守自动流。

**G-live 实跑拆成【三层】，逐层实测（2026-06-02 全量 live 攻坚，干净 `csdemo` profile）：**
1. **onboarding 卡死 —— 纯 config 可修，已验证（我原以为要 kick，是误判）。** 根因:agent 的 sandbox `CLAUDE_CONFIG_DIR`（如 `~/.ezagent/cc-orchestrator/.claude`）**没有 `.claude.json`** → claude 当首次运行、弹主题选择屏阻塞。**修法（纯 config、无代码、可直接进 seed 代码）**:往该目录写 `.claude.json`，含 `hasCompletedOnboarding:true` + `hasTrustDialogAccepted:true` + `bypassPermissionsModeAccepted:true` + `theme:"dark"`。**实测两次有效**:主题选择屏消失。⟹ 应进 cc sandbox seed（`cc_orchestrator_seed`）默认写好,是干净的 gap remediation。注:macOS auth 走共享 Keychain(已 OK),onboarding 状态是 `CLAUDE_CONFIG_DIR` 隔离的、必须单独 seed。
2. **MCP-server JOIN —— onboarding 修好后自动通,不需任何 kick。** 实测:`theme=0 spawn=1 join=1 killed=0`,编排器 PTY spawn + JOIN esr-bridge,8 工具的 MCP server 绑定(`Orchestrator.McpSocket` CONNECTED),UI 里 `cc_orchestrator-main` **online、真成员**。⟹ 此前以为要 #512 的 `\r` kick 是**误判**——onboarding 一通,系统自带 `default_auto_prompts/0` 就把 dev-channels prompt 答了、正常 join。**我加的 kick 补丁已撤、未提交,无用。**
3. **入站 CHANNEL 不可用 —— 真根因 = 认证(已修复;此前"版本漂移"结论已订正)。** 实测:编排器 join 后,operator 发消息,后端 `chat.receive` **granted + delivered**,但编排器 5+ 分钟零回复;claude 屏幕 `--dangerously-load-development-channels ignored (server:esr-bridge)` / `Channels are not currently available`。
   **逐层证伪(Allen 人工配合,在终端实跑同一条命令)**:
   - `strings ~/.local/bin/claude` 证明 **channel 功能代码还在二进制里**(`Listening for channel messages` / `channelsEnabled` 都在)→ **flag 没被删,我那个结论错了**。
   - 手动跑同样命令、**`/login` 之后**:claude 弹出 dev-channels 确认框、选"1" → **`Listening for channel messages from: server:esr-bridge`** —— **channel 能通!** 唯一变量是登录态。
   - 对比 ESR headless spawn 的 claude:**没有 `Welcome back` 登录横幅**(交互跑每次都有)→ **ESR spawn 的 claude 其实未登录**。
   **铁证根因**:`/login` 的 OAuth token 存在 **macOS Keychain**,你的交互终端读得到,但 ESR 用 PtyServer/erlexec spawn 的 claude 进程**读不到那个 Keychain 条目**(macOS 把 Keychain 访问绑在发起进程身份上)→ 它未认证 → ignore channel → 收不到 chat。
   **修复(已验证跑通)**:`claude setup-token` 生成一个**绕开 Keychain 的长效 OAuth token**(走 Max 订阅),作为 `CLAUDE_CODE_OAUTH_TOKEN` 注入 ESR server 环境 → spawn 的 claude 子进程继承 → 认证通过 → `listening=1`、编排器 **12s 真回复 + 真调 `list_templates` + 一句话 `add_managed_member` spawn 出真客服坐席**。⟹ **运维结论(交 Allen)**:macOS 上 headless agent 不能靠 Keychain 登录,必须用 token(`setup-token` / `api_key_helper`);这条应进 cc seed / 文档。

- **环境烂账(实跑逐层发现,均已处理或记录):** (a) dev `default` profile DB **stale-不兼容** current main —— 真 agent 快照(cc_funk/cc_orchestrator-main,2026-05-26)`:respawn_template_data` KeyError、crash-loop `ensure_main_session` → `/sessions` 挂;(b) 历史遗留 orphan `ezagent_mcp_bridge.py` / `claude server:esr-bridge` 进程反复重连、刷崩 AgentSupervisor;(c) 一条 `cc_spawn-invariant-test` 测试快照污染。**干净 `csdemo` profile 一次性绕开 (a)(c)**,(b) 已杀。
- **对 demo 的含义(最终订正):** **核心 live demo 跑通了**——清 `csdemo` profile + onboarding seed + `CLAUDE_CODE_OAUTH_TOKEN` 三件齐,编排器真 live:operator 对话 → 列模板 → 一句话 spawn 真客服坐席,**已录 `.webm` 交付**(rec2)。顺带修了 `add_managed_member` 的 `structuredContent` 真 bug(G-mcp,已改 `mcp_server.ex`)。
- **剩余 follow-up(G-worker,customer→AI 回答):** worker(售前/售后)被 spawn 后,其 claude PTY/channel 生命周期还差:restart 后不自动重起、per-agent config 的 onboarding/channel 未像编排器那样配好 → worker 收到 `chat.receive` 但不回复。编排器侧的 token 修法对 worker 同样适用(worker 继承同一 env token、auth OK),欠的是 worker 的 onboarding seed + PTY 重起/channel listening。这半留作下一步。

**G-ui — 创建 session 的模板下拉错填。** LV「+New」的 `template_class` 下拉只列了 agent 模板 `cc.agent.cc_funk`（提交即 `{:session_template_not_found}`），**正确的 `default` SessionTemplate**（`template://session/system/default@…`，main 自己就用它）不在列；客户端注入 `default` 又被 LV morphdom 抹掉。⟹ operator 无法经 UI 干净地新建带 orchestrator 的团队 session（强化 GAP #2）。

> **最终结论：** 后端语义（rev 2）已严格验证；bring-up 三层里 onboarding 是 config 可修（已验证）、JOIN 自动通、**入站 channel 是 main 代码 gap、挡死整条 live 对话流**。**live 视频须先修第 3 层**;当前可交付 = 脚本/PRD + 后端验证 + 完整三层 gap 定位。

---

## 4. 录制注意

- **字幕规范**：每个 `🔴 GAP` 当场打全屏字幕（红底/角标），停留 ≥2 秒，文案就用 §2 右栏里的 GAP 句；这些字幕是「demo → gap 统计」的桥。
- **节奏**：幕 0 快（非对话前置，10–15s）；幕 2/幕 3 是高光（AI 自动答 + 对话改行为），放慢；幕 4 是**诚实的撞墙时刻**——拍清「编排器调用 → 后端返回 `{:unknown_member_role}` → GAP 字幕」，给错误返回一个特写。
- **渠道次要**：全程旁白至少点一次「这里换飞书/external-mirror 后端一行不改」，呼应 P12/P13 论点。
- **证据**：截图/录屏用 **Playwright**（headless Chromium + ffmpeg `.webm`，本机已装）对 `http://127.0.0.1:10042`，不靠肉眼复述。（"agent-browser" 不在 PATH，用 Playwright 等价替代——见 §3.5。）
