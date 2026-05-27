# AutoService → ezagent 迁移评估（2026-05-26）

> 4 视角合成评估：把 `D:\Work\h2os.cloud\AutoService-dev-a` 的能力迁到 ezagent 是否可行、按什么顺序、什么是死活搬不过去的。
>
> 评估基于 AutoService 2026-05-26 主干运行真实态（区分 spec vs 落地，规避 fork 架构 / runtime/sandbox / Feishu legacy 等遗弃物）+ ezagent 当前 P1-P27 设计原则 + 17 条架构不变式 + URI SPEC v3。

## 术语澄清（2026-05-27 补，含同团队纠正）

整个目录采用以下角色定义，**不要混淆**：

| 角色 | 含义 |
|---|---|
| **h2oslabs** | 我们公司 — 同时拥有 AutoService 和 ezagent 两个产品 |
| **AutoService** | h2oslabs 现役产品（Python/FastAPI）— 多租户 AI 社交通道应用框架 |
| **ezagent** | h2oslabs 新平台（Elixir/OTP）— message router runtime，迁移目标底座 |
| **cinnox** | h2oslabs 在 AutoService 上的**一个真实租户**。当前迁移工作**以 cinnox 作为测试载体**，用真实租户数据/真实端用户流量验证 AutoService→ezagent 迁移方案的可行性 |
| **我们（迁移工作流 / 团队）** | **AutoService 和 ezagent 是同一团队的两个项目**——没有跨团队协商成本。所谓"AutoService 迁移工作流"和"ezagent core 工作流"是**同一团队内部的两条工作线**，不是两个团队。早期 doc 误写"cinnox 团队"已纠正；"等 ezagent team 决议"也是**误用**——其实是同团队内排期 + 架构决议（由 Allen 主导 brainstorm） |
| **Allen** | 团队架构主导者，所有触及核心模块的改动需要 Allen review + brainstorm。这是**架构纪律时间成本**，不是跨团队协商成本 |
| **客户 / 端用户** | cinnox 这个租户的**最终使用者**（通过 web SSE 跟 cs_main agent 对话的人） |

**关键定位**：

1. **cinnox 不是被服务的客户**，是**迁移方案的验证载体**。M2/M3 的"影子流量对比"、"A/B 切流"等术语，目标是**验证迁移方案**（"ezagent 能否承接现网负载且不退化体验"），而不是给某外部客户做交付。
2. **AutoService 和 ezagent 是同团队的两个项目**。早期 doc 把 M0 阻塞描述为"等 ezagent team 决议"、"AutoService 迁移团队完全控制不了节奏"是**错误框架**——实际是同团队内**架构决议 + 内部排期**，时间成本来自 Allen brainstorm 的实质工作量，不是跨团队协商。受影响的 ROI / 等待时间估算见 [06 §4.1 §4.9](06-plan-review-comparison.zh_cn.md) + [07 §1 §2](07-feasibility-vs-conventions.zh_cn.md) 已重写部分。

## 文件

| 文件 | 视角 | 日期 | 立场 |
|---|---|---|---|
| [00-synthesis.zh_cn.md](00-synthesis.zh_cn.md) | **综合报告**（4 视角合成 + 推荐路径） | 05-26 | 中立合成 |
| [01-infra-perspective.zh_cn.md](01-infra-perspective.zh_cn.md) | 基础架构（cc_pool / dispatch / workspace / prewarm → Kind/Behavior） | 05-26 | 假设要迁，给具体映射 |
| [02-business-perspective.zh_cn.md](02-business-perspective.zh_cn.md) | 业务能力（4 层 soul/skill、两棵树存储、CR 流程、RBAC→CapBAC、lead/ExternalMirror） | 05-26 | 假设要迁，给具体映射 |
| [03-perf-ux-perspective.zh_cn.md](03-perf-ux-perspective.zh_cn.md) | 会话性能体验（Pipeline v2 三色编排 12 项优化逐项 P0/P1/P2） | 05-26 | 假设要迁，给具体映射 |
| [04-autoservice-view.zh_cn.md](04-autoservice-view.zh_cn.md) | AutoService 反向视角（真诚批判 + Python 生态损失 + ROI + 混合方案） | 05-26 | **不推荐全迁** |
| [05-cinnox-implementation-plan.zh_cn.md](05-cinnox-implementation-plan.zh_cn.md) | **cinnox 落地方案**（M0-M4 排期 + 验收 + 工程周）— 在 eval + PR #297 之上（含 07 review 的 9 处修正 inline patch） | 05-27 | 决定迁，给可执行 roadmap |
| [06-plan-review-comparison.zh_cn.md](06-plan-review-comparison.zh_cn.md) | **三方案 review**（eval / PR #297 / cinnox 落地方案对比 + 缺点 + 下一步） | 05-27 | 批判性 review，给 4 条 caveat 补丁 |
| [07-feasibility-vs-conventions.zh_cn.md](07-feasibility-vs-conventions.zh_cn.md) | **约定符合性 review**（M0 逐项 invariant/P 检查 + 整体判定 + M1-M3 plan drift 5 处 + 修正清单） | 05-27 | M0 没破坏约定但成本被低估；M1-M3 有 5 处 drift 需修正（已 inline patch 到 05） |

## 30 秒结论

**不推荐全迁；推荐"混合方案 + 优先吸收会话流程优化"**：

- ezagent 当 identity / workspace / routing / audit 底座
- AutoService Python 主体（cc_pool / Pipeline v2 / voice / admin portal）保留
- **但** AutoService 沉淀的会话流程 P0 五项优化（fast/cc 双相位 / 并发 ack / FillerLoop / prewarm / output filter）必须迁到 ezagent 的 chat domain，让 ezagent 原生会话体验对齐 AutoService 同级别

## 当前阶段性方案（cinnox 测试载体）

**目标**：以 cinnox（h2oslabs 在 AutoService 上的真实租户）为测试载体，验证 AutoService → ezagent 迁移方案。详 [05-cinnox-implementation-plan](05-cinnox-implementation-plan.zh_cn.md) + [06-review](06-plan-review-comparison.zh_cn.md) + [07-feasibility](07-feasibility-vs-conventions.zh_cn.md)。

**2026-05-27 关键决议**：

- **B1 (bridge handshake) = Path B**：EagerBridge plugin 原语（plugin tier，~1 周）；Path C 保留 fallback
- **B2 (within_workspace cap)**：策略性推到 M3+，不阻塞 M0/M1/M2
- **M0 关键路径 ~1-2 周**（同团队内部排期，无跨团队等待）
- **总 wall-clock**：M0+M1+M2 ≈ 3-7 个月（看 dev 容量），A/B 切流 ≈ 6-9 个月

## 关键张力

| 支持全迁 | 反对全迁（真诚批判） |
|---|---|
| Pipeline v2 的 `asyncio.Lock` per-conv、cc-dot race、`_STATES` 全局 dict 在 OTP 模型里**根本不存在** | **storage v3 vs 6-scheme allowlist 是结构性冲突** — L0/L1/L2 系统/平台/行业层在 ezagent 找不到位置，要 Allen 改架构（阻塞项） |
| CR / snapshot / per-tenant 隔离能用 ezagent 核心原语替换自造轮子 | **voice 在 ezagent 是 explicit out-of-scope**（anti-patterns.md:50），4601 行 voice 子树搬不过去 |
| workspace_uri NOT NULL + cross-workspace deny 是 Python 当前没有的结构性保证 | **cc_pool `set_model` 是 SDK 协议层 API**，erlexec 拉裸 CLI 无等价；要么 600-1000 行重写 control protocol，要么双层 sidecar（资源 +30-50%） |
| | ROI 不对 — AutoService 痛点是"加功能慢"，OTP 治不了；沉没成本 ~12000 行 Python + admin portal V2 React |

## 先决条件（开始任何业务迁移前必须解决）

1. **HIGH** — ezagent capability 加 `{:within_workspace, _}` 形状，否则 tenant_admin 权限无法表达
2. **HIGH** — Template Class 加声明式 cross-layer lint hook（防 L3 越权改 L1 域规则）
3. **MEDIUM** — `Ezagent.CircuitBreaker` core primitive（避免 plugin 自造熔断违反 P22）

## 不要做的事

因为 "ezagent 设计更优雅" 这种**审美驱动**启动全迁 — ezagent 的 17 条 invariant + grill 文化是为 message router 工作量身定做，AutoService 是 AI 客服应用，业务形状不是 router，强搬等于"用 OpenAPI 工具链写报表系统"。先用混合 + P0 优化拿 80% 收益，剩下 20% 等信号触发再说。

## 维护

本评估快照时间：2026-05-26。AutoService 后续版本 / ezagent 后续 phase 都可能让某些结论失效。**重新评估触发条件**：

- ezagent capability 形状新增 `{:within_workspace, _}` → 业务侧迁移阻塞消失
- AutoService 完成 voice 子树重构（SFU 外部化）→ voice "搬不过去" 论据消失
- claude CLI 加 in-place `set_model` 控制消息 → tier upgrade 优化可恢复 P1
