# CLAUDE.md

ESR(Ezagent Session Router)— Elixir/OTP message router runtime,multi-channel → multi-agent 编排。

本文件 supplements `phx.new` 生成的 `@AGENTS.md`(Phoenix/Elixir LLM 常见错误修正,由 Phoenix.new agent 提炼)。**先读 AGENTS.md 拿 Phoenix idioms,再读本文件拿 Ezagent 特有约定**。

---

## 必读

按以下顺序读完才开工:

1. `@ARCHITECTURE.md` — v0.4_final,2700+ 行,设计权威。**不要尝试修改这份文档**(Allen 维护,实施期发现架构问题暂停 → 讨论 → Allen 改 → 继续)
2. `@GLOSSARY.md` — 术语表 + 易混淆词消歧 + Decision Log(80+ 条决策)
3. `@IMPLEMENTATION_ROADMAP.md` — 6 phase 划分 + 4 条贯穿 track
4. `docs/phase-specs/<current-phase>/` 全部 4 文件 — SPEC / VERIFICATION / PLAN / DECISIONS

读完后,你应该能在 30 秒内回答以下问题(否则回去再读):
- Ezagent 跟 typical Phoenix app 的两条核心差异是什么?
- 8 条硬不变式是哪些?
- 当前 phase 在哪个 sub-step?

---

## 8 条硬不变式(违反 = bug,即使代码"工作")

每个 sub-step 完成前 grep 自查:

1. **inbound 永远走 `Ezagent.Invocation.dispatch/1`** — 不允许裸 `Phoenix.PubSub.broadcast` 到 inbound topic。Phoenix.PubSub 不 buffer 没订阅者的 topic,裸 broadcast 在 register→subscribe 窗口会丢消息(事故 2.1 根因)。Grep:`PubSub.broadcast` 出现在 inbound 路径 = bug
2. **`use Ezagent.Kind` 生命周期严格 register→subscribe→announce_ready** — plugin 作者无法绕过。手写 `init/1` 不调宏 = bug
3. **`:call` to not-ready actor 必须 fail-fast,不能 buffer** — caller 同步阻塞等结果,buffer 会撞 deadline_ms
4. **Unique-key RoutingRegistry 表用 `put_new`,duplicate-key 用 `put`** — `declare_table` 时 `duplicate_keys: false/true` 决定;混用 = bug
5. **Snapshot 只在 slice 真变了写** — `new_slice != old_slice` 才落 SQLite,不是 invoke 后都写
6. **Audit 异步 cast,不阻塞 invoke** — `:telemetry` handler 只 `GenServer.cast` 到 `Ezagent.Audit.Writer`,不直接写 SQLite
7. **零匹配路由必须 telemetry + DLQ unroutable,不能静默** — 默认静默 = Ezagent 是 router 不是 req/resp app 的根问题
8. **CC channel 用 stdio**(Channels 协议要求,不是我们的选择)

---

## /goal 贯穿条款

无论当前在哪个 phase / sub-step,/goal 跑代码时遵守以下:

### sub-step gate(M1 规则)

- sub-step 是 /goal 内部 e2e gate,**不是 Allen 介入点**
- 每个 sub-step 完成时,跑该 sub-step 对应的 e2e flow(从 `docs/phase-specs/<phase>/VERIFICATION.md` 找)+ 单元/集成测试
- **全部 gate 绿才能 tag 进下一 sub-step**
- 任何 gate 红或不变式违反 → **不要 tag,暂停,等 Allen**
- **不要为赶进度绕过 gate**

### 不变式自查

每个 sub-step 完成前,grep 上面 8 条:

```bash
# 不变式 #1 反例
grep -rn "PubSub.broadcast" lib/ | grep -v ":events"  # inbound 路径 = bug

# 不变式 #2 反例
grep -rn "def init/1" lib/ | grep -v "use Ezagent.Kind"   # 手写 init 跳过宏 = bug
```

(完整 grep 清单在 `docs/phase-specs/<phase>/VERIFICATION.md`)

### 不要做的事

- 不要修改 `ARCHITECTURE.md`(Allen 维护)
- 不要跨 phase 实施(per-phase brainstorm 决定边界,不要"顺手"做下个 phase 的事)
- 不要 silent 失败(返回 `:ok` 但实际啥也没发生)
- 不要"修复"显式 stub(例如 Phase 1-3c 的 `authz_check/2` 永远 grant 是故意的,有 `:stub_grant` telemetry 标记,Phase 3d 才替换为真实检查)
- 不要发明新 Decision(任何架构决策走 Allen review,加进 GLOSSARY.md Decision Log)

---

## 写代码核心约定

### Plugin 判定原则(ARCHITECTURE.md §2.2)

**读什么数据决定归属**:

| 类别 | 归属 | 例子 |
|---|---|---|
| 读 core 数据(`%Invocation{}` / `%Message{}` / KindRegistry / RoutingRegistry) | **core** | Matcher 读 `%Message{}.mentions` |
| 通用 invariants(注册一致性、投递保证、幂等) | **core** | `Ezagent.PendingDelivery` / `Ezagent.Idempotency` / `Ezagent.ReadyGate` |
| 通用机制 infrastructure | **core** | `Ezagent.Routing.Matcher` 的 DSL 宏 + 求值器 |
| 读 plugin 专属 payload | **plugin** | 假设的 `feishu_card_type(:approval)` |
| 业务概念(Chat / Workspace / Identity) | **plugin** | `esr_behavior_chat` 等 |
| 外部协议(Feishu / CC Channel) | **plugin** | `ezagent_plugin_feishu` 等 |
| 可选 transport / UI | **plugin** | `esr_adapter_cli` / `ezagent_web_liveview` |

**硬测试**:plugin 作者应该专注业务,不应该被强迫做"我是不是要装 PendingDelivery plugin"这种基础设施决策。

### LOC budget(ARCHITECTURE.md §14)

- `ezagent_core` target ~870 LOC,red line 1100
- 每模块有 cap(详见 §14)
- 写完后 `wc -l lib/ezagent_core/**/*.ex` 核对,超 cap 触发设计 review

### 命名 convention(ARCHITECTURE.md §13)

```
Ezagent.<Category>.<KindType>            — Kind 声明
Ezagent.Behavior.<Name>                  — Behavior 模块
:ezagent_plugin_<name>                   — OTP app atom
EsrPlugin<Name>                      — Plugin 模块前缀
:ezagent_behavior_<name>                 — 单 Behavior plugin
:ezagent_adapter_<name>                  — 单侧 transport adapter
:ezagent_web_<name>                      — Phoenix 入口 plugin
```

---

## Domain 词汇(易混淆 — 完整版见 GLOSSARY.md)

Ezagent 跟外部世界有很多同名概念,**用错术语会让架构理解漂移**。常见的:

| 词 | Ezagent 意义 | 不要混淆 |
|---|---|---|
| **channel** | Claude Code Channel(MCP 协议) | Phoenix.Channel(WS 抽象) |
| **session** | Ezagent Session(routing context owner) | Phoenix session(cookie/web session) |
| **registry** | KindRegistry(URI→pid)或 RoutingRegistry(routing rules) | Elixir Registry(底层 module) |
| **behavior** | Ezagent.Behavior(action 处理者) | Elixir behaviour(callback 契约) |
| **template** | Template Class(模块级)或 Template Instance(运行时 Resource) | Phoenix template(.heex 文件) |
| **plugin** | OTP app 形式的 Ezagent 扩展 | Mix.Project plugin(完全不同) |
| **dispatch** | `Ezagent.Invocation.dispatch/1`(消息分发) | Phoenix.Router.dispatch(HTTP 路由) |

写代码 / 文档时,如果出现易混淆词,**显式 disambiguate**(例:"this Phoenix.Channel, not the CC Channel")。

---

## 关键 commands

```bash
# Dev
mix phx.server                 # 起 dev server
iex -S mix phx.server          # 起 dev server with REPL

# Test
mix test                       # 全部
mix test path/to/file_test.exs # 单个文件
mix test path/to/file_test.exs:42  # 单个 test(行号)

# Format
mix format                     # 格式化
mix format --check-formatted   # CI 用

# DB
mix ecto.create
mix ecto.migrate
mix ecto.reset                 # drop + create + migrate + seed

# Phase 0 后才有:
# (Phase 0 brainstorm 时定义自定义 mix tasks,例如 mix ezagent.check_invariants)
```

具体 phase 加了什么命令,看那个 phase 的 SPEC.md。

---

## Ezagent 是 router 不是 req/resp app(读这一节之前你应该已经读过 ARCHITECTURE.md §1.2)

如果你正在写一段代码,问问自己:

- **这条 message 如果没人接收,谁会知道?**
  - 如果答案是"没人会知道",bug
  - 正确路径:telemetry 出口 + DLQ unroutable + 显式 reject
- **这个 actor 还没 ready 时收到 dispatch,会怎样?**
  - 如果答案是"消息丢了",bug
  - 正确路径:ReadyGate 接住 → :cast 进 PendingDelivery / :call fail-fast
- **这个 invocation 失败时,caller 怎么知道?**
  - `:call` mode:`{:error, _}` 同步返回
  - `:cast` mode:DLQ + telemetry,caller 已经不在了
- **重复 inbound(webhook 重试)会怎样?**
  - `ctx.idempotency_key` + `Ezagent.Idempotency.seen?/1` 检查
  - v0 语义:**收到即记**(失败也算 seen),失败走 DLQ 兜底

每写一个路由/投递点,**问"这里失败了谁会知道"**——这是 Ezagent 比 typical Phoenix app 多出来的认知负担,没有别的办法。

---

## 关于 grill 文化

Ezagent 的 ARCHITECTURE.md 是 Allen 跟工程师做了 4 轮 grill 闭环写出来的,每条决策都有论证。实施期你可能会:

- **发现某个不变式跟代码冲突** → 暂停,写 issue,等 Allen,**不要自作主张绕过**
- **发现某个 Behavior 抽象不合理** → 同上
- **发现 ARCHITECTURE.md 缺口**(例如 v0.4_final 漏了 `message_store.ex`,工程师 review 发现的) → 暂停,标 issue,等 Allen + 工程师改 ARCHITECTURE

**不要在 phase 实施期"顺手"改架构**。架构 grill 是 Allen + 工程师的工作,实施期"暂停 → 讨论 → 改 spec → 继续"是正常流程,不是失败。

如果你识别到有什么 stale 或冲突的判断,**明说**:"这里跟 ARCHITECTURE.md §X.Y 不一致,我不确定该按哪边走,等 Allen 决定。"

---

## 启动 checklist(每次开 session 自查)

第一次进 ezagent 时:

- [ ] 读完了 ARCHITECTURE.md 至少 §1-§7?
- [ ] 读完了 GLOSSARY.md 的术语表?
- [ ] 知道当前在 phase 几 / sub-step 几?(看 `docs/phase-specs/` 哪个目录最新 + 最近 git tag)
- [ ] 当前 phase 的 SPEC / VERIFICATION / PLAN / DECISIONS 都读了?
- [ ] 8 条硬不变式记得?(回想一下,记不清就回去 grep)
- [ ] 知道 phase 完成的验收 checklist?

每次新 session(同一 phase 内):

- [ ] 当前 sub-step 是什么?
- [ ] 上次 commit 到哪?
- [ ] 当前 sub-step 的 e2e flow 是哪几条(从 VERIFICATION.md)?

---

## End

Ezagent 不是一个普通 Phoenix app,本文件 + ARCHITECTURE.md + GLOSSARY.md 三件套保证你不犯典型错误。如果有疑问,**问 Allen,不要假设**。
