# 三方案对比 review：原 eval / PR #297 / cinnox 落地方案（2026-05-27）

> 对照 [00-synthesis](00-synthesis.zh_cn.md)（4 视角 eval）、[PR #297](https://github.com/ezagent42/AutoService/pull/297) 的 PoC verdict、和 [05-cinnox-implementation-plan](05-cinnox-implementation-plan.zh_cn.md) 当前阶段性方案，分析三者的覆盖、矛盾、当前方案的优缺点和未被回答的问题。

---

## 1. 三方案画像

| | 方案 A (eval) | 方案 B (PR #297) | 方案 C (cinnox 落地) |
|---|---|---|---|
| **日期** | 2026-05-26 | 2026-05-27（合并前） | 2026-05-27（基于 A+B） |
| **形式** | 4 视角并发 subagent 纸上分析 | 7 PoC worktree 实测 verdict | 4 milestone 排期 + 验收 |
| **核心问题** | "该不该迁、怎么迁" | "在 ezagent 上跑 1 条 message 该选什么基元" | "cinnox 怎么在 ezagent 上跑起来" |
| **范围** | 全栈（infra + biz + perf + critical） | 仅 transport + identity 层 | cinnox 全链路（无 voice / admin portal） |
| **决断度** | 中（推荐 hybrid + P0） | 高（A1 / C3 / per-conv 已选） | 高（M0-M4 排期 + 验收清单） |
| **可执行性** | 低（没 ticket） | 中（每 verdict 有 reviewer entry） | 高（推荐起手三件事下周就能做） |
| **风险揭露** | 全面但 abstract | 实测的窄但深 | 集成 A+B 但加了几条新的 |

---

## 2. 三方案如何递进

**方案 A → 方案 B**：A 是 abstract recommendation（"声明性 prewarm via agent_slots"），B 用实测把这个推翻（"bridge 不 eager-spawn，prewarm 是 no-op"）。A 提供了 mental model 让 B 知道哪些点要测；B 提供了 ground truth 让 A 的推荐能 reality-check。

**方案 B → 方案 C**：B 把 transport 层选好了（A1 + C3 + per-conv），但是 cinnox 上线不仅是 transport — 还要 4 层 soul 合成、preamble strip、DIRECT_TRANSFER detect、`[线索]` 出口、KB 挂载、UX 优化。C 在 B 的基础上**补齐了业务正确性 + UX 拉齐两层**，并把"哪些不做"（voice / admin portal / tier upgrade / cross-layer lint）写明，hybrid 边界**第一次具体化**。

**方案 A → 方案 C**：A 推荐"混合方案 + P0 优化"，C 实质采纳了这个建议（M0 边界 + M3 落地 P0 五项），但**没显式记录退出条件**（"如果 M2 ROI 不够就停"这种）。

---

## 3. 当前方案 C 的优点

1. **目标具体到一个租户**：从抽象的 "AutoService → ezagent" 收窄到 "cinnox 能跑起来" — 这是工程上能 grok 的范围，避免"全迁是一座山"的瘫痪。
2. **排期分层**：M1（能通）/ M2（业务对）/ M3（UX 平）— **强制把"功能完整性"和"感知质量"分到两个 milestone**，避免"全做完才能上"的死循环。
3. **每个 milestone 有验收**：M1 = 2 客户不串台 + KB 真返回；M2 = 影子流量功能等价；M3 = 感知延迟 p50/p95 不退化。验收都是**可测的事实**，不是 "看起来 OK"。
4. **明确边界**：voice / admin portal / Dream 显式 out-of-scope，hybrid 不是含糊的"两边各跑一些"而是**按子系统**分（admin 在 Python 编辑，文件落到 ezagent 读的目录）。
5. **集成 A+B 关键发现**：per-conv session 用 B 的强证据、A1 soul template arg 直接采纳、KB sidecar 走 A 的混合方案、prewarm 推到 M3 是因为 B 发现 prewarm 没解决前是 no-op。
6. **起手三件事可操作**：调用链图 / bridge meeting / KB sidecar spike — 都是 1 周内能做完的、能解锁 M1 ticket 拆分的具体动作。
7. **诚实标注未知**：M0 Allen brainstorm 工作量、KB sidecar 协议选型不确定性等。（**注**：早期写的 "不在 AutoService 迁移团队控制内 / 等待 2-6 周" 是错误框架——同团队内部排期，已在 [07 §2](07-feasibility-vs-conventions.zh_cn.md#2-m0-整体判定) 纠正为 ~2-3 周关键路径）

---

## 4. 当前方案 C 的缺点 / 风险

按严重度排：

### 4.1 HIGH — 没量化"验证成果"指标 / 退出条件

（**框架纠正**：cinnox 是 h2oslabs 用于**验证迁移方案**的测试载体，不是"被服务的新客户" — 见 [README 术语澄清](README.zh_cn.md#术语澄清2026-05-27-补)。所以 ROI 不是问"cinnox 上线获得什么"，而是问"用 cinnox 跑一遍验证了什么、retire 了什么风险、为下一个租户解锁了什么"）。

M1+M2 7-10 周做出来 cinnox 在 ezagent 上跑通，**验证成果指标是什么没说**：

- **结构性 invariant 验证**：workspace_uri NOT NULL / cross-workspace deny / per-conv session / CapBAC chokepoint 是否在真实 cinnox 数据形态下成立？
- **协议层假设验证**：A1 soul Template arg / C3 SSE / per-conv URI / OutputFilter plugin pipeline 在跑真流量后是否稳？
- **风险 retire 列表**：跑通 cinnox 后，第二个租户上线时**哪些工作不用再做**（结构性的）、**哪些必须重新评估**（cinnox-specific 没暴露的）？
- **AutoService 包袱量化**：哪些 Python 代码因迁移可以删（cc_pool / Pipeline v2 / 等）？保留的 Python sidecar（KB / voice / admin）占总 LOC 多少？
- **运维实测差异**：BEAM observer 排查能力 vs `grep gateway.log` 的实际场景对比

**退出条件**：

- **M1 go/no-go**：能不能并发不串台（PR §2 强证据回归） — 不通则同团队内部回滚到 PR PoC 重新验证
- **M2 go/no-go**：影子流量功能等价率 <X% 或 cinnox 真实流量场景**暴露 invariant 不适用**（如 KB 大数据量下 sidecar 不稳） → 停 M3，回 AutoService 维护现状
- **M3 go/no-go**：感知延迟回归 >Y% 且无收敛路径 → 接受 ezagent 不适合此 workload，沉淀经验文档

**建议补到 05 plan §1 总览表**：在每个 milestone 列加"验证目标"和"go/no-go 阈值"两栏。

**特别提醒**：cinnox 作为测试载体的特殊性 — cinnox 现网用户是**真人在等**，影子模式必须严格 dry-run 不产生 lead / 不触发 DIRECT_TRANSFER / 不计费；M3 切流必须可秒级回退。这条 risk profile 跟"内部 PoC 环境"完全不同（详见 §4.3）。

### 4.2 HIGH — Hybrid 边界的**文件同步机制 fuzzy**

C §7 说："admin 仍在 Python 那边编辑 soul/KB，文件落盘到 ezagent 能读到的目录（共享 mount 或 git push 后 ezagent 端 pull）" — **这是个隐含的分布式系统问题**：

- 共享 mount：两个进程同时写 KB sqlite 怎么办？
- git push + pull：admin save 到生产生效有多少延迟？谁触发 ezagent 端 pull？failure mode？
- soul 文件改了后 ezagent 端 cc agent 怎么知道要重建？（A1 verdict 说 soul 是 spawn-time burned）

**当前 AutoService 是 `make stop && make start` 解决这个**。迁到 ezagent 后这个**重启信号怎么传过来没设计**。

**建议补**：M2 spec 加一节"admin → ezagent 内容同步协议"。

### 4.3 HIGH — M2 影子流量对比测试本身是个不小工程

"同一条客户消息 send to AutoService（生产）+ ezagent（影子），对比 cc reply 应该功能等价" — 听起来轻巧，实际：
- 客户请求怎么 mirror 到两端？（需要 gateway 改造）
- "功能等价"怎么自动判定？LLM-as-judge？还是人工 case-by-case？
- 影子端不能产 lead 不能 DIRECT_TRANSFER（污染生产数据）— 需要 dry-run 模式
- 影子流量的 latency / cost 不会反映真实 — 因为没有真客户在等

**没把这个测试基础设施算进工程周**。1 个 dev 单独做这一块可能 2-3 周。

### 4.4 MEDIUM — M2 影子对比偏向 AutoService

M2 验收时**ezagent 端还没 fast ack / filler**（M3 才上），但**AutoService 端有**。影子对比时 ezagent 的 reply 会**显著慢于** AutoService — 这会让 M2 "完成"的判定失真，容易低估 M2 结果（实际功能正确但被延迟拖累）。

**建议补**：M2 验收明确"只对比 functional equivalence，延迟比较留 M3"，或者 M2 末期临时 hack 一个静态 ack（不接 deepseek）让客户端首帧出现避免完全空白。

### 4.5 MEDIUM — KB sidecar 风险被低估

C §M1 估 "1 周 spike"。实际：
- AutoService `kb_mcp_server.py` 是 stdio MCP 协议，**不是** `ezagent_domain_python/server.ex` (699 行) 处理的 JSON-RPC sidecar 协议
- cc agent 的 `--mcp-config` 期望 MCP server 直接接 stdio，sidecar 加在 erlexec 下面要看 erlexec 透传 stdin/stdout 行为是否对齐 MCP 协议
- KB 的 PDF/XLSX 入库 pipeline（`kb_core.py`）是 admin-time 的，迁不迁这一波要不要决定

**真实工程量**：1.5-3 周 spike，且可能发现需要把 KB sidecar 重新打包成符合 ezagent_domain_python 模式。

### 4.6 MEDIUM — M0 B1 (bridge) 解决前 prewarm + M3 都不能跑

C §M3 prewarm 一栏说"取决于 M0 B1 决议"。如果 B1 决议是 **Path C（新 cc-sdk-flavor agent）**，工程量是 ~300-500 行 plugin + 100-200 行 Chat Behavior 改造（[07 §1 修正](07-feasibility-vs-conventions.zh_cn.md#path-c-新-cc-sdk-flavor-agent走-claude_agent_sdk-stdio-json)；早期 eval 04 §3 估的 "600-1000 行 control protocol 重写"针对的是无 SDK 复用的硬场景，Path C 复用 Python `claude_agent_sdk` 不适用此数）。

**重要框架纠正**：同团队两项目，**没有"等 ezagent core team"的跨团队成本**——是同团队内部串行排期。Path C 的 ~2-3 周是 Allen brainstorm + 实施的**认知工作时间**，已在 [07 §2](07-feasibility-vs-conventions.zh_cn.md#2-m0-整体判定) 重估。

**建议补**：在 M0 加一个分叉 — "若 Path C，M0 关键路径含 plugin + Chat Behavior 改造 ~2-3 周（同团队内部排期，含 brainstorm 实质时间）"。

### 4.7 MEDIUM — 没考虑 cinnox 当前 active session 的迁移

cinnox 现网应该有正在进行的客户对话（multi-turn）。切流时：
- 是只切**新 session**，老 session 在 AutoService 跑完？
- 还是把 conversation history 也迁过去？
- ezagent `MessageStore` schema vs AutoService transcript 格式不一样

C 没说。建议至少明确"M3 切流策略 = 只切新 session"，老 session 灰度自然衰减。

### 4.8 LOW — `conv_id` 兼容性

C §M1 "conv_id 客户端生成 UUID"。AutoService 现在 conv_id 是什么生成的？（看了一下应该是 cookie 派生 + 后端给）— 如果 ezagent 用客户端 UUID 但 AutoService 是后端给，影子流量对比时怎么对齐两端的 conv_id？

### 4.9 LOW — 团队容量 / wall-clock 时间

C 给的工程周都是 "1 dev"。但实际（**同团队两项目**框架下重估）：

- AutoService 和 ezagent 是同团队 — 同一批人同时承担两个项目。M0 同团队 brainstorm + 实施 ~2-3 周，但 **dev 的注意力还要分给 AutoService 主线开发**（修 bug / 加 feature） — 这是**容量竞争**，不是跨团队等待
- M0 关键路径 ~2-3 周，M1+M2 工程周 ~7-10 周；**1 dev 全职 + Allen 兼职 review** 的乐观估算
- 加上：cinnox 真实流量风险（影子模式 dry-run 设计本身有工程量）、KB sidecar 协议选型不确定性、Pipeline v2 OTP 重写复杂度

**总 wall-clock**：

- **乐观**（专职 1 dev + Allen review 优先级高）：M0+M1+M2 = 12-15 周（~3-4 个月）
- **现实**（dev 容量分摊 + AutoService 主线优先级竞争）：~5-7 个月
- **总 cinnox 在 ezagent 跑 + UX 拉齐到 A/B 切流（含 M3）**：现实历时 6-9 个月

**没在文档里说清这个 wall-clock 估算**，容易被读者误解为 3-5 个月就能 A/B 切流。**早期写的"不算 ezagent team 等待时间"是错误前提**——同团队没有等待时间，只有 Allen brainstorm 认知工作 + dev 容量分配。

---

## 5. 三方案的矛盾 / 未解决问题

### 5.1 矛盾：方案 A 推荐"声明性 prewarm" vs 方案 B 实测"prewarm 在 ezagent 当前模型下做不到"

C 把这个矛盾用"取决于 M0 B1 决议"圆了过去，但**没把 eval 03 文档里的 prewarm naive 立场标 stale**。

**建议**：编辑 [03-perf-ux-perspective.zh_cn.md](03-perf-ux-perspective.zh_cn.md) §4 加一条 caveat："2026-05-27 update: PR #297 §4 实测 cc bridge 不 eager-spawn，本节方案在 M0 B1 解决前是 no-op。"

### 5.2 矛盾：方案 A 推荐"A2 soul Behavior+Slice 更对齐 CR 流程" vs 方案 B 实测 "A2 dispatch 接口有 hidden respawn cost，A1 更honest"

A 没明确推荐 A2，但隐含偏向（cleaner dispatch）。B 拒绝了 A2 选 A1。C 跟 B 选 A1，正确。

**建议**：编辑 [02-business-perspective.zh_cn.md](02-business-perspective.zh_cn.md) §1 加 caveat："PR #297 EXP-A 实测 A2 在 OS-process boundary 有 hidden respawn cost，dispatch 接口暗示的 mutability 是 illusory；soul 应作为 spawn-time 烧死的 Template arg（A1），不要 Behavior+Slice 化。"

### 5.3 未解决：cinnox 端的 admin portal 仍在 Python，ezagent 端怎么不"绕过"它

如果 cinnox 上线 ezagent 后，AutoService admin portal 还在改 soul/KB，**两边的真相源是什么**？
- 真相源在 AutoService 文件树 → ezagent 是只读 mirror → 等于 ezagent 是 AutoService 的"渲染前端"，业务大脑还在 Python
- 真相源在 ezagent → admin portal 要 RPC 调 ezagent 写数据 → 但 admin portal 本身 React + FastAPI，做这个 RPC 是新工程

C §7 用"hybrid 方案的具体落地点"一笔带过 — **这是 hybrid 方案最大的隐藏成本**，应该单独立项澄清。

### 5.4 未解决：cinnox 作为测试载体的"代表性"边界

（**框架重述**：cinnox 是 h2oslabs 用于**验证迁移方案**的测试载体，**本来就是单租户**测试场景。本节问题不是"单租户没价值"，而是"cinnox 这个具体租户能代表 h2oslabs 其它租户多少？"）

eval 02 + 04 反复强调"ezagent workspace 隔离 + CapBAC 是真本事"。**cinnox 作为单租户载体跑通 ≠ 证明 workspace 隔离在多租户压力下成立** — 当前阶段验证的是"协议/Kind/dispatch 在真流量下不破"，**workspace 隔离 / cross-workspace deny / `{:within_workspace, _}` cap 这些核心收益只有第二个租户落地后才能验证**。

cinnox 代表性的具体限制：

- cinnox 当前没有 L1 / L2 自定义 skill（autoservice-overview §4.3）→ 4 层 soul 合成的复杂度**没被 cinnox 真实数据压**，只是"配置成 4 层但实际只用 L0+L3"
- cinnox 走 CINNOX 字面量 DIRECT_TRANSFER 是特定 wire format → 第二个租户可能用不同 directive，OutputFilter plugin 设计的可扩展性**未被 cinnox 验证**
- cinnox KB 是 OneSyn PDF/XLSX → KB sidecar 性能在 cinnox 大小下可能 OK，但**其它租户 KB 形态**未必同（短 chunk 多 / 大文件少 / 多语言）

**建议补 05 plan §0 范围边界**：

- 明确 cinnox 是**第一个测试载体**，不是产品上线
- M2 验收报告必须包含 "cinnox 代表性局限" 一节，列出哪些 invariant 跑通**只能证明 cinnox-fits**、哪些**可推广**
- M1+M2 完成后立刻启动**第二个租户的 RFC**（不必立刻迁，但要确认下一个候选 + 跟 cinnox 差异点），否则 workspace 隔离层投入的 ROI 永远无法 close loop

---

## 6. 最终立场

**方案 C 是好的方案，但需要补 4 处**：

1. **加 ROI 量化 + go/no-go gate**（§4.1）
2. **加 admin → ezagent 内容同步协议设计**（§4.2 + §5.3）
3. **加 M0 B1 = Path C 分叉的工程周估算**（§4.6）
4. **加 wall-clock 时间估算**（不是单 dev 工程周）（§4.9）

**回写两条 caveat 到原 eval 文档**（§5.1 + §5.2），保持本 notes 目录的内部一致性。

**最大的开放问题**（值得在迁移 kickoff meeting 单独讨论）：

- 影子流量基础设施在 cinnox 真实流量下**绝不能污染生产**（不产 lead / 不触发 DIRECT_TRANSFER / 不计费），严格 dry-run 设计本身有工程量。同团队内 owner 是谁、跟 M1 是否并行？
- M0 B1 如果 Allen 决议是"现状不改，cc 插件就是 operator-bound 模式"，整个方案怎么办？（=Path C 是 ~300-500 行 plugin + Chat Behavior 兼容 ~100-200 行 + brainstorm，~2-3 周同团队内部排期；不是历时翻倍，是 M0 关键路径明确化）
- cinnox 跑通后第二个测试租户的 RFC 什么时候立项？workspace 隔离层投入 ROI 必须靠**多租户验证 close loop**，不能只用 cinnox 单点闭环。
- **容量竞争**：同团队同时还要维护 AutoService 主线 + ezagent 平台演进，cinnox 迁移工作流的优先级如何排？（这是同团队两项目的真实约束）

---

## 7. 推荐下一步

按优先级：

1. **本周**：Allen 主持 bridge handshake brainstorm（C §9 #2）— 同团队内部架构决议，越早定 B1 Path B/C 越早能并行 M1。注意：这不是"跨团队 meeting"，是团队架构纪律时间
2. **本周**：KB sidecar spike（C §9 #3）— 1.5-3 周（不是 1 周），但越早开始越早暴露未知
3. **下周**：补本文 §4.1-4.4 的 4 条 caveat 进 [05-cinnox-implementation-plan.zh_cn.md](05-cinnox-implementation-plan.zh_cn.md)
4. **下周**：回写 §5.1 + §5.2 两条 caveat 到 [03](03-perf-ux-perspective.zh_cn.md) + [02](02-business-perspective.zh_cn.md)
5. **2 周内**：影子流量基础设施立项（独立 PR / 独立 owner）
6. **2 周内**：第二个租户的 RFC 草稿（哪个客户 / 时间表 / 跟 cinnox 共用什么）

走完这 6 步，方案 C 的执行风险大幅下降，可以正式开 M1 ticket。
