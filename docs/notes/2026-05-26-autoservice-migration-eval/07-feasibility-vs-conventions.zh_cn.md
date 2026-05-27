# cinnox 方案可行性 vs ezagent 约定 review（2026-05-27）

> 针对 [05-cinnox-implementation-plan](05-cinnox-implementation-plan.zh_cn.md) 的逐项约定检查，重点 M0，附 M1-M3 plan drift 修正。
>
> 检查依据：`.claude/skills/ezagent-developer/references/architecture-invariants.md`（17 不变式）+ `references/design-principles.md`（P1-P27）+ `references/anti-patterns.md`。
>
> **2026-05-27 updates**：
>
> 1. **同团队纠正**：AutoService 和 ezagent 是同团队两项目（[README 术语澄清](README.zh_cn.md#术语澄清2026-05-27-补含同团队纠正)）。所有"等 ezagent team"、"AutoService 迁移团队完全控制不了节奏"原表述是**错误框架**——同团队内部 Allen brainstorm + 排期，没有跨团队协商成本。文中相关段落已重写。
> 2. **B1=Path B 决议**：暂定走 Path B（EagerBridge plugin 原语），不走 Path C。本 doc §1 Path C 段落**保留作未来 fallback 参考**（若 EagerBridge 出现在多个 inbound plugin → anti-pattern 重出 → 届时再考虑 Path C）。

---

## 1. M0 逐项可行性 + 约定检查

### B1 — bridge handshake (Path B vs Path C)

#### Path B（plugin 层 `EzagentPluginCc.EagerBridge.ensure_bound!/2` 原语）

- **不破坏约定**。新增 plugin-internal helper，没动 dispatch / Kind / URI 任何边界
- ✅ P12 Adapter pattern：bridge 握手是 cc 协议的细节，留在 plugin 内合理
- ✅ P22 reliability primitives：plugin 自己 retry / fail-loudly 是 plugin tier 责任
- ⚠️ **隐性风险**：plugin 内的 `EagerBridge` 实际上是给"cc 必须 operator-bound"这个**结构假设**打补丁。如果将来又有第二个 inbound 通道需要这套，会有第二个 `EagerBridge` copy — 容易演变成 anti-pattern "ad-hoc reliability per plugin"
- **判定**：可行，但是治标。

#### Path C（新 cc-sdk-flavor agent，走 `claude_agent_sdk` stdio JSON）

| 检查项 | 结论 |
|---|---|
| 新增 agent flavor = 新 plugin（`ezagent_plugin_cc_sdk`） | ✅ 不变式 #11 6-scheme 不变；URI 仍是 `entity://agent/<ws>/<name>` |
| Adapter pattern P12 | ✅ cc-sdk 是 claude-agent-sdk protocol 的 adapter，跟现有 cc plugin（claude CLI + PTY 的 adapter）是兄弟，**不是替换** |
| 跟现有 `Ezagent.Behavior.Chat` 的兼容性 | ⚠️ **真问题**。`chat.ex:522-549` 做 `BridgeRegistry.lookup`；cc-sdk flavor 没有 PTY 也没有 bridge。要么 cc-sdk plugin 注册到 BridgeRegistry（语义牵强 — 没有 PTY 哪来 bridge），要么 Chat Behavior 加 flavor 分发（**Behavior 不应该懂 plugin 内部** — 违反 P12/P13） |
| 工程量 | eval 04 §3 估的 "600-1000 行 control protocol 重写" **不适用**于 Path C — `claude_agent_sdk` 是 Python 库，直接拿来用就行，不用重写协议。**真实工程量**：Python sidecar 包装 + ezagent 端 plugin（300-500 行）。**但** Chat Behavior 兼容性是单独的 ~100-200 行 + brainstorm |
| 是否要 Allen review | **是**。Chat Behavior 加 flavor 分发是核心域的修改，必须走 brainstorm |

**判定**：Path C 不破坏 invariant，但**触及核心域**（`Ezagent.Behavior.Chat` 必须调整），不是纯 plugin 层工作。原计划 M0 把它写成"等 ezagent team 决议"是**错误框架**——AutoService 和 ezagent 是同团队两个项目（见 [README 术语澄清](README.zh_cn.md#术语澄清2026-05-27-补含同团队纠正)），所谓"等"实际是**同团队内 Allen brainstorm + 排期**。真实工程量：Allen brainstorm（~3-5 天）+ Chat Behavior 改 ~100-200 行 + plugin 新建 300-500 行 ≈ **2-3 周同团队内部串行**（不是跨团队 4-6 周等待）。

---

### B2 — capability `{:within_workspace, _}` 形状

| 检查项 | 结论 |
|---|---|
| 加新 cap shape 到 `Ezagent.Capability` | ⚠️ **触及核心模块**，不是 plugin tier |
| P15 narrow-never-broaden | ✅ `{:within_workspace, _}` 比 `:any` 窄，比 `{:within_session, _}` 宽，**在合法的 narrow 范围内**。不违反 |
| 不变式 #5 scope-bounded delegation caps narrow, never broaden | ✅ 同上 |
| anti-pattern "admin_caps() bypass" / `:any` cap | ✅ workspace cap 正是为了**避免**给 tenant_admin 发 `:any`，是合规方向 |
| 需要 Allen review | **是**。所有 cap shape 改动必须 Allen review + 新 invariant test |
| 工程量 | 实际改动小（Capability 模块 + 一组 invariant tests）但**brainstorm + Allen 时间不可控**，2-6 周 |

**判定**：**不破坏约定**，但绕不开 Allen brainstorm + invariant test 添加（同团队内部，~1-2 周工作量）。M1/M2 阶段策略上**不依赖此 cap**（admin portal 留在 AutoService 时不需要 tenant_admin cap）—— 推到 M3+ 或第二个测试租户立项时再做，给 Allen 留充裕设计时间。05 plan 已经隐式这么处理了，但应该**显式标注**。

---

### B3 — ezagent issues #392/393/395/396

| issue | 类型 | 约定相关 |
|---|---|---|
| #392 empty env var bug | 纯 bug | 无 |
| #393 cap-grant parser mismatch | 纯 bug，但**是 cap 系统的 bug** — 修复时要注意保持 P15 invariant test 通过 | 间接 |
| #395 dispatch no lazy-spawn | **设计决策**：dispatch 默认不 lazy-spawn 是当前约定（`SpawnRegistry.spawn` 显式 spawn），改成 lazy-spawn 会**改 P14 dispatch 语义** | ⚠️ 这条**可能触及不变式 #1 dispatch is the only path** — lazy-spawn 让 dispatch 同时承担 spawn 责任，逻辑边界变模糊 |
| #396 cc onboarding UX | 纯 UX | 无 |

**判定**：#395 需要关注。如果团队（Allen 主导）决议 "dispatch 增加 lazy-spawn"，是个**语义扩展**，必须走 Decision Log + brainstorm。**cinnox 方案对这条不应该依赖**（M1 应该显式 spawn cc agent，不靠 lazy-spawn）—— 这样 #395 修不修都不影响 M1 进度。

---

### B4 — per-conv session URI 约定

| 检查项 | 结论 |
|---|---|
| URI shape `session://default/cinnox/<conv_id>` | ✅ 不变式 #11 3-segment authority for per-tenant scheme：`default/cinnox/<conv_id>` = 3 segment，合规 |
| 加新 scheme？ | ❌ 不加，6-scheme allowlist 不变 |
| 是否改 session Kind 语义 | ⚠️ **是个隐性变更**。PR §2 实测发现 `session://` 现在是"group-chat container"。约定改成"per-customer 1:1"是**语义重定义**，不是结构变更 |
| 需要 Allen review？ | **建议**：不必走 brainstorm，但 GLOSSARY.md "session" 条目应更新："session 是 per-conversation 容器（之前文档暗含的 group-chat 用法是误用）" |

**判定**：**不破坏约定**，是"未明文的约定**澄清**"。05 plan §M1 应该补一条 deliverable："更新 GLOSSARY.md session 条目"。

---

## 2. M0 整体判定

| 项 | 破坏约定？ | 触及核心？ | Allen 必看？ | M0 同团队工作量（含 brainstorm） |
|---|---|---|---|---|
| B1 Path B | 否 | 否（plugin 层） | 否 | ~1 周（plugin 内 helper） |
| B1 Path C | 否 | **是**（Chat Behavior） | **是** | ~2-3 周（brainstorm 3-5 天 + 改 ~100-200 行 + 新 plugin 300-500 行） |
| B2 within_workspace cap | 否 | **是**（Capability 模块） | **是** | ~1-2 周；**M1/M2 不依赖，推到 M3+ 启动**给 Allen 留充裕设计时间 |
| B3 #395 lazy-spawn | **可能**（dispatch 语义） | **是** | **是** | **方案不依赖此修复**；并行修复不阻塞 |
| B4 per-conv session | 否（是澄清） | 否 | 否（GLOSSARY 更新） | <1 天 |

**结论**：M0 **没有一条真正破坏 ezagent invariant 或 design principle**，3 条（B1-Path-C / B2 / B3-#395）**触及核心模块 + 必须走 Allen brainstorm**。早期分析框架"AutoService 迁移团队完全控制不了节奏 / 等 ezagent team 2-6 周"是**错误**——AutoService 和 ezagent 是同团队两项目（[README 术语澄清](README.zh_cn.md#术语澄清2026-05-27-补含同团队纠正)），没有跨团队协商成本。

**真实 M0 同团队工作量**（含 brainstorm 实质工作时间）：

- B1 Path C 串行：~2-3 周
- B2 推到 M3+ 不阻塞 M0
- B3 #395 不依赖
- **M0 关键路径 ≈ 2-3 周**（同团队 1 dev focus 时间，含 Allen brainstorm 实质工作；不是 6-12 周跨团队等待）

唯一无法压缩的是 Allen brainstorm 的**认知工作时间**——架构决议要想清楚，不会因为同团队就缩短。但**调度延迟**（meeting 排不进 / 跨 team 邮件回合）这部分消失了。

---

## 3. M1-M3 plan drift（review 中发现的 5 处偏移）

按严重度排：

### 3.1 HIGH — SessionOrchestrator 应该是 Session Kind 的 slice，不是独立 GenServer

05 plan §M3 写："新 GenServer `Ezagent.Domain.Chat.SessionOrchestrator` per session"。

- ezagent 约定：state per session-URI 由 Session Kind 持有（P3 KindRegistry 是 URI→pid 的权威 SoT）
- 独立 GenServer 会变成第二个状态源 — 重启恢复 / snapshot / cap-check chokepoint 全都两份
- **正确做法**：fast/cc phase / deepseek_failure_count / fast_ack_disabled? 全部进 Session Kind 的 chat slice 字段（snapshot-on-change，P22）
- **修正**：[01-infra-perspective §4](01-infra-perspective.zh_cn.md) 写的就是 slice 形式，05 plan §M3 这一行**自己跟自己的 eval 不一致**

### 3.2 HIGH — OutputFilter 在错的 tier

05 plan §M2 写："新 Behavior `Ezagent.Behavior.Chat.OutputFilter`"，把 preamble strip / DIRECT_TRANSFER detect / `[线索]` split 都塞进去。

- 这 3 个都是 **cinnox-specific** 或 **AutoService-framework-specific** 行为
- 放进 `Ezagent.Behavior.Chat.*` = core domain 层 — 违反 P9（reads what data 决定 tier ownership）+ P12
- **正确做法**：分两个 plugin
  - `ezagent_plugin_autoservice_filters`（preamble strip — framework 级，多租户共用）
  - `ezagent_plugin_cinnox`（DIRECT_TRANSFER 字面量 detect、`[线索]` wire format — cinnox 特定）
- 输出 pipeline 走 ExternalMirror Adapter pattern 的 `event_to_payload/1` 做 transform，**不是** Chat Behavior 子类

### 3.3 MEDIUM — SoulComposer 输出落盘是 ezagent persistence 盲区

05 plan §M2 写："SoulComposer.compose(...) → 写出合成文件 → cc Template `soul_path` 指向"。

- "写出合成文件" 是文件系统写，**没进 ezagent persistence**
- 不变式 #14 要求 per-tenant 数据 `workspace_uri NOT NULL`；散落文件**绕过这个约束**
- GDPR delete / snapshot / backup 都不知道这些文件
- **正确做法**：合成结果是个 Resource Kind 实例，存进 `kind_snapshots` 表（已经有 workspace_uri 列），cc Template 的 `soul_path` 改成 `soul_uri` 指向这个 resource
- 简化版（M2 早期可接受）：合成结果存在 `.autoservice/data/tenants/cinnox/_compiled/soul.md` 文件，但**显式标 TODO**：M3+ 改成 Resource Kind

### 3.4 MEDIUM — KB sidecar 协议错配

05 plan §M1 写："Python sidecar via erlexec... cc plugin `--mcp-config` 加 `autoservice_kb` server"。

- ezagent 现有 `ezagent_domain_python/server.ex` (699 行) 跑的是 **JSON-RPC sidecar**
- AutoService `kb_mcp_server.py` 跑的是 **MCP stdio 协议**
- 两个协议不通 — 不能直接复用 `ezagent_domain_python`
- 3 个选项：
  - **(a)** cc CLI 的 `--mcp-config` 直接指向 Python 脚本，**绕开 ezagent_domain_python** — 简单但 cc CLI 直接 spawn 一个 ezagent 不管的子进程，BEAM crash 时 orphan
  - **(b)** `ezagent_domain_python` 扩展支持 MCP 协议 — 工程量
  - **(c)** 写一个 MCP↔JSON-RPC shim — 工程量
- **(a) 是 M1 现实选择**，但要在 docs 标注 "KB MCP server 不在 BEAM 监督树下，依赖 cc CLI 自己管"

### 3.5 LOW — filler 的 `Notifications.notify` cap 来源未定义

05 plan §M3 写：FillerLoop 通过 `Notifications.notify` 推 filler。

- `Notifications.notify` 是 cap-gated（`:notify` cap）
- Session Kind 自己 emit filler 时，**caller 是谁**？session 自己？还是 `system://chat-router`？
- 这个 cap 不能预先存在 session slice — 否则 session 永远能 spam 任何 user inbox
- **正确做法**：filler 通过 ExternalMirror Publisher event stream emit（`%Event{kind: :filler}`）—— 不走 Notifications.notify，而走已有的 outbound mirror 路径，cap-gating 由 ExternalMirror Adapter 的 `cap_subject/0` 处理

---

## 4. 修正清单（已对 05 plan 执行 patch — 见 git diff）

| # | 位置 | 修正 |
|---|---|---|
| 1 | 05 §M0 B1 表 | (a) Path C 工程周补正同团队 ~2-3 周（不是跨团队 6-12 周）；(b) **2026-05-27 决议**：B1=Path B EagerBridge plugin 原语（~1 周），Path C 保留 fallback |
| 2 | 05 §M0 新增 B5 | "GLOSSARY.md 'session' 条目澄清为 per-conversation 容器" |
| 3 | 05 §M0 B3 新增脚注 | "M1 workspace boot 显式 spawn cs_main agent，不依赖 #395 lazy-spawn 修复" |
| 4 | 05 §M1 KB MCP 行 | "1 周 spike" → "1.5-3 周 spike 含协议选型（3 个选项见 07 §3.4）" + 标注 "BEAM 不管该子进程" |
| 5 | 05 §M2 SoulComposer 行 | 加 TODO "M3+ 改 Resource Kind 进 kind_snapshots，M2 阶段先写文件可接受" |
| 6 | 05 §M2 preamble strip / DIRECT_TRANSFER / [线索] 三行 | tier 全部改 plugin 层（`ezagent_plugin_autoservice_filters` + `ezagent_plugin_cinnox`），**不**塞进 `Ezagent.Behavior.Chat.*` |
| 7 | 05 §M3 fast/cc 双相位行 | 删 "新 GenServer `SessionOrchestrator`" → 改 "Session Kind chat slice 新增字段 phase / deepseek_failure_count / fast_ack_disabled?" |
| 8 | 05 §M3 FillerLoop 行 | "Notifications.notify" → "ExternalMirror Publisher `%Event{kind: :filler}`"，cap 由 Publisher Adapter `cap_subject/0` 持有 |
| 9 | 05 §M3 prewarm 行 | 把 B1 Path C 加 Chat Behavior 改造的 2-3 周同团队内部排期写明（不是外部依赖） |

---

## 5. 总结

**M0 没破坏约定**：
- 4 个 sub-task 都在 ezagent 现有 invariant + design principle 框架内
- 没有任何一项需要新建 URI scheme / 改 dispatch 单一路径 / 引入新 cap shape 之外的 bypass

**M0 真实成本**（同团队前提下重估）：
- B1 Path C + B2 + B3-#395 三件事都触及 ezagent 核心模块且必须 Allen brainstorm
- **关键路径 ≈ 2-3 周**（B1 Path C 串行 + B2 推到 M3+ 不阻塞）
- 时间成本来自 Allen 架构决议的**认知工作**，**不是跨团队协商**（同团队两项目，无协商成本）
- 早期 doc 的"6-12 周等待 / 完全控制不了节奏"是基于跨团队假设，错误，已纠正

**M1-M3 有 5 处 plan drift 需要修正**：
- 2 处 HIGH（SessionOrchestrator tier、OutputFilter tier）违反 P9/P12/P22，必须改
- 3 处 MEDIUM/LOW 是 reliability / persistence 层面 leak，应改

**所有修正已 patch 到 05 plan**（见 git diff）。

**下一步建议**（覆盖 [06 §7](06-plan-review-comparison.zh_cn.md) 的 6 步基础上）：

7. **Allen 主持 bridge meeting**（同团队内部 brainstorm，不是跨团队邮件）：决 B1 Path B vs Path C；若 Path C，定 Chat Behavior 兼容性改造的内部排期；B2 within_workspace 是否跟 Path C 在同一 brainstorm 串决（如有上下文耦合）还是分开
8. **M2 SoulComposer 简化版可以先用文件**，但 M3 改 Resource Kind 的 ticket 现在就开
9. **OutputFilter 拆 plugin 的工作**应该跟 M2 同时启动，不要等 M2 后期发现 tier 错了再返工
