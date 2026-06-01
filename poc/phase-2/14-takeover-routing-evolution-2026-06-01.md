# 接管:现在用 Mode 抑制,将来改路由重配(决策 + 不要重新推导的洞见)

> 2026-06-01 讨论(无代码)。决策:**路线 1 —— 保留当前的 Mode 输出抑制式接管
> (Block 2 / PR #526,即现在的 #532);把基于路由的接管 + Copilot 推迟到
> `Behavior.Mode` 的 Phase-2 演进。** 近期没有 Copilot 需求。这份 note 记录*为什么*
> 路由才是长期正确的原语,免得 Copilot 落地时再重新推导一遍。

## 洞见(已在代码中验证)
"一个 session 里谁能应答"是由**路由层**决定的,而这一层是一个
**Session 级原语 —— 不归 orchestrator 所有**:
- `Chat.handle_send` 通过 `Routing.Resolver.resolve` 对着一张规则表
  (`RuleStore` SQLite → `RoutingRegistry` ETS)算出接收者。连"广播给所有人"也只是
  一条规则(`{:always} → [$session_users, $mentions]`)。没有硬编码的 fan-out。
- `routing.add_rule` / `disable_rule` / `enable_rule` 是注册在
  **`Ezagent.Entity.Session`** 上的 CapBAC action(`Ezagent.Behavior.Routing`)。
  任何持有对应 cap 的人都能直接调。
- orchestrator 的 `write_matcher` 只是 `routing.add_rule` 的**一个调用方**(对它自己的
  Session URI 派发)。**方案 B 的 `customer_session.install_routing` 已经通过
  `RuleStore.add` 直接写入 customer→agent 规则** —— 路径上没有 orchestrator。
- ⇒ 要用这个能力,我们**直接用 Session 路由原语**;**不**耦合(也不需要)orchestrator agent。

## 为什么路由是这三种模式的正确原语
术语表里的三种模式本质都是"谁收到什么" —— 也就是路由:
| 模式 | 路由 |
|---|---|
| **Auto** | customer→agent、agent→customer(operator 加入后经 `$session_users` 观察) |
| **Takeover** | customer→operator、operator→customer;**agent 被从接收者里剔除** |
| **Copilot** | customer→agent+operator;agent→operator(审核)→customer,或反向 |

**输出抑制无法表达 Copilot**(它只能二值地静音 agent 的*出向*消息)。路由可以。所以
干净的长期分层是:**`Mode` slice = 意图声明(auto/takeover/copilot);其*效果* = 一次
路由重配** —— 从而去掉 `Chat.handle_send` 里那个特判式的抑制。

## 当前的接管(#526 实际做了什么)
- operator 以自己的 `entity://user/...` URI 加入(`chat.join`)并以该 URI 经 `chat.send`
  回复 → 正常 fan-out 给客户(它本就是一等参与者;"operator 加入 + 前端过滤"**已经是
  现实**)。
- `mode.set(:takeover)` 翻转 `:mode` slice;`Chat.handle_send` 随后**仅在发送者是 agent
  时**丢弃面向客户的接收者。所以客户消息**仍然路由到 agent,agent 仍然跑一整轮 LLM** ——
  只是它的回复在 fan-out 处被丢掉。浪费 + 有一个 turn 中途的竞态,但简单且可轻易回退。

## 做路由版时要解决的 gap(Phase 2)
1. **可逆性** —— 路由是持久化状态;恢复时必须还原到之前精确的接收者集合 / enabled 标志。
   用一条临时 overlay 规则(disabled 优先)或 store-and-restore。(今天翻 slice 是免费的;
   路由不是。)
2. **没有"丢弃单个接收者"的 helper** —— 只有整条规则 `disable` 或整个列表
   `update_receivers`。小问题:B 已经能按 agent URI 定位到规则。
3. **turn 中途已在途的回复** —— 路由只能阻止*新*的 agent turn;已派发的回复仍会落地。
   ⇒ 为在途窗口保留一个**薄薄的输出抑制兜底**。所以 Phase-2 形态是*混合式*:路由重配
   (无新 agent turn、可支持 copilot)+ 一张小的抑制网。

## 何时重做
当 **Copilot** 进入范围时(或当繁忙接管下每 turn 浪费的 agent LLM 调用成为可测量的成本时)
再做路由版。在那之前,#526 的 Mode 抑制方案成立。
