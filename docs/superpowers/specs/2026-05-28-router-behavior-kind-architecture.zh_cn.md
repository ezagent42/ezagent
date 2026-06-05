# SPEC — Router/Behavior/Kind 自建架构（plugin 契约全量重写）

**状态：** r2 — codex r1 closures（7 HIGH + 4 MED + 2 LOW 全部内联处理；裁决从 REJECT → CONDITIONAL）
**取代（仅前向设计 — 备选方案历史保留）：** [PR #442 / `spec/eventstore-commanded-migration`](https://github.com/ezagent42/ezagent/pull/442)

## r2 changelog（codex r1 closures, 2026-05-28）

Codex r1 返回 **REJECT** 含 7 HIGH + 4 MEDIUM + 2 LOW。r2 通过 inline 编辑解决全部 13 个 finding（章节如下）：

| Finding | 处理位置 |
|---|---|
| HIGH-1 — effects 语法无法表达 `MessageStore.write` 这类返回值/事务性调用 | §4.4：新增 `{:effect_returning, mfa, args, bind_as: :name}` effect + §4.5 记录的 inline-Ecto 例外 |
| HIGH-2 — LegacyBehaviorAdapter 非 replay-equivalent | §6.1 Phase 1：明确标注 adapter 为 **dispatch-equivalent，NOT replay-equivalent** |
| HIGH-3 — Resource=on_change 对高频 ExternalMirrorWorker 错误（当前是 `:ephemeral`） | §5.2：Resource 模式拆为 `:cold_resource`（默认 `on_change`）+ `:hot_resource`（默认 `:ephemeral`） |
| HIGH-4 — Resource 所有权模型未明确（binding "属 Session" vs "属 Workspace"；cap-grant 双向） | §3.3：新增 `primary_owner` + `cascade_from` 区分；cap-grant 是 TWO Resource（GranteeView + GrantorView）相互 cross-link |
| HIGH-5 — Saga rollback 夸大为"自动补偿"；应该是"best-effort partial" | §4.4 + §5.4：明确改为 BEST-EFFORT，列出哪些 step 可补偿、哪些不可，destroy 级联留下 operator-repair marker |
| HIGH-6 — `ctx.read` 规则与例子矛盾（UserCredentials 内联调用 `Ezagent.Users.set_password`） | §4.5：新增"允许 inline 调用 vs forbidden"子节 — idempotent + transactional Repo writes 可 inline，详见允许清单 |
| HIGH-7 — `caps:` 宏不保留 5-轴 cap shape（`kind: :any`、scope tuple、cross-workspace） | §4.3：完整宏语法重写 — `caps: [{action, axes_map}]` 形式支持全部 5 轴 + scope 元组 + `workspace_scoped?: false` |
| MED-1 — Resource URI shape 缺 workspace 段 | §3.3 + OQ-1：URI 现为 `resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>` — workspace 段强制 |
| MED-2 — Multi-Behavior routing 未明示 BehaviorRegistry shape | §2.3 + §4.1：`attach Behavior, actions: […]` 构建等同于今天的 `BehaviorRegistry.register/3`；现存的 `%Capability{behavior: Module}` 行无需迁移 |
| MED-3 — 迁移对等测试排除 EventLog 行但 EventLog 有可观察消费者 | §7.3：拆分为"dispatch parity"（adapter 模式）vs "replay parity"（仅 native）。新增 EventLog 行被显式标记为 **intentional incompatibility** |
| MED-4 — 工作量估计偏乐观（8-10wk 最可能实际更接近 15-21wk） | §6.3 修订：最可能 14-17wk、上限 25wk。基线对比 PR-G AgentBridge（3wk 一个 plugin）+ PR-EM（5wk 一个 domain） |
| LOW-1 — `:dispatch_call` 在语法但 OQ-7 建议去掉 | §4.4：`:dispatch_call` 删除；saga 是唯一同步链接机制 |
| LOW-2 — PubSub ordering 例子与 OQ-3 推荐冲突 | §4.4：6 phase ordering 规范化；Chat 例子按 phase order 重排 |

详细英文版本见 EN spec 同段 r2 changelog。ZH 文件中关键章节（§3.3、§4.3、§4.4、§4.5、§5.2、§5.4、§6.1、§6.3、§7.3）的实质更新与 EN 平行；本 changelog 提供 quick-scan 索引。

**Allen 指令轨迹（2026-05-28 09:33 → 10:36）：** Allen 确认：(a) plugin 契约 full breaking-change 重写（Q2=a, 无兼容 shim），(b) 新前向 SPEC 取代 #442 §2–§12（Q3=a），(c) 两个 in-flight slice/snapshot bug（Bug A + Bug B）暂停 — 待本 SPEC 落地后重做。PR #442 §1.5.7（Native Consolidation Path / Option B''）是本 SPEC **直接上游的设计血脉**：B'' 识别出 5 个 framework primitive；本 SPEC 把它们收紧为 3-primitive（`Router` / `Behavior` / `Kind`）契约，**plugin 作者永远不接触 slice 或 snapshot**。

**架构承诺**：本 SPEC 是 ezagent 未来 8–10 周工作所承诺的设计（Phase 1：~3wk framework primitives；Phase 2：~4–6wk per-domain plugin 迁移；Phase 3+4：~1wk 清理）。北极星是 `feedback_north_star_plugin_isolation` — "未来开发者在不同 plugin 上独立工作，无需协调"。本 SPEC 中的每个决策都通过同一个问题来检验：这是否让 plugin 作者远离 core？

---

## 目录

- [§1 — 问题陈述](#§1--问题陈述)
- [§2 — 3 个核心原语（Router / Behavior / Kind）](#§2--3-个核心原语router--behavior--kind)
- [§3 — 3 种组合模式（Session / Entity / Resource）](#§3--3-种组合模式session--entity--resource)
- [§4 — Plugin 契约表面](#§4--plugin-契约表面)
- [§5 — Framework 机器（plugin 不可见）](#§5--framework-机器plugin-不可见)
- [§6 — Breaking-change 迁移计划](#§6--breaking-change-迁移计划)
- [§7 — 测试策略](#§7--测试策略)
- [§8 — 留给 Allen 的开放问题](#§8--留给-allen-的开放问题)
- [§9 — Codex 对抗式 review 攻击向量](#§9--codex-对抗式-review-攻击向量)
- [§10 — 迁移风险登记表](#§10--迁移风险登记表)
- [§11 — 验收标准（"完成"门）](#§11--验收标准完成门)

---

## §1 — 问题陈述

*本节回答："今天痛在哪里，把 Router/Behavior/Kind 命名为 3 个独立原语 — Behavior 对 slice 和 snapshot 失明 — 为什么能从结构上解决？"*

PR #442 §1.1–§1.4 已经全面盘点了痛点：没有正式的 event log，没有 replay，没有 projection 拆分，没有 saga 原语，没有 caller-supplied id 的幂等，没有跨 Kind 编排抽象。**本 SPEC 不重复那份盘点** — 阅读 PR #442 §1.1–§1.4 获取规范列表，然后回到这里看本 SPEC 新增的三个诊断轴。

### §1.1 — Plugin 作者认知超载类

当前 `@behaviour Ezagent.Behavior`（文件 `apps/ezagent_core/lib/ezagent/behavior.ex`，580 LOC 契约）强制每个 plugin 作者学习：

| 概念 | plugin 作者必须学的 | framework 泄漏出处 |
|---|---|---|
| Slice schema | Behavior 的 `state_slice/0` atom、slice 内部 shape、对 legacy snapshot 的防御性 `Map.get/3`、snapshot 加载时的 slice 合并（`load_or_init/3` 的 `init_slice` ∪ snapshot） | `state_slice/0`、`init_slice/1`、`invoke/4` 的第 3 个 arg |
| Snapshot 策略 | 5-enum `persistence/0`（`:ephemeral` / `{:snapshot, :on_change}` / `{:snapshot, :periodic, ms}` / `:on_terminate` / `:external`）、什么被持久化、什么不会、`:not_durable` 是什么意思 | `Kind.persistence/0`、post-init commit 细节、`handle_kind_message/3` 持久化、`terminate/3` slice 不持久化 |
| 不变式维护 | 跨 Behavior slice 字段（如 `:lifecycle` counter、`:identity` `caps`）、`reads_sibling_slices/0` 声明、对后注册 Behavior 的默认 `Map.update/4` 懒初始化 | `reads_sibling_slices/0`、`Kind.Runtime.maybe_inject_sibling_slices/3` |
| 从 `invoke/4` 内部跨 Kind dispatch | `Ezagent.Invocation.dispatch/1` 调用、ctx 传递、partial-failure 的 `try/rescue` 清理模式 | `EzagentDomainInstanceMessage.create_session/3` 是反模式典范：5 个 dispatch 跨 4 个 Kind，加手工编写的补偿 |
| 持久化错误语义 | `commit_and_notify/3` 返回 `{:error, _}` 时的处理 — `commit_post_init/2` 吞掉 + 记日志；`commit_and_notify/3`（dispatch 路径）传播 `{:persistence_failed, _}`；`persist_handle_info_mutation/4` 吞掉 | 3 条不同路径（dispatch / post-init / handle_info）3 种不同策略 |
| 带 action 轴的 Cap 声明 | `required_caps/0` 返回带 kind+behavior+action 的 `Capability.cap/3`；dispatch 时把 `:any` 替换；`cap_exempt_actions/0`；`workspace_scoped?/0`；`data_owner/1` | 4 个 callback 都和 `Kind.Runtime.handle_dispatch/4` step 5.5 互动 |
| Boot 顺序生命周期 | `post_init/2` + `handle_continue/3` + `on_ready/2` + `terminate/3` — 各自何时触发、什么被持久化、什么被丢弃 | `behavior.ex` 217-524 行的 4 个 optional callback |

那是 **8 个独立的概念簇**，plugin 作者必须在写第一个可 dispatch 的 action **之前**就内化。当前 `behavior.ex` moduledoc 是 580 LOC 契约；同类 Behavior 200–1300 LOC。signal-to-boilerplate 比很差。

**可追溯到 plugin 作者误用的历史 bug**：

1. **PR #141 SPEC v2 register/lookup key 对等** — register 与 lookup 之间 `workspace_scoped?` 默认值发散，dispatch 静默错绑（memory `feedback_register_lookup_key_parity`）。根因：plugin 作者必须知道 cap-key 对等不变式，而它隐式存在于两个独立 callback 中。
2. **PR #150 ApiKeys-to-Agent flip CRIT-1（`reads_sibling_slices` 逃生口）** — codex r1 标记原始的"通过 `ctx.all_slices` 暴露所有 sibling slice"让任何 Behavior 可读任何 sibling 的密钥。修复：`reads_sibling_slices/0` 显式列表。根因：plugin 作者需要跨 Behavior 读取，但 framework 唯一的机制是 full slice 暴露。
3. **SPEC #440 destroy 级联 — 4 轮 codex REJECT** — `Behavior.Lifecycle.invoke(:terminate)` 在返回 success 后 `Task.start(fn -> ... DynamicSupervisor.terminate_child ... end)`。"延迟终止"hack 是必要的，因为 `invoke/4` 跑在目标 Kind 的 GenServer 里 — 在 reply 落地前 kill self。根因：Behavior 代码里的跨 Kind 编排。
4. **SPEC #423 cap-vis 4 轮 REJECT 类** — 每轮 codex 都标记"plugin 代码读 framework 内部"（caps 存储 shape、slice projection 与 source-of-truth 等）。根因：slice 对 Behavior 的暴露泄漏了 framework cap 存储。
5. **SPEC #431 URI-canonical r2 fix** — 修复前的 snapshot 含 `URI.parse`-built `%URI{authority: "user"}` struct，与 canonical `URI.new!`-built shape 做 struct-equality 时静默失败。Plugin 作者朴素比较 URI；framework 只在某些缝隙做 canonical。根因：每个 Behavior 作者必须知道哪些缝隙做 canonical，哪些不做。

这违反了 `feedback_north_star_plugin_isolation`：plugin 作者想写一个 30 LOC 的 Behavior，必须先内化 ~580 LOC framework 契约，加 5+ 历史 bug post-mortem。**认知负担一直是每个多轮 REJECT 周期最大的隐藏成本。**

### §1.2 — 反复 4 轮 REJECT 类

最近 3 个 SPEC 撞了 4 轮 codex REJECT 墙：

| SPEC | codex 反复标记的 | 根因 |
|---|---|---|
| #440 destroy-lifecycle | "invoke/4 产生的合成事件不是真事件"、"deferred-termination Task 是为了绕开 self-kill 的 hack"、"cap on `(agent, :terminate)` 与 cap on `(workspace, :destroy)` 重叠" | `Behavior.invoke/4` 无法编排跨 Kind 清理；framework 没有 Saga 原语 |
| #442 eventstore-commanded | "Behavior 的 slice 暴露泄漏进业务代码"、"Behavior 中的 snapshot 策略把持久化关注点和 action 关注点搅在一起"、"Commanded 迁移只是把同样的搅合在 Commanded 原语上重写，而不是修复它们" | Plugin 契约把 3 个 framework 关注点（state、snapshot、跨 Kind dispatch）搅合进一个 callback |
| #423 cap-vis r1–r4 | "plugin 代码读 framework 内部"、"`required_caps/0` 上的 cap action 轴住在 plugin 代码里但由 framework matcher 解释" | `required_caps/0` 上的 cap action 轴是 plugin 声明的 shape 被 framework 消费；解释规则在每轮间游移 |

模式：codex 不是抓 SPEC 的缺陷；**codex 反复抓的是同一个结构性缺陷 — 抽象层位置错了。** Plugin 代码不应看到 slice、不应拥有 snapshot 策略、不应编排跨 Kind 清理、不应解释 cap 匹配语义。

### §1.3 — LOC 增长模式

当前 22 个 Behavior（`find apps -path "*/lib/ezagent/behavior/*.ex"` 产出）：

| Behavior | LOC | 模式主导者 |
|---|---:|---|
| Chat (`domain_instance_message/.../chat.ex`) | 1343 | invoke/4 + `MessageStore.write` + `Phoenix.PubSub.broadcast` + `Resolver.resolve` + N 个 recipient dispatch |
| Workspace (`domain_workspace/.../workspace.ex`) | 1332 | 跨 Kind 编排（workspace → bindings → sessions → agents）全在一个 invoke/4 |
| Identity (`domain_identity/.../identity.ex`) | 912 | cap MapSet 管理 + slice 字段 + boot reconcile + 跨 Kind grant 传播 |
| ExternalMirror (`domain_external_mirror/.../external_mirror.ex`) | 877 | binding 生命周期、per-binding Worker spawn、slice-as-projection-cache |
| AgentTemplate (`domain_instance_message/.../template.ex`) | 747 | template 实例化级联 |
| Sandbox (`core/.../sandbox.ex`) | 746 | config_dir 创建/销毁 + Template Class plugin 契约 |
| ExternalMirrorWorker (`...external_mirror_worker.ex`) | 692 | publisher cursor + ring + slice reconcile |
| Publisher.SessionImpl (`...publisher/session_impl.ex`) | 610 | slice-change 观察 + cursor 管理 |
| NpAgent / CurlAgent / Echo plugin Behavior | 1069（合计） | dispatch 扇出 + slice 作为请求日志 |
| UserTokens / WorkspaceUserAdmin / Lifecycle | 807（合计） | admin 操作 + workspace 传播 |
| ApiKeys / Routing / Echo / UserCredentials | 826（合计） | per-Behavior slice + cap 声明 |

**总计**：22 个模块约 11,000 LOC。其中粗略：

- ~30%（~3,300 LOC）— 真正的业务逻辑（action **意味着**什么）
- ~30%（~3,300 LOC）— slice 管理样板（读/写/默认/合并/reconcile）
- ~20%（~2,200 LOC）— 跨 Kind dispatch + 补偿（`try/rescue` 清理）
- ~10%（~1,100 LOC）— snapshot/持久化连线
- ~10%（~1,100 LOC）— cap 声明 & framework 接口样板

**60–70% 不是业务逻辑** 是本 SPEC 结构性消灭的类。Framework 吸收 slice/snapshot/dispatch/cap-interpretation 作为机器；plugin 作者写 action。

按 `feedback_let_it_crash_no_workarounds`：**结构修复是把抽象层下移**，不是加兼容 shim、不是叠加 Commanded 迁移、不是把 event-sourcing 作为第三方关注点。挪边界；重写一次 plugin 契约；完。

---

## §2 — 3 个核心原语（Router / Behavior / Kind）

*本节回答："plugin 和 operator 接触的三件东西是什么，各自由 framework 还是 plugin 拥有？"*

ezagent 架构可以归约为三个原语。代码库中的每个概念都从它们组合而来。

| 原语 | 拥有 | plugin 作者接触 |
|---|---|---|
| **Router** | dispatch 信封、cap 检查、审计、幂等、workspace 隔离、replay 路由 | 永不直接调用；接收路由进来的 command |
| **Behavior** | action 命名空间 + 每个 action 的 effects 如何计算 | 声明 `action/3` + 写 `handle_<action>/2` |
| **Kind** | URI 身份、进程生命周期、附加的 Behavior 列表、组合模式 | 声明 Kind + attach Behaviors |

### §2.1 — `Ezagent.Router`

#### 概念定义

Router 是 **dispatch 原语**。它接收一个 `%Cmd{target, action, args, ctx}` 信封并返回 `{:ok, result} | {:error, term}` — 处理完 URI 解析、capability 检查、幂等、workspace 隔离、审计写入、behavior-handler 路由、effect 应用、结果后处理。

概念上，它就是今天的 `Ezagent.Invocation.dispatch/1` + `Ezagent.Kind.Runtime.handle_dispatch/4` — 但**命名了**、**由 framework 拥有**、**从不从 Behavior 内部调用**。

#### Public API

```elixir
defmodule Ezagent.Router do
  @type cmd :: %Ezagent.Cmd{
    target: URI.t(),                # Kind 实例 URI
    action: atom(),                 # action atom，如 :send、:destroy
    args: map(),                    # 按 Behavior 的 @interface 校验
    ctx: %{
      caller: URI.t() | :system,
      reply: Ezagent.Invocation.reply_target(),
      trace_id: String.t(),
      command_uuid: String.t() | nil,   # 调用方提供的幂等 key
      deadline_ms: pos_integer() | nil
    }
  }

  @spec dispatch(cmd) ::
          {:ok, term()}
          | :ok
          | {:error, :unauthorized | :cross_workspace_denied | :no_such_actor |
                     :not_ready | {:unknown_action, atom()} | {:invalid_args, list()} |
                     {:behavior_exception, term(), term()} | term()}

  @spec dispatch_saga(saga :: Ezagent.Saga.t(), ctx :: map()) ::
          {:ok, effect_map :: map()}
          | {:error, step :: atom(), reason :: term(), compensated :: [atom()]}
end
```

#### 内部机制（framework 私有）

1. URI canonical 化（`Ezagent.URI.instance/1`）— 剥离 `?action=…`，规范化 scheme/host/path
2. 通过 `ctx.command_uuid`（如有）对 `Ezagent.Idempotency` 做幂等检查
3. Ready-gate 咨询（`:ready` / `:not_ready` / `:unknown` 按 `Ezagent.ReadyGate`）
4. Behavior 查找（`BehaviorRegistry.lookup({kind_module, action})`）
5. **在 dispatch 边界做 capability 检查** — Behavior 永远看不到
6. Workspace 隔离检查（caller 的 workspace ↔ target 的 workspace，`:any` 绕过）
7. Args 按 `behavior.interface()[action].args` 校验
8. 读取 framework 管理的状态（slice — 但 Behavior 拿到的是 `read/1` 函数，不是 slice 本身）
9. 调用 handler：`behavior.handle_<action>(args, ctx)` → 返回 `{result, effects}`
10. 按声明顺序应用 effects（参见 §4.4 vocabulary）
11. EventLog append（审计）
12. Snapshot commit（按 Kind 级策略 — Behavior 失明）
13. 结果后处理（按 ctx.reply 走 `Invocation.reply/2`）

#### Plugin 作者**接触**什么 vs **不接触**什么

| 关注点 | plugin 作者 | framework |
|---|---|---|
| 构造 `%Cmd{}` | Operator/LV/CLI/Channel adapter 构造 command（它们调 Router） | — |
| 调用 `Router.dispatch/1` | 调用（从 adapter） | — |
| 在 handler 收到 `(args, ctx)` | 看到 handler 的两个 arg | 注入 ctx |
| Capability 检查 | 永不 — 通过 `action/3` 宏的 `caps:` 声明 | 在 dispatch step 5 |
| 审计写入 | 永不 | 在 step 11 |
| Snapshot commit | 永不 | 在 step 12（按 Kind 策略） |
| 跨 Kind 级联 | 永不直接 — 发出 `{:dispatch, %Cmd{}, …}` effect 或返回 Saga | Router 路由该 effect |
| URI canonical 化 | 永不 | 在 step 1 |

#### 具体代码示例（5 行调用方）

```elixir
# LV handle_event — operator 点击 "Destroy" 按钮
def handle_event("destroy", %{"agent_uri" => uri_str}, socket) do
  caller = socket.assigns.current_user_uri

  cmd = %Ezagent.Cmd{
    target: URI.new!(uri_str),
    action: :destroy,
    args: %{},
    ctx: %{caller: caller, reply: :ignore, trace_id: socket.assigns.trace_id, command_uuid: nil}
  }

  case Ezagent.Router.dispatch(cmd) do
    {:ok, _} -> {:noreply, push_navigate(socket, to: ~p"/agents")}
    {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "权限拒绝")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, "失败：#{inspect(reason)}")}
  end
end
```

LV handler 的 shape 与 `:destroy` 住在 `Agent`（Entity 模式）、`Worker`（Resource 模式）还是 `Session`（Session 模式）无关。Router 不关心；Behavior 负责 `:destroy` 意味着什么。

#### 模块位置 & LOC

`apps/ezagent_core/lib/ezagent/router.ex` — ~150–200 LOC。大致：50 LOC dispatch pipeline + 50 LOC saga delegation + 50 LOC type 定义 + 30 LOC 错误规范化。它主要是今天 `Invocation.dispatch/1` + `Kind.Runtime.handle_dispatch/4` 的重构，**重命名 + slice 处理移到 framework 私有模块**。

---

### §2.2 — `Ezagent.Behavior`

#### 概念定义

一个 Behavior 是 **附加到一个或多个 Kind 的一束 action handler**。它声明哪些 action 存在、每个 action 需要的 args/caps/return、以及每个 action 的纯 `(args, ctx) → {result, effects}` 函数。

**与今天关键的 breaking change**：handler 不再接收 `slice`、不再返回 `new_slice`、永不直接调用 `Ezagent.Invocation.dispatch/1`。

#### Public API — 新宏

```elixir
defmodule Ezagent.Behavior.Chat do
  use Ezagent.Behavior

  # 声明式 action 命名空间 — 哪些 action 存在、schema 是什么、caps 是什么
  action :send,
    args: %{message: Ezagent.Message},
    returns: %{stored: :boolean},
    caps: [:send],                       # caller 必须持有 action: :send 的 cap
    modes: [:cast]

  action :receive,
    args: %{message: Ezagent.Message},
    returns: :ok,
    caps: [:receive],
    modes: [:cast]

  # Handler — 没有 slice arg，没有 new_slice 返回。
  # ctx 暴露 `read` 函数读取 framework 管理的状态。
  def handle_send(%{message: %Ezagent.Message{} = msg}, ctx) do
    session_uri = ctx.self_uri

    case ctx.read.(:last_message_id) do
      ^msg.id ->
        # 幂等重试 — 无 effects
        {:ok, %{stored: true}, []}

      _ ->
        recipients = Ezagent.Routing.Resolver.resolve(msg, session_uri, ctx.read.(:members))

        effects = [
          {:set, :last_message_id, msg.id},
          {:set, :last_message, msg},
          {:set, :send_cursor, ctx.read.(:send_cursor, 0) + 1},
          {:emit, :message_sent, %{message: msg, session_uri: session_uri}},
          {:notify, "esr:session:#{URI.to_string(session_uri)}:events",
                    {:chat_message, session_uri, msg}}
        ] ++ Enum.map(recipients, fn rcpt ->
          {:dispatch, %Ezagent.Cmd{
            target: rcpt, action: :receive,
            args: %{message: msg},
            ctx: %{caller: session_uri, reply: :ignore, command_uuid: "chat:#{msg.id}:#{rcpt}"}
          }}
        end)

        {:ok, %{stored: true}, effects}
    end
  end

  def handle_receive(%{message: msg}, ctx) do
    case ctx.kind_module do
      Ezagent.Entity.User ->
        {:ok, :ok, [
          {:set, :recent_messages, prepend_bounded(ctx.read.(:recent_messages, []), msg, 20)},
          {:emit, :message_received, %{user_uri: ctx.self_uri, message: msg}}
        ]}

      Ezagent.Entity.Agent ->
        {:ok, :ok, [
          {:effect, &Ezagent.AgentBridge.deliver/2, [ctx.self_uri, msg]},
          {:emit, :message_received, %{agent_uri: ctx.self_uri, message: msg}}
        ]}
    end
  end
end
```

#### 宏机制

`use Ezagent.Behavior` 注入：

- `@before_compile` 钩子聚合所有 `action :name, ...` 声明到 `actions/0`、`required_caps/0`、`interface/0`、`cap_subjects/0` — legacy 契约 callback 从新的声明式形式自动派生。
- 一个 `handle_<action>/2` dispatcher 供 Router 调用。
- 编译时不变式：每个 `action :foo, …` 声明 **必须** 有匹配的 `def handle_foo(args, ctx)`。plugin checks（当前 `Ezagent.Invariants.BehaviorRequiredCapsParityTest`）变成编译期错误。

#### `ctx.read` 契约

在 handler 内，`ctx.read.(key)` 和 `ctx.read.(key, default)` 读取当前 Kind 实例的 **framework 管理状态**。Handler：

- **不能** 把 slice 看作数据结构（无防御性 `Map.get`，无 merge-on-load 关注点）
- **不能** 直接看到 sibling-Behavior 状态（跨 Behavior 读通过 Kind 声明的 cross-behavior-read 契约 — 见 §3.4 Mapping 表）
- 得到 strongly-consistent、进程内的读（同一个 GenServer 进程拥有状态）

#### Plugin 作者**接触**什么 vs **不接触**什么

| 关注点 | plugin 作者 | framework |
|---|---|---|
| 声明 action | 通过 `action :name, args: …, caps: […]` 宏 | 聚合到 `actions/0`/`interface/0`/`required_caps/0` |
| 写 `handle_<action>/2` | 是 | Router step 9 调用它 |
| 读当前状态 | 通过 `ctx.read.(:key)` | 拥有存储 |
| 变更状态 | 永不直接 — 发出 `{:set, key, value}` effect | 按顺序应用 effects |
| 发出事件 | 永不直接 — 发出 `{:emit, type, payload}` effect | 写入 EventLog |
| 跨 Kind dispatch | 永不直接 — 发出 `{:dispatch, %Cmd{}}` effect | Router 扇出 |
| Snapshot | 永不 — Kind 级策略 | 是 |
| Cap 检查 | 永不 — 通过 `caps:` 声明 | 在 Router 边界 |
| 补偿 / saga | 永不在 `handle_<action>/2` 里 — handler 返回 `{:ok, result, [{:saga, %Ezagent.Saga{…}}]}` 或编排者构造 saga 并 `Router.dispatch_saga/2` 运行它 | `Ezagent.SagaRunner` |

#### 模块位置 & LOC 预算

`apps/ezagent_core/lib/ezagent/behavior.ex` — ~250–300 LOC（宏 + behaviour callback 定义）。当前 580 LOC `behavior.ex` 缩小因为：

- `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3` boot-lifecycle 钩子成为 Kind 级关注点（大多数 Behavior 不需要；需要的 Kind — 如 ExternalMirror Worker — 在 Kind 上声明，而不是每个 Behavior 上）。
- `reads_sibling_slices/0` 消失（Kind 声明跨 Behavior read 图；见 §3.4）。
- `state_slice/0` 消失（Kind 通过声明的字段 schema 从 Behavior 贡献组合状态 — 见 §4.4 effects vocabulary）。
- `reconcile_after_load/2` 成为 Kind 级关注点（Kind 从其附加的 Behavior 贡献组合 rebuild）。

---

### §2.3 — `Ezagent.Kind`

#### 概念定义

一个 Kind 是 **一类有状态实体的命名类**，具有 URI、生命周期和状态。ezagent 今天有 13 个 Kind（数所有当前 `entity://` 方案 + `session://` + `system://` 派生）。每个 Kind 声明：其 URI 方案、附加的 Behavior、组合模式（§3）、监督策略、持久化策略。

Plugin 作者声明 Kind。它们**不**接触 Kind 的状态机器 — 那是 framework 内部。

#### Public API — Kind 声明

```elixir
defmodule Ezagent.Entity.Agent do
  use Ezagent.Kind,
    pattern: :entity,                            # 见 §3
    uri_scheme: "entity://agent/",
    supervisor: EzagentDomainInstanceMessage.AgentSupervisor

  # 附加到此 Kind 的 Behavior（以及 cap 限制 shape）
  attach Ezagent.Behavior.Chat,            actions: [:receive]
  attach Ezagent.Behavior.Identity,        actions: [:list_caps, :grant_cap, :revoke_cap]
  attach Ezagent.Behavior.Sandbox
  attach Ezagent.Behavior.ApiKeys
  attach Ezagent.Behavior.Lifecycle,       actions: [:destroy]

  # 跨 Behavior read 图（替换 per-Behavior `reads_sibling_slices/0` 声明）
  read_graph %{
    Ezagent.Behavior.Chat => [Ezagent.Behavior.ApiKeys],
    # Agent 上的 Chat handler 读 ApiKeys.key 以附加 Authorization header
  }

  # 组合模式的必需位（Entity 模式 — §3.2）
  owner_kind Ezagent.Entity.User
  authenticates_via Ezagent.Behavior.ApiKeys
end
```

#### 必需与可选 callback

Legacy `@behaviour Ezagent.Kind` callback（`type_name/0`、`behaviors/0`、`persistence/0`、`uri_from_args/1`、`snapshot_version/0`、`supervisor/0`、`spawn_strategy/0`、`terminate_strategy/0`、`holds_cap?/2`）归约为：

| 新 | 替换（今天） | 拥有者 |
|---|---|---|
| `pattern:` 宏 arg | （无 — 模式隐式） | 由 Kind 作者声明 |
| `attach Behavior, opts` | `behaviors/0` + per-Behavior `required_caps/0`/`actions/0` 切分 | 由 Kind 作者声明 |
| `uri_scheme:` 宏 arg | 每个 Kind 硬编码 module attr | 由 Kind 作者声明 |
| `supervisor:` 宏 arg | `supervisor/0` callback | 由 Kind 作者声明 |
| `spawn_strategy:`/`terminate_strategy:` 宏 arg | 同上 | 由 Kind 作者声明 |
| `read_graph` | per-Behavior `reads_sibling_slices/0` | 由 Kind 作者声明 |
| **（framework 拥有，无 Kind callback）** | `persistence/0` | **framework 按模式决定** — 见 §5.2 |
| **（framework 拥有）** | `snapshot_version/0` | framework 从 EventLog event-type 版本派生 |
| **（framework 拥有）** | `holds_cap?/2` | framework — 用 `EventLog.stream_by_aggregate` + projection |

#### 内部机制

- `Kind.Server` GenServer（`apps/ezagent_core/lib/ezagent/kind/server.ex`，今天 828 LOC）变成 `apps/ezagent_core/lib/ezagent/kind/host.ex` — 同样角色但状态模型对 framework 私有。
- GenServer 上的状态是一个以 `{behavior_module, field_atom}` 为 key 的单一 map（替换今天嵌套的 `%{slice_key => slice_map}`）。Effect `{:set, key, value}` 填充该 map；`ctx.read.(:key)` 查询；Behavior 永不看到外层 map shape。
- `reads_sibling_slices/0` 变成 Kind 的 `read_graph` 声明 — 编译期对附加的 Behavior 的 action 做校验。
- **`attach Behavior, actions: [...]` 填充 BehaviorRegistry**（codex r1 MED-2 closure）：宏在 app boot 时 emit 等同于今天 `Ezagent.BehaviorRegistry.register(kind_module, action, behavior_module)`。路由 key 仍是 `(kind_module, action)` → `behavior_module`，**与今天 lookup shape 相同**。User identity slice 中现存的 `%Capability{behavior: Ezagent.Behavior.Identity, ...}` MapSet 条目仍有效 — Behavior 模块引用跨宏变更保留。**cap 行无需 DB 数据迁移。**

#### 模块位置 & LOC

`apps/ezagent_core/lib/ezagent/kind.ex` — 宏（~150 LOC）+ behaviour（~50 LOC），从今天的 459 LOC 降，因为 `holds_cap?/2`、`default_holds_cap?/2`、`get_slice/2`、spawn/terminate 策略逻辑移到 framework 内部模块（`Ezagent.Kind.Host`、`Ezagent.Caps.Engine`）。

`apps/ezagent_core/lib/ezagent/kind/host.ex` — ~400–500 LOC（host 每个 Kind 实例的 GenServer）。

---

## §3 — 3 种组合模式（Session / Entity / Resource）

*本节回答："每个 Kind 都恰好是三种模式之一；这是 plugin 作者唯一需要知道的、决定哪种生命周期、身份、cap shape 适用的知识。"*

一个 Kind **总是恰好是**三种组合模式之一。模式决定：URI 方案约定、生命周期钩子、默认 caps、所有权 shape、允许哪些跨 Kind 引用。

| 模式 | URI 方案 | 生命周期 | 认证 | 拥有 | 典型 Behavior |
|---|---|---|---|---|---|
| **Session** | `session://` | 创建 → 成员加入 → 消息 → 归档 | 继承 caller 身份 | 消息、成员、监视器 | Chat、ExternalMirror Worker binding、Routing |
| **Entity** | `entity://kind/workspace/name` | 注册 → 授 caps → 运行 → 销毁 | password/token/key（按 Kind 的 `authenticates_via`） | Resources | Identity、Credentials、Lifecycle、Sandbox |
| **Resource** | `resource://owner_kind/owner_name/type/name` | 创建 → 变更 → 销毁（与 owner 级联） | 由 Entity 所有权（传递） | 无 | 通常一个 Behavior |

### §3.1 — Session 模式

#### 定义

一个 **多参与方、有时限** 的上下文，调解实体之间的通信或状态协调。URI 方案：`session://<template>/<workspace>/<name>`（如 `session://default/team-alpha/main`）。

#### 属性

- **多参与方**：成员加入/离开；一个 Session 可附加 N 个实体
- **有时限**：有独立于任何单个成员的生命周期
- **外部绑定**：可选绑定到外部 channel（Feishu 群、WS bridge）通过 ExternalMirror — binding 是 Session 拥有的 Resource
- **消息是一等事件**：每个 `:send` 是 EventLog 行；replay 有意义（审计、time-travel）
- **身份继承**：Session 不认证；caller 的 Entity URI 通过 ctx.caller 流过

#### 生命周期钩子（framework 提供，per-Kind opt-in）

- `created` — 第一个 dispatch 到达，尚无成员
- `member_joined(entity_uri)` — Routing 更新扇出表
- `message_sent(msg)` — EventLog append；PubSub 扇出
- `member_left(entity_uri)` — 如果是最后一个成员，可能归档 Session
- `archived` — 冻结状态；允许读；不再有新 dispatch

#### 当前匹配此模式的 Kind

`Ezagent.Entity.Session`（尽管它的模块名 — 它**是** Session 模式 Kind）。

### §3.2 — Entity 模式

#### 定义

一个 **命名的、可认证的主体** — user、agent、workspace、template。URI：`entity://<kind>/<workspace>/<name>`。有 admin 生命周期（创建 / 销毁 / 更新）。可能拥有 Resources。

#### 属性

- **可认证**：声明一个 `authenticates_via` Behavior — `User` 通过 `UserCredentials`（密码）；`Agent` 通过 `ApiKeys`；`Workspace` 通过成员资格；`AgentTemplate` 通过 owner-cap 继承
- **拥有 Resources**：每个 Entity 可拥有 N 个 Resource；销毁 Entity 级联到其 Resources（saga 驱动、framework 管理）
- **持 cap**：持有 capability（委托、结构、admin 授予）
- **Admin 生命周期**：workspace-scoped admin 可创建 / 更新 / 销毁

#### 当前匹配此模式的 Kind

`Ezagent.Entity.User`、`Ezagent.Entity.Agent`、`Ezagent.Entity.Workspace`、`Ezagent.Entity.AgentTemplate`、`Ezagent.Entity.SessionTemplate`。

### §3.3 — Resource 模式

#### 定义

一个 **由 Entity 拥有**、由 URI 引用、生命周期管理、per-action 授权检查的东西。URI 方案：`resource://<owner_kind>/<workspace>/<owner_name>/<type>/<name>`（如 `resource://agent/team-alpha/cc_demo/config-dir/main`）。

**Codex r1 MED-1 closure** — URI 现包括 workspace 段以防止跨 workspace 冲突（`resource://agent/team-alpha/cc_demo/...` 与 `resource://agent/system/cc_demo/...` 是不同的）。workspace 段是 Resource 创建时的 **owner 的 workspace**，对 Resource 整个生命周期不可变。

#### 属性

- **有 `primary_owner`**：控制 Resource 生命周期（创建/销毁/cap-shape 决策）的 Entity URI。作为 Resource Kind 的一部分声明，不作为 slice 字段。
- **可能有 `cascade_from`**：SECONDARY 关系 — 当 cascade-from Entity 被销毁，此 Resource 也被销毁，**即使** 其 primary_owner 仍活着。用于 cap-grant 这样的关系（见下文）。
- **类型标记**：每个 Resource 声明其类型（`:config-dir`、`:secret`、`:file`、`:binding`、`:cap-grant`、`:token`……）
- **Per-action 授权**：caps 按 action 检查；primary_owner 隐式授权大多数 action，但可通过 per-action `caps:` 声明覆盖
- **Owner 销毁时级联**：当 primary_owner 或任何 `cascade_from` Entity 被销毁，framework 的 destroy-saga（§5.4）销毁此 Resource

**Codex r1 HIGH-4 closure（Resource 所有权模型）** — 早期草稿有两个矛盾：

1. **§3.1** 说外部 binding "属 Session"，**§3.3** 说"属 Workspace"。修复：binding 是 **primary_owner: Session, cascade_from: Workspace**。销毁 Session 销毁 binding（primary 生命周期）；销毁 Workspace 也销毁 binding（cascade — binding 不能比 workspace 活更久）。
2. **Cap-grant 是双向的** — User1 授 cap 给 User2。谁"拥有"该 grant？grantor 控制 revocation；grantee 在 identity slice 持有 cap 用于匹配。单一 `owner_uri` 表达不了。修复：cap-grant 是 **TWO Resource** — `GrantorView`（primary_owner: grantor, 索引"我授出去什么"）和 `GranteeView`（primary_owner: grantee, 索引"我持有什么 cap"），通过共享 `grant_id` 链接。两者都有 `cascade_from: <另一方>` — 销毁 grantor User 也级联销毁 GranteeView（grant 不再有效）；销毁 grantee User 级联销毁 GrantorView。Router step 5 的 cap matcher 只读 GranteeView。

#### 当前**是** Resources 的项目（一些今天嵌入在 Entity slice 中 — 边界修复）

| Resource | 当前住在 | 应该是 | 新 URI shape |
|---|---|---|---|
| Agent 的 config-dir | Agent Kind 上的 `Behavior.Sandbox` slice | Agent 拥有的 `Resource` Kind | `resource://agent/cc_demo/config-dir/main` |
| Agent 的 API keys | Agent Kind 上的 `Behavior.ApiKeys` slice | Agent 拥有的 `Resource` Kind | `resource://agent/cc_demo/api-key/anthropic` |
| User 的密码哈希 | `Ezagent.Users` Ecto schema（不在 slice — 已经是 Resource shape，只是不可 URI 寻址） | `Resource` Kind | `resource://user/admin/credential/password` |
| Workspace 的 binding（Feishu chat → Session） | `external_mirror_bindings` 表，ExternalMirror Kind 上的 slice-projection | Workspace 拥有的 `Resource` Kind | `resource://workspace/team-alpha/binding/feishu-main` |
| User 到 Agent 的 cap-grant | User Kind 上的 `Ezagent.Behavior.Identity` slice（`:caps` MapSet） | User（授予方）拥有的 `Resource` Kind | `resource://user/admin/cap-grant/123e4567` |
| Agent 的 lineage parent | `Ezagent.AgentLineage` ETS 表 | 保持为 registry（**不是** Resource — 它是查询索引，不是可寻址状态） | （无 URI；仅 registry） |
| User 的 magic-link token | `Ezagent.Entity.MagicLinkToken`（当前自己是一个 Kind — 已是 Resource shape） | `Resource` Kind | `resource://user/<owner>/magic-link/<token-id>` |

此边界修复是迁移中 plugin 作者实际看到的最大单一变化。今天，"config-dir" 是一个 slice 字段；明天，它是一个 Resource，有自己的 URI、自己的生命周期、自己的 cap shape。Plugin 作者写一次 Resource Kind；cascade-on-destroy 从 framework 免费获得。

### §3.4 — Mapping 表 — 当前 Kind → 模式

| 当前 Kind | 模块路径 | 模式 | 边界问题（file:line） |
|---|---|---|---|
| `Ezagent.Entity.User` | `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:1` | Entity | 今天：`MagicLinkToken` 是平行 Kind 但概念上 owned-by-User — 应是 `resource://user/<owner>/magic-link/<id>` |
| `Ezagent.Entity.Agent` | `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex:1` | Entity | 今天：`:sandbox` slice 持 `config_dir_path`（行 79：附加 `Ezagent.Behavior.Sandbox`） — 应是 Resource。`:api_keys` slice（行 80：`Ezagent.Behavior.ApiKeys`） — 应是 Resource |
| `Ezagent.Entity.Workspace` | `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:1` | Entity | 今天：binding 生命周期泄漏到 `Behavior.Workspace` slice — bindings 应是 Workspace 拥有的 Resource |
| `Ezagent.Entity.AgentTemplate` | `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex:1` | Entity | 干净 — 已是 Entity shape |
| `Ezagent.Entity.SessionTemplate` | `apps/ezagent_domain_instance_message/lib/ezagent/entity/session_template.ex:1` | Entity | 干净 |
| `Ezagent.Entity.Session` | `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:1` | **Session** | 今天唯一的 Session 模式 Kind。误导性 `Entity.` 命名空间 — 迁移后重命名为 `Ezagent.Session.Default` |
| `Ezagent.Entity.ExternalMirrorWorker` | `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:1` | **Resource** | 当前命名为 `Entity.` 但概念上由 `(Workspace, Binding)` 拥有。因此有两层 supervisor。URI 应为 `resource://workspace/<ws>/worker/<binding-id>` |
| `Ezagent.Entity.Token` | `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:1` | Resource | 已 owned-by-User，只是没 URI-shaped 为 resource |
| `Ezagent.Entity.MagicLinkToken` | `apps/ezagent_domain_identity/lib/ezagent/entity/magic_link_token.ex:1` | Resource | User 拥有 |
| `Ezagent.Entity.Profile` | `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:1` | Resource（或合并入 User） | 今天平行 Kind；大多只读展示数据 — OQ-5 |
| `Ezagent.Plugin.Np.Agent` | `apps/ezagent_plugin_np/lib/ezagent/entity/np_agent.ex:1` | Entity | plugin 定义 |
| `Ezagent.Plugin.Curl.Agent` | `apps/ezagent_plugin_curl_agent/lib/ezagent/entity/curl_agent.ex:1` | Entity | plugin 定义 |
| `Ezagent.Plugin.Echo.Echo` | `apps/ezagent_plugin_echo/lib/ezagent/entity/echo.ex:1` | Entity | plugin 定义（测试 plugin） |
| `Ezagent.Entity.System` | `apps/ezagent_core/lib/ezagent/entity/system.ex:1` | Entity（bootstrap 特例） | 用于 `:system` caller 主体；大多 framework 拥有 |

**按模式计数**：1 个 Session，9 个 Entity（5 个 ezagent + 3 个 plugin + 1 个 system），3 个 Resource（今天；边界修复后再多 ~5 个）。

---

## §4 — Plugin 契约表面

*本节回答："plugin 作者写新 Behavior 或 Kind 时接触的全部表面是什么？"*

### §4.1 — 整个契约

一个 plugin 定义：

1. **零个或多个 Kind**（通常只有 ezagent core + 每个 domain 定义 Kind；大多数 plugin 把 Behavior 附加到现有 Kind）
2. **一个或多个 Behavior**（每个 Behavior 是一束 action）
3. **一个 plugin 模块** 在 app boot 时把它们接起来

```elixir
defmodule Ezagent.Plugin.MyPlugin do
  use Ezagent.Plugin

  # 1. 声明新 Kind（仅当引入新的时）
  defkind MyEntity,
    pattern: :entity,
    uri_scheme: "entity://my-kind/",
    behaviors: [Behavior.MyKind.Basic, Behavior.MyKind.Advanced]

  # 2. 附加 Behavior 到现有 Kind（最常见情况）
  attach_behavior Behavior.MyCrossKind, to: [Ezagent.Entity.Agent, Ezagent.Entity.User]
end

defmodule Behavior.MyKind.Basic do
  use Ezagent.Behavior

  action :greet,
    args: %{},
    returns: %{greeted: :boolean},
    caps: [:greet],
    modes: [:call]

  def handle_greet(_args, ctx) do
    name = ctx.read.(:name, "world")
    {:ok, %{greeted: true}, [
      {:emit, :greeted, %{to: name, at: DateTime.utc_now()}}
    ]}
  end
end
```

那是 **整个** plugin 契约。每个 Behavior 通常 ~10–30 LOC（从今天 200–1300 LOC 降）。

### §4.2 — 并排：3 个当前 Behavior 重写前后

#### 例 1：`Behavior.UserCredentials.set_password`

**重写前**（`apps/ezagent_domain_identity/lib/ezagent/behavior/user_credentials.ex`，177 LOC）：

```elixir
defmodule Ezagent.Behavior.UserCredentials do
  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:set_password]

  @impl Ezagent.Behavior
  def required_caps do
    %{set_password: Ezagent.Capability.cap(:user, __MODULE__, :set_password)}
  end

  @impl Ezagent.Behavior
  def cap_subjects, do: [{:set_password, "set or rotate user password (bcrypt)"}]

  @impl Ezagent.Behavior
  def state_slice, do: :user_credentials

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{set_password_count: 0}

  @impl Ezagent.Behavior
  def invoke(:set_password, slice, %{password: pw}, ctx) do
    case Ezagent.Users.set_password(ctx.self_uri, pw) do
      :ok ->
        new_slice = Map.update(slice, :set_password_count, 1, &(&1 + 1))
        {:ok, new_slice, %{user_uri: URI.to_string(ctx.self_uri), password_set: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{set_password: %{
      description: "...",
      args: %{password: :string},
      returns: %{user_uri: :string, password_set: :boolean},
      modes: [:call]
    }}
  end

  @impl Ezagent.Behavior
  def data_owner(%URI{} = uri), do: uri
end
```

**重写后**（`apps/ezagent_domain_identity/lib/ezagent/behavior/user_credentials.ex`，~30 LOC）：

```elixir
defmodule Ezagent.Behavior.UserCredentials do
  use Ezagent.Behavior

  action :set_password,
    args: %{password: :string},
    returns: %{user_uri: :string, password_set: :boolean},
    caps: [:set_password],
    description: "set or rotate user password (bcrypt)",
    data_owner: :self,                # self = ctx.self_uri 拥有此 action 的目标
    modes: [:call]

  def handle_set_password(%{password: pw}, ctx) do
    case Ezagent.Users.set_password(ctx.self_uri, pw) do
      :ok ->
        {:ok,
         %{user_uri: URI.to_string(ctx.self_uri), password_set: true},
         [{:emit, :password_set, %{user_uri: ctx.self_uri, at: DateTime.utc_now()}}]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

**LOC 减少**：177 → ~30（83% 减少）。

#### 例 2：`Behavior.Lifecycle.terminate`

**重写前**（`apps/ezagent_core/lib/ezagent/behavior/lifecycle.ex`，243 LOC — 用 deferred-task hack 避免 self-kill 占 ~50 LOC 管道）：

```elixir
def invoke(:terminate, slice, _args, ctx) do
  self_uri = Map.get(ctx, :self_uri)
  kind_module = Map.get(ctx, :kind_module)
  schedule_termination(self_uri, kind_module)   # Task.start → 20ms sleep → DynamicSupervisor.terminate_child
  notify_spawning_principal(self_uri)            # AgentLineage → Notifications.notify
  {:ok, bump(slice), {:ok, :terminated}}
end
```

**重写后**（~25 LOC；framework 通过 `{:terminate, self}` effect 处理延迟终止）：

```elixir
defmodule Ezagent.Behavior.Lifecycle do
  use Ezagent.Behavior

  action :destroy,
    args: %{},
    returns: %{destroyed: :boolean},
    caps: [:destroy],
    data_owner: :self,
    modes: [:call]

  def handle_destroy(_args, ctx) do
    # destroy saga 处理级联 + 清理；framework 知道 Kind 的
    # 组合模式（Entity）并先遍历拥有的 Resources。
    {:ok, %{destroyed: true},
     [{:emit, :destroyed, %{uri: ctx.self_uri, by: ctx.caller, at: DateTime.utc_now()}},
      {:terminate, :self}]}  # framework 在 dispatch reply 后延迟终止
  end
end
```

Resource 级联（User destroy → 撤销所有 caps → 销毁所有 sessions → 销毁所有 agents）不再由 `EzagentDomainInstanceMessage.create_session/3`-style 命令式代码手工编排。Framework 的 destroy-saga 按声明顺序遍历 `pattern: :entity` 声明的 Resource 集合，任何步骤失败时自动补偿。见 §5.4。

**LOC 减少**：243 → ~25（90% 减少）。

#### 例 3：`Behavior.Chat.send`（最大、最复杂的 Behavior）

**重写前**（`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:297-419`，仅 `:send` 占 ~120 LOC）：

预存 handler 做：`MessageStore.write` → `Phoenix.PubSub.broadcast` → `WorkspaceRegistry.lookup` → `Routing.Resolver.resolve` → `notify_dropped_mentions` → 按 recipient `dispatch_receive` / `dispatch_cross_session` → 为 SliceChange 的 3 字段 slice 变更。

**重写后**（~35 LOC）：

```elixir
action :send,
  args: %{message: Ezagent.Message},
  returns: %{stored: :boolean},
  caps: [:send],
  modes: [:cast]

def handle_send(%{message: %Ezagent.Message{} = msg}, ctx) do
  session_uri = ctx.self_uri
  members = ctx.read.(:members, %{})
  workspace_uri = ctx.read.(:workspace_uri)

  case Ezagent.Routing.Resolver.resolve(msg, session_uri, Map.keys(members),
                                         workspace_uri: workspace_uri) do
    [] ->
      {:ok, %{stored: false, reason: :no_recipients}, []}

    recipients ->
      # Codex r1 HIGH-1 closure：用 :effect_returning 拿到 stamped message。
      # 下游 effects 通过 {:ref, :stored_msg, [...]} 引用它。
      # Effects 按 §4.4 中声明的 6 个 phase 触发：
      #   Phase 1 (:set)：slice 更新
      #   Phase 2 (:emit)：EventLog append
      #   Phase 3 (:effect_returning + :effect)：副作用（Repo 写在这里）
      #   Phase 4 (:dispatch)：跨 Kind 扇出
      #   Phase 5 (:notify)：PubSub broadcast
      #   Phase 6 (:terminate/:saga)：post-reply（这里 n/a）
      effects = [
        # Phase 3：Repo 写（返回 stamped msg 给下游 ref）
        {:effect_returning, &Ezagent.MessageStore.write/2, [msg, session_uri],
         bind_as: :stored_msg},

        # Phase 1：slice 更新 — 通过 {:ref, ...} 引用 stored stamped msg
        {:set, :last_message_id, {:ref, :stored_msg, [:id]}},
        {:set, :last_message,    {:ref, :stored_msg}},
        {:set, :send_cursor,     ctx.read.(:send_cursor, 0) + 1},

        # Phase 2：EventLog append
        {:emit, :message_sent, %{message: {:ref, :stored_msg}, session_uri: session_uri,
                                  recipient_count: length(recipients)}}
      ] ++
      # Phase 4：per-recipient dispatch（通过 {:ref, ...} 用 stored msg）
      Enum.map(recipients, &recipient_dispatch_effect(&1, session_uri)) ++
      [
        # Phase 5：dispatch 入队后通知 session 订阅者
        {:notify, "esr:session:#{URI.to_string(session_uri)}:events",
                  {:chat_message, session_uri, {:ref, :stored_msg}}}
      ]

      {:ok, %{stored: true}, effects}
  end
end
```

**LOC 减少**：~120 → ~45（62% 减少；比 r1 估计略大因 `:effect_returning` + `{:ref, ...}` 引用多几个字符但完全显式）。`notify_dropped_mentions` 旁路移到 `Routing.Resolver.resolve` 的返回（它知道哪些 mention 被丢弃）。

**此例中可见的 phase 排序**：runtime 按 phase 应用 effects，而不是按源码行顺序 — 但源码行分组让意图明显。dispatch effect 中的 `command_uuid` 不再需要 message id（framework 在替换前从 stored msg 的 id 派生）。

### §4.3 — Capability 声明

Caps 在 **`action/3` 宏内部** 声明 — 没有独立的 `required_caps/0` callback。Router 在 dispatch 边界、handler 运行**之前**强制 cap。Handler 永远看不到 auth 状态。

```elixir
action :grant_cap,
  args: %{target_uri: URI, cap: Ezagent.Capability},
  returns: :ok,
  caps: [
    {:grant_cap, scope: :self},        # caller 可授其持有的 caps
    {:grant_cap_any, scope: :admin}    # 或 admin 可授任意 caps
  ],
  modes: [:call]
```

**完整 `caps:` 语法**（codex r1 HIGH-7 closure — 保留今天 `%Ezagent.Capability{}` struct 支持的所有 5 轴 — `kind`、`behavior`、`action`、`instance`、`workspace_uri` — 加 scope 元组）：

```elixir
caps: [
  # 形式 1：裸 atom — 速记为 {action: :send, ...defaults...}
  :send,

  # 形式 2：带显式轴的 tuple
  {:send, kind: :session, action: :send, instance: :self_target, workspace_uri: :target_workspace},

  # 形式 3：带 scope 元组（within-session、within-workspace、spawned-by）
  {:read, scope: {:within_session, :ctx_session}},
  {:cross_workspace_grant, scope: {:within_workspace, :any}},
  {:terminate, scope: {:spawned_by, :ctx_principal}},

  # 形式 4：kind 轴通配 — 用于 Chat 这种 multi-Kind Behavior
  {:receive, kind: :any},

  # 形式 5：workspace_scoped? 退出（per-action）
  {:admin_grant, kind: :user, workspace_scoped?: false},
]
```

`caps:` 参数接受一个列表，每项是 atom（`:send`）— 解糖为 `{:send, []}` 带默认值；或 tuple `{action_atom, opts_keyword}`：

| 键 | 值 | 默认 | 备注 |
|---|---|---|---|
| `kind` | atom（如 `:user`、`:session`）或 `:any` | 此 Behavior 附加的 Kind | 通配 `:any` 用于 Chat 这种跨 Kind Behavior（今天的 `Capability.cap(:any, ...)`） |
| `behavior` | module atom | `__MODULE__`（当前 Behavior） | 很少覆盖 |
| `action` | atom 或 `:any` | 此 `caps:` 声明所在的 action | `:any` 意味着"此 Behavior 的任何 action 都匹配" |
| `instance` | `:self_target` / `:any` / 具体 URI | `:self_target`（dispatch 的 target URI） | `:any` 用于类范围 cap |
| `workspace_uri` | URI / `:target_workspace` / `:any` | `:target_workspace`（从 target 派生） | `:any` 用于跨 workspace cap |
| `scope` | `{:within_session, X}` / `{:within_workspace, X}` / `{:spawned_by, X}` | （无） | `X` 是字面量 URI 或替换 token（`:ctx_session`、`:ctx_principal`、`:ctx_workspace`） |
| `workspace_scoped?` | `true` / `false` | `true` | `false` 时绕过 step 5.6 cross-workspace iso（今天的 `Behavior.workspace_scoped?/0` 退出） |

**替换语义**：`:self_target` / `:target_workspace` / `:ctx_session` 这类 token 在 dispatch 时对实际 `%Cmd{}` 和 `ctx` 求值。它们 **不是** plugin 持有的运行时值；宏在编译时把替换 emit 为 struct 字段，Router 在 step 5 替换。

**Cap-vis SPEC #423 r4**（带 `{:within_session, S}` shape 的 action-axis caps）完全可表达：

```elixir
caps: [{:read_messages, action: :any, scope: {:within_session, :ctx_session}}]
```

**Multi-Kind Behavior**（Chat 附加到 Session + User + Agent — 三个 Kind）用 `kind: :any` 声明单一 cap shape 匹配 dispatch 落到的任何 Kind：

```elixir
defmodule Ezagent.Behavior.Chat do
  use Ezagent.Behavior

  action :receive,
    args: %{message: Ezagent.Message},
    returns: :ok,
    caps: [{:receive, kind: :any}],   # 匹配 Chat 附加的任何 Kind
    modes: [:cast]
  # ...
end
```

今天 `IdentityAdmin` 的 `workspace_scoped?: false`（跨 workspace admin Behavior）表达为：

```elixir
action :grant_user_in_other_workspace,
  args: ...,
  caps: [{:cross_workspace_grant, kind: :user, workspace_scoped?: false}],
  ...
```

### §4.4 — Effects vocabulary

Effects 是 handler 引起世界改变的 **唯一** 方式（一个例外：idempotent 的 inline Repo 写 — 见 §4.5）。完整语法：

| Effect | 含义 | 例 |
|---|---|---|
| `{:set, key, value}` | 更新此 Kind 实例的 framework 管理状态 | `{:set, :last_message_id, msg.id}` |
| `{:emit, event_type, payload}` | 向 EventLog 追加事件（审计 + replay） | `{:emit, :message_sent, %{...}}` |
| `{:dispatch, %Cmd{}}` | 通过 Router 扇出到另一个 Kind（异步 — cast 语义） | `{:dispatch, %Cmd{target: rcpt, action: :receive, ...}}` |
| `{:notify, topic, payload}` | Phoenix.PubSub broadcast（UI / 外部） | `{:notify, "esr:session:…:events", msg}` |
| `{:effect, mfa_or_fn, args}` | 副作用 — 文件/IO/外部 API 调用；framework 包装审计 + （可选）重试；**返回值丢弃** | `{:effect, &Ezagent.AgentBridge.deliver/2, [user_uri, msg]}` |
| `{:effect_returning, mfa_or_fn, args, bind_as: name}` | 同 `:effect` 但绑定返回值到 handler 的续接 map 的 `name`；后续 effects 可以用 `{:ref, name, path}` 引用（codex r1 HIGH-1 closure） | `{:effect_returning, &MessageStore.write/2, [msg, session_uri], bind_as: :stored_msg}` |
| `{:terminate, :self \| uri}` | 调度延迟 Kind 终止（reply 后） — framework 处理级联 | `{:terminate, :self}`（Lifecycle.destroy） |
| `{:saga, %Ezagent.Saga{}}` | 把剩余级联交给 SagaRunner | （见 §5.4） |
| `{:halt, reason}` | 中止：framework 回滚已应用 state effects，丢弃待处理 effects，返回 `{:error, reason}` | `{:halt, :preflight_failed}` |

**HIGH-1 closure**：早期草稿用 `{:effect, ...}` 表达 `MessageStore.write`，但 legacy handler 依赖其 **返回值**（stamped message）做后续 broadcast/dispatch effects。一个 fire-and-forget effect 表达不了这个。两种解决，都采纳：

1. **`:effect_returning`** 是结构化方式：handler 声明"我需要这个 Repo 写的返回值给后续 effects"；framework 执行调用、绑定结果、在应用后续 effects 之前把 `{:ref, :stored_msg, [:id]}` 引用替换掉。
2. **Inline Repo 例外**（§4.5）让 handler 在调用 idempotent + transactional 的 Repo-backed 模块时可以 inline。这是 `UserCredentials.set_password` 例子的前提。

Chat.send 例子（§4.2 Example 3）重写为用 `:effect_returning`；handler 然后用 `{:ref, :stored_msg, ...}` 引用声明所有下游 effects。

**Effects 顺序语义**（规范，codex r1 LOW-2 closure）：

Effects 在 **每个 phase 内按声明顺序** 触发。6 个 phase 顺序运行：

1. **Phase 1 — `:set`**：状态更新作为单个 Ecto 事务 + EventLog appends 一起应用（handler 的 `ctx.read` 读 pre-handler 快照；in-flight `:set` effects 对同一 handler 后续 `ctx.read` 不可见）
2. **Phase 2 — `:emit`**：事件按声明顺序 append 到 EventLog，**与 phase 1 同事务**
3. **Phase 3 — `:effect_returning`** 然后 **`:effect`**：副作用在 phase 1+2 事务 commit 后触发，按声明顺序。`:effect_returning` 结果绑定到续接 map，之后的 effects 才被求值
4. **Phase 4 — `:dispatch`**：跨 Kind dispatch 按声明顺序入队（每个是 async cast — Router 并发扇出；dispatch 之间的顺序是 best-effort）
5. **Phase 5 — `:notify`**：Phoenix.PubSub broadcast 按声明顺序触发（LV / 外部订阅者在 dispatched Kind 启动后看到、但不一定在它们完成前 — 按设计：notify 是"我身上发生了什么"信号，dispatch 是真正的扇出）
6. **Phase 6 — `:terminate` / `:saga`**：在同步 reply 交付后触发

`{:halt, reason}` 短路 phase 1+2 — 已声明的 `:set`/`:emit` effects **不 commit**（事务回滚）；handler 似乎从未运行。Phase 3-6 effects 永不到达。

**HIGH-5 closure（saga compensation honesty）**：phase 6 的 saga 只能 **补偿本身可逆的步骤**。不可逆的副作用（phase 5 已发出的 PubSub broadcast、phase 3 已发起的外部 API 调用、phase 4 已被另一个 Kind 消费的 dispatch）**不会** 回滚 — saga 在 EventLog 标记它们为"irreversibly happened"并继续补偿能补偿的。Destroy 级联是 **best-effort partial restore**，**不是** true rollback。详见 §5.4 显式补偿契约。

### §4.5 — 与当前契约比，什么消失了

| Callback / 概念 | 今天 | 新设计 |
|---|---|---|
| `Behavior.invoke/4` | 第 3 arg slice；返回 `{:ok, new_slice, result}` | `handle_<action>/2`；返回 `{:ok, result, [effect]}` |
| `state_slice/0` | Behavior 声明其 slice key | 消失 — Kind 通过字段 schema 拥有状态组合 |
| `init_slice/1` | Behavior 构建其初始 slice | 消失 — Kind 的 `attach Behavior, init_state: %{...}`（或 per-Kind `init_state/1`） |
| `persistence/0` | per-Kind enum（5 值） | 消失 — framework 按模式决定（见 §5.2） |
| `reads_sibling_slices/0` | per-Behavior 列表 | `Kind.read_graph` — Kind 级声明一次，编译检查 |
| `data_owner/1` | per-Behavior callback | per-action `data_owner:` 宏 arg 带声明 shape（`:self`、`:any`、`{:owner_of, kind}` 等） |
| `cap_subjects/0` | per-Behavior 列表 | per-action `description:` 宏 arg |
| `required_caps/0` | per-Behavior map | per-action `caps:` 宏 arg |
| `cap_exempt_actions/0` | per-Behavior 列表 | action 上 `caps: []` 空列表 |
| `workspace_scoped?/0` | per-Behavior boolean | Kind 级 `workspace_scoped:` 宏 arg（默认 `true`） |
| `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3` | per-Behavior optional callback | per-Kind 生命周期钩子（通过 `lifecycle/2` 宏声明；大多数 Kind 不需要） |
| `reconcile_after_load/2` | per-Behavior callback | per-Kind 从 EventLog rebuild（framework）+ optional `on_rebuild/1` Kind callback |
| 从 `invoke/4` 内部 `Ezagent.Invocation.dispatch/1` | 允许（Chat 使用） | **禁止** — 发出 `{:dispatch, %Cmd{}}` effect |
| 从 `invoke/4` 内部 `Phoenix.PubSub.broadcast/3` | 允许 | **禁止** — 发出 `{:notify, topic, payload}` effect |
| `MessageStore.write` 等 — Repo-backed 查询模块 | 允许 | **有条件允许 inline**（见 §4.5.1 下）；否则用 `{:effect_returning, ...}` |

### §4.5.1 — 允许 inline 调用 vs 禁止调用（codex r1 HIGH-6 closure）

**"plugin 代码可 inline 调用"与"plugin 代码必须走 effects"的界**：

| 调用 shape | 允许 handler 内 inline？ | 为什么 |
|---|---|---|
| `ctx.read.(:key)` — framework 状态 | ✓ 总是 | 这就是 read API |
| 自己 domain 模块中的纯函数 | ✓ 总是 | 如 `Routing.Resolver.resolve/4` — 纯 |
| Registry 式 lookup：`AgentLineage.lookup`、`WorkspaceRegistry.lookup` | ✓ 总是 | 只读 ETS 读；幂等档同 `ctx.read` |
| 带 **idempotent** 写的 Repo-backed 查询模块（`Ezagent.MessageStore.write/2` — `ON CONFLICT DO NOTHING`；`Ezagent.Users.set_password/2` — 全行替换） | ✓ 允许 | 每调用是自己的事务；retry-safe；失败暴露为 `{:error, _}` handler 可返回 |
| **非** idempotent 的 Repo-backed 写 | ✗ 禁止 | 必须走 `{:effect_returning, fn, args, bind_as: ...}` 让 framework 包装 retry + audit |
| 通过 `Ezagent.Invocation.dispatch/1` 跨 Kind dispatch | ✗ 禁止 | 总是通过 `{:dispatch, %Cmd{}}` effect |
| Phoenix.PubSub.broadcast | ✗ 禁止 | 总是通过 `{:notify, topic, payload}` effect |
| 文件系统写、外部 HTTP、OS 级副作用 | ✗ 禁止 | 总是通过 `{:effect, mfa, args}` — framework 包装 retry + audit |
| 通过 `Kind.get_slice/2` 读任何其他 Kind 的状态 | ✗ 禁止 | 跨 Kind 读走 `ctx.read`（Kind 的 `read_graph` 声明它们） |

**为什么这个例外**：强制每个 Ecto 写走 `{:effect_returning, ...}` 给常见情况（旋转密码、写聊天消息）增加语法负担但不带来 replay-equivalence（Ecto 写是 source of truth；replay 重建 slice 状态，**不是** Ecto 行）。该例外是 **有限可枚举的允许 Repo-backed 查询模块清单**；新增需要 SPEC 变更。§7.4 的 grep-gate 按名字强制 — 不在允许清单中的任何 Repo 模块触发 gate。

**允许清单**（初始；可通过 SPEC 增长）：

- `Ezagent.Users.*` — User Ecto schema（罕见写 — 密码旋转、profile 更新）
- `Ezagent.MessageStore.write/2` — 消息持久化（在 `(id, session_uri)` 上幂等）
- `Ezagent.AgentLineage.*` — 今天只读 ETS；如果变为写支持，移到禁止
- `Ezagent.WorkspaceRegistry.lookup/1` — 只读 ETS
- `Ezagent.CapabilityRegistry.*` — 只读路径

直接调用 `Ezagent.Repo` 在 plugin 代码中 **禁止** — 把它包装在一个 domain 查询模块中，经过审查纳入允许清单。

---

## §5 — Framework 机器（plugin 不可见）

*本节回答："被删除的 plugin 关注点现在住在哪里，framework 如何结构化？"*

Framework 内部住在 `apps/ezagent_core/lib/ezagent/` 下，**永远不**被 plugin 引入。

### §5.1 — `Ezagent.EventLog`

Append handler 通过 `{:emit, …}` effect 发出的事件。包装现有 `invocations` 表（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6`）。Public API：

```elixir
@spec append(envelope :: map) :: :ok | {:error, term}
@spec stream_by_aggregate(uri :: URI.t, opts :: [from: DateTime.t, limit: pos_integer]) :: [event_row]
@spec stream_by_workspace(ws :: URI.t, opts) :: [event_row]
@spec stream_since(cursor :: DateTime.t, opts) :: [event_row]
```

**排序**：行按 `(inserted_at ASC, id ASC)` 排序 — `id` 作为同微秒写入的 tie-breaker。游标分页 key 为 `(inserted_at, id)`。

**无 plugin 接触**。Router 写；StateRebuilder 读。

**LOC**：~150（大多在现有 `Audit.Writer` 上的委托）。

### §5.2 — `Ezagent.SnapshotStore`

管理 per-Kind 状态 snapshot。Framework 按组合模式决定 snapshot 策略（Resource 有一个子分类）— plugin 作者挑模式但 **永不** 直接挑策略：

| 模式 | 默认策略 | 理由 |
|---|---|---|
| Session | `every_n_events: 100` + `on_archive` | Session 有高事件量；周期 snapshot 限制 replay 成本 |
| Entity | `on_change`（同步） | Entity 很少变；per-mutation 持久化便宜 |
| Resource（`:cold_resource`）— 默认 | `on_change`（同步） | per-action 变更不频繁；per-mutation 持久化便宜 |
| Resource（`:hot_resource`） | `:ephemeral`（不持久化）+ opt-in `{:periodic, ms}` | 高频 Resource 状态为遥测/cursor/counter — 重启丢失是 by-design |

**HIGH-3 closure**：早期草稿让 Resource = `on_change` 统一，这会让 `Ezagent.Entity.ExternalMirrorWorker`（当前 `:ephemeral`，因为 publish cursor + count 是纯遥测；见 `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:50`）的写入率 10 倍。修复是 `:hot_resource` 子分类 — 在 Kind 通过 `pattern: {:resource, :hot}` 声明（cold 就是 `pattern: :resource`）。双轴模式保留"framework 决定策略"，同时保留现有 Worker 的正确性。

Kind 宏接受：

```elixir
use Ezagent.Kind, pattern: :entity                    # 默认 Entity → on_change
use Ezagent.Kind, pattern: :resource                  # 默认 cold Resource → on_change
use Ezagent.Kind, pattern: {:resource, :hot}          # hot Resource → ephemeral
use Ezagent.Kind, pattern: {:resource, :hot, periodic: 5_000}  # opt-in periodic
use Ezagent.Kind, pattern: :session                   # Session → every_n_events
```

**Plugin 作者不直接挑 `on_change`** — 他们挑模式，framework 挑策略。真正 pattern-misfit 的 Kind 的逃生口是 `pattern: {:custom, hooks: [...], snapshot: :on_change}` — 但用它是 SPEC 变更（该 Kind 离开标准 3 模式 + 显式 review）。

每个模式的默认是 **`Ezagent.SnapshotStore` 中一次性做出的单一决策**，不是 22 个 per-Behavior `persistence/0` 声明。

Public API：

```elixir
@spec latest(uri :: URI.t) :: {:ok, state :: map, version :: non_neg_integer} | :empty
@spec write(uri :: URI.t, state :: map) :: :ok | {:error, term}
@spec delete(uri :: URI.t) :: :ok
```

**LOC**：~200（现有 `Kind.Snapshot` 逻辑，去掉 5-enum dispatch — 模式 dispatch 取代）。

### §5.3 — `Ezagent.Kind.StateRebuilder`

泛化今天的 per-domain `BootReconciler`（当前只有 `ExternalMirror.BootReconciler`）。在 Kind 进程 spawn（冷启动、重启或崩溃后第一次 dispatch）时：

1. 从 `SnapshotStore.latest/1` 读 snapshot
2. 通过 `EventLog.stream_by_aggregate(uri, from: snapshot.at)` stream snapshot 之后的事件
3. 通过每个 Behavior 的 framework 派生 `apply_event/2`（从原 handler 中的 `{:set, …}` 和 `{:emit, …}` effect 自动生成）把事件 fold 进 snapshot 状态
4. 可选：per-Kind `on_rebuild/1` callback — 在 fold 后、`:ready` 前运行，让 Kind 对 DB-projection-backed 字段做 reconcile（今天的 `reconcile_after_load/2` use-case）

**Plugin 作者永不调用此模块**。Framework 从 `Kind.Host.init/1` 调。

**LOC**：~200。

### §5.4 — `Ezagent.SagaRunner`

带补偿的单次调用线性编排。在以下情形使用：

- handler 返回 `{:saga, %Ezagent.Saga{steps: [...]}}` effect
- framework destroy 级联（Entity destroy → Resource 列表 → 按声明顺序遍历）
- framework 的 per-pattern 生命周期 saga（Session create → workspace bind → publisher start → ready）

Public API（`Sage` 子集 — 不需要并行/异步）：

```elixir
defstruct steps: [], compensations: [], ctx: %{}, name: nil, command_uuid: nil

@spec new(name :: String.t, opts :: [command_uuid: String.t]) :: t
@spec step(saga, name :: atom, forward :: (map -> {:ok, term} | {:error, term}),
                                compensate :: (map, map -> :ok | {:error, term})) :: t
@spec execute(saga, initial_ctx :: map) ::
        {:ok, effect_map :: map}
        | {:error, step :: atom, reason :: term, compensated :: [atom]}
```

**Saga 补偿声明**（OQ-4）：内联步对 `(forward, compensate)`。Framework 在失败时反向补偿。Per-step `command_uuid = "saga:<saga_name>:step:<step_name>"` 提供崩溃后幂等重试语义。

**补偿诚实性（codex r1 HIGH-5 closure）**：补偿是 **best-effort partial restore**，**不是** true rollback。SagaRunner 契约：

| Step 类型 | 可补偿？ | "补偿"意味着 |
|---|---|---|
| 纯状态变更（slice 变化） | ✓ 完全可逆 | forward 前 snapshot slice；rollback 时恢复 |
| `:emit` 事件（仅审计） | ✓ 通过 append 补偿事件可逆（不是删除） | append `:compensated_<event>` 事件；下游消费者看到两个 |
| `:dispatch` 跨 Kind（已 cast 到另一个 Kind） | ✗ 不可逆 | dispatched Kind 可能已经动作；saga 在 EventLog 标记"irreversibly happened" |
| `:notify` PubSub broadcast（订阅者已收到） | ✗ 不可逆 | 同上 — 订阅者已动作；saga 标记不可逆 |
| `:effect` 外部 IO（文件写、HTTP 调用） | ✗ 一般不可逆 | 补偿函数可尝试反操作（DELETE 文件、POST "rollback"）；但原 effect 仍记"已发生" |
| `:terminate`（Kind 已终止） | ✗ 同调用内不可逆 | 终止后重 spawn 是 SEPARATE Kind 实例 — 原 caps/state **丢失** |

**诚实的 destroy 级联契约**：当 destroy User → 撤销 caps → 销毁 sessions → 销毁 agents → 销毁 resources → terminate user — 如果"销毁 agents"在"销毁 sessions"成功 **之后** 失败：

1. saga 反向补偿会尝试 **resurrect sessions** 通过从 pre-destroy snapshot 重 spawn
2. 但 destroy 窗口期间从外部 channel（Feishu）到达的任何 in-flight 消息 **丢失** — 因 Session 不在被丢弃
3. 重生的 Session 是新 GenServer 进程；订阅者（LV chat 流、ExternalMirror Worker）需要重新订阅
4. saga 在 EventLog 标记 resurrection 为 `{:partial_restore, sessions_resurrected: [...], messages_lost: <count>}`
5. 写一个 operator-repair marker：`{:saga_incomplete_restore, saga: "destroy_user:#{uri}", step: :destroy_agents, recoverable: false}` — 在 `/admin/saga_history` LV 可见

**这解决 SPEC #440** 通过对什么可能诚实，**不是** 通过声称假 rollback。codex 在 #440 r4 标记的"User 处于不一致状态"失败模式变成 **declared、observable、repair-tracked** 状态而非静默不一致。operator 有 UI 看到"此 destroy 90% 成功；丢了 1 条消息；这是修复 handle。"

**LOC**：~200（现有 `EzagentDomainInstanceMessage.create_session/3` 手工 `try/rescue` 清理模式，提升为可复用原语）+ ~50 LOC 用于 partial-restore marker 处理。

### §5.5 — `Ezagent.EventSubscriber`

用于异步、事件驱动的跨 Kind 反应：

```elixir
defmodule Ezagent.Plugin.ExternalMirror.WorkerBootstrapSubscriber do
  use Ezagent.EventSubscriber, application: :ezagent_domain_external_mirror

  def interested?(%{type: :binding_created, kind_module: Ezagent.Entity.Workspace}), do: true
  def interested?(_), do: false

  def handle_event(%{target: workspace_uri, args: %{adapter: a, params: p}}, state) do
    {:dispatch, [%Ezagent.Cmd{
      target: derive_worker_uri(workspace_uri, a),
      action: :spawn,
      args: %{adapter: a, params: p},
      ctx: %{caller: :system, reply: :ignore,
             command_uuid: "subscriber:worker-bootstrap:#{workspace_uri}"}
    }], state}
  end
end
```

Subscriber **声明** 事件兴趣 + handler；framework 拥有监督、重启、排序。

**LOC**：~250（behaviour + supervisor + registry）。

### §5.6 — `Ezagent.Caps.Engine`

中心化 cap 匹配 — Router step 5 的瓶颈。今天的 `Ezagent.Capability.matches?/2` + `Kind.holds_cap?/3` + `Kind.default_holds_cap?/2` 合并到这里。Plugin Behavior 永不直接调用；它们声明 `caps:`，引擎消费声明。

**LOC**：~250（大多是现有 `Ezagent.Capability` 1038 LOC 瘦身 — 今天该文件大部分是 `Capability.cap/3`、`Capability.cap_for_action/3`、`matches?/2` 之间的 shape 转换胶水。一旦 `caps:` 声明化，转换胶水消失）。

### §5.7 — `Ezagent.Kind.Host`

host 每个 Kind 实例的 GenServer（替换今天的 `Ezagent.Kind.Server`，828 LOC）。同样角色 — 但状态是 `{behavior_module, field} → value` 扁平，effect 应用通过 Router pipeline 而不是 Server 内部，snapshot/事件/通知顺序由 framework 拥有。

**LOC**：~400–500。

### §5.8 — Framework 内部总 LOC

| 模块 | LOC |
|---|---:|
| `Ezagent.Router` | ~200 |
| `Ezagent.Behavior`（宏 + behaviour） | ~300 |
| `Ezagent.Kind`（宏 + behaviour） | ~200 |
| `Ezagent.Kind.Host`（GenServer） | ~500 |
| `Ezagent.EventLog` | ~150 |
| `Ezagent.SnapshotStore` | ~200 |
| `Ezagent.Kind.StateRebuilder` | ~200 |
| `Ezagent.SagaRunner` | ~200 |
| `Ezagent.EventSubscriber` | ~250 |
| `Ezagent.Caps.Engine` | ~250 |
| `Ezagent.Cmd`（struct） | ~30 |
| **总计** | **~2,480** |

今天的等价物（散布在 `behavior.ex`、`kind.ex`、`kind/server.ex`、`kind/runtime.ex`、`kind/snapshot.ex`、`snapshot/writer.ex`、`audit.ex`、`audit/writer.ex`、`invocation.ex`、`capability.ex`、`slice_change.ex`、`behavior_registry.ex`、`capability_registry.ex`、`idempotency.ex`、`ready_gate.ex`、`pending_delivery.ex` 中）：

今天大致 ~5,000 LOC framework 代码。新设计是 **~2,500 LOC framework** — **framework LOC 减半**，做的事更多（Router、EventLog stream-by-aggregate、SagaRunner、EventSubscriber、StateRebuilder 是新原语）。

**净 plugin 代码节省**：按 §1.3，plugin Behavior 今天共计 ~11,000 LOC；新设计目标 ~3,500 LOC（真正的业务逻辑）。**~7,500 LOC plugin 样板被消除。**

**总净**：跨代码库大约 -10,000 LOC（framework 省 2,500 + plugin 省 7,500）。被消除的每一行都是高认知负担（§1.1 的 8 概念簇代码）。

---

## §6 — Breaking-change 迁移计划

*本节回答："鉴于 Allen 授权 Q2=a（无兼容 shim），具体如何从今天到那里？"*

### §6.1 — Phase 计划

#### Phase 1 — Framework primitives（暂无 plugin 迁移）

- 构建 `Ezagent.Router`、`Ezagent.Behavior`（新宏）、`Ezagent.Kind`（新宏）、`Ezagent.Kind.Host`、`Ezagent.EventLog`、`Ezagent.SnapshotStore`、`Ezagent.Kind.StateRebuilder`、`Ezagent.SagaRunner`、`Ezagent.EventSubscriber`、`Ezagent.Caps.Engine`
- **`LegacyBehaviorAdapter`** — 老的 `Behavior.invoke/4`-shape Behavior 通过 adapter 包装 `invoke/4` 返回成新 effect shape。Adapter：
  - 通过 `Map.merge` diff 新老 slice 并为每个变化的 top-level key 发出 `{:set, key, value}` effect
  - 把 legacy handler 已执行的副作用（PubSub broadcast、跨 Kind dispatch、MessageStore write）包装成 `{:legacy_already_executed, [<副作用描述符列表>]}` 审计记录 — 在 EventLog 可见但 **不可重执行**
  - **明确标注 NON-REPLAY-EQUIVALENT**（codex r1 HIGH-2 closure）：adapter 保留运行时 dispatch 行为（相同 reply、相同时间的 PubSub broadcast），但 **不** 保留 replay 语义。adapter 模式 Behavior 的 EventLog 行不能通过 `apply_event/2` fold 进状态，因为 legacy handler 的副作用发生在 effect 语法 **外**。StateRebuilder 对 adapter 模式 Behavior 视为"snapshot-only"— 依赖 snapshot 而非 event fold。Phase 3 后（adapter 删除、所有 Behavior native），完整 replay-equivalence 成立。
  - **从第一天起被标记删除** — 有 `delete-by-end-of-phase-3` 标签的 issue、每次加载发 deprecation warning、`mix ezagent.audit.legacy_adapter` task 列出剩余调用点
  - 估计 ~300-400 LOC（加进 Phase 1 LOC 预算；§5.8 表早期遗漏）
- 所有当前测试通过（legacy plugin 通过 adapter 编译 + 运行）
- 估计：**~4-5 周**（codex r1 MED-4 closure — 从 3wk 上调；adapter 非平凡且 framework primitive 在构建期间暴露潜在设计问题，~1wk 用于 OQ 1-8 设计收敛）

#### Phase 2 — Per-Domain plugin 迁移

每个 domain 把其 Behavior 和 Kind 迁移到新契约。顺序优化为最小化爆炸半径：

| PR | Domain | Behavior | 风险 |
|---|---|---|---|
| Phase 2 PR 1 | `ezagent_core` | Lifecycle、Routing、Sandbox、Notifications、Presence | 低 — core 测试基础设施捕获回归 |
| Phase 2 PR 2 | `ezagent_domain_identity` | Identity、UserCredentials、UserTokens、ApiKeys、WorkspaceUserAdmin | 中 — auth 触及每个 dispatch |
| Phase 2 PR 3 | `ezagent_domain_workspace` | Workspace | 中 — workspace iso 在每个 dispatch step 5.6 |
| Phase 2 PR 4 | `ezagent_domain_instance_message` | Chat、Template、OrchestratorAdmin、Publisher.SessionImpl | 高 — Chat 是最大 Behavior、多 Kind |
| Phase 2 PR 5 | `ezagent_domain_external_mirror` | ExternalMirror、ExternalMirrorWorker、Publisher | 高 — Worker 有两层 supervisor + boot reconciler |
| Phase 2 PR 6 | `ezagent_domain_pty` | Pty | 低 — 表面小 |
| Phase 2 PR 7 | Plugin 包 | NpAgent、CurlAgent、Echo | 低 — plugin 隔离 |
| Phase 2 PR 8 | Resource 边界修复 | Sandbox config-dir → Resource；ApiKeys → Resource；Workspace bindings → Resource | 中 — schema 迁移触及 DB |

每个 PR 独立通过迁移对等测试（§7.3）。Legacy adapter 保留直到每个 domain 都迁移完。

估计：**~4–6 周**（可按 domain 并行；取决于一周能否落地多个 domain — Allen 的 review 带宽是约束）。

#### Phase 3 — 删除 legacy adapter

- 删除 `LegacyBehaviorAdapter`
- 所有 Behavior 在新宏下编译
- 从 `Ezagent.Behavior` 删除 `:invoke/4` callback
- CI grep 门：`apps/*/lib/.../behavior/*.ex` 中零 `def invoke(`

估计：**~3 天**。

#### Phase 4 — 清理

- `Kind.Server` → `Kind.Host` 重命名（或保留为别名，PR 时决定）
- 删除 `Kind.Runtime`（其职责融入 Router + Kind.Host）
- `Kind.Snapshot` → `SnapshotStore` 重命名
- `Ezagent.Invocation` 保留 reply/24h-format 机器；`dispatch/1` 入口变成薄 facade 调 `Router.dispatch/1`（或如所有调用方已更新则删除）
- 文档重写（CONTRIBUTING.md、plugin author guide、ARCHITECTURE.md）
- `slice_change.ex` SliceChange 模块重命名为 `Ezagent.StateChange`，语义收紧（现在是事件驱动，不是 slice-diff 派生）

估计：**~4 天**。

### §6.2 — Per-Behavior 改造清单

每个当前 Behavior，迁移的 plugin 作者：

1. **识别 `invoke/4` body 中所有 slice 读** → 替换为 `ctx.read.(:key)` 或 `ctx.read.(:key, default)`
2. **识别所有 slice 写**（返回的 `new_slice` map delta）→ 按声明顺序发出 `{:set, key, value}` effect
3. **识别所有 `Snapshot.Writer` / `Snapshot.save_now` 调用** → 删除（framework 处理）
4. **识别 `invoke/4` 内部所有 `Ezagent.Invocation.dispatch/1` 调用** → 发出 `{:dispatch, %Cmd{...}}` effect
5. **识别所有 `Phoenix.PubSub.broadcast/3` 调用** → 发出 `{:notify, topic, payload}` effect
6. **识别所有直接副作用**（文件写、Repo 写、外部 API 调用）→ 发出 `{:effect, &fn/N, args}` effect
7. **识别所有 cap 检查 / `Ezagent.Capability.matches?` 调用** → 删除（framework 通过 `caps:` 声明处理）
8. **识别错误返回** — 区分业务错误（handler 返回 `{:error, reason}`）与基础设施错误（让 framework 处理 — handler raise，framework 捕获并写 failure event）
9. **转换 `state_slice`/`init_slice` 声明** → Kind 级 `attach Behavior, init_state: %{...}` 或 per-Kind `init_state/1`
10. **转换 `data_owner/1`** → action 级 `data_owner:` 宏 arg
11. **转换 `required_caps/0` / `cap_subjects/0` / `cap_exempt_actions/0`** → action 级宏 arg
12. **转换 `post_init/2` / `handle_continue/3` / `on_ready/2` / `terminate/3`** → Kind 级生命周期钩子（如有；大多没有）
13. 重跑 domain 测试套件；确保迁移对等测试 §7.3 通过

### §6.3 — 估计工作量（含置信区间）（codex r2 r3 — 从 GitHub PR 历史的数据驱动重新校准）

> **r3 方法**：依据 Allen 2026-05-28 11:44 指令，r2 估计（14-17 wk 最可能，25 wk 上限）是从两个引用先例（PR-G ~3 wk、PR-EM ~5 wk）做的*定性*推断。r3 从 GitHub PR 历史挖掘了这两个 + 其他 6 个可比迁移，计算经验速度并据此推断。r2 估计**假设了人类节奏的循环时间**；ezagent 实际的自主循环速度显著更快，所以数据驱动的重新校准**收紧**而不是拓宽区间。

#### §6.3.1 — 速度校准语料（从 `gh pr view` 挖掘）

每行 = 一个历史迁移系列；"经过 hr" = 该系列首个 PR `min(created)` → 末个 PR `max(merged)`；LOC + / - / net 跨所有 PR 求和；"Behaviors" / "Kinds" = 新建或契约迁移的数量。

| 系列 | PR 数 | 经过 (hr) | LOC + | LOC − | 净 | Files | Behaviors | Kinds | 跨 plugin 契约边界？ | 类型 |
|---|---|---:|---:|---:|---:|---:|---:|---:|:---:|---|
| `plugin-contract` (#217..#223) | 5 | 1.18 | 3,854 | 678 | 3,176 | 46 | 0 | 0 | 是 | framework |
| `phase7-template` (#231..#250，含 10 轮 hardening) | 20 | 4.80 | 17,591 | 1,722 | 15,869 | 139 | 1 | 3 | 是 | mixed |
| `external-mirror` (#314..#334) | 9 | 10.37 | 21,388 | 1,807 | 19,581 | 143 | 3 | 1 | 是 | behavior-migration |
| `agent-bridge` (#421..#436) | 7 | 10.53 | 4,492 | 856 | 3,636 | 97 | 0 | 0 | 是 | framework |
| `uri-canonicalization` (#431, #438) | 2 | 15.63 | 3,682 | 578 | 3,104 | 130 | 0 | 0 | 否 | cross-cutting |
| `workspace-cap-visibility` (#423, #434) | 2 | 2.70 | 2,154 | 328 | 1,826 | 24 | 0 | 0 | 否 | cross-cutting |
| `apikeys-flip` (#389) | 1 | 0.44 | 1,211 | 562 | 649 | 28 | 1 | 2 | 否 | behavior-migration |
| `session-unification` (#408) | 1 | 1.79 | 2,768 | 89 | 2,679 | 26 | 0 | 3 | 否 | mixed |

推导速率：

| 系列 | hr / PR | hr / 净 LOC | hr / Behavior | hr / Kind |
|---|---:|---:|---:|---:|
| `plugin-contract` | 0.24 | 0.00037 | — | — |
| `phase7-template` | 0.24 | 0.00030 | 4.80 | 1.60 |
| `external-mirror` | 1.15 | 0.00053 | 3.46 | 10.37 |
| `agent-bridge` | 1.50 | 0.00290 | — | — |
| `uri-canonicalization` | 7.81 | 0.00504 | — | — |
| `workspace-cap-visibility` | 1.35 | 0.00148 | — | — |
| `apikeys-flip` | 0.44 | 0.00068 | 0.44 | 0.22 |
| `session-unification` | 1.79 | 0.00067 | — | 0.60 |

**样本量诚实**：只有**3 个系列**（`phase7-template`、`external-mirror`、`apikeys-flip`）涉及真正的 Behavior 迁移。**5 个系列**跨越 plugin 契约边界（最相关的可比项）。hr/Behavior 统计 N=3 — 小样本。r3 明确指出这一点而不是抹平掉。

#### §6.3.2 — 经验统计

| 统计量 | min | p10 | p50 | avg | p90 | max | N |
|---|---:|---:|---:|---:|---:|---:|---:|
| 每 Behavior 迁移 hr | 0.44 | 0.44 | 3.46 | 2.90 | 4.80 | 4.80 | 3 |
| 每净 LOC 变更 hr | 0.00030 | 0.00030 | 0.00067 | 0.00150 | 0.00504 | 0.00504 | 8 |
| 每 PR hr | 0.24 | 0.24 | 1.35 | 1.81 | 7.81 | 7.81 | 8 |

**关键观察 ——"经过"反映 ezagent 自主循环节奏，不是人类开发时间**：语料中几乎每个 PR 都是几秒内开-合并（`createdAt ≈ mergedAt`），而*整个多 PR 系列*都在单个工作日完成（Phase 7 的 20-PR 序列：4.8 hr；ExternalMirror 的 9 PR + 3 Behavior + 1 Kind：10.4 hr；AgentBridge 的 7 PR：10.5 hr）。r2 中引用的 PR-G "3 周" 与 PR-EM "5 周" 实为*日历*间隔（包含其他无关工作）；那些迁移的实际*活跃*时间是小时级。r2 循环时间膨胀来自将日历经过 = 活跃时间，底层数据驳斥这一点。

#### §6.3.3 — 阶段级数据驱动推断

**换算假设**：30 活跃 hr/wk 持续（= 6 hr/天 × 5 天/wk，相对于 2026-05-22..2026-05-28 观察到的 7 天爆发峰值 50+ hr/wk 与 22-53 commit/天保守）。封顶考虑：review 带宽 + ZH lockstep + 竞争优先级（esr-channel、loom plugin、codex review queue）。

**Phase 1 — Framework primitives + LegacyBehaviorAdapter**

- LOC 预算（§5.8）：~2,480 framework + ~400 LegacyAdapter = ~2,880 净新 LOC
- 最佳 framework 可比项：`plugin-contract`（0.00037 hr/LOC）、`phase7-template` framework 部分（0.00030 hr/LOC）
- 活跃 hr（LOC × 0.0005 — 保守中段）：~1.4 hr
- OQ-1..8 设计收敛开销（codex r1 MED-4 指出"每 OQ 波及 primitive"）：~20 hr
- **Phase 1 p50：~22 hr ≈ 0.7 wk**
- **Phase 1 p90：~32 hr ≈ 1.1 wk**（设计探索 50% 加成）
- 下限（原始 LOC 速率）：~0.05 wk；上限（OQ 解决浮出 2 个潜在问题）：~2 wk

**Phase 2 — Per-Domain Behavior 迁移（§6.1 表中 8 PR 共 22 个 Behavior）**

- 经验 hr/Behavior（N=3）：p10=0.44、p50=3.46、p90=4.80
- **Phase 2 p50：22 × 3.46 = 76 hr ≈ 2.5 wk**
- **Phase 2 p90：22 × 4.80 = 106 hr ≈ 3.5 wk**
- 逐 PR 校验（§6.1 表中 8 个 PR）：
  - PR 1（`ezagent_core`，5 个 Behavior）：5 × 3.46 = 17 hr ≈ 3 天
  - PR 4（`ezagent_domain_instance_message`，4 个 Behavior，最大）：4 × 4.80（p90）= 19 hr ≈ 3 天
  - PR 5（`ezagent_domain_external_mirror`，3 个 Behavior + Worker Kind）：可比过往 EM 系列 = ~10 hr ≈ 2 天
  - PR 8（Resource 边界修复，schema 迁移）：无过往可比项；单独预算 1 wk

**Phase 3 — 删除 LegacyBehaviorAdapter**

- 可比项：`workspace-cap-visibility`（DROP COLUMN 重构）= 2.70 hr
- **Phase 3 p50：~6 hr ≈ 1 个工作日**
- **Phase 3 p90：~18 hr ≈ 3 个工作日**

**Phase 4 — 清理（重命名 + 文档 + slice_change → StateChange）**

- 可比项：`agent-bridge` PR-F（`refactor(domain_agent): detect PTY lifecycle by behavior`）= ~1 hr；文档 PR 如 #379 ~1 hr/个
- **Phase 4 p50：~12 hr ≈ 2 个工作日**
- **Phase 4 p90：~30 hr ≈ 1 wk**

**总挂钟时间**

| Phase | 下限（原始经验） | **p50（数据驱动）** | **p90（数据驱动）** | 上限（2× p90 应对未知-未知） |
|---|---|---|---|---|
| Phase 1 | 0.05 wk | **0.7 wk** | **1.1 wk** | 2 wk |
| Phase 2（22 个 Behavior） | 0.3 wk | **2.5 wk** | **3.5 wk** | 7 wk |
| Phase 3 | 0.04 wk | **0.2 wk** | **0.6 wk** | 1 wk |
| Phase 4 | 0.07 wk | **0.4 wk** | **1.0 wk** | 2 wk |
| **合计** | **~0.5 wk** | **~3.8 wk** | **~6.2 wk** | **~12 wk** |

#### §6.3.4 — 置信度声明 + 与 r2 的差值

**r3 置信度受限于**：
1. **N=3 个可比 Behavior 迁移系列**（`phase7-template`、`external-mirror`、`apikeys-flip`）— 小样本；一个 outlier（如 `domain_instance_message` 迁移浮现一个 HIGH 级结构缺陷）可让 Phase 2 翻倍。
2. **LegacyBehaviorAdapter 路径是新颖的** — 过往 ezagent 迁移没有用过运行时 adapter 做后向兼容。~400 LOC 预算来自设计推导，未经实证验证。
3. **22 个 Behavior 是 SPEC 计数** — 如果 domain-chat 的 "Publisher.SessionImpl" 或 `external_mirror` 的 Worker 有隐藏子-behavior 不能干净 fit 进 macro，计数上升。
4. **Allen 带宽是约束**，不是自主循环吞吐量。30-hr/wk 持续速率**高于**爆发周外历史持续均值；如某段时间 Allen review 1 PR/wk，Phase 2 拉到 8 wk 挂钟。

**与 r2 差值（14-17 wk 最可能，25 wk 上限）**：

- r2 把日历间隔（PR 系列间 3-5 wk）当成活跃开发时间。数据显示过往迁移**活跃工作时间在小时级**，日历间隔代表其他优先级，不是迁移本身。
- r3 数据驱动 p50（~4 wk）比 r2 的 14-17 wk **紧约 4 倍**。r3 p90（~6 wk）比 r2 的 25 wk 上限**紧约 3 倍**。
- r3 *上限*（12 wk，2× p90 应对未知-未知探索）**仍紧于 r2 最可能值** — 重新校准是**收紧**而非拓宽。

**r3 是收紧还是拓宽原 14-17 wk 区间**：**r3 大幅收紧区间**。经验数据显示过往迁移在小时级而非日历级完成。r2 校准把日历经过（被 Allen 多项目上下文切换支配）误认为迁移活跃时间。

**Allen 决定**：
- 若 Allen 把 Phase 2 当作下一个*聚焦爆发*（如 Phase 7、ExternalMirror 那样），p50 ~4-wk 估计是现实的。
- 若 Phase 2 必须与其他优先级（esr-channel、loom、plugin review）交错，实际挂钟拉向 12-wk 上限 — 仍低于 r2 的 25-wk 上限。
- 基于实际 GitHub PR 历史速度，14-17 wk r2 "最可能" 区间现被视为**高估 ~3-4 倍**。诚实的单一答案是 **聚焦执行 ~4-6 周；交错执行 ~10-12 周**。

---

## §7 — 测试策略

### §7.1 — Framework primitive 测试

`apps/ezagent_core/test/ezagent/` 下的单元测试：

- `router_test.exs` — dispatch 正确性、cap 强制在 handler 前发生、审计行已写、idempotency 去重、workspace iso 强制、错误规范化
- `behavior_macro_test.exs` — `action :name, ...` 声明正确聚合、缺 `handle_<action>/2` 编译错误、cap 声明但不在 cap subject 中的编译错误、`ctx.read.(:key)` 返回正确值
- `kind_macro_test.exs` — `attach Behavior, ...` 校验 Behavior 的 action 存在、`read_graph` 对附加的 Behavior 编译检查、`pattern: :entity` 宏添加期待的生命周期钩子
- `event_log_test.exs` — `stream_by_aggregate` 排序正确（含同微秒测试）、游标分页完整 + 稳定、对重复 command_uuid append 幂等
- `state_rebuilder_test.exs` — rebuild = snapshot + fold(events_since_snapshot)；100-dispatch 混沌测试：kill、rebuild、与内存状态比对
- `saga_runner_test.exs` — 仅前向 happy path、step-N 失败反向补偿、补偿自身失败留下 operator-repair 标记

### §7.2 — Plugin 契约不变式测试

所有 plugin 必须满足的不变式 — 在 boot 时 + CI 中检查：

| 不变式 | 测试 |
|---|---|
| Handler 永不看到 slice | grep 门：`apps/*/lib/.../behavior/*.ex` 中 `def handle_` 没有 `slice` arg |
| Handler 永不直接 dispatch | grep 门：`def handle_` body 内零 `Ezagent.Invocation.dispatch` 调用 |
| 所有状态变更通过 effects | grep 门：`apps/ezagent_core/lib/ezagent/snapshot/` 外无 `Snapshot.Writer` / `Snapshot.save_now` |
| Cap-required action 在缺 cap 时拒绝 | 每个 Behavior 一个属性测试 |
| 所有 effects 是有效语法 | 运行时不变式 — Router step 10 的 effect-validator |

### §7.3 — 迁移对等测试（codex r1 MED-3 closure — 拆为 2 个对等级别）

每个迁移的 Behavior，对等测试套件有 **两个独立级别**：

#### Level 1 — Dispatch parity（legacy adapter 模式）

验证未修改的 `invoke/4`-shape Behavior 通过 `LegacyBehaviorAdapter` 跑产出 **与 native 跑（迁移前）相同 dispatch 可见结果**。比较：

- **相同输入**（老 `Invocation.dispatch/1` shape vs 新 `Router.dispatch/1` shape 下的 `%Cmd{}` 信封 — 两个 shape 线兼容）
- **相同最终状态**（dispatch 后的 snapshot 行 — 内容相等，模 `inserted_at` 抖动）
- **相同可观察副作用**（PubSub broadcast：相同 topic、相同 payload — 通过探测订阅者同时捕获新老）
- **相同 dispatch reply**（`{:ok, result}` shape 相等）

Dispatch parity 是每个 Phase 2 PR 的门 — 只有对该 PR 中每个 Behavior 都有 dispatch parity 时迁移才被允许 land。

#### Level 2 — Replay parity（仅 post-migration native Behavior）

验证对于完全迁移到新 `handle_<action>/2` shape 的 Behavior，**从 EventLog 重建状态产生与 live dispatch 相同的 slice**。这是比 dispatch parity **更强** 的论断，仅对 native-shape Behavior 有意义（不对 adapter 模式）。

比较：
- 从空 snapshot 开始
- 跑 N 个 dispatch
- 捕获内存 slice 状态
- 杀掉 Kind 进程
- 重生 — StateRebuilder 读空 snapshot，通过 `apply_event/2` 从 EventLog fold 事件
- 断言：重生后 slice = 内存 slice（模非确定性标记如时间戳）

**Replay parity 不适用于 LegacyBehaviorAdapter Behavior** — 它们被记录为非 replay-equivalent（§6.1 Phase 1）。Adapter 包装了 legacy 副作用（PubSub broadcast、跨 Kind dispatch、Repo 写）发生在 effect 语法 **外**；通过 `apply_event/2` fold 事件回去无法重建它们。StateRebuilder 对 adapter 模式 Behavior 视为"snapshot-only"— 依赖 snapshot 而非 event fold。Phase 3 后所有 Behavior 是 native 时 Replay parity 才有意义。

#### 对等测试 **不** 比较

- **EventLog 行数**（intentional incompatibility — 新设计 emit 更多事件；这是设计而非缺陷。订阅 `EventLog.stream_by_workspace/2` 和 EventSubscriber 消费者迁移后 **会** 看到新事件类型；迁移计划在每个 Phase 2 PR 的 CHANGELOG 中记录）
- **Snapshot 频率**（老：按 `:on_change`；新：按模式 — 按设计，见 HIGH-3 closure）
- **Telemetry 事件**（在新结构下重命名 — `[:ezagent, :invoke, :stop]` 变成 `[:ezagent, :router, :dispatch_stop]`）

### §7.4 — "完成"不变式测试

按 `feedback_completion_requires_invariant_test`，架构目标是"未来开发者在不同 plugin 上独立工作，无需协调"。证明迁移完成的可执行检查：

```bash
# Phase 3 完成门 — 在 CI 中跑
ALL_BEHAVIOR_FILES=$(find apps -path "*/lib/ezagent/behavior/*.ex" -not -path "*/test/*")

# 1. 无 plugin Behavior 定义 invoke/4
test "$(grep -l 'def invoke(' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 2. 无 plugin Behavior 读 slice
test "$(grep -l ', slice,' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 3. 无 plugin Behavior 调用 Invocation.dispatch
test "$(grep -l 'Ezagent.Invocation.dispatch' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 4. 无 plugin Behavior 直接调 Phoenix.PubSub.broadcast
test "$(grep -l 'Phoenix.PubSub.broadcast' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 5. 无 plugin Behavior 直接调 Snapshot
test "$(grep -l 'Ezagent\.\(Kind\.\)\?Snapshot\.' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 6. 无 plugin Behavior 触及 BehaviorRegistry / CapabilityRegistry
test "$(grep -l 'Ezagent\.\(Behavior\|Capability\)Registry' $ALL_BEHAVIOR_FILES | wc -l)" = "0"

# 7. Plugin LOC 减少 ≥ 50%
NEW_LOC=$(cat $ALL_BEHAVIOR_FILES | wc -l)
test $NEW_LOC -lt 5500   # 之前 ~11,000

echo "DONE — plugin 契约与 framework 内部隔离"
```

7 个检查必须全部通过。否则迁移未完成。**这是与 `mix test` 一起在 CI 跑的架构承诺测试。**

---

## §8 — 留给 Allen 的开放问题

这些是真正需要 Allen 输入的架构决策（或明确推迟）。按优先级列出。

### OQ-1 — Resource URI 方案

**问题**：Resource URI 该怎样构成？

- 方案 A：`resource://<owner_kind>/<owner_name>/<type>/<name>` — 如 `resource://agent/cc_demo/config-dir/main`。优点：类型编码进 URI；所有权清晰。缺点：所有权变更需重建 key 的 URI（如所有权曾转移，违反 `feedback_uuid_is_canonical_identifier`）
- 方案 B：`<owner_uri>?resource=<type>:<name>` — owner 上的查询串形式。优点：所有权转移不需重建 key。缺点：丑；非 RFC-3986 干净
- 方案 C：每个类型独立 scheme — `config-dir://agent/cc_demo/main`、`api-key://agent/cc_demo/anthropic`。优点：每种资源类型是"一等名词"。缺点：scheme 爆炸

**建议**：方案 A。所有权转移罕见；可读性提升大。文档化"资源 URI 创建后不可变"的约束；如必须转移所有权，资源销毁后重建。

### OQ-2 — Per-Kind 组合模式强制

**问题**：组合模式强制只是文档，还是编译时？

如果 `use Ezagent.Kind, pattern: :entity` 宏看到 Resource 模式的生命周期钩子（如 `cascade_on_owner_destroy`），应该 (a) 警告、(b) 编译时报错、还是 (c) 静默允许 + 运行时 opt-in？

**建议**：编译时报错。按 `feedback_let_it_crash_no_workarounds`，结构性不匹配应该响亮。文档化逃生口为 `pattern: {:custom, [hook1, hook2]}`，应对标准模式不适合的（罕见？）情况。

### OQ-3 — Effects 顺序语义

**问题**：见 §4.4 — effects 按声明顺序应用，EventLog + 状态一个事务，notify/effect 在 commit 后触发，dispatch 异步，terminate/saga 在 reply 后。这是对的顺序吗？

具体：`{:dispatch, %Cmd{}}` effect 应在 `{:notify, …}` **之前** 应用（这样 dispatch 扇出通过被 dispatch 的 Kind 自己的 emit 在 PubSub 上可观察，而不是 originator 的 notify）？还是之后（这样 notify 是首个信号）？

**建议**：commit 后，dispatch BEFORE notify。被 dispatch 的 Kind 发出自己的事件订阅者会看到；originator 的 notify 是一个粗粒度"我身上发生了什么"信号最后到达。这匹配今天 Chat 的顺序（Resolver → dispatch_receive → 给 LV 的 PubSub broadcast）。

### OQ-4 — Saga 补偿声明

**问题**：saga 定义内联 `(forward, compensate)` 对，还是独立 `compensate_<step_name>` callback？

- 内联：`SagaRunner.step(saga, :revoke_caps, &revoke_all_caps/1, &restore_caps/2)` — 简练但定义 + 行为耦合
- 独立：`def compensate_revoke_caps(effect_map, prior_effects), do: ...` — 纯函数，更可发现但更多文件

**建议**：内联。ezagent 中的 saga 短（典型 4–7 步）；内联保持 saga 作为单一声明式 pipeline 可读。

### OQ-5 — Multi-Behavior-per-Kind 合并

**问题**：User Kind 今天有 4 个 Behavior（Identity + UserCredentials + UserTokens + WorkspaceUserAdmin）。新模型中 User Kind 暴露 ONE 合并的 action 命名空间，还是 per-Behavior 命名？

今天：`entity://user/system/admin?action=user_credentials.set_password` — Behavior 名前缀。

选项：
- A：去掉 Behavior 前缀 — `entity://user/system/admin?action=set_password`（假设跨附加 Behavior 无 action 名冲突）
- B：保留 Behavior 前缀 — 与今天相同
- C：重命名 Behavior 使 action 名在 Kind 上唯一（如 `Behavior.UserCredentials` 变成 `Behavior.UserPassword`，`:set_password` 变成 `:set` — 读 Behavior 名作命名空间）

**建议**：A，在 `use Ezagent.Kind, ... attach Behavior, ...` 处做编译时冲突检查。Kind 内 action 命名空间平坦；冲突是编译错误。大幅简化调用方代码。

### OQ-6 — ExternalMirror 的特殊地位

**问题**：今天 ExternalMirror Worker 有自己的 `BootReconciler`（当前唯一）。新设计中 ExternalMirror Worker 变成常规 Resource 模式 Kind，还是保持特殊？

**建议**：常规 Resource 模式 Kind。Framework 的 StateRebuilder + per-Kind `on_rebuild/1` callback 通用处理 BootReconciler 的角色。两层 supervisor 保留（这是 domain 关注点）。`external_mirror_bindings` projection 表变成 StateRebuilder 咨询的 read-model。

### OQ-7 — 需要返回值的 Effect handler

**问题**：`{:dispatch, %Cmd{}}` 是异步（cast）；originator 看不到 dispatched Kind 的结果。罕见的需要 originator 链接 dispatch 结果的情况怎么办？

- `{:dispatch_call, %Cmd{}, on_result: fn r -> [effect, effect] end}` — 声明式续接
- 或：拒绝支持；如果需要链接，写 saga

**建议**：拒绝。如果 handler 需要链接 dispatch 结果，那其实是个 saga（编排多步工作）。强制走 SagaRunner；saga 原语便宜，而带续接的 chained-dispatch effect 是 callback 地狱的配方。

### OQ-8 — In-flight 数据迁移的向后兼容

**问题**：现有 `kind_snapshots` 表的数据持有 slice-shape 状态（`%{slice_key => slice_map}`）；新设计的 snapshot 持有扁平 `{behavior_module, field} → value` 状态。如何迁移？

选项：
- A：写一次性数据迁移工具（`mix ezagent.migrate.snapshots`）遍历每行，应用 legacy-adapter 变换，写新 shape
- B：Phase 3 后首次 Kind 加载时 snapshot 重建（StateRebuilder 读 legacy shape，fold 事件，写新 shape snapshot）
- C：Phase 2 期间并行保留两种 shape（每个 shape 一列）；读时挑

**建议**：B。StateRebuilder 反正要 fold 事件；legacy snapshot 是起点但事件日志是 SoT。写一次性 `mix ezagent.snapshots.replay` 在 Phase 3 后触及每个 Kind URI 强制 rebuild + 新 shape 持久化。

---

## §9 — Codex 对抗式 review 攻击向量

预加载给 codex review subagent（10 个提示；仅静态 — 无 `mix` 命令按 `feedback_codex_companion_no_mix`）：

### AV-1 — Effects vocabulary 覆盖度

走 `Behavior.Chat.invoke(:send)`（`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:297-419`）、`Behavior.ExternalMirror.invoke(:bind_session)`（`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`）、`Behavior.Workspace.invoke(:create_session)`（`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`）。对每个：每个副作用是否能用 §4.4 语法表达？如不能，缺什么 effect？具体检查：Chat 内的 `MessageStore.write`（Ecto 写 — `{:effect, &fn/N, args}` 覆盖？）。Chat 的 `:join` 内的 `Process.monitor`（运行时原语，非真正 effect — framework 暴露 `{:monitor, target_uri}` effect？）。Worker `post_init` 内的 `Phoenix.PubSub.subscribe`（不通过 effects — 保留为 Kind 生命周期钩子？）。

### AV-2 — Framework 管理 snapshot 策略正确性

§5.2 让 framework 按模式决定策略：Session = `every_n_events: 100`，Entity = `on_change`，Resource = `on_change`。对每个当前 Kind 这真的正确？具体：ExternalMirror Worker 高量（每个 binding 事件触发 Worker dispatch）；其当前 `persistence/0` 是 `:on_terminate`。强制为 `on_change`（per Resource 模式默认）会让 snapshot 写入率 10 倍。framework 决策在这里错了，还是 Resource 模式该有子分类（`:hot_resource` vs `:cold_resource`）？

### AV-3 — Legacy adapter 机制

§6.1 Phase 1 通过 `LegacyBehaviorAdapter` 让老 `Behavior.invoke/4` Behavior 工作。定义 adapter 的机制：它必须把 `invoke/4` 的返回包装为 `{result, effects}` shape。它怎么知道为哪些 slice key 发出 `{:set, k, v}`？通过新老 slice diff — 但 slice 是 Behavior 的私有数据 shape；adapter 必须知道 slice shape 才能 diff 它。这真的是 slice 泄漏进 framework？走过 `Behavior.Chat` adapter 运行：adapter 看到老 slice `%{members: ..., monitors: ..., last_message_id: nil}` 和新 slice `%{members: ..., monitors: ..., last_message_id: "abc", last_message: %Message{...}, send_cursor: 1}` — 它发出 `{:set, :last_message_id, "abc"}, {:set, :last_message, %Message{...}}, {:set, :send_cursor, 1}`？是，并且没事 — diff 是通用 Map 操作，不是 slice-shape 感知。**确认或反驳此论断。**

### AV-4 — 新 `caps:` 宏下的 cap action 轴

cap-vis SPEC #423 在 action 轴上花了 4 轮：caps 是 `{kind, behavior, action, instance}` 4 元组；`action: :any` 的 cap 匹配任何 action；`action: :send` 的 cap 只匹配 `:send`。新 `caps: [:send]` 宏形式看起来强制 action 为 `:send` — 但应匹配 Behavior 任意 action（"此 Behavior 的 owner 可做任何事"shape）的 cap 怎么办？是否有 `caps: [:any]` 形式？走 `Behavior.Identity` 的 `:list_caps`（今天：Identity Behavior 上任何 cap 匹配；action 轴是 `:any`）。

### AV-5 — Resource 模式适合每个 owned-by-Entity 的东西

走每个当前"Entity 拥有的东西"，确认 Resource 模式适合：

1. Agent 的 config_dir（今天：Agent 上的 `Behavior.Sandbox` slice）
2. Agent 的 API keys（今天：Agent 上的 `Behavior.ApiKeys` slice）
3. User 的密码哈希（今天：`Ezagent.Users` Ecto 行）
4. Workspace 的 bindings（今天：`external_mirror_bindings` Ecto + slice）
5. User 到 Agent 的 cap-grant（今天：User 的 Identity slice 上的 `:caps` MapSet）
6. AgentTemplate 配置（今天：AgentTemplate Kind 上的 `Behavior.Template` slice）
7. Session 消息（今天：`Ezagent.MessageStore` Ecto）

对每个：把它当作带 `resource://owner/.../...` URI 的 Resource Kind，是否会在 (a) lookup 人体工程学（LV 查询）、(b) cascade-on-destroy 正确性、(c) per-action cap shape 清晰度上回归？

### AV-6 — destroy 级联的端到端 saga 补偿

SPEC #440 的 #1 失败场景：destroy User → 撤销 User 持有的 caps → 销毁 User 所有 Session → 销毁 User 所有 Agent → 销毁 User 所有 Resource。Codex 标记："如果 step 3 成功但 step 4 失败，User 处于不一致状态 — 一些 Agent 已销毁，其他还活着。"

走新设计的完整 destroy saga：

```elixir
saga
|> step(:enumerate_resources, ...)
|> step(:snapshot_state_for_compensation, ...)
|> step(:revoke_held_caps, ..., compensate: &restore_caps/2)
|> step(:destroy_sessions, ..., compensate: &resurrect_sessions/2)
|> step(:destroy_agents, ..., compensate: &resurrect_agents/2)
|> step(:destroy_owned_resources, ..., compensate: &resurrect_resources/2)
|> step(:terminate_user_kind, ..., compensate: &noop/2)
|> execute(...)
```

对每个补偿：它真的可能？"resurrect_sessions" 可能意味着从 snapshot 恢复 — 但 Session 在补偿窗口期间收到了新消息。这些丢了？saga 的补偿真的是"尽力部分恢复"还是"真回滚"？文档化诚实答案。

### AV-7 — 状态依赖 emit 的 `ctx.read`

"plugin 代码中无 slice"不变式 — 那些合法地需要 READ 当前状态、基于结果 emit 事件的 plugin 怎么办？

例：`Behavior.Lifecycle.destroy` 读 Agent 的 lineage parent 以通知他们。今天这是 `Ezagent.AgentLineage.lookup(self_uri)` — registry 调用。新设计中，`AgentLineage` 通过 `ctx.read.(:lineage_parent)` 暴露，还是 handler 内部的运行时调用（即 handler **被允许** 调用 registry-style 模块）？

走影响：如果 handler 可以直接调 ANY 不是 `Ezagent.Invocation`/`Snapshot`/`Capability` 的模块，"plugin 代码中无 framework 内部"不变式有逃生口。线到底在哪里？

### AV-8 — 迁移对等测试可行性

§7.3 定义对等为"相同输入 → 相同最终状态 + 相同可观察副作用 + 相同 dispatch reply"。但新设计 emit 更多事件（每个 `{:emit, …}` 是老设计从未写过的新 EventLog 行）。对等测试必须紧定义"相同可观察"：今天从 `Behavior.Chat.send` 收 0 事件、明天收 1 个 `message_sent` 事件的订阅者怎么办？他们观察到"无操作变更"还是"根本性转变"？

走一个 `Behavior.Chat.send` 的具体迁移对等测试：比较什么、有意分歧什么、失败标准。

### AV-9 — Multi-Behavior-per-Kind dispatch 路由

User Kind 今天有 4 个 Behavior（Identity + UserCredentials + UserTokens + WorkspaceUserAdmin）。新模型用 OQ-5 方案 A（扁平 action 命名空间），跨附加 Behavior 的 action 名冲突是编译错误。但 `Behavior.Chat` 同时附加到 User 和 Agent Kind 用 `:receive` action 怎么办？同 Behavior、同 action、不同 Kind — Router 按 `(kind, action)` 还是 `(kind, behavior, action)` 路由？

如果 `(kind, action)`：一个 Kind 有多个 Behavior 时 Router 怎么知道调哪个 Behavior？（今天：`BehaviorRegistry.lookup(kind_module, action)` 返回注册的 Behavior；冲突不可能因为 action 在 Behavior 内唯一）。

如果 `(kind, behavior, action)`：URI 包括 Behavior 名，与 OQ-5 方案 A 矛盾。

真实路由 key 是什么，它如何与今天携带 `{kind, behavior, action, instance}` 的 cap-vis cap 互动？

### AV-10 — 工作量估计现实性

§6.3 说 8–10 周最可能，16 周上限。对比：AgentBridge 抽取 ~3 周一个 plugin。ExternalMirror domain 抽取 ~5 周一个 domain。本 SPEC 迁移 22 个 Behavior + 13 个 Kind + framework。8–10 周现实，还是玫瑰色下限？

详细走 Phase 1：framework primitive 中多少真正是新代码（Router、EventLog stream-by-aggregate、SagaRunner、EventSubscriber、StateRebuilder、Caps.Engine — ~1,200 LOC）vs 现有代码重构（Behavior 宏、Kind 宏、Kind.Host — ~1,200 LOC）。在 ezagent spec 重 review 流程下（codex 轮、ZH lockstep、对等测试）~250 LOC/dev-day，Phase 1 的 2,400 LOC = ~10 dev-days = 2 wall-week 专注工作 — **如**没东西浮现。带现实 spec-review 开销，3 周是 Phase 1 单独的下限，5 周上限。

Phase 2 的 22 个 Behavior 每个 1–3 天（按 §6.2 机械改造）= ~44–66 dev-days = ~9–13 wall-week 在 1 PR/wk review 节奏下。4–6 wk 最可能假设 2 PR/wk review 节奏，这对该代码库 REJECT 重的过去激进。

经过此分析后诚实的重估计？

---

## §10 — 迁移风险登记表

| # | 风险 | 可能性 | 影响 | 缓解 |
|---|---|---|---|---|
| R-1 | Behavior 签名 breaking change 阻塞无关工作 8+ 周 | 高 | 高 | Phase 2 PR 可独立 merge；非迁移 PR 在 Phase 2 期间继续通过 legacy adapter 使用 |
| R-2 | Legacy adapter（Phase 1）意外变永久 | 中 | 高 | Adapter 从第一天就有 `delete-by-end-of-phase-3` issue；每次加载 deprecation warning；`mix ezagent.audit.legacy_adapter` 显示剩余点；存在剩余点时 Phase 3 PR 无法 land |
| R-3 | Effects vocabulary 中途发现不足 | 中 | 高 | AV-1 codex pass 必须在 Phase 2 开始 **前** 走每个当前 Behavior 的 effect 需求；浮现的任何 gap 成为 Phase 1 收尾的一部分 |
| R-4 | Resource 边界修复（Phase 2 PR 8）需要的 schema 迁移与 in-flight Phase 2 PR 互动 | 高 | 中 | Resource 边界修复是 **最后** 一个 Phase 2 PR；所有其他 domain 先迁移完再做 schema 变更 |
| R-5 | Saga 补偿正确性 gap（AV-6 的"尽力回滚"）泄漏进 ezagent 的 destroy 语义，使 operator 惊讶 | 中 | 中 | SagaRunner 契约文档化补偿为"尽力"，不是"真回滚"；ezagent destroy SPEC #440 v2（本 SPEC 后重做）必须显式说明语义 |
| R-6 | StateRebuilder 的"fold events into state"路径发现没 `apply_event/2` 能解释的事件 | 低 | 高 | Phase 1 从 `{:set, …}`/`{:emit, …}` effects 派生 `apply_event/2`；如果 Behavior 的模式不能干净生成 apply_event 派生，Phase 1 把它作为阻塞器浮现 |
| R-7 | Allen 的 review 带宽把 Phase 2 PR 限到 <1/wk，把挂钟时间推到 16wk 上限 | 中 | 中 | 把迁移 PR 与 codex 预 review 配对；Allen 的带宽仅用于设计检查点，不是逐行 |
| R-8 | `feedback_north_star_plugin_isolation` 不变式在 Phase 2 期间溜走（一些隐秘的 framework 访问泄漏进"就一个 Behavior"） | 中 | 高 | §7.4 的 7 个不变式检查在 CI 跑；任何检查迁移后失败则 Phase 2 PR 阻塞 |

---

## §11 — 验收标准（"完成"门）

按 `feedback_completion_requires_invariant_test`，迁移在以下所有为真时"完成"（CI 检查）：

1. **Plugin Behavior 中零 `def invoke(`** — `find apps -path "*/lib/ezagent/behavior/*.ex" -not -path "*/test/*" -exec grep -l "def invoke(" {} \; | wc -l == 0`
2. **Plugin handler 中零 `slice` arg** — 同 find，grep `, slice,` → 0 匹配
3. **Plugin handler 内零 `Ezagent.Invocation.dispatch`** — 同 find，grep → 0
4. **Plugin handler 内零 `Phoenix.PubSub.broadcast`** — 同 find，grep → 0
5. **Plugin 中零直接 snapshot 调用** — 同 find，grep `Ezagent\.\(Kind\.\)\?Snapshot\.` → 0
6. **Plugin 对 framework registries 零访问** — 同 find，grep `Ezagent\.\(Behavior\|Capability\)Registry` → 0
7. **Plugin LOC 减少 ≥ 50%** — `wc -l apps/*/lib/ezagent/behavior/*.ex` 合计 ≤ 5,500（曾 ~11,000）
8. **所有当前 dispatch 流通过迁移对等测试** — 每个 Behavior 有 `<behavior>_migration_parity_test.exs` 在固定输入下比较新老（§7.3）
9. **Legacy adapter 已删除** — `apps/ezagent_core/lib/ezagent/legacy_behavior_adapter.ex` 不存在；`mix ezagent.audit.legacy_adapter` 报"无 legacy 调用方"
10. **CONTRIBUTING.md 和 plugin 作者指南反映新契约** — 当前 per-Behavior 样板从指南消失；30 LOC 例子取代 200 LOC 例子

直到所有 10 项在主分支 CI 上变绿，本 SPEC 未完成。

---

## 附录 A — 与 PR #442 §1.5.7 的对比

PR #442 §1.5.7（Option B''）已识别出 5 个 framework primitive — `EventLog`、`SnapshotStore`、`StateRebuilder`、`SagaRunner`、`EventSubscriber`。本 SPEC 保留所有 5 个（§5.1–§5.5），**但新增 3 个 PR #442 未浮出的原语**：

| PR #442 §1.5.7 | 本 SPEC |
|---|---|
| `EventLog` ✓ | `EventLog` ✓（§5.1）— 同 |
| `SnapshotStore` ✓ | `SnapshotStore` ✓（§5.2）— 但 plugin 作者不挑策略；framework 按模式决定 |
| `StateRebuilder` ✓ | `StateRebuilder` ✓（§5.3）— 同 |
| `SagaRunner` ✓ | `SagaRunner` ✓（§5.4）— 同 |
| `EventSubscriber` ✓ | `EventSubscriber` ✓（§5.5）— 同 |
| `Behavior.invoke/4` 保留 + 可选 `execute_command/apply_event/effects` 三元组 | **`Behavior.handle_<action>/2` 取代 `invoke/4` — full breaking change**，无 opt-in（Allen 10:30 指令） |
| Slice 保留作为 plugin 作者数据模型 | **Slice 从 plugin 作者表面消失** — `ctx.read` 读 framework 管理状态 |
| `Router` 提及为第 6 个模块（~50 LOC，r8 添加） | **`Router` 是 FIRST 原语**，~200 LOC — 提升为 `Behavior` 和 `Kind` 的同伴（Allen 10:08 洞察） |
| 组合模式未命名 | **Session / Entity / Resource** 模式形式化 — 3 模式轴是新核心（Allen 10:30 指令） |
| ~880 LOC framework | ~2,480 LOC framework |
| ~50 个 Behavior 作者估计 | 22 个 Behavior 实际；迁移后每个 ~10–30 LOC |

与 PR #442 最大的 delta：**Allen 10:30 的重构 — "router、behavior、kind 三个" — 是核心架构洞察**。PR #442 是在现有 plugin 契约之上的 CQRS shape 精炼。本 SPEC 围绕 plugin 隔离重构一切：plugin 作者写 `handle_<action>/2`、声明 effects、不知道其他。那就是赌注。
