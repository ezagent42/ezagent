# Phase 7 实现审计 — 设计 vs 已交付（2026-05-22）

> **审计性质：** 只读。未改动任何代码。本笔记是唯一产物。
> **触发：** Allen 飞书 2026-05-22 —"做 phase 7 审计，看起来 phase 7 很多没完成。"
> **方法：** 读真实代码（不靠 grep 计数）。每个 Phase-7 要素对照
> `docs/phase-specs/phase7/SPEC.md`（LOCKED v3）+ `VERIFICATION.md`（V1-V5）
> 分类为 IMPLEMENTED / STUB / PARTIAL / ABSENT。

## 为什么要做这个审计 —— resume-state 文档自相矛盾

`docs/notes/phase-7-resume-state.md` **自相矛盾，不可信**：

- 头部写"Phase 7 at v1 release. Code-complete"，并列出 #118/#119/#120
  当晚已合并（"#119 = PR 46-impl — 7 个 orchestrator 工具体已接线"）。
- 它自己的状态**表格**同时把 PR 46/47/48/49/52 标为 ⏳ pending，摘要行写
  "7-2 templates ⏳"、"7-3 orchestrator ⏳"、"7-4 handoff ⏳"。

真相（2026-05-22 读代码得出）介于两者之间：**模块骨架全都存在，部分
确实完整**，但 **核心特性 —— 一个能把 SessionTemplate 变成活团队的运行中
Orchestrator —— 端到端不工作。** 几个"已合并"的 PR 落的是
*表面声明 + 结构测试*，而不是可工作的行为。

另外：仓库早已走过 Phase 7（现在在 Phase 8 / Phase 9 —— mention-gated
routing、租户隔离、nested-shell UI）。Phase-7 的缺口是被带着走、没补完，
不是被关闭。

---

## 状态表 —— 各 Phase-7 要素

| # | 要素 | 状态 | 证据 |
|---|------|------|------|
| 1 | **WorkspaceRegistry**（第 5 个 ETS registry） | **IMPLEMENTED** | `apps/ezagent_core/lib/ezagent/workspace_registry.ex` —— `bind/unbind/lookup/list_all/default_workspace_uri` 齐全，真实 ETS。Phase 9 PR-7 后降级为"一致性缓存"（workspace 现在从 URI 结构性推导），但 registry 本身完整且在用。 |
| 2 | **AgentTemplate Kind + `template://` scheme** | **PARTIAL** | `agent_template.ex` —— Kind 契约存在（`type_name/behaviors/persistence/supervisor`），`template://` host 分派已接在 `application.ex:404`。**但：** 未实现 SPEC §D7-2 要求的 `Ezagent.Kind.Template` behaviour（`template_name/0`/`validate/1`/`instantiate/3`）；slice schema 只在 moduledoc —— 无 slice 字段代码、无校验、无 `instantiate/3`。是裸 Kind，不是 Template Class。 |
| 3 | **SessionTemplate Kind + SHA-256 版本化** | **PARTIAL** | `session_template.ex` —— Kind 契约 + `compute_version_hash/1`（真 SHA-256，`:erlang.term_to_binary(_, [:deterministic])`）+ `build_uri/3`。测试通过。**但：** 无 `Ezagent.Kind.Template` 实现、无 `instantiate/3`、无 slice 字段、**无 `fork/2`、无 `create/2`**。`parent_template_uri` / `version_tag` / `template_tags` registry 只在 moduledoc。**`template_tags` registry 模块根本不存在。** |
| 4 | **template caps**（`template:read/write/instantiate`） | **PARTIAL** | `template_caps_test.exs`（12 测试）锁住语义划分 —— cap kind 是开放 atom 所以结构上"能用"。**但：** 没有任何代码路径真的*检查* `template:` cap。`template:instantiate` 零调用点。Generator 显式信任调用方。 |
| 5 | **`Agent.spawn/4` + AgentLineage** | **IMPLEMENTED** | `agent.ex:132` —— 真 `spawn/4`，组合 `SpawnRegistry.spawn` + `WorkspaceRegistry.bind` + `AgentLineage.record`。`agent_lineage.ex` —— 完整 registry + 有界血缘遍历。**注意：** 故意不把 `spawned_by` 作为 Agent *slice* 字段（与 SPEC §7-3(b) 偏离，但对 `{:spawned_by,_}` cap 功能等价）。 |
| 6 | **Generator —— `Session.spawn_from_template/2`** | **PARTIAL（"minimal PR-41"版本 —— 从未扩展）** | `session.ex:146` —— 真函数：确认 template 存活、spawn 新 session、绑 workspace、spawn 内嵌 orchestrator agent、授 2 个 scope-bounded cap。**未做（SPEC §Generator 步骤 3/5/6/7）：** 不解析 `agent_slots` worker 模板、不 spawn worker agent、不装 routing rule、不初始化 working-copy slice。其 moduledoc 自承："PR 41 minimal scope... 只 spawn orchestrator... 其余 deferred 到 PR 46"。PR 46 从未交付这些。 |
| 7 | **Orchestrator + 它的 7 个 MCP 工具** | **STUB / 仅表面 —— 不运行** | 见下方"Orchestrator 深挖"。7 个工具*函数*有真实体（非 `:not_implemented_yet`），但其中 2 个不完整（返回 URI 但不落 row），且关键是 —— **工具表面没接到任何东西。** 无 MCP bridge、无 agent flavor、无 chat-behavior 路径把 `Ezagent.Orchestrator.Tools` 暴露给运行中的 LLM。cc-orchestrator"agent"是个空 AgentTemplate Kind。 |
| 8 | **Scope-bounded delegation caps** | **IMPLEMENTED** | `capability.ex:108-130` —— `instance_match?/2` 对 `{:within_session,_}`（带 `/` 边界守卫的字符串前缀）和 `{:spawned_by,_}`（真 `AgentLineage.spawned_in_lineage?` 遍历，**不是** deny placeholder）都有真实子句。`capability_test.exs` 309-483 行覆盖授予/拒绝/前缀边界/血缘缺失拒绝/血缘记录命中/跨血缘拒绝。Phase-7 最完整的要素。 |
| 9 | **Session persistence 翻转** | **IMPLEMENTED —— 但 working-copy slice 没加** | `session.ex:80` —— `persistence, do: {:snapshot, :on_change}`。翻转**已做**（commit `2743635`，PR #199 —— 注意是 Phase-8/9 期的 PR，不是 Phase-7 PR）。resume-state"PR 44 partial —— flip deferred"已过时。**然而** 翻转本应让其持久化的 `template_working_copy` slice 字段**从未加** —— 只在 `chat.ex:78-86` 的 moduledoc 注释里存在。 |
| 10 | **`mix ezagent.bootstrap` + `mix ezagent.plugin.install`** | **IMPLEMENTED** | `ezagent.bootstrap.ex`（home.init + deps.get + adopt_db + ecto.create/migrate + `SELECT 1` 健康检查）和 `ezagent.plugin.install.ex`（250 行，真 `:application.load` + start）。均功能正常。 |
| 11 | **3 个 session 创建入口** | **ABSENT（3 缺 2）** | SPEC §"Session-creation entry points"：(a) instantiate-from-template = `spawn_from_template/2` —— 存在但 partial；(b) fork+instantiate = `SessionTemplate.fork/2` —— **不存在**；(c) create-blank+instantiate = `SessionTemplate.create/2` —— **不存在**。3 个入口只有 1 个在场，且那个还是 partial。 |
| 12 | **VERIFICATION V1-V5** | 见下表 | ≥10 个 gating test 中有 ~7 个完全缺失；核心特性（V2）未达成。 |

### Orchestrator 深挖（要素 7）—— 最关键的发现

`apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex`（444 行）
声明正好 7 个工具函数。读工具体：

- `add_agent_slot` / `remove_agent_slot` / `update_agent_template` /
  `write_matcher` / `list_templates` —— **真实**，委托给 `Agent.spawn/4` /
  `RuleStore` / `KindRegistry`。
- `update_template` —— **不完整。** 构建 working-copy slice、算 version
  hash、`build_uri` 出新 SessionTemplate URI —— 然后**返回该 URI 但从不
  插入 SessionTemplate row。** 无 registry 写。SPEC §"update_template
  mechanics"的"新 hash row 存在 / 老 session 不受影响"未满足。
- `save_template_as` —— **不完整。** 同形 —— 算 hash、返回 URI、**什么
  都不持久化。**

**决定性缺口：** `Ezagent.Orchestrator.Tools` **没有被任何东西
import。** grep `apps/` 找 `Orchestrator.Tools` / `Orchestrator`（在
`.ex` 里）只找到模块自身和它的测试。没有：

- 把 7 个工具暴露给 LLM 的 **MCP server / bridge**；
- *作为* Orchestrator 的 **agent flavor / Kind**；
- 把 `@cc-orchestrator` mention 路由进工具调用的 **chat-Behavior 路径**。

"cc-orchestrator AgentTemplate seed"（`application.ex:298`）只是对
`template://agent/default/cc-orchestrator` 调 `SpawnRegistry.spawn` ——
spawn 一个**空 AgentTemplate Kind**，无 `claude_config_dir`、无 prompt、
无 `settings_path`、无 MCP 工具接线。

**结论：Orchestrator 不运行。** 它是一个工具表面模块 + 一个 CI 锁测试
（"正好 7 个工具、无 fork、无 grant_cap"）+ 一个空 seed Kind。SPEC D7-1
的"住在 session 里的 LLM-driven agent"在代码里没实现。VERIFICATION V2
的 e2e demo（PR 49）从未录制，因为没东西可演示。

---

## V1-V5 验证表

| 准则 | 达成? | 证据 |
|------|-------|------|
| **V1.1** 5 分钟 `mix ezagent.bootstrap` 上手 | **大概达成** | bootstrap task 真实 + 烟测过；但 CI gate `bootstrap_to_serving_test.exs` **缺失**。 |
| **V1.2** esr-developer skill 激活 + 引导 | **达成（skill 存在）** | `.claude/skills/ezagent-developer/SKILL.md`（SPEC 写 `esr-developer`，落地名 `ezagent-developer`）。 |
| **V1.3** 自助错误排查 / runbook | **达成** | `docs/runbook/common-failures.md`。 |
| **V1.4** Plugin 热安装 | **部分** | task 工作；gate `plugin_hot_install_test.exs` **缺失**。 |
| **V2.1** Orchestrator 从自然语言起团队 | **未达成** | Orchestrator 不运行。 |
| **V2.2** Mention 路由隔离 worker | **另行交付** | mention-gated routing Phase 9 落地（#226）—— 但不经由 orchestrator。 |
| **V2.3** `save_template_as` 产可复用模板 | **未达成** | `save_template_as` 不落 row。 |
| **V2.4** 重新实例化产相同团队 | **未达成** | Generator 不 spawn worker，无 template row。 |
| **V2.5** 精炼 + 版本递增（`update_template`） | **未达成** | `update_template` 不落 row。 |
| **V2.6** 持久化跨重启 | **部分** | Session 翻转已做；但无 `template_working_copy` slice 可存活。 |
| **V2.7** Orchestrator 失败的错误反馈 | **部分** | `:parent_template_deleted` 路径有码；活 orchestrator 永远到不了。 |
| **V3.1-V3.3** Scope/血缘 bounded cap 拒绝 | **达成** | `capability.ex` + `capability_test.exs` 全覆盖。 |
| **V3.4** CLI ↔ LV cap 平价 | **达成** | `cli_lv_cap_parity_test.exs`。 |
| **V3.5** Feishu inbound 保留错误反馈 | **达成（既存）** | PR 27。 |
| **V3.6** Decision Log 退役 v0-no-delegation | **达成** | Decision #137。 |
| **V4.1** 仓库树无 DB | **达成** | `repo_root_clean_test.exs`。（当前仓库根有 `ezagent_core_test.db` 等*测试* DB —— 值得一个跟进检查。） |
| **V4.2** 无 v1 prototype 引用 | **达成** | `no_v1_bridge_after_cutover_test.exs`。 |
| **V4.3** 零孤儿 sidecar | **达成** | `sidecar_orphan_reap_test.exs`。 |
| **V4.4** 路由中的 workspace 隔离 | **达成** | `workspace_isolation_test.exs`。 |
| **V4.5** bootstrap 一条命令 | **达成（task）** | gate 测试缺失。 |
| **V4.6** CC v2 唯一路径 | **达成** | v1 prototype 已删。 |
| **V4.7** CLI 按用户 token 鉴权 | **达成** | `ezagent.user.token` + 平价测试。 |
| **V4.8** Session persistence 翻转 == `{:snapshot,:on_change}` | **达成** | `session.ex:80`。 |
| **V5.1** ≥8 个不变式测试 gate Phase-7 原则 | **部分** | 在场：workspace_isolation、no_v1_bridge、sidecar_orphan_reap、repo_root_clean、cli_lv_cap_parity、capability scope、orchestrator/tools（7-tool 锁）。**缺失：** orchestrator_cap_scope、template_immutable_hash、template_fork_lineage、template_tag_resolution、plugin_hot_install、bootstrap_to_serving、orchestrator_e2e_demo。 |
| **V5.2** Skill 抓反模式 | **大概达成** | skill 存在。 |
| **V5.3** D7-* Decision Log #135-#144 | **达成** | ARCHITECTURE.md #135-#144（及 #146）。 |
| **V5.4** GLOSSARY 16 个 Phase-7 术语 | **达成** | GLOSSARY §624+。（小过时点：Orchestrator 条目写"6 MCP tools"却列 7。） |
| **V5.6** `phase-7-handoff.md` 宣告 v1 | **达成（但过早）** | 存在，宣告"v1 release（code-complete）"—— 被本审计推翻。 |
| **V5.7** 4 篇上手文档 | **部分** | `docs/onboarding/` 3 篇 + `docs/runbook/common-failures.md` = 4 个文件，匹配。 |

---

## 结论 —— Phase 7 真正还剩什么

Phase 7 大约**真实完成 55-60%。** *基础设施*子步（7-1）和*委托*原语
（7-3 caps）确实做完且测试良好。*交接*子步（7-4）基本做完。**它命名所
依据的核心特性 —— 带活的 in-session orchestrator 的 session-template
生成器 —— 没建。** 它是模块骨架、moduledoc 散文、和没有可工作管线支撑
的 CI 锁测试。

resume-state 文档的"code-complete v1 release"是**假的。** 交接笔记
`phase-7-handoff.md` 应被降级。

### 具体未完成项（按影响排序）

1. **Orchestrator 不运行。** 无 MCP bridge / agent flavor / chat-behavior
   接线把 `Ezagent.Orchestrator.Tools` 连到活 LLM。cc-orchestrator seed
   是空 Kind。这是中心缺口 —— V2（核心特性）完全未达成。
2. **`update_template` 与 `save_template_as` 什么都不持久化。** 两者算
   hash + URI 返回；都不插 SessionTemplate registry row。
3. **Generator 是"minimal PR-41"残桩。** `spawn_from_template/2` 只
   spawn orchestrator —— 无 worker `agent_slots`、无 routing rule、无
   working-copy slice。延后到 PR-46 的工作从未落地。
4. **3 个 session 创建入口缺 2 个。** `SessionTemplate.fork/2` 与
   `SessionTemplate.create/2` 不存在。无 `template_tags` registry。
5. **AgentTemplate / SessionTemplate 是裸 Kind，不是 Template Class。**
   都没实现 `Ezagent.Kind.Template`（`validate/1` + `instantiate/3`）；
   都没有 slice 填充代码。slice schema 只在 moduledoc。
6. **没有任何 `template:` cap 被强制。** `template:instantiate/read/write`
   零运行时调用点 —— Generator 显式信任调用方。
7. **~7 个 V1-V5 gating test 缺失：** orchestrator_cap_scope、
   template_immutable_hash、template_fork_lineage、template_tag_resolution、
   plugin_hot_install、bootstrap_to_serving、orchestrator_e2e_demo。

### 确实扎实的部分（别重做）

- WorkspaceRegistry、AgentLineage、`Agent.spawn/4` —— 完整 + 测试。
- Scope-bounded delegation caps（`{:within_session,_}` /
  `{:spawned_by,_}`）—— 完整且测试充分。SPEC 称之为"最棘手的部分"，
  它确实做对了。
- Session persistence 翻转 —— 已做（在后续 phase 的 PR #199）。
- `mix ezagent.bootstrap` / `mix ezagent.plugin.install` —— 已做。
- Decision Log #135-144、GLOSSARY 术语、ezagent-developer skill、上手
  文档 —— 已做。

---

## 与 cc-agent-config SPEC 的重叠 / 冲突

`docs/superpowers/specs/2026-05-22-cc-agent-config.md` 在分支
`origin/docs/cc-agent-config-spec`（尚未上 `main`）。它设计两层 cc-agent
配置：Layer 1 = 按 agent 的 `cwd` + `settings_path`；Layer 2 = cc-plugin
全局的 `sandbox_mode` 布尔，为 true 时经由隔离的 `CLAUDE_CONFIG_DIR` 把
每个 cc agent **完全隔离于 host `~/.claude/`**。

**与 AgentTemplate（Phase 7）的直接重叠：**

- Phase-7 AgentTemplate 的 **slice schema 早就设计了完全相同的模式**
  —— 其文档化字段是 `claude_config_dir`（→ 成为 `CLAUDE_CONFIG_DIR` 环
  境变量）、`settings_path`、`mcp_config_path`、`api_key_helper`（macOS
  Keychain 绕过法）。resume-state 第 3 轮 brainstorm 明确写"AgentTemplate
  adds `CLAUDE_CONFIG_DIR` env var pattern + macOS Keychain caveat"。
- **但该模式今天不在 AgentTemplate 代码里。** `claude_config_dir` /
  `CLAUDE_CONFIG_DIR` **只出现在 moduledoc 注释**里（`agent_template.ex`、
  `agent.ex`、`tools.ex`、`application.ex`）—— 无 slice 字段、无环境变量
  构造、无消费它的 PTY 启动代码。AgentTemplate 是文档化意图，不是可工作
  的 sandbox 指针。

**因此两个工作是在空地上相撞，不是在已建好的地基上：**

- cc-agent-config 的 `sandbox_mode` 和 Phase-7 的 `claude_config_dir`
  是**同一机制**（隔离的 `CLAUDE_CONFIG_DIR`），在两份 SPEC、两个层次
  （cc-plugin 全局 vs 按 AgentTemplate）被各自描述。谁实现都要先调和：
  sandbox 开关是 plugin 全局（cc-agent-config Layer 2）还是按模板
  （AgentTemplate slice）？两份 SPEC 答案不同，且都没建。
- cc-agent-config Layer 1 的按 agent `settings_path` 与 AgentTemplate
  的 `settings_path` 字段重叠 —— 同名同用途。
- cc-agent-config 引入一个**不可绕过的 PTY 安全 `--settings` 覆盖**
  （强制 `remoteControlAtStartup: false`）。若 AgentTemplate 的
  `settings_path` / `claude_config_dir` 日后被天真地实现，可能撤销该安
  全覆盖。任何未来的 AgentTemplate PTY 启动代码必须尊重 cc-agent-config
  SPEC 的 HIGH 级发现。

**建议：** 在建任一个之前，把分层一次性定清。最干净的调和：AgentTemplate
拥有按 agent 的 sandbox 指针（`claude_config_dir`）；cc-plugin 的
`sandbox_mode` 开关只是*默认*新 cc AgentTemplate 是否拿隔离目录。若按序
推进则不冲突 —— 但今天两者都未建，且两份 SPEC 各自独立声称
`CLAUDE_CONFIG_DIR` 机制。

---

## docs/notes 双语约定

`docs/notes/` 遵循 `<name>.md` + `<name>.zh_cn.md` 平行文件约定（如
`phase-8-deploy-notes.zh_cn.md`、`uri-design.zh_cn.md`）。本文件即本审计
的中文平行版，与英文版 `phase-7-implementation-audit-2026-05-22.md` 并存。
