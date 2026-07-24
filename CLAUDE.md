# CLAUDE.md

Ezagent(Session Router)— Elixir/OTP message router runtime,multi-channel → multi-agent 编排。

本文件 supplements `phx.new` 生成的 `@AGENTS.md`(Phoenix/Elixir LLM 常见错误修正,由 Phoenix.new agent 提炼)。**先读 AGENTS.md 拿 Phoenix idioms,再读本文件拿 Ezagent 特有约定**。

---

## 必读

按以下顺序读完才开工:

1. `@ARCHITECTURE.md` — v0.4_final,2700+ 行,设计权威。**不要尝试修改这份文档**(Allen 维护,实施期发现架构问题暂停 → 讨论 → Allen 改 → 继续)
2. `@GLOSSARY.md` — 术语表 + 易混淆词消歧 + Decision Log(80+ 条决策)
3. `@IMPLEMENTATION_ROADMAP.md` — 6 phase 划分 + 4 条贯穿 track
4. `docs/phase-specs/<current-phase>/` 全部 4 文件 — SPEC / VERIFICATION / PLAN / DECISIONS

操作类 how-to(如何跑 E2E / 起 disposable docker 栈 等)看 `CONTRIBUTING.md` → `docs/guide/`(操作指引的 durable 家;specs 是 point-in-time 设计、不是操作手册)。

读完后,你应该能在 30 秒内回答以下问题(否则回去再读):
- Ezagent 跟 typical Phoenix app 的两条核心差异是什么?
- 设计原则的五个 group 是哪些?(见下方 link)
- 当前 phase 在哪个 sub-step?

---

## 设计原则(权威集在 SKILL)

**权威源**:`.claude/skills/ezagent-developer/SKILL.md` §Design Principles — 26 条编号原则(P1-P26),分 5 组(Engineering / Architecture & boundaries / Dispatch & runtime / Persistence & URIs / Plugin contract)。

历史上本节列过 "8 条硬不变式",现已合并进 SKILL 权威集(对照表见 SKILL §"Where each old principle now lives")。**本文件在每个 prompt 都加载,刻意不复述原则**(memory `feedback_claude_md_links_only`)— 写代码 / review 前 load SKILL,改架构原则改 SKILL,不在这里。

最常出 bug 的两条速查:
- **P14 — Dispatch is the only path between Kinds**(inbound 永远走 `Ezagent.Router.dispatch/1`/legacy `Ezagent.Invocation.dispatch/1`,不许 `PubSub.broadcast` 到 inbound topic — 事故 2.1 根因)
- **P22 — Reliability primitives live in core**(ReadyGate / PendingDelivery / Idempotency / Snapshot-on-change / async audit / DLQ-on-zero-match;plugin 作者绕不过)

完整集 + CI gate + 触发的 Decision Log 编号都在 SKILL。

## 安全姿态(开发期 · Allen 2026-07-24)

当前功能快速迭代期,**功能完善 >> 安全需求**。代码大多 in-VM 执行(尚未全量引入外部插件),不需要复杂防御机制。

- **唯一确定必要的安全机制 = caps-based access control**(业务必须:靠"持有哪些 caps"区分使用者)。其当前主要目的是**防漂移**:没有签名/密钥时,开发者(人或 Agent)能构造假 admin caps 绕过 authz,让功能"可用但业务逻辑错";签名后必须想清"谁用、如何授权"→ 业务逻辑才对。这类加固**保留**。
- 实施功能时**不要内联引入 caps 正确性以外的安全代码**。其它安全关切拆到**统一/中央机制**解决,不在功能 PR 里逐个做(不同方向的加固/workaround 会相互冲突)。
- 非"防漂移 / caps 正确性"动机的安全机制,加之前**先与人类开发者确认必要性**;若必要,问是否应统一实现。若某安全机制**挡住当前功能,考虑下线它,而非强行 workaround**。
- **对抗性评审据此校准**:判"是否正确实现业务逻辑 + 是否正确用 caps",而非"攻击安全"。撤销-TOCTOU 等源自已推迟的 revocation-completeness 缺口的理论边界**不作 merge 阻塞**——归统一安全轨(见 memory `feedback_security_posture_dev_phase`)。

## Behavior contract(2026-05-28 重写)

写任何 Behavior / Kind 代码前必读:`.claude/skills/ezagent-developer/references/new-contract.md`(Router / Behavior / Kind self-built architecture,SPEC PR #445)。

短结论:
- `use Ezagent.ActionSet` + `action :foo, args: ..., returns: ..., caps: [...]` 宏 + `def handle_foo(args, ctx) → {:ok, result, [effect]}` —— **不再写** `invoke/4`(Phase 3 PR #464 后是 `@optional_callbacks`,无 runtime 路径用)
- 9 个 effects:`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:terminate` / `:halt`
- Plugin author **永远不见** `slice` 或 `snapshot`(framework 通过 `ctx[:read]` reader 注入读;`{:set, key, value}` effect 写)
- Plugin code 禁止 import `Ezagent.EventLog` / `SnapshotStore` / `StateRebuilder` / `EventSubscriber` / `Router internals` / `SagaRunner.execute/2`(SPEC §11 grep gate)

ARCHITECTURE.md §6.0 是 load-bearing 项目文档;Decision Log #147-#152 是 per-phase landmarks。

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

### Plugin 判定 / 三层架构 / Adapter pattern

合并进设计原则权威集(SKILL §Design Principles):
- **P9 — "Reads what data" decides tier ownership**(原 ARCHITECTURE §2.2 + 本文件旧表)
- **P12 — Adapter pattern: protocol-specific code in adapters only**(原 ARCHITECTURE §2.4)
- **P13 — Phoenix is transport, not fullstack**(原 ARCHITECTURE §2.3)
- **SKILL §Three-tier project structure** — core / domain / plugin 边界表

### LOC budget(ARCHITECTURE.md §14)

- `ezagent_core` target ~870 LOC,red line 1100
- 每模块有 cap(详见 §14)
- 写完后 `wc -l lib/ezagent_core/**/*.ex` 核对,超 cap 触发设计 review

### 命名 convention(ARCHITECTURE.md §13)

```
Ezagent.<Category>.<KindType>            — Kind 声明
Ezagent.ActionSet.<Name>                  — Behavior 模块
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
| **behavior** | Ezagent.ActionSet(action 处理者) | Elixir behaviour(callback 契约) |
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
