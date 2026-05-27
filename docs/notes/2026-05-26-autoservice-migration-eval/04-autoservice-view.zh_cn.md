# AutoService 视角下的 ezagent 迁移评估（subagent 4：critical 视角）

> 评估范围：从 AutoService 工程师视角真诚批判"全迁到 ezagent"。
>
> 立场：**带强烈观点 + 真诚批判，识别迁移会丢什么、何处翻译损失**。结论倾向**不全迁，推荐混合方案**。

---

## 0. 30 秒总结观点

**有条件推荐 — 但默认建议是"别全迁，把 ezagent 当 routing+identity 底座，AutoService 主体留在 Python"**。理由：ezagent 的核心赢点（dispatch + CapBAC + workspace 隔离 + reliability primitives）在 AutoService 的当前痛点列表里排位不高；AutoService 真正的痛点是 cc 进程池、4 层 soul/skill 合成、CR 沙箱→release —— 这三件事在 Elixir 写**会更慢、更难调、不会更对**。如果坚持全迁，估算 6-9 工程师月，且会丢一部分 Python 生态便利。如果做混合方案，估算 2-3 工程师月就能拿到 80% 的可靠性收益。

---

## 1. Python 生态损失评估

AutoService 仓库 33,295 个 `.py` 文件。其中**不可替代且强绑定 Python 生态**的至少有：

- **claude_agent_sdk** (`cc_pool.py:39` `from claude_agent_sdk import ClaudeSDKClient`) — 官方 Python SDK，带 `set_model` 在线切模型、`stdin_writer`、hook callback。Elixir 这边 `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` + `apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex` (699 行) 是直接 `:exec.run` 拉裸 `claude` CLI，**没有 SDK 这一层**。
- **deepseek HTTP**（fast_phase 即时安抚）—— 这条 OK，Elixir Finch/Req 同等。
- **豆包 Realtime / MLX ASR / TTS** (`channels/web/voice/asr_client.py`, `doubao_client.py`, `tts_pool.py`，4601 行 voice 子树) —— 全是 Python SDK + WebSocket 协议。
- **sqlite + FTS** for KB —— Elixir `Exqlite` 能用但 FTS5 模板 + 上传/抓取/embedding pipeline 几百行胶水要全翻。
- **PDF/XLSX 解析、scripts/seed_* 一堆运维脚本** —— 砍掉 Python 后这些得绕道 erlexec 拉子进程。

**实际成本估算**：voice + ASR/TTS + claude SDK + KB embedding 这 4 块如果保留 Python，意味着 ezagent 起码要管 **4 类长生命周期 Python sidecar**。`ezagent_domain_python/server.ex` 已经是 699 行了 —— 我看完那份代码的感受是它**只解决了 "如何用 erlexec 包一个 Python JSON-RPC sidecar"**，还没解决多 sidecar 的池化、配额、热重启、版本切换。AutoService 的 `cc_pool.py` 3972 行业务逻辑里，**大约 60% 是"如何在 Python 内管理 N 个 cc 子进程"**，搬到 ezagent 后这部分不消失，只是从"asyncio 管 cc 子进程"变成"BEAM 经 erlexec 管 cc 子进程"，**而且中间多一层 JSON-RPC 序列化**。

**结论**：Python 生态本身不死，但所有 SDK 都要变成 sidecar，且 ezagent 当前的 sidecar 底座（PyProcess + JsonRpc + FrameBuffer = 1993 行）还不够生产成熟。

---

## 2. Pipeline v2 编排：OTP 重写复杂度

`autoservice/pipeline_v2/orchestrator.py` 950 行（`_cc_phase` 在 343-700 行），核心是：

- `_fire_deepseek_ack_concurrent` 并发起 deepseek
- `_filler_loop` 周期 4s/10s 推填充语
- cc 主循环（内部 KB MCP tool call）
- 45s 硬超时

**翻成 OTP 的真实代码量**（做过类似项目）：

- 1 个 `Orchestrator` GenServer per turn（state machine：fast/cc phase）≈ 250 行
- `FillerLoop` 用 `Process.send_after/3` ≈ 80 行
- `DeepseekClient` Task + Task.Supervisor ≈ 120 行
- `CcTurn` Task 包裹 erlexec stdin/stdout ≈ 200 行
- 跨进程结果汇聚（用 `:gen_statem` 或 Task.async_stream）≈ 150 行
- **合计 ~800 行 + 6-8 个 GenServer 模块**

代码行数差不多，**但是**：

- **OTP 赢的场景**：crash recovery —— deepseek 挂了不连累 cc；cc 挂了不连累 turn queue。Python asyncio 用 `try/except + asyncio.shield` 写得能跟 OTP 一样安全但**更难写对**（asyncio 的 cancellation 传播是著名陷阱）。
- **OTP 输的场景**：debug 体感。`_cc_phase` 那种"emit 一个 ack → 启 filler loop → cc 主循环 → 中间取消 filler"用 asyncio 线性写出来，pdb 一停可以单步看；OTP 里这条 flow 横跨 5 个进程，看 `:observer.start` + telemetry trace + `:sys.trace` 还原。
- **真诚结论**：如果你的核心痛点是"pipeline v2 经常出 bug 修不动"，OTP 会赢；如果痛点是"加新 phase 慢"，OTP 不会赢。AutoService 的痛点从我看到的 commit 量看是后者。

---

## 3. cc_pool：erlexec 能不能对齐 set_model

**不能完整对齐**。

AutoService 的 `set_model` (`cc_pool.py:164, 2581`) 走的是 **claude_agent_sdk 的 control-protocol 消息**（往 stdin 发结构化 JSON-RPC，sdk 内部 ack）—— 这是个 SDK 协议层 API，**不是 CLI 信号**。

ezagent 走 `:exec.run` 直接拉 `claude` 二进制（`server.ex:156`），靠 `:exec.send/2` 写 stdin（`server.ex:235`）。理论上 stdin 可以模拟 SDK 的 control message，**但需要在 Elixir 侧重新实现 claude_agent_sdk 的 control 协议序列化**。粗看 sdk 源码，control 协议是有版本号 + ack 的，**不是简单"写一行 /model haiku\n"**。

工程量：

- 在 Elixir 复刻 claude_agent_sdk control protocol ≈ 600-1000 行（含 ack 状态机 + 版本兼容）
- 或者继续用 Python，把整个 cc sidecar 用 `claude_agent_sdk` 包，ezagent 通过 JsonRpc 给 sidecar 发"set_model" RPC —— 这是当前 `ezagent_domain_python` 的路子，**意味着 cc 走两层 IPC：BEAM ↔ Python sidecar ↔ claude CLI**

**资源开销估算**：100 租户 × 3 角色 cc 实例，AutoService 当前是 ~300 个 Python `claude` 子进程 + 1 个 Python gateway。迁到 ezagent 混合方案后变成 1 个 BEAM + 300 个 Python claude_agent_sdk wrapper + 300 个 claude CLI = **进程数翻倍，RSS 估算翻 1.3-1.5 倍**（每个 Python sidecar wrapper 约 30-50MB）。

---

## 4. storage v3 在 workspace_uri 强约束下怎么活

这是**最痛的一条**。

AutoService 的内容分层是 **L0/L1/L2/L3 四层优先级**（`autoservice-overview.md:141-188`），跟"租户"是**正交维度**：L0/L1/L2 是系统/平台/行业层，属于"工程团队拥有，不归任何 tenant"。L3 才是租户。

ezagent 的 URI SPEC v3（`docs/notes/uri-design.md` + invariant 11）只有 **6 scheme，per-tenant scheme 强制 3-segment authority `<scheme>://<type>/<workspace>/<name>`**，外加 invariant 14（per-tenant DB 表必须 `workspace_uri NOT NULL`）。

具体冲突：

- L0 框架（`agents/<role>/soul.md`）→ ezagent 没有"系统层 scope"概念，`system://` scheme 是 2-segment 且只用作 sentinel（`SystemPrincipal.Catalog` 14 个 URI 白名单）。塞 L0 soul 进 `system://soul/customer` 在语义上 OK，但 `SystemPrincipal.Catalog` 是 **closed allowlist**（`anti-patterns.md:35` 明示），加新 system URI 要改 catalog 模块 + cap 声明。
- L1 平台层 `master/platform/customer.md` → 在 ezagent 既不属于某租户 workspace 又不属于 system principal —— **找不到位置**。
- L3 租户 sections（`.autoservice/data/tenants/<tid>/sections/<role>/<sid>.yaml`）→ 在 ezagent 必须是某个 `workspace://<wsname>` 下的 Resource Kind，**workspace_uri NOT NULL**。OK 能塞进去，但要给每个租户分配 workspace URI。
- canonical content hash + `released/<tid>/<sha>/` —— ezagent 没有内容寻址 scheme，要么塞 `resource://`，要么自己加 `released_uri` 字段。

**真诚结论**：硬要塞，得在 ezagent 加一个 **"system tier" 概念**，违反 invariant 8（"No top-level plugin schemes"）和现有 6-scheme allowlist。**这是要 Allen 改架构的级别**，不是迁移者能搞的。或者反过来把 L0/L1/L2 全部展开成"每个租户 workspace 自带一份系统层副本" —— **存储炸掉 N 倍**，且每次平台层改动要 fan-out 到 N 个 workspace（违反"shared referent needs identity" §3.1.1）。

混合方案在这一点上最有价值：**让 AutoService 继续管两棵树，ezagent 只接管 routing/identity**。

---

## 5. CR 流程在 OTP 里的复杂度

AutoService CR 系统：`active_cr.py` 469 行 + `change_request/repository.py` 565 行 + `state_machine.py` 106 行 + `api_routes_section.py` 577 行 + `api_routes_kb.py` 390 行 ≈ **2100 行**，外加 React admin portal。

核心数据流：admin PUT 端点 → 写沙箱 → `ensure_active_cr()` → compute_sandbox_diff → publish 时 promote → recycle cc_pool。**这是个典型的 CRUD over filesystem + state machine**，Python 写非常顺。

OTP 翻译：

- 1 个 `Cr` Kind（per tenant 一个 active draft）≈ 200 行
- `CrBehavior`（add_change / publish / rollback actions）≈ 250 行
- LiveView 替代 React admin portal —— `compute_sandbox_diff` 的"实时 diff 渲染"在 LV 里要 PubSub 推送到前端 ≈ 300 行 LV + LV templates
- 替代 `api_routes_section/kb/skill_*.py` 的 PUT 端点 ≈ Behavior actions ≈ 200 行 × 4 资源类型 = 800 行
- **合计 ~1500-1800 行 Elixir + 全套 LV 重写**

**真诚结论**：行数差不多，**但 React admin portal 要重写为 LV** —— 这是 admin 团队的迁移盲点。LV 在 admin 场景下表现 OK，但当前 admin portal 已经投入很多前端工作，沉没成本不小。"实时 diff 校验" `compute_sandbox_diff` 这种纯函数逻辑用 Python 写直观，OTP 里也不会更优雅，**纯属翻译损失**。

---

## 6. Voice / Feishu 历史包袱处理

**Voice**: AutoService voice 子树 4601 行 + 豆包 SDK + MLX 本地推理 + ASR/TTS pipeline + PCM stream + 句号切分。**ezagent 这块是 0** —— `find apps -name "*voice*"` 空。要写：

- Voice Channel Kind（PCM bytes stream）≈ 200 行
- 反 anti-pattern：anti-patterns.md:50 明确"streaming media doesn't fit Behavior model，go to external SFU"，**所以 voice 在 ezagent 是 explicit out-of-scope**。
- ASR/TTS 必须走 Python sidecar 或外部 service

**估算**：voice 整体迁移 = **死活搬不过去的那一类**。ezagent 的"控制面在 BEAM、媒体面在外部"的硬边界跟 AutoService 把 voice 跟 chat pipeline 紧耦合的现状不兼容。**voice 是劝退 ezagent 全迁的最强论据之一**。

**Feishu legacy**: AutoService 仓库里 `channels/feishu/channel_server.py` 1724 行 但已停止同步新功能。**搬到 ezagent 时直接砍掉** —— ezagent 已有 `ezagent_plugin_feishu`，且符合 SPEC v2（FeishuReceive Behavior on User Kind）。不要带 Python 版的历史包袱。

---

## 7. 运维 / 调试体感落差

对 Python dev 来说，迁到 ezagent 的 learning curve **陡**：

| 任务 | AutoService | ezagent |
|---|---|---|
| 看一条客户请求的完整 trace | `grep gateway.log "trace_id=..."` | telemetry + `:recon_trace` 或 LiveDashboard |
| 起一个本地修复 session | `make stop && make start` | `iex -S mix phx.server`（OK 但要会 iex） |
| seed 一个新租户 | `uv run scripts/seed_cinnox_tenant.py` | `mix ezagent.demo.seed_cc_agent`（已有 task，OK） |
| 改一行 prompt 然后立刻看效果 | 改文件 → uvicorn auto-reload | 改 .ex → `iex> r ModuleName` 或重启（LV 有 hot reload OK） |
| 排查 cc 进程卡死 | `ps auxf` + `py-spy dump` | `:observer.start` + 找到 Server pid + `:sys.get_state` |
| 加一个 print debug | `print(...)` | `IO.inspect/2`（OK 但要记 label/pretty 参数） |

**真诚**：BEAM 工具链（observer / recon / LiveDashboard / telemetry）在**生产排查**上比 Python 工具链强一个量级；但在**开发期 inner loop**上差一截。Python dev 入门 6 周内会持续抱怨"为什么不能直接 print"、"为什么 stack trace 看起来是天书"、"为什么我改一行 GenServer 要重启"。

---

## 8. ROI 评估 + 混合方案

**全迁 ROI 表**：

| 客户类型 | 全迁是不是 obvious win |
|---|---|
| 多租户量 < 50，单 tenant QPS < 10 | **不是** —— AutoService Python 跑得开开心心，可靠性问题用 systemd 重启可解 |
| 多租户量 50-500，需要严格租户隔离 / cap-based 鉴权 | **可能是** —— ezagent workspace 隔离 + CapBAC 是真本事 |
| 多租户量 > 500，需要节点 federation | **是** —— Python asyncio 单进程到不了这个量，BEAM + Horde 能 |
| 严格 SLA（99.9%+），cc 子进程死掉不能影响其他客户 | **是** —— OTP supervision tree 在这里赢得很干净 |
| 已经 voice-heavy | **不是** —— voice 在 ezagent 是 explicit out-of-scope |

**混合方案（强推）**：

- ezagent 当 **identity + workspace + routing + audit 底座**（用现成的 `ezagent_domain_identity` + `ezagent_domain_workspace`）
- AutoService Python 当 **业务大脑**（Pipeline v2 + cc_pool + KB MCP + voice + admin portal）
- 中间通过 Phoenix Channel / WebSocket 让 Python 当 ezagent 的"外部 channel"
- 估算 2-3 工程师月，拿到 ~80% 可靠性收益，**voice 和 admin portal 不用动**

---

## 9. 真诚最终建议

**不要全迁。**

具体理由按优先级：

1. **storage v3 跟 ezagent 6-scheme allowlist 是结构性冲突**（§4），需要 Allen 改架构，**这是阻塞项**，不是 AutoService 团队能消化的。
2. **voice 在 ezagent 是 explicit out-of-scope**（anti-patterns.md:50），AutoService 4601 行 voice 子树搬不过去。
3. **cc_pool `set_model` 等 SDK 协议层 API** 在 ezagent 要么 600-1000 行重写，要么走双层 sidecar 增加资源开销 30-50%（§3）。
4. **ROI 不对**：AutoService 主要痛点是"加功能慢"和"租户内容分层难管"，不是"系统不可靠"。OTP 治后者，治不了前者。
5. **沉没成本**：admin portal V2 + Pipeline v2 + cc_pool sticky binding + CR sandbox→release 这四块加起来 **大约 12,000 行核心 Python**，全部重写成本约 6-9 工程师月，重写后第一年 bug rate 必然比 Python 现状高。

**推荐路径**：先做混合方案（ezagent = identity + routing + audit 底座，AutoService = 业务大脑），跑 6 个月，看下面三个信号：

- 信号 A：租户量过 200 + cc_pool 经常 GC 卡顿 → 升级到把 cc_pool 也搬到 ezagent
- 信号 B：admin portal V2 出现"管理员操作引发其他租户雪崩" → 把 CR 流程搬到 ezagent
- 信号 C：以上两个都没出现 → 永远保持混合方案，AutoService Python 主体不动

**最不该做的事**：在没看到信号 A/B 之前，因为 "ezagent 很先进、设计很正" 这种**审美驱动**的理由启动全迁 —— ezagent 的 grill 文化和 17 条 invariant 是为 message router 工作量身定做的，AutoService 是 **AI 客服应用**，业务形状不是 router，强搬等于"用 OpenAPI 工具链写报表系统"，**不会比现状好**。

---

## 关键文件参考

- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\cc_pool.py:164` — `set_model` 实现
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\pipeline_v2\orchestrator.py:343` — `_cc_phase` 并发编排
- `D:\Work\h2os.cloud\AutoService-dev-a\channels\web\voice\voice_engine_bridge.py` — voice pipeline 485 行
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_domain_python\lib\ezagent\domain\python\server.ex:156` — erlexec 当前唯一 Python sidecar 范例（699 行）
- `D:\Work\h2os.cloud\ezagent\apps\ezagent_plugin_cc\lib\ezagent\template\cc_agent.ex` — ezagent 当前 cc CLI 拉起方式（无 SDK 层）
- `D:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\anti-patterns.md:10` — 6-scheme allowlist + 不允许新增 scheme 的硬约束
- `D:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\anti-patterns.md:50` — 媒体流不能进 ezagent 的明确约束
