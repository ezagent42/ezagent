# Handoff: Mindmap 产品助手 Agent（path B — 对话里智能改图 + 智能需求总结）

> **Date:** 2026-06-24 · **From:** Sy（df-tech 线）· **To:** Allen + 做 agent 配置 UI 的同事（human + cc/codex）
> **Tracking:** df-prd mindmap 片7 path B · **Base:** `origin/main` @ faf5979f（df-tech-yao-2026-06-23 分支已含片1–6+8+文件上传+确定性 GitHub worker）
> **Status:** brainstormed（两轮 skill-1 探查，证据见 §3）— path A 部分已落地+e2e；path B 卡 3 个实现缺口，需 Allen 决策

## 0. Mission
让一个**可配置角色/skill 的 cc agent**（LLM）当"mindmap 产品助手"：在对话里被 @ 后，**听人话改思维导图的各种数据**（认领/改状态/挂附件/改 stage/加节点）+ **智能总结祖先链文档**生成 PR 留言。地基（agent 身份持 cap 就能 dispatch 改图、owner=agent）已 diag 验证；**缺的是让 LLM agent 能调到 mindmap 动作的那层 MCP 工具 + 配套的 cap 授予/skill 解析**——这三段卡在 CI 上锁的工具集机制上，归 Allen。

## 1. Required reading（写代码前）
1. Skill **ezagent-developer** — 设计原则 P1–P26 + CI gate（必读，gate 你的 PR）。
2. Skill **ezagent-session-orchestrator** — agent/orchestrator 契约。
3. `docs/guide/world-coordination.md` — 本工作**碰 world**，必读。
4. **dev-together** skill — 本工作流 + handoff 标准。
5. 设计依据：`docs/superpowers/specs/2026-06-21-agent-contract-spec2-tools-participant.md`（Spec-2 工具/participant 契约——本 handoff 的核心依据）。
6. 已落地的 path A（参照实现）：`apps/ezagent_plugin_mindmap/`（Behavior.Mindmap 全 action）+ `apps/ezagent_plugin_world/lib/ezagent/world/mindmap_actions.ex`（world dispatch 层）。

## 2. Locked decisions（brainstorm 已定，别重开）
| # | Decision | Value |
|---|----------|-------|
| 1 | agent 编辑 = path B（LLM + MCP 工具），不是 path A 规则 | 用户要"听人话改各种数据"，规则 worker 做不到 |
| 2 | GitHub 同步闭环 = path A 确定性 worker，**已落地+e2e**，不归本 handoff | register_pr 出站需求摘要 + sync_prs 轮询 merged→done（faf5979f） |
| 3 | agent 改图走**现有 dispatch + CapBAC**，零特判 | 已 diag 验证：agent 持 claim_node/set_status cap → owner=agent 可改（§3） |
| 4 | 配 role/skill 用 **AgentTemplate** 机制（不发明新的） | `role` / `desired_skills` / `desired_caps` / `mcp_config_path` 字段已存在 |
| 5 | 智能需求总结 = LLM 综合（path B）；**确定性拼装版已落地** | `EzagentPluginMindmap.Ci.requirement_digest/2`（沿祖先链汇总文档） |

## 3. Architecture primer（给不熟代码的 dev）
**agent contract 已支持配角色/skill/工具**，机制 = AgentTemplate `:template` 切片：
- `role`（如 default/orchestrator，决定加载哪个 persona）— `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex:107`；cc 物理化在 `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:251`
- `desired_skills: [...]`（Claude Code skill 文件，置入 agent config_dir）— `agent_template.ex:84-93`
- `desired_caps: [...]`（CapBAC）— `agent_template.ex:84-91`
- `mcp_config_path`（MCP 工具集）— `agent_template.ex:68-71`
- @mention 路由已就绪：`$mentions`（mention-gated）— `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/default_rules.ex:15-26`；matcher `apps/ezagent_core/lib/ezagent/routing/matcher.ex:142-150`
- cc agent 收消息走 `Ezagent.Behavior.Agent.Receive` → AgentBridge（LLM）

**地基已验证**（fresh-boot diag，本线已跑）：agent 身份（仅持 `claim_node`+`set_status` cap）→ dispatch `claim_node` → `owner=entity://system/agent/worker1` → dispatch `set_status doing` 成功。即"agent 改图"在 dispatch+CapBAC 层**零代码即支持**，缺的只是让 LLM 能调到这些 dispatch 的工具层。

## 4. Design & phased plan
**目标形态**：一个 cc AgentTemplate `mindmap-assistant`（`role: "default"`，`desired_skills: ["mindmap-editor"]`，`desired_caps: [claim_node, set_status, attach_artifact, set_stage, add_node, …]`，`mcp_config_path` 指向一个 mindmap MCP server），@ 它即可对话改图。

**3 个必须先补的实现缺口（= Allen 决策点，见 §6）**：
- **P0 — mindmap MCP 工具**：让 cc agent 能调 mindmap 动作。Spec-2 设计了 `tools[]`（工具→`action=mindmap.xxx` dispatch + caps），但 **flavor.compile() 把 tools[] 物化成 MCP server 条目的代码没找到**（spec2-tools.md:15-16, 57-66）。要：定义 mindmap 工具 manifest + 实现 compile + 一个 MCP server（或复用现有 MCP 注入）。
- **P1 — desired_caps 真正授予的时机**：字段进了 template data，但**实际 grant 给 agent identity 切片的调用点找不到**（`agent_template.ex:84-91` 注释 "deferred to #533"）。要：在 spawn 后把 desired_caps grant 到 agent identity（否则 agent dispatch 改图会被 CapBAC 拒）。
- **P2 — skill 按名解析**：`desired_skills` 目前只有 orchestrator skill 硬编码 source（`cc_agent.ex:491-498`）。新的 `mindmap-editor` skill 怎么从名字找到文件——**没有通用注册表**。要：一个 skill name→source 解析（或约定 config_dir 下现成）。

**Phase 0**（discuss-first，Allen）：定 P0/P1/P2 的实现边界（工具集 compile 落在哪、cap grant 时机、skill 解析）。
**Phase 1**：实现 mindmap MCP 工具（manifest + compile + server），desired_caps grant。
**Phase 2**：写 `mindmap-editor` skill（SKILL.md：怎么用工具改图 + 怎么读祖先链做智能总结）。
**Phase 3**：建 `mindmap-assistant` AgentTemplate + spawn + @ 路由 + e2e。

## 5. Definition of Done（可演示产物）
- [ ] **agent-browser 截图/录屏**：在一个 session 里 @mindmap-assistant "把登录节点标记完成，并挂上 PR #5"，agent **真的改了图**（节点状态→done + PR 挂上），截图为证。
- [ ] **真渠道 transcript**：agent 在对话里回复 + mindmap 树刷新（不是 stub）。
- [ ] **智能总结演示**：@它 "给这个 PR 写产品需求总结" → 它读祖先链 → 出一段 LLM 综合的留言（对比确定性版 `requirement_digest`）。
- [ ] 全 gate 绿：arch.scan / doc.scan / uri_query.scan / check_invariants / format / test / :ezagent_plugin_check。
- [ ] 本工作的回归测试（agent dispatch mindmap 动作的 CapBAC 测试 + 工具 manifest 测试）。

## 6. Discuss-first vs Deferred
**Discuss-first（建前必须 Allen 确认）**：P0 工具集 compile 机制、P1 desired_caps grant 时机、P2 skill 解析——**全部碰 CapBAC + core 工具集 + CI 上锁的工具机制**，命中多条 discuss-first 触发器（CapBAC / core / 跨切面不变式 / 未验证假设）。
**Deferred（已标，有目标）**：token 级流式回复、富编辑器、多 agent 协作编排——后续 phase。
**Never deferred**：P0/P1/P2 三个 load-bearing 决策本身、gate、需人协助的 Allen 决策（已显式标，不绕过）。

## 7. Conflict-avoidance
- 本工作主要碰 `apps/ezagent_domain_agent`（AgentTemplate/spawn）、`apps/ezagent_plugin_cc`（flavor compile/tools）、新建 mindmap MCP 工具，**少量碰 world**（@ 路由 + 可能的 mindmap 工具 endpoint）。
- 碰 world → 读 `docs/guide/world-coordination.md` + 在其 in-flight registry 加一行。
- **不碰** df-tech 线已落地的 `mindmap_actions.ex` / `Behavior.Mindmap`（path A 已稳，agent 复用其 dispatch action，不改它）。

## 8. Merge model
所有 PR 并入任务分支（不是 `main`）；保持 rebase on `main`；DoD 满足后由 lead 合并任务分支→`main`。

## 9. Gates, 文件/LOC 估计, open questions
- **新文件**（估）：mindmap 工具 manifest（~80 LOC）、flavor compile 扩展（~120）、mindmap MCP server 或注入（~150）、desired_caps grant（~60）、skill 解析（~60）、`mindmap-editor` SKILL.md（文档）、`mindmap-assistant` AgentTemplate seed（~50）。
- **Open questions for Allen**：
  1. mindmap 工具走 MCP server（独立进程）还是 dispatch-注入（agent ctx 直接能 dispatch）？Spec-2 倾向哪个？
  2. desired_caps grant 是 #533 的范围还是本工作补？grant 落在 spawn 的哪一步？
  3. skill 要不要全局注册表，还是约定 `desired_skills` 必须在 config_dir 现成？
  4. 智能总结要不要也做成一个工具（agent 调"读祖先链"工具拿数据再总结），还是把 `requirement_digest` 的结构化输出喂给 agent？

---
**已落地的相邻能力（agent 可直接站在上面）**：片1–6+8（9阶段链/R1.1/attachment/gate软门/CI评价/GitHub出站）、文件上传、**确定性 GitHub PR 闭环 worker**（register_pr 需求摘要留言 + sync_prs 轮询 merged→done）、`Ci.requirement_digest/2`（确定性需求汇总，agent 的智能总结可对照/复用）。全部真浏览器 e2e + 截图存 `docs/superpowers/evidence/assets/`。
