# Ezagent v0.3 架构评审 — Grill Findings

> **评审对象**: `EZAGENT_ARCHITECTURE.md` v0.3（2026-05-14）
> **评审方法**: 通读 v0.3 全文 + 实测现有 Ezagent 代码库的等价模块行数 + 通读 6 份现有 Ezagent 事故复盘（`docs/notes/`）
> **写给谁**: v0.3 的架构师
> **重要前提**: 你看不到现有 Ezagent 代码。所以这份文档里每一条都配了**代码示例**和**功能解释**——你可以脱离 Ezagent 代码库、纯靠推理来验证我说的对不对。凡是"我猜你的想法"的地方都明确标了 **【揣测意图】**。凡是引用现有 Ezagent 代码量的地方都是我**实测**的，不是估的。

---

## 总评

v0.3 的抽象骨架是对的。"URI = operationId，`@interface` = schema，Adapter = 协议翻译器，Behavior = 纯可调用单元，Kind = GenServer，Plugin = OTP app"——这套类比有解释力，而且 v0.3 相比 v0.2 已经吸收了上一轮评审的大部分缺口（DLQ、文件附件、RoutingRegistry、Transport Adapter、multi-app routing key）。

但三个问题域需要在 v0.4 处理：

1. **LOC 预算没校准**——文档自己的数字前后矛盾，且几个核心模块明显低估
2. **现有 Ezagent 踩过的 5 个真实事故坑，v0.3 没设计进去**——而 v0.3 偏偏是个全 PubSub 架构，其中 3 个坑会原样复现
3. **几个二级机制还没落到模块级**——Workspace 操作面、Plugin 运行时配置、`@interface` 类型校验器

下面逐条展开。

---

# 一、LOC 预算没校准

## 1.1 文档内部数字前后矛盾

这是个硬伤，先指出来：

| 出处 | 数字 |
|---|---|
| §1.1「不是什么」 | `ezagent_core ≈ 475 LOC` |
| §2.1「少发明，多装配」 | `约 475 行` |
| §16「What's ours」 | `自己写代码 ≈ 475 LOC` |
| §14 LOC budget 表（逐模块加总） | **595 LOC** |
| Appendix B Decision #44 | `target ~580 LOC` |

§14 的表自己列了每个模块的 target，加起来是 595（`25+70+25+30+15+40+30+50+60+50+30+15+40+80+20+15`）。475 这个数大概是 v0.3 加入 `message.ex`/`matcher.ex`/`view.ex`/`scheduler.ex` **之前**的旧数字，没同步更新。

**建议**: 先把三处 475 改成 595，让文档自洽。但更重要的是——595 本身也偏低，见下。

## 1.2 `invocation.ex` ~70 LOC（cap 90）—— 低估

【揣测意图】你可能觉得 dispatch 就是"解析 URI → 查 registry → `GenServer.call`"，很薄。

但 Appendix A 的 invocation flow 是 **12 步**，其中两步是真有代码量的：

**步骤 2.5 — args validation against `@interface`**。`@interface` 的类型记号是递归的：

```elixir
# 一个 @interface 声明长这样
@interface %{
  move: %{
    args: %{
      position: {:tuple, :integer, :integer},
      tags:     {:list, :string},
      meta:     %{owner: :string, weight: :integer}   # 嵌套 map
    }
  }
}
```

要校验一个 `args` map 是否符合这个 schema，你需要一个**递归的类型校验器**——`{:tuple, ...}`、`{:list, ...}`、`{:option, ...}`、嵌套 `%{field => ty}` 每种都要递归下去。这个校验器本身就 ~30 行，而且它在 v0.3 里没有自己的模块、没有自己的 LOC 预算（见 §三-3）。

**步骤 12 — `Ezagent.Invocation.reply(ctx, result)`**。§12.5 的 reply 路由表有 7 个 case：

```elixir
def reply(%{reply: {:phoenix_channel, topic}}, result),
  do: EzagentWeb.Endpoint.broadcast(topic, "reply", result)
def reply(%{reply: {:phoenix_pubsub, topic}}, result),
  do: Phoenix.PubSub.broadcast(Ezagent.PubSub, topic, {:ezagent_reply, result})
def reply(%{reply: {:plug_conn, conn}}, result),
  do: Plug.Conn.send_resp(conn, 200, Jason.encode!(result))
def reply(%{reply: {:stdio_pipe, port}}, result),
  do: # 写 erlexec stdin 或 stdio framing —— 这条本身就要几行
def reply(%{reply: {:mcp_response, req_id}}, result),
  do: # 构造 MCP response packet
def reply(%{reply: {:caller_inbox, pid}}, result),
  do: send(pid, {:ezagent_reply, result})
def reply(%{reply: :ignore}, _result), do: :ok
```

光这个表，加上 dispatch 主流程（parse + lookup + call + 错误路径），70 行**几乎肯定撑不住，会撞到 90 的 cap**。

我实测了现有 Ezagent 里最接近 dispatch 的两个模块（`handler_router` + `handler`）一共 116 行——而且它们**只覆盖了"调用 Python worker"这一条窄路径**，不含 arg validation、不含 7-case reply 表。

**建议**: `invocation.ex` 改成 target ~95 / cap 120。或者把 arg validator 拆成独立的 `interface_validator.ex`。

## 1.3 `matcher.ex` ~50 LOC（cap 70）—— 低估

【揣测意图】你可能觉得 matcher DSL"就是几个 constructor"。

数一下 §5.5 实际要求的：

- **11 个内建 constructor**：`always` / `mention` / `mention_uri` / `from` / `from_member` / `from_external` / `text_contains` / `ref_to` / `and` / `or` / `not`。即使每个只占 2 行，就是 22 行。
- **递归的 `match?/2` 求值器**：要 walk `and`/`or`/`not` 组合 + 8 种叶子类型，每种叶子一个匹配子句。~25-35 行。
- **DSL 宏**：把 `mention("B") and not from(x)` 编译成数据 AST。~15 行。
- **plugin 扩展 API**（§5.5.4 `Matcher.register/2`）：~5 行。
- **`to_string/1`**（Appendix D.1.5 要求的反向渲染，给 LiveView 显示 rule 用）：文档自己说 ~10 行。

加起来 **~75-95 行**，不是 50。这个模块**很可能直接破 70 的 cap**。

**建议**: 要么把 `matcher.ex` 的 target 提到 ~85 / cap 110；要么——更符合 v0.3 自己"少发明，移到 plugin"的原则——**把整个 routing matcher 拆成独立 plugin `esr_routing_matcher`**。它不是 `ezagent_core` 的必需品：core 只需要 RoutingRegistry 能存 `(matcher_data, receivers)`，至于 matcher 怎么求值，完全可以是 plugin 的事。

## 1.4 `kind.ex` ~40 LOC（cap 60）—— 低估

【揣测意图】你可能觉得 `use Ezagent.Kind` 是个薄薄的注册宏。

但看 §5.2 的用法，这个宏要生成的东西不少：

```elixir
defmodule Ezagent.Entity.Agent do
  use Ezagent.Kind,
    behaviors: [Ezagent.Behavior.Identity, Ezagent.Behavior.Movable, Ezagent.Behavior.Spawnable],
    template: Ezagent.Entity.Agent.Template,
    persistence: {:snapshot, :on_change}
end
```

这一个 `use` 要展开出：

- 一个完整的 **GenServer**（`init/1` 要从 snapshot 表读状态、`handle_call` 要做 BehaviorRegistry 查找 + authz gate + slice 取出 + invoke + snapshot 落盘）
- **snapshot 集成**——`init/1` 里"从 snapshot 表读最新 state，无记录则 `init_slice`"，`handle_call` 里"`new_slice != old_slice` 才写"（§10.1）
- **每个 behavior 的 state slice 初始化**（遍历 `behaviors:` 列表调 `init_slice/1`）
- **URI 注册**到 KindRegistry
- 关联 `Server` / `Supervisor` 模块

生成 GenServer 的 `use` 宏在实践中很容易膨胀到 80-150 行。**40 行的 target 偏离比较大，cap 60 也大概率守不住。**

我无法给你一个"现有 Ezagent 等价物"的精确数字，因为现有 Ezagent 没有统一的 `use Ezagent.Kind` 宏（它的 Kind 类型是手写 GenServer）。但正因为现在是手写的，每个 Kind GenServer 都是几百行——这个宏要"替所有 Kind 把那几百行的公共部分收进来"，它不可能是 40 行。

**建议**: `kind.ex` 改成 target ~90 / cap 130。这是 v0.3 LOC 预算里我最担心的一个数字。

## 1.5 `routing_registry.ex` ~60 LOC「统一所有二级表」—— 数字对，但框架有误导

这一条我**部分同意你**。core 那层 60 行的 wrapper（`declare_table` / `put` / `lookup` / `lookup_all` / `delete` + owner-check）——这个数字是现实的，没问题。

但 §5.4 末尾那句"dev review ❌ 区里的 4 项二级 routing 表全部统一到这个机制"会**误导读者**，让人以为 1700 行的 routing 复杂度被"解决"了。

实测：现有 Ezagent 有 9 个 `registry.ex`，一共 **1722 行**。我看了其中最大的两个，它们**不只是存储**：

- `slash_route/registry.ex`（493 行）：有 **longest-prefix 匹配**逻辑（`lookup_prefix("/" <> rest)`）、**plugin overlay 合并**（`register_overlay`/`unregister_overlay`）、**snapshot dump/load**。这些不是 KV 表，是有逻辑的。
- `chat_routing/registry.ex`（417 行）：value 形状是 `{current: sid, attached: MapSet}`，有 **attach / detach / set_current 的状态语义**。也不是纯 KV。

一个通用的 `put`/`lookup` wrapper **无法覆盖** longest-prefix 匹配、overlay 分层、attach/detach 语义。

**真相是**: `ezagent_core` 的 routing_registry.ex 确实只有 ~60 行（存储底座），但那 ~1000+ 行的 routing **逻辑没有消失，只是从"散落在 core"搬到了"各 owner plugin 内部"**。这其实**符合** v0.3 的设计哲学（§5.4.6"core 不预定义任何 table"），是好事——但文档应该**诚实地说出来**："core 60 行是存储底座；prefix 匹配、overlay、attach/detach 这类逻辑由 owner plugin 自己实现"。否则读者会低估总工作量。

**建议**: §5.4 加一句话澄清。LOC 不用改，框架表述要改。

## 1.6 文档自己的 cap 总和已经破了自己的红线

§14 给每个模块标了 cap（target + 40% buffer）。把所有 cap 加起来：

```
35+90+35+40+25+60+40+70+80+70+40+25+55+110+30+25 = 830
```

而 §14 自己写："**全局警戒线：总和超过 750 LOC，触发架构 review**"。

也就是说——**如果每个模块都用满它自己的 buffer**（而 §1.2 / §1.3 / §1.4 已经论证 invocation / matcher / kind 几乎肯定会用满甚至超），那么按 v0.3 自己定的规则，现在就该触发架构 review 了。

这不是说架构错了。是说**预算数字本身没校准**——buffer 设得太松，松到"全用满"就破红线，那这个红线就形同虚设。

**建议**: 重新校准。我的诚实估算是 ezagent_core 真实落地在 **650-800 行**之间。要么接受这个数字（把 475/595 改成 ~700，红线提到 900），要么把 matcher 拆成 plugin（省 ~85 行）、把 arg validator 也算清楚。关键是让"红线"重新变得有意义。

---

# 二、现有 Ezagent 踩过的坑，v0.3 没设计进去

现有 Ezagent 在 `docs/notes/` 里有一批事故复盘。我读了其中 6 份。**v0.3 已经学到的坑**（值得肯定）：

- ✅ erlexec 子进程孤儿生命周期 —— §6.3 明确写了"Kind GenServer 是 erlexec port owner、`terminate/2` 必须 kill、`EZAGENT_SPAWN_TOKEN`、开机扫 `/tmp/esr-worker-*.pid`"。这一条现有 Ezagent 出过"8 倍孤儿"事故（一条消息被回复 8 次），v0.3 把教训完整内化了。
- ✅ Capability 改成 struct（§3.4），而不是字符串。现有 Ezagent 出过"spec 写 `cap.session.create`、代码要 `prefix:name/perm`"的格式不匹配 bug。v0.3 用 struct 从根上消除了这个坑。
- ✅ Feishu WebSocket 留在 Python（§12.4.A）。现有 Ezagent 明确记录过"别想把 Feishu WS 搬进 Elixir"——lark SDK 是 Python 生态。v0.3 尊重了这一点。

下面是**没学到的 5 个**，按严重度排。每条都给：现有 Ezagent 的真实事故 → 代码示例 → 揣测你的想法 → 为什么还是个坑 → 建议。

## 2.1 🔴 P1 — PubSub「先发后订」静默丢消息

**现有 Ezagent 的真实事故**（`docs/notes/cc-mcp-pubsub-race.md`）：

用户发来第一条消息，系统自动创建 session，然后**立刻**往一个 PubSub topic 广播这条消息。但那个 topic 的订阅者（一个刚被拉起、还在启动的下游进程）**还没 join 这个 topic**。Phoenix.PubSub 对"没有订阅者的 topic"的广播是**静默丢弃**的。结果：用户的第一条消息凭空消失，下游永远没收到。

**代码示例**——这就是 PubSub 的结构性陷阱：

```elixir
# Session 创建流程
{:ok, session_uri} = start_session(...)
{:ok, _pty_pid}    = start_pty_child(session_uri)   # ← 这个 child 要花时间才能 join topic

# 立刻路由第一条消息
Phoenix.PubSub.broadcast(Ezagent.PubSub, "#{session_uri}:inbound", first_message)
#                                     ↑
#         如果 pty child 还没跑到 Phoenix.PubSub.subscribe，这条消息就没了
#         broadcast 不会报错、不会阻塞、不会重试——它只是什么都不做
```

**【揣测意图】** 你可能觉得："Kind GenServer 在 `init/1` 里就注册了自己的 topic，等到有人 broadcast 时它早就订阅好了。" —— 对**它自己的 topic** 是对的。但事故的场景是**跨 actor**：Session（一个 actor）创建了一个 pty child（另一个 actor），然后马上往 child 的 topic 发消息。child 的 `init/1` 还没跑完，或者跑完了但 `subscribe` 那行还没执行到。

**为什么 v0.3 没解决**：v0.3 的**整个路由层都建立在 PubSub 上**——§5.5 的 routing rules 算出 receivers 后逐个 dispatch，§12.7 的 View 从 `<session_uri>:events` topic 拿数据。只要有"A 创建 B、A 立刻给 B 发消息"的链路，这个 race 就存在。Appendix A 的 invocation flow 里**没有任何投递保证**——`dispatch` 之后消息到没到、有没有订阅者，无人知道。

**建议**: 在 §5.5 或 Appendix A 加一个"投递保证"小节。现有 Ezagent 事故文档给了三个方案，最干净的是 **B（buffer + flush on ready）**：

```elixir
# 下游 actor 还没 ready 时，发给它的消息先 buffer
def deliver(receiver_uri, message) do
  case Ezagent.KindRegistry.lookup(receiver_uri) do
    {:ok, pid} -> GenServer.cast(pid, {:inbound, message})   # 直接投递，不走 PubSub
    :error     -> Ezagent.PendingDelivery.buffer(receiver_uri, message)
  end
end

# actor ready 后主动 flush
def handle_continue(:ready, state) do
  Ezagent.PendingDelivery.flush(state.uri) |> Enum.each(&handle_inbound/1)
  {:noreply, state}
end
```

注意这里**用 `KindRegistry.lookup` + `GenServer.cast` 直接投递**，而不是 `PubSub.broadcast`——因为 KindRegistry 是"查得到就一定在"的强保证，PubSub 不是。PubSub 适合"广播给不确定数量的旁观者"（比如 View 渲染），不适合"投递给一个确定的 receiver"。这个区分 v0.3 现在没有。

## 2.2 🔴 P1 — 重复注册静默 shadowing

**现有 Ezagent 的真实事故**（`docs/notes/mcp-transport-orphan-session-hazard.md`）：

两个外部客户端（两个 `claude` 进程）都连上来，都把自己注册到**同一个逻辑地址**。注册表是 last-writer-wins，第二个静默覆盖了第一个。结果：路由到这个地址的消息全发给了"错误的那个"客户端（或者一个已经死了的连接）。**用户看得到系统的输出，但自己发的东西全部蒸发，没有任何报错**——因为存活的那个客户端的 TCP 连接还活着，PING/PONG 正常，它根本不知道自己被 shadow 了。

**代码示例**——v0.3 §12.8.4 的 CC channel 鉴权代码：

```elixir
def connect(%{"token" => token, "cc_instance" => instance_id}, socket, _info) do
  case verify_token(token, instance_id) do
    {:ok, agent_uri} ->
      Ezagent.RoutingRegistry.put(CCInstanceConnection, instance_id, agent_uri)
      #                       ↑
      #  put 是 last-writer-wins。如果同一个 instance_id 已经有一条连接，
      #  第二次 connect 直接覆盖，第一条连接被静默孤立——没有 reject，没有日志
      {:ok, assign(socket, %{agent_uri: agent_uri})}
    _ -> :error
  end
end
```

**【揣测意图】** 你可能觉得："§12.8.5 说了每个 CC 实例有不同的 `instance_id`，不会撞。" —— 在**理想情况**下对。但现实里同 key 双写有好几种来路：上一次进程崩溃留下的孤儿连接还没清理、配置错误导致两个 CC 用了同一个 instance_id、客户端重连时旧连接还没断开。事故文档说的就是这种——而且关键是**它静默**，你不会知道。

**为什么 v0.3 没解决**：v0.3 的 `RoutingRegistry.put` 语义就是覆盖。§5.4.7 的"四条硬约束"里没有"同 key 已存在且存活时拒绝写入"这一条。

**建议**: RoutingRegistry 的 `put` 对"unique key 表"应该提供 `put_new` 语义——key 已存在且指向的 pid 还活着，就 reject：

```elixir
# RoutingRegistry 增加一个变体
def put_new(table, key, value) do
  case lookup(table, key) do
    {:ok, existing} ->
      if alive?(existing),
        do: {:error, {:already_registered, existing}},   # ← reject，不静默覆盖
        else: put(table, key, value)                      # 旧的死了，可以接管
    :error -> put(table, key, value)
  end
end
```

CC channel 的 `connect/3` 用 `put_new`，撞了就 `{:error, %{reason: "instance already connected"}}`——让重复连接**显式失败**，而不是静默 shadow。

## 2.3 🟠 P2 — 零匹配消息静默丢

**现有 Ezagent 的约束**（`docs/notes/system-invariants.md` 的 invariant I5）：

现有 Ezagent 有一条**硬 CI gate**：routing 层的代码**不准**出现 `other -> Logger.warning + drop` 这种 catch-all。理由很简单——静默丢消息是不可观测的 bug，必须从代码层面禁掉。

**代码示例**——v0.3 §5.5.1 的路由函数：

```elixir
def route(session_uri, message) do
  Ezagent.RoutingRegistry.lookup_all(SessionRules, session_uri)
  |> Enum.filter(fn {matcher, _} -> Matcher.match?(matcher, message) end)
  |> Enum.flat_map(fn {_, receivers} -> receivers end)
  |> Enum.uniq()
end
# 如果没有任何 rule 匹配 → receivers = []
# 调用方拿到 [] → Enum.each([], &dispatch/1) → 什么都不做 → 消息没了
```

**【揣测意图】** 你可能觉得："匹配不到 rule 的消息就是 no-op，没问题。" —— 在一个**纯路由层**这么想是合理的。但 Ezagent 是个 **chat 系统**：用户发的一条消息**到达了零个 receiver**，这本身就是 bug——用户期待"有人收到"。返回 `[]` 跟"正常工作"在代码上无法区分，所以这个 bug 永远不会被发现。

**为什么 v0.3 没解决**：v0.3 的 additive-rules 路由（§5.5）天然有"零匹配"这个出口，但 v0.3 没说零匹配怎么办。DLQ（§10.3 class E）只抓"失败"（Behavior 异常、进程崩溃、超时）——零匹配不是失败，是"成功地路由到了没有人"，DLQ 抓不到它。

**建议**: §5.5 明确零匹配的处理。最小方案：零匹配 → 写一条 `unroutable` 系统事件 + DLQ 条目：

```elixir
def route(session_uri, message) do
  receivers = # ... filter + flat_map + uniq ...
  case receivers do
    [] ->
      :telemetry.execute([:ezagent, :routing, :unroutable], %{}, %{session: session_uri, message: message})
      Ezagent.DeadLetter.put(:unroutable, message)
      []
    rs -> rs
  end
end
```

这样"用户消息没人收"至少在 telemetry 和 DLQ 里**可观测**。

## 2.4 🟠 P2 — 幂等 / webhook 重试去重缺失

**背景**：Feishu（以及绝大多数 webhook 提供方）在没有快速收到 200 响应时**会重试投递**。同一条 inbound 消息可能到达 2-3 次。现有 Ezagent 在它的 actor 里用一个 idempotency key 做去重（bounded MapSet，记最近见过的 key）。

**代码示例**——v0.3 Appendix A 的 invocation flow 是 12 步：

```
1. dispatch(%Invocation{})
2. parse URI
2.5 validate args against @interface
3. KindRegistry.lookup → pid
4. GenServer.call(pid, ...)
5. BehaviorRegistry.lookup → behavior_module
5.5 AUTHZ GATE
6. slice = state[slice_key]
7. invoke(action, slice, args, ctx)
8. {:ok, new_slice, result}
9. put_in(state, ...) [+ snapshot]
10. :telemetry
11. {:ok, result}
12. Invocation.reply(ctx, result)
```

**这 12 步里没有"去重"。** `ctx` 里有 `trace_id`，但没人拿它做幂等。Feishu webhook 重试一次 → 同一条消息走完整个 flow 两次 → Behavior 的 `invoke/4` 被调两次 → 状态被改两次 / 消息被回两次。

**【揣测意图】** 你可能觉得："adapter 可以自己去重。" —— 但这跟 v0.3 §2.3 的硬规矩冲突："**Adapter 不允许有业务语义**。判断标准:这段代码能在 ExUnit 里直接 `Invocation.dispatch/1` 复现吗?" 去重是个跨所有 adapter 的横切关注点，放在 adapter 里就是每个 adapter 各写一遍、风格不一。它应该在 invocation flow 里，或者做成一个标准 cross-cutting Behavior。

**建议**: Appendix A 在 step 2.5 之后加一步 **2.7 幂等检查**：

```elixir
# Invocation 带一个可选的 idempotency_key（adapter 从外部协议的 message_id 填）
%Ezagent.Invocation{
  ctx: %{idempotency_key: "feishu:om_abc123", ...}
}

# dispatch 里:
case ctx[:idempotency_key] do
  nil -> :proceed
  key ->
    if Ezagent.Idempotency.seen?(key),
      do: {:ok, :duplicate_ignored},          # 重试到达，直接返回，不进 Kind
      else: Ezagent.Idempotency.record(key)        # 第一次见，记下，继续
end
```

`Ezagent.Idempotency` 是个 bounded 的 ETS 表（记最近 N 个 key，LRU evict）——~20 行，可以是 core 的一部分，也可以是 `esr_behavior_idempotency` plugin。

## 2.5 🟡 P3 — SQLite 缓存模块名的 staleness

**现有 Ezagent 的真实事故**（`docs/notes/refactor-lessons.md` §三-2）：

现有 Ezagent 的运行时状态文件里缓存了**字符串形式的模块名**（比如 `command_module: "Ezagent.Admin.Commands.Session.End"`）。当你 rename 那个模块后，磁盘上缓存的字符串还是旧的 → daemon 启动时按旧名字找模块 → `unknown_module` → 启动失败级联。

**代码示例**——v0.3 §10.1 的 snapshot 表：

```sql
CREATE TABLE kind_snapshots (
  uri          TEXT PRIMARY KEY,
  kind_module  TEXT NOT NULL,     -- ← 存的是 "Elixir.Ezagent.Entity.Agent" 这种字符串
  state        TEXT NOT NULL,
  ...
);
```

`invocations` 表（§10.2）也存 `caller TEXT` / `target TEXT`，里面也是 URI + 模块引用。

**rename 一个 Kind 模块 → 它所有的 snapshot 行 `kind_module` 字段就 orphan 了** → 下次 `init/1` 想从 snapshot 恢复，按旧模块名 `String.to_existing_atom` 会炸。

**【揣测意图】** 你可能觉得："ezagent 是全新的库，不会有现有 Ezagent 那种大规模 rename。" —— **部分对**，新库的 rename 压力确实小很多。但在 v0 早期开发阶段，Behavior / Kind 模块**一定会被改名**（这就是开发）。一个 keyed 到旧模块名的 snapshot 行，rename 后就 rehydrate 失败。这个结构性 hazard 跟着"用字符串存模块引用"这个设计回来了——只是存储介质从 YAML 换成了 SQLite。

**为什么标 P3 不是 P1**：因为 ezagent 是 greenfield、rename 频率低，而且影响面是"开发期偶尔炸一下"，不是"生产事故"。但值得在 §10 提一句。

**建议**: 两个方向，选一个：

1. **存稳定 ID 而非模块名**——`kind_snapshots` 存一个 `kind_id`（比如 `"agent"`），由 KindRegistry 在运行时映射到当前模块。模块改名，映射改一处，snapshot 行不动。
2. **接受它，但写进 migration 纪律**——§10 加一句"rename 一个 Kind 模块时，必须同步 `UPDATE kind_snapshots SET kind_module = ... WHERE kind_module = ...`"。

方向 1 更彻底，符合 v0.3"少让新人记东西"的哲学——开发者改名时不需要记得"还要去 patch SQLite"。

---

# 三、二级机制还没落到模块级

这些不是"错"，是"还没设计到能开始编码的粒度"。

## 3.1 Workspace —— 你的直觉部分对，但结论要修正

这一条单独展开，因为它最值得讨论。

**【揣测意图】** "既然有了持久化层，是不是就没必要增加 Workspace 这个概念了？" —— 我猜你的想法是：workspace 不就是"一个目录 + 几行配置"吗？它又不像 Session / Agent 那样**活着、做事**，给它一个 GenServer actor 是过度设计。

**你这个直觉，关于"Workspace 不需要是个重量级 actor"——是对的。** 一个 workspace 确实不需要常驻 GenServer：它不接收消息流、不持有 PTY、没有生命周期事件。

**但结论要修正。** 问题不是"Workspace 要不要是个 actor"，问题是"**workspace 上的操作要不要是 Behavior**"。

现有 Ezagent 的 workspace 有这些操作（我实测，现有 `commands/workspace/` 有 12 个命令模块）：`add-folder`、`bind-chat`、`import-repo`、`list-registered-repos`、`describe`、`set-default`……

如果这些操作**绕过 v0.3 的统一模型**（直接写 SQLite 行），那么：

- `workspace add-folder` **不经过 CapBAC** —— 谁都能加，没有权限门
- 它**不进 audit log**（§10.2 D）—— 谁在什么时候改了 workspace 配置，查不到
- 它**不会出现在 CLI / LiveView**（Appendix D 说这两个 UI 是从 `@interface` 自动生成的）—— workspace 操作就得手写 UI，破坏了"多 View 同源"
- 它是一条**特殊路径**，游离在 v0.3"一切可调用的都是 Behavior"的统一模型之外

而 v0.3 的**全部价值**就建立在"统一模型"上。开一个口子，口子会变多。

**正确的结论**：v0.3 的三种 Kind 子类里，**`Resource` 这个子类就是为这种情况准备的**——§3.1 自己写的："Resource = 操作对象，无 Principal"。Workspace 完美符合：它是个**被操作的对象**，不是 Principal，不需要重量级生命周期。

所以 Workspace **应该**是个 `Resource` Kind，但它可以是个**极薄的 Resource**——它的"state"基本就是持久化层的几行，它的 GenServer（如果有）可能只在被操作时短暂存在、操作完就 `:on_terminate` 落盘退出（§10.1 的 `persistence: {:snapshot, :on_terminate}` 正好适配）。甚至可以是 `persistence: :external`——状态完全在持久化层，Kind 实例只是操作的入口。

**给你的具体建议**：v0.3 不需要删掉 Workspace 概念，需要的是 **§3.5 之后加一段，明确 `Resource` Kind 的"薄"形态**——一个 Resource 可以几乎没有自己的运行时状态，它存在的意义是"给操作它的 Behavior 一个 URL 可寻址的挂载点"。然后把 Workspace 当成这个薄形态的**示范例子**，列出它的标准 Behavior 集（`Ezagent.Behavior.WorkspaceFolders`、`Ezagent.Behavior.WorkspaceBindings` 等）。

这样你既保住了"workspace 不是重量级 actor"的正确直觉，又没有在统一模型上开口子。

## 3.2 Plugin 运行时配置 —— 可能只是没说，不是没有

**【揣测意图】** §9.4 的 plugin discovery 用 `Application.spec/2` 读 `:env` 里的 `:ezagent_kinds`。我猜你可能觉得"plugin 配置就是 `:env` 块"。

但 `:env` 是**编译期静态**的。现有 Ezagent 的 plugin 有**运行时可变**的配置——比如 Feishu plugin 要配"用哪个 Feishu app 的 credentials"、"哪些 chat 绑到哪些 workspace"，这些是运维在系统运行时会改的，不是编译进 `:env` 的。

**这一条可能其实你已经覆盖了，只是没说**：v0.3 §10 的持久化分层里，**类型 A「配置/定义」**写的是"KindType 注册、Plugin 装载、Template 内容 → Ecto + SQLite"。Plugin 的运行时配置**完全可以就是类型 A 持久化**——plugin 在 `Application.start/2` 里从 SQLite 读自己的配置行。

**给你的建议**：如果是这样，§9 或 §10 加一句话明确："plugin 的运行时可变配置属于持久化类型 A，plugin 自己用 Ecto 读写"。如果不是这样、你有别的设计，那就需要补。无论哪种，现在文档里这块是空的，读者不知道 Feishu plugin 的 app credentials 该存哪。

## 3.3 `@interface` 类型校验器没有自己的模块和预算

这条在 §1.2 提过，这里单列因为它是个**独立的可交付物**，不只是 LOC 问题。

`@interface` 的类型记号（§6.2）是 `{:tuple, :integer, :integer}` / `{:list, :string}` / `{:option, :string}` / 嵌套 `%{field => ty}`。要在 dispatch step 2.5 校验 args，需要一个**递归校验器**。v0.3 的 §14 模块布局里**没有这个模块**——它要么塞进 `invocation.ex`（撑爆那 70 行预算），要么塞进 `behavior.ex`（那只是 `@callback` 契约，不该有逻辑）。

**给你的建议**：§14 加一个 `interface_validator.ex`（~35 LOC，cap 50），职责单一：给一个 type spec + 一个 value，返回 `:ok | {:error, violations}`。

## 3.4 实例化策略没说

v0.3 删掉了 Process trait/impl（好），`persistence:` 声明了**状态**策略。但还缺一个**实例化**策略：一个 Kind 是"每个 session 一个实例"还是"全局单例"还是"按需创建"？

【揣测意图】你可能觉得这隐含在 Kind 子类里（Session 显然是多实例、按需建）。对 Session 是清楚的。但 `Ezagent.Entity.Agent`——是每个 session 一个 agent 实例，还是一个 agent 实例跨 session 复用？v0.3 没说。这个不紧急（P3），但开始写 `Ezagent.Kind.Template` 的 `instantiate/2` 时会撞到。

---

# 四、给 v0.3 → v0.4 的改动清单

按优先级：

| 优先级 | 改动 | 对应章节 |
|---|---|---|
| 🔴 P1 | 加"投递保证"——区分 `KindRegistry.lookup + cast`（确定 receiver）vs `PubSub.broadcast`（不确定旁观者）；下游未 ready 时 buffer + flush | §5.5 / Appendix A |
| 🔴 P1 | RoutingRegistry 加 `put_new` 语义，CC channel `connect/3` 撞 key 显式 reject | §5.4 / §12.8.4 |
| 🟠 P2 | 路由零匹配 → telemetry + DLQ，不静默返回 `[]` | §5.5 |
| 🟠 P2 | Appendix A 加 step 2.7 幂等去重；加 `Ezagent.Idempotency` 模块或 plugin | Appendix A / §14 |
| 🟡 P3 | snapshot/audit 表存稳定 `kind_id` 而非模块名字符串 | §10 |
| 🟡 P3 | LOC 预算重新校准：475→~700；invocation/matcher/kind 三个 target 上调，或把 matcher 拆 plugin | §14 |
| 🟡 P3 | `Resource` Kind 的"薄形态"明确化 + Workspace 作为示范，列出它的标准 Behavior 集 | §3.5 后 |
| 🟡 P3 | plugin 运行时配置归属说清楚（大概率就是持久化类型 A） | §9 / §10 |
| 🟡 P3 | §14 加 `interface_validator.ex` | §14 |
| — | 修文档内部 LOC 数字矛盾（475 vs 595 vs 580） | §1.1 / §2.1 / §14 / §16 |
| — | §5.4 澄清"routing_registry core 60 行 ≠ routing 逻辑被解决，~1000 行逻辑 relocate 到 plugin" | §5.4 |

**最重要的两条是 🔴 P1**。它们是现有 Ezagent 的真实生产事故，而 v0.3 是个**全 PubSub 架构**——这两个坑不设计进去，会原样复现，而且都是"静默丢消息、无报错"的那种最难查的 bug。

其余的 P2/P3 是"开始编码前补齐"，不补也能写，但会在写到对应模块时撞墙。

---

# 附：评审方法说明

- **v0.3 全文**：2170 行，通读。
- **LOC 实测**：现有 Ezagent 代码库里，每个 v0.3 core 模块的最接近等价物，用 `wc -l` 实测。具体数字在正文里标了"实测"。我没有猜任何一个数字——猜不出来的地方（比如 `kind.ex` 没有现成等价物）我明说了"无法给精确对照"，只做功能推理。
- **事故复盘**：读了 `docs/notes/` 里 6 份：`cc-mcp-pubsub-race.md`、`mcp-transport-orphan-session-hazard.md`、`system-invariants.md`、`refactor-lessons.md`、`capability-name-format-mismatch.md`、`erlexec-worker-lifecycle.md`、`feishu-ws-ownership-python.md`。每个"坑"都能追溯到一份具体的事故文档。
- **【揣测意图】标记**：凡是这个标记下的内容，都是我在猜你的设计意图——可能猜错，欢迎反驳。其余内容是基于代码事实和 v0.3 文本的推理。
