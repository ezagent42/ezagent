# Phase 1 — DECISIONS

> Phase 1 brainstorm 阶段已决的判断点 + 实施期可能撞到的决策点 + 决策原则。
> 已决项实施完后 append 进 `GLOSSARY.md` Decision Log(impl 期 #84 起;Phase 0 已用 #84 占位的话 Phase 1 从 #85 起算 — 实际编号由实施时核对 GLOSSARY 决定)。

## 已决(Phase 1 brainstorm,Allen sign-off)

### P1-D1 — Bridge↔Ezagent wire = stdio + JSON-RPC(Q1)

bridge↔CC 必须 stdio(channels 协议硬要求,不变式 #8)。bridge↔Ezagent 也用 stdio + JSON-RPC,Ezagent 用 OSProcess 风格拉起 bridge 子进程(Phase 1 临时用 `:erlexec.run/2` 直接调,标 `TODO Phase 5 替换为 OSProcess Behavior`)。
**理由**:1c(实施时改名 1b)是 `_v1_prototype`,Phase 5 wholesale replace。YAGNI — 不给注定扔的原型镀金接近 Phase 5 形态。

### P1-D2 — 不用 `use Ezagent.Kind` 宏,用单 server + behaviour callbacks(Q2)

每个 Kind 模块只声明 `@behaviour Ezagent.Kind` + 几个 callback 函数(`type_name/0`、`behaviors/0`、`persistence/0`、可选 `uri_from_args/1`)。整个系统**一个**共享 `Ezagent.Kind.Server` GenServer,Kind 实例由 `Ezagent.Kind.Server.start_link({kind_module, args})` 启动。
**理由**:Decision #66 的 property(register→subscribe→announce_ready 不可绕过)反而**更强** — 用户不写 `init/1`,根本没 init 可改。架构上 property vs means 分离(用户原话「架构上的要求与使用宏还是不使用无关」点透)。
**对 ARCHITECTURE.md 的关系**:§5.7.4 字面写 "宏 展开出..." 是描述 means;实际 property(三步生命周期不可绕过)在 Option Y 下结构性更强。架构师后续 patch §5.7.4 改为承认两条等价路径(见架构师 Phase 1 review Patch A)。

**真实 trade-off**(架构师 Phase 1 review P2-1 显式化):
- 收益:Property 不可绕过(用户写不出 wrong init)— 比宏路径更结构性
- 代价:所有 Kind 共享 `Ezagent.Kind.Server` module,**Kind 间隔离从 compile time 推到 runtime**
  - `Ezagent.Kind.Runtime.handle_dispatch/3` 必须 defensive 处理任何 Kind 传进来的 state shape
  - Phase 1 Echo 的 slice 是 `%{count: 0}` map;Phase 2+ 其他 Kind 可能用 struct 当 slice;handle_dispatch 不能假设 map 操作工作
- ARCHITECTURE.md §5.7.4 措辞("宏展开生成的 init")由架构师同步 patch 为承认两条等价路径(Patch A)— 工程师本侧不改

**接受 trade-off 的理由**:Phase 1 只有 Echo 一个业务 Kind,共享 Server 的 runtime 隔离风险**接近零**;property 收益(用户写不出 wrong init)对 Phase 1 dogfood loop 价值更大。Phase 2+ 加 Chat Behavior 时如果发现共享 Server 跟某些 Kind 的 state shape 假设冲突,届时评估是否需要每 Kind 独立 Server module(等价回到宏路径)。

**架构师 Decision Log 入口**(架构师本侧 patch,GLOSSARY.md #84):"Phase 1 采用路径 B 不用宏 — 共享 Server 把 Kind 隔离从 compile time 推到 runtime;Phase 1 接受 trade-off 因为只有 Echo 一个业务 Kind;Phase 2+ 若 state shape 假设冲突再评估"。

### P1-D3 — Phase 1 = 2 sub-step(1a 合并 core + LiveView,1b = CC bridge),1a 内部 6 个 PLAN step(Q3)

ROADMAP §4 原 Phase 1 entry 是 3 sub-step(1a core / 1b LiveView / 1c CC bridge)。Phase 1 brainstorm 决定合并为 2:
- **1a**:ezagent_core MVP + ezagent_web_liveview /admin(~600 LOC core + ~150 LOC plugin,SPEC §1a Deliverables 模块表逐项加起来),内部 6 个 PLAN step,每步 commit 作 fine-grained checkpoint
- **1b**:CC stdio bridge 原型 + LiveView wire-up(~80 LOC Python + 少量 Elixir)

**理由**:测试员视角第一个 milestone 是「Allen 能 drive 系统」 — 1a 单跑(in-test only)的中间 tag 价值零。合并后第一个 tag 直接对应「Allen 能 drive」。密度顾虑由 PLAN.md 内部 step 排序 + checkpoint commit 消化(per Decision #80 sub-step gate 机制,PLAN-内部 step 是更细的 commit checkpoint,sub-step gate 在合并的末尾)。

### P1-D4 — LiveView audit 流 = Phoenix.LiveView.stream + last-50 bounded + 双路 fan-out(Q4)

`:telemetry` handler 一进来 fan-out 两路:
- 路径 1:`Phoenix.PubSub.broadcast(Ezagent.PubSub, "esr:audit:stream", {:audit_event, event})` 给 LV(view 渲染,§5.7.6 合法 broadcast)
- 路径 2:`GenServer.cast(Ezagent.Audit.Writer, {:write, event})` 给 SQLite(异步持久化,Decision #60)

LV `mount` 时 subscribe `esr:audit:stream` topic + 用 `stream/3` API(limit: 50);`handle_info({:audit_event, _})` 用 `stream_insert` 增量 push,bounded window(旧 entry 自然滚出)。
**理由**:§5.7.6 硬不变式说 "dispatch 用于确定 receiver,broadcast 用于不确定旁观者";audit 流的受众(LV / 未来 Feishu admin / CLI tail)是不确定旁观者,典型 broadcast 用法。phx 1.1 `stream/3` 就是为这设计的 — 高频也撑得住,零额外复杂度(不需要 throttle timer)。

### P1-D5 — admin 常量挂在 `Ezagent.Entity.User`,无独立 `Ezagent.Bootstrap` 模块(Q5,修正自初版 B)

Phase 1 的 `Ezagent.Entity.User` 是 stub Kind 模块,**包含 admin-specific 常量函数**:
```elixir
defmodule Ezagent.Entity.User do
  @behaviour Ezagent.Kind
  def type_name, do: :user
  def behaviors, do: []                # Phase 3d 加 [Ezagent.Behavior.Identity, ...]
  def persistence, do: {:snapshot, :on_change}
  def admin_uri, do: URI.parse("user://admin")
  def admin_caps, do: MapSet.new([%Ezagent.Capability{kind: :any, behavior: :any, instance: :any, ...}])
end
```
Phase 1 **不 spawn** User Kind 实例(没 Identity Behavior),但常量已在它逻辑上属于的 module。Phase 3d 同文件 append `bootstrap_admin_if_needed/0` + Behaviors 接入 — 纯 append 演化,无新模块。

**初版 brainstorm 我推荐独立 `Ezagent.Bootstrap` 模块(B 选项),Allen 反问「admin 不就是 Ezagent.Entity.User 吗?」一针见血 — 我接受修正**。admin-specific 知识就该在 User Kind module 上,不需要 Bootstrap 命名空间。**不可 revoke 守门仍在 `Ezagent.Capability.revoke/2`(Decision #81 不动)**。

#### Phase 2 forward note: `user://admin` 是否 spawn(架构师 review P3-2)

Phase 1 `ctx.caller = user://admin`,但**不 spawn** User Kind 实例(没 Identity Behavior)。reply 路径用 `{:caller_inbox, self()}` 不需要 lookup caller pid,Phase 1 内部一致 — `user://admin` 在 KindRegistry 里没有 pid,**Phase 1 不撞**。

但 Phase 2 加 Chat Behavior 后,可能出现 "reply to caller's chat inbox" 形态 — `agent://A` 发消息给 `agent://B`,B 处理完想 reply 给 A 的 chat inbox,需要 `KindRegistry.lookup(ctx.caller)` 拿 A 的 pid。**这时 `user://admin` 不 spawn 就撞墙**。

**Phase 2 brainstorm 必须决定**:
- (a)启动时 spawn admin User Kind 实例(消除 inconsistency,后续 reply 路径用 `KindRegistry.lookup`)
- (b)reply 路径里特殊处理 admin URI(读 `User.admin_caps/0` 当 placeholder,不 lookup)

**架构师倾向 (a)** — 但 Phase 2 时再正式定,此处留 reminder 防止 Phase 2 实施期撞 trap。

### P1-D6 — sub-step 切分名 1b 重指 CC bridge,不是「LiveView」(隐含在 P1-D3)

ROADMAP 原 Phase 1 entry 是 1a/1b/1c;Phase 1 brainstorm 合并后是 1a(core+LV)/1b(CC bridge,原 1c)。
**实施期约定**:tag 用 `phase1a` 和 `phase1b`(不是 `phase1a` 和 `phase1c`)— `phase1b` 指 CC bridge,跟 ROADMAP 原 1c 内容对齐。

### P1-D7 — 1a 内部 PLAN 6 步 + 1 个 PLAN-内部 checkpoint(隐含在 P1-D3)

1a 内部 step 排序:
1. ETS primitives + Capability + User stub(零依赖,各自单测)
2. Dispatch 主路径(Invocation.dispatch/1 + Kind.Server + Kind.Runtime + Authz stub)
3. Audit + DLQ + Snapshot 骨架 + SQLite migrations
4. ezagent_plugin_echo + Application 接线 — **PLAN-内部 checkpoint:F1 直接 invoke 在 `mix test` 跑通**
5. ezagent_web_liveview plugin(/admin LiveView + stream + form + Echo 按钮)
6. **sub-step gate:F1 via LiveView 浏览器 agent-browser verify**

每步 commit;step 4 后即使 step 5 撞墙,前 4 步 commits 仍是有价值的 partial work(core 在测试里通了)。

### P1-D8 — VERIFICATION 验证原则 = SUPERSETS human review(memory `feedback_goal_human_ergonomic_verification` 修正版)

**自动 gate 跑的所有 check 中,必须包含人类 review 时实际会做的所有事;gate 可以更多,以便更充分定位问题**。关系是 `人类 review ⊆ gate checks`,不是等式。任何 UI-touching phase 的最终 gate **必须**以 `agent-browser screenshot` 结尾。
**实施期影响**:每条 e2e step 给完整可粘贴文本(URI / JSON args),不让人手打 UUID / 长字符串。每个 sub-step gate 都包含 agent-browser open + snapshot + screenshot。
**初版 D8 措辞错**:我写过 "gate = 人类 review"(等式),Allen 纠正成 superset。已落 memory + VERIFICATION.md。

---

## 实施期决策点(/goal 撞到时按原则定)

### `Ezagent.Kind.Server` state 形状的细节

主体 3 个字段已定(`%{kind, uri, state}`),但 `state` 里 slice keys 的命名约定 — 用 atom(`:identity`)还是 module(`Ezagent.Behavior.Identity`)?
**原则**:用 atom(`behavior.state_slice()` 返回 atom)。理由:JSON-friendly(便于 SQLite snapshot 序列化),hash 快,跟 ARCHITECTURE.md §3.5 `state_slice :: atom()` 对齐。

**Phase 2 重评估点**(架构师 review P3-3): Phase 1 用简单 atom(`:echo`)。Phase 2 加 Chat 后按 ARCHITECTURE.md §6 line 1034 重评估命名空间 vs 简单 atom 的 trade-off:
- 简单 atom (`:chat`) — UI/snapshot 更可读,plugin namespace 可能碰撞
- 命名空间 (`:"Ezagent.Behavior.Chat"`) — 防 plugin 碰撞,序列化字符串更长

Phase 1 不动(收益和风险都在 Phase 1 外)。

### ETS table owner — 单个 GenServer 还是多个

5 个 ETS-backed primitives 的 table lifecycle 谁管?选项:
- **A**:每个 primitive 自己的 GenServer 持表(`Ezagent.ReadyGate.Server` 等 5 个 GenServer)
- **B**:一个共享 `Ezagent.Core.EtsOwner` GenServer 持所有 5 张表
- **C**:在 `Ezagent.Application.start/2` 直接 `:ets.new` 拥有

**原则**:B(共享 EtsOwner)— 减少 supervision tree 噪声 + 单点重启恢复所有表;读写都通过模块函数,GenServer 只负责 lifecycle。Phase 2+ 如某张表需要独立 backpressure(`Ezagent.Idempotency` 的 LRU prune),那张表升 A;其他保 B。

### `:erlexec` 拉 Python bridge — Phase 1 vs Phase 5 OSProcess

P1-D1 写明 1b 临时用 `:erlexec.run/2` 直接调起 Python bridge,标 `TODO Phase 5 替换为 OSProcess Behavior`。
**原则**:实施时这条 TODO 必须**实际写进代码注释**,且 phase1 spec 的 `DECISIONS.md` (本文件)有 reference — Phase 5 brainstorm 时找得到。

### `docs/phase-specs/phase1/artifacts/` 存 screenshot?

VERIFICATION 要求 `/tmp/phase1a-final.png` 和 `/tmp/phase1b-final.png` 两个 screenshot。
**原则**:这俩 PNG **拷贝一份到 `docs/phase-specs/phase1/artifacts/`** 进 git(SCREENSHOT 是验收凭证,跟 spec 一起留);commit 时一起。**注意:确认 PNG 不超过 1MB,否则用 git LFS 或考虑只留摘要(text 描述)**。Phase 0 没存 screenshot 是疏漏,Phase 1 起补上。

### ETS table lifecycle 跟 Application children 顺序(架构师 review P4-5)

`Ezagent.Kind.Server.init/1` 依赖三张 ETS table(`:ezagent_kind_registry` / `:ezagent_ready_gate` / `:ezagent_behavior_registry`),**必须**先于第一个 Kind 实例 spawn 时 ready。Phase 1 SPEC §1a-step 4 写 "启动时 spawn 一个 default echo 实例" — 如果 `EtsOwner` 启动顺序晚于 `EchoApplication`,**100% boot 失败**(`ArgumentError: ETS table does not exist`,或 `Registry not_alive`)。

**Phase 1 Application children 推荐顺序**(`apps/ezagent_core/lib/ezagent_core/application.ex`):

```elixir
children = [
  Ezagent.Core.EtsOwner,              # ① 起 5 张 ETS table(ReadyGate/PendingDelivery/Idempotency/BehaviorRegistry/KindRegistry-aux)
  {Registry, keys: :unique, name: Ezagent.KindRegistry},  # ② stdlib Registry
  Ezagent.Audit.Writer,               # ③ 异步 batch flush GenServer
  Ezagent.Idempotency.Sweeper,        # ④ LRU prune
  Ezagent.DLQ.Sweeper,                # ⑤ DLQ evict
  EzagentWeb.Endpoint                 # ⑥ HTTP/LV
  # ⑦ ezagent_plugin_echo 在自己的 mix.exs 依赖 ezagent_core,umbrella 自动后启动
]
```

**原则**:
- 任何 ETS-backed primitive **必须**在使用它的 GenServer 之前 ready
- umbrella `extra_applications` / `applications` 顺序保证 plugin app 后启动(因为 plugin depends on ezagent_core)
- 若顺序错,boot 期 Echo plugin 的 default 实例 spawn 撞 `Registry not_alive`,立即 `ArgumentError`
- 测试方法:`mix phx.server` 立刻可观察。boot 期 race 不可能在 unit test 中复现 — 这就是为什么必须 spec 预先列出

### Phase 0 既有的 `mix ezagent.check_invariants` 升级时机

Phase 0 留下骨架(no-op skeleton)。Phase 1 step 1 完成时:
- ReadyGate/PendingDelivery/Idempotency 模块已经存在
- KindRegistry/BehaviorRegistry 已经存在
- 不变式 #4(put_new for unique-key)已经可 grep

→ Phase 1 step 1 commit **同时升级** `mix ezagent.check_invariants`:加上 VERIFICATION.md 1a-G2 列的 5 条 grep 检查;后续 step 完成时再追加适用的(step 2 加 #2 #3,step 3 加 #1 #6 #7)。

---

## 跟 ARCHITECTURE.md / GLOSSARY.md 同步

**架构师本侧 patch**(工程师不动 ARCHITECTURE.md / GLOSSARY.md):
- **Patch A** — ARCHITECTURE.md §5.7.4 措辞更新为承认两条等价路径(宏 vs `@behaviour + 共享 Server`),P1-D2 的 trade-off 进 §5.7.4
- **Patch B** — GLOSSARY.md Decision Log **#84**:"Phase 1 采用路径 B 不用宏 — `@behaviour Ezagent.Kind` + 共享 `Ezagent.Kind.Server`;property 等价 #66 但 means 不同;共享 Server 把 Kind 隔离从 compile time 推到 runtime;Phase 1 接受 trade-off 因为只有 Echo 一个业务 Kind;Phase 2+ 若 state shape 假设冲突再评估"
- **Patch C** — GLOSSARY.md Decision Log **#85**:"`.claude/` 暂用 plain dir 不 vendor+submodule(Phase 0 实施期决策)— 短期符合"少发明多装配";trigger 迁 vendor: (a)出现 skill 需要 upstream 更新需求,或 (b)Phase 5 完成后整理 tech debt"

**工程师实施期可能再追加的条目**(等 /goal 跑完确认):
- Phase 1 不引入 `Ezagent.Bootstrap` 模块;admin 常量挂 `Ezagent.Entity.User`;`Ezagent.Capability.revoke/2` 守门(Decision #81 不动)— 大概 #86
- VERIFICATION 原则修订:gate checks 是 human review 的 **superset**(包含人类做的所有事,可以更多);Phase 0 memory 设的 "match" 措辞已纠正(2026-05-15 user-set memory 已修)— 大概 #87

具体编号实施期跟架构师对齐。
