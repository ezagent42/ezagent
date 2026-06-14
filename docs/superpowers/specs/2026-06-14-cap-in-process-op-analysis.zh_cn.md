# 带 cap 检查的进程内操作原语 —— 分析（任务 #56）

> **分析，不是已定设计**（它动 CapBAC 收口 —— "never weaken authz" —— 所以写代码前
> 走 Allen review + codex adversarial-review）。框出问题、列出要退役的变通类、勾勒原语、
> 列待定问题。代码引用是时间点快照（9b 改名为 `ezagent_domain_session` 之后）。
>
> 双语镜像：[`2026-06-14-cap-in-process-op-analysis.md`](./2026-06-14-cap-in-process-op-analysis.md)。

## 1. 问题

一个 Kind 无法对**自己的状态做带 cap 检查的进程内操作**。正常授权路径是*跨进程*的：
构 `Invocation` → dispatch → `GenServer.call` 到目标 Kind → `Kind.Runtime` step 5.5
（`Capability.matches?`）→ handler。一个 Kind 想这样派发给*自己*会**死锁** —— 它卡在
自己的 `call` handler 里等一个发给自己的 `call`（`runtime.ex:392-398`：*"那个
GenServer.call 会对自己死锁……直到 5s 默认超时"*）。

所以当 handler 需要本 Kind 的另一个（或自己的）slice 时，代码用**非受检的变通**绕开派发：

## 2. 要退役的变通类

1. **`reads_siblings/0`**（+ 旧 `reads_sibling_slices/0`）—— Behavior 静态声明它要
   in-process 读的兄弟 slice key；`Kind.Runtime` 把这些 slice 喂给 handler。这个读由
   **静态声明、而非能力**门控。今天活跃的 consumer：
   - `ezagent_domain_session/.../behavior/agent/receive.ex` → `reads_siblings([:sandbox])`
   - `ezagent_domain_external_mirror/.../behavior/external_mirror.ex` → `reads_siblings([:publisher])`
   - `ezagent_domain_identity/.../behavior/config_evolve.ex` → `reads_siblings([:sandbox, :identity])`
2. **`get_slice(self)`-avoidance** —— `Kind.Runtime` / delivery 代码刻意避免对 `self` 调
   `Kind.get_slice` 来躲同一个死锁。

两者都是读侧 hack，绕过 cap 收口：一个 Behavior 读兄弟 slice 是靠*被声明*授权的，不是靠*持有 cap*。

## 3. 为什么 gate 能在进程内复用（关键洞察）

`Ezagent.Capability.Match.matches?/2`（`capability/match.ex`）是个**纯函数** —— 它拿 cap
对 `%{kind, behavior, action, instance, workspace_uri}` 做检查，不发任何进程调用。死锁是
*传输*（`GenServer.call` 自己）造成的，**不是** cap 检查造成的。所以授权决策可以**在进程内**
对 `ctx.caps` 跑、零死锁风险；只有请求的跨进程*投递*需要跳过。

这正是被否的 option-D 的 part(a)（#53 orchestrator "D vs C" 辩论，2026-06-13）被称为
*干净 + 不和 runtime 对打*的原因：它是纯函数授权，与死锁机制解耦（orchestrator 最终用
option C / SessionManager Kind 走正常跨进程派发解决；本原语正交，留作 #56）。

## 4. 原语草案（待 brainstorm）

一个 cap 门控的进程内操作：对 `ctx.caps` 用 `matches?` 授权，然后直接操作内存里的 slice ——
全在 Kind 自己进程内，无 `GenServer.call`。概念上：

```elixir
# 在 handler 里，ctx.caps 在作用域内：
with :ok <- Ezagent.Capability.authorize_in_process(ctx.caps,
              %{kind: k, behavior: b, action: a, instance: self_uri, workspace_uri: w}) do
  # 直接读/操作自己/兄弟 slice（已在本进程）
end
```

- **同一个 gate、同一套语义**，和 step 5.5 一致——同样的 `{kind, behavior, action,
  instance, workspace_uri}` 检查。它**不削弱 authz**；移除的是*传输*、不是*检查*。
  （对比：今天的 `reads_siblings` 是把检查整个移除了。）
- **退役**变通类：`reads_siblings([:sandbox])` 的读变成 cap 门控的进程内读；静态兄弟声明
  机制 + `get_slice(self)`-avoidance 就能删掉。
- **不包含** option-D 那套和 runtime 对打的死锁机制（按 #56 任务说明明确排除）。

## 5. 待定问题（给 Allen，写 plan 前）

1. **API 形态。** 纯函数 `Ezagent.Capability.authorize_in_process/2`（纯、返回
   `:ok | {:error, :unauthorized}`）、还是 `Kind.Runtime.in_process_op/…`（连操作一起做）、
   还是 Behavior 宏？推荐：**先做纯 `authorize_in_process/2` helper**（最小、可测、不动
   runtime），再迁移 consumer。
2. **只读 vs 读+写？** `reads_siblings` 今天只读。扩到 cap 门控的进程内*写*（对自己 slice 的
   effect）还是把 #56 只锁定在读（对等它退役的东西）？推荐：**先只读；写作为单独后续**避免
   范围膨胀。
3. **迁移范围。** 一次性引入原语 + 迁移全部 3 个 consumer + 删 `reads_siblings`/
   `reads_sibling_slices` + avoidance？还是落原语、增量迁移、最后删机制？推荐：**一次性（干净）**。
4. **排序 vs 基座化。** `matches?` + `Kind.Runtime` 在 `core`；3 个 consumer 里两个在刚改名的
   session/external_mirror/identity 域。9b 已合；只剩 9c（allowlist 收缩，机械）。所以 #56 可在
   9c 后在 `core` 起、低 churn。确认时机。

## 6. 完成判据

证明 #56 真的补上了缺口的测试（按 `feedback_completion_requires_invariant_test`）：
**当所需 cap 缺失时，一个 Kind 的进程内自/兄弟读被拒** —— 这是今天 `reads_siblings` 表达不了的
（它的读是非门控的）。该测试在当前静态声明机制下失败，只有当读真正被进程内 cap 检查时才通过。

## 7. 交叉引用

- `Ezagent.Capability.Match.matches?/2` —— 要复用的纯 gate。
- `Ezagent.Kind.Runtime`（`runtime.ex:392-398`）—— 逼出变通的自调用死锁。
- `Ezagent.Behavior` / `Ezagent.Lifecycle` —— `reads_siblings/0` 声明 + surfacing。
- §2 的 3 个活跃 `reads_siblings` consumer。
- 起源：#53 orchestrator "D vs C" 设计（Allen 2026-06-13）—— option D 的 part(a)。
