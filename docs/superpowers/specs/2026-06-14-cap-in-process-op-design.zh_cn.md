# 带 cap 检查的进程内操作原语 —— 设计（任务 #56）

> **⚠️ 已废弃 2026-06-15 —— 决策 B（结构性授权 + 静态 gate）。下面的 cap 检查方案未实现。**
> Allen 2026-06-15：一个 Kind 在进程内读**另一个 Behavior** 的 slice，视为**结构性授权——
> 不做运行时 cap 检查**。理由：`reads_siblings` 的消费者全是跨 *Behavior* 的（不是"一个 Kind
> 读自己"）；读方和数据同属一个 Kind/实体的信任域;"哪个 Behavior 读哪个 Behavior"是类型级/
> 静态关系（已由 `@required_reads`/`@slice_owners` 闭包编码），给它铸一个每实例都相同的 cap
> 只是重复编码同一事实、不增信息；而且对 4 个 **Session** Kind 消费者，运行时自读 cap **结构上
> 不可能**（Session Kind 不挂 `Behavior.Identity`，本身不持有任何 cap —— 见 analysis）。关键：
> **调用（invocation）始终在 dispatch step 5.5/5.6 被 cap 网关拦截**，所以这**不会**造成面向用户
> 的提权：sibling 读是 behavior 作者代码（用户不可在运行时调用）、同 Kind 内、且只读。
>
> **替代运行时 cap 的纵深防御：** 一个静态 CI gate ——
> `apps/ezagent_core/test/invariants/sensitive_slice_read_test.exs` —— 要求任何**非 owner** 代码
> 读**机密 slice**（`:identity` caps、`:api_keys` 凭证）都必须带理由进 allowlist，覆盖
> `reads_siblings`（宏 + 手写 `def`）**和** `Kind.get_slice/2` 两条路径。新增未经 review 的
> 凭证/caps 读会在代码层 CI 失败，而不是运行时悄悄泄漏权限。下面草拟的
> `Ezagent.Capability.authorize_in_process/2` 与 cap 化 `ctx.read_slice` 访问器**未实现**（B 下无
> 消费者）。本 banner + #56 PR 即 durable 记录；`ARCHITECTURE.md` Appendix-B Decision Log
> 条目（#155）留给 Allen 加（ARCHITECTURE.md 由 Allen 维护，本处不改 —— 见 CLAUDE.md）。§1–§8 的
> cap 检查设计保留在下面，仅作被否决的备选。

> **设计 spec。** 基于
> [`2026-06-14-cap-in-process-op-analysis.zh_cn.md`](./2026-06-14-cap-in-process-op-analysis.zh_cn.md)。
> 推荐答案 Allen 2026-06-14 暂批（"写完 spec + codex review 后再决策"）—— 故本 spec 走
> **codex adversarial-review**（已跑、findings 已并入），再由 Allen 决策后实现。实现排在
> **基座化 PR-9c 之后**。动 CapBAC 收口 → "never weaken authz" 统领每个选择。
>
> 双语镜像：[`2026-06-14-cap-in-process-op-design.md`](./2026-06-14-cap-in-process-op-design.md)。
>
> **consumer 数量更正（post-9c）：** §3、§5 写「3 个 consumer」；post-PR-9c 实际
> `reads_siblings` 数是 **6**（9c 把 curl state Behavior reparent 进 agent 域 +
> 两个 session 域 reader 不在最初过滤 grep 里）。权威清单见
> `docs/superpowers/plans/2026-06-14-cap-in-process-op-plan.md` 的 Scope-correction 表。
> §3 迁移适用于全部 6 个。

## 1. 目标

把**非受检**的进程内自/兄弟 slice 读机制（`reads_siblings` / `reads_sibling_slices` +
`get_slice(self)`-avoidance）换成**受检**的进程内读，复用现有 CapBAC gate —— 补上 authz
缺口、又不重新引入自调用死锁。

## 2. 原语

### 2.1 `Ezagent.Capability.authorize_in_process/2`（纯函数）

```elixir
@spec authorize_in_process(MapSet.t(Capability.t()), needed :: map()) ::
        :ok | {:error, :unauthorized}
```

- **纯函数** —— 无进程调用，故无死锁。与 `Kind.Runtime` step 5.5 用同一个
  `Capability.matches?` 决策、同一个 `needed` 形状
  `%{kind, behavior, action, instance, workspace_uri}`。它移除*传输*（跨进程
  `GenServer.call`），绝不移除*检查*。
- 这是全部 authz 表面。其余都是调它的管道。

### 2.2 cap 门控的进程内 slice 访问器（runtime 管道）

handler 运行在它的 Kind 的 GenServer *内部*，所以 Kind 的全部 slice map 已在进程内 ——
数据从不需要 call 自己；只有*授权*需要，而那现在是 `authorize_in_process/2`。`Kind.Runtime`
给 handler 一个 `ctx` 里的门控访问器：

```elixir
case ctx.read_slice.(:sandbox) do
  {:ok, sandbox} -> ...
  {:error, :unauthorized} -> ...   # 缺 cap —— fail closed
end
```

`ctx.read_slice.(key)` 内部：构 `needed`（§2.3）、对**该 Kind 自己的有效 caps** 授权
（§2.5 —— **不是**入站 caller 的 `ctx.caps`）、`:ok` 时直接从 Kind 自己 state 返回 slice 值。
无声明、不 surface 没被请求的 slice、不死锁。

### 2.3 进程内 slice 读的 cap 形状（关键设计点）

"Kind 读自己 slice `key`" 的 `needed`：

```elixir
%{kind: self_kind, behavior: owning_behavior_of(key), action: :read,
  instance: self_uri, workspace_uri: self_workspace_uri}
```

`owning_behavior_of(key)` 是 `state_slice` 为 `key` 的 Behavior（`Kind.BehaviorSet` 已可解析）。
所以读 `:sandbox` 的 Kind 必须持有匹配 `{kind, <sandbox 拥有者 behavior>, :read, self, ws}` 的 cap。

**含义：** 这让进程内读从「声明即可」变成「需授予的能力」。合法自读的 Kind（3 个 consumer）
必须在 **create 时被授予对应自读 cap** —— 是有意的加强（读现在被授权、可审计、可撤销），但
是真的迁移成本。授予发生在 Kind 本来就做的 create 时 cap 铸造里；无运行时 cap 捏造。

### 2.4 读 cap 的 subject 注册（codex review）

自读 cap 的 **subject 是 Kind 自己的 URI** —— cap 行以 create 时权威为 `granted_by` 铸造、
挂在 Kind 身份下（Kind 其它 cap 所在处）。即 3 个 consumer 的 create 时 cap 铸造各加自己的自读
cap（`cap(self_kind, owning_behavior, :read, self_uri, ws)`）。没有单独的「读 cap 注册表」——
就是 Kind 上一条普通 cap，按 Kind 所有 cap 同样方式解析。boot 重建给已存在的该类 Kind 补授（§3）。

### 2.5 谁的权威、以及有效集闭包（codex review —— 承重）

naive 的 `authorize_in_process(ctx.caps, …)` 错了两点：

1. **谁的 caps。** Kind 读自己 slice 是以**自己的权威**行事，不是入站 caller 的。所以 principal
   是 **Kind 自己**，它的 caps 按 `Kind.Runtime` 解析 target 权威**同样的方式**解析（Kind 身份
   slice 的 caps / Kind 自己的 cap 集）—— **不是**触发派发带来的 `ctx.caps`（那属于调进来的人）。
   用 `ctx.caps` 会让特权 caller 的 cap 漏进 Kind 自读，或在非特权 caller 触发时拒掉合法自读。
   访问器内部解析 Kind 自己的 caps；handler 从不传 cap 集。
2. **有效集闭包。** 检查必须套用与 step 5.5/5.6 相同的闭包 —— `Capability.cross_workspace?/2`
   （admin `:any` + 系统成员旁路）+ 完整有效 cap 集 —— 不是裸 `matches?` 过原始 list。
   `authorize_in_process/2` 因此精确镜像 runtime 的授权语义（它就是同一决策的进程内*调用点*），
   于是进程内读既不比等价跨进程派发更严、也不更松。

一句话：**`authorize_in_process/2` 就是 `Kind.Runtime` 已经在做的同一授权，只是在进程内对 Kind
自己解析出的权威调用** —— 去传输、留 principal 与闭包。

## 3. 迁移（一次性 —— Allen 批的推荐）

1. 加 `authorize_in_process/2` + `ctx.read_slice` 访问器 + 自读 cap 的 `:read` 铸造。
2. 把 3 个活跃 consumer 从 `reads_siblings` 转过来：
   - `behavior/agent/receive.ex` `reads_siblings([:sandbox])`
   - `behavior/external_mirror.ex` `reads_siblings([:publisher])`
   - `behavior/config_evolve.ex` `reads_siblings([:sandbox, :identity])`
   各变成 `ctx.read_slice.(key)` + 一条被授予的自读 cap。
3. 删 `reads_siblings/0` + `reads_sibling_slices/0`（宏、callback、`behavior/introspection.ex`
   里的合并、runtime surfacing）+ `get_slice(self)`-avoidance。
4. `mix ezagent.check_invariants` / `arch.scan` 按删掉的机制更新。

## 4. 范围守卫

- **只读。** cap 门控的进程内*写*（对自己 slice 的 effect）是单独后续 —— 不在 #56。
- **无死锁机制。** 明确排除 option-D 和 runtime 对打的部分（按 #56 任务说明）。#56 只是
  纯 gate + 访问器 + 迁移。

## 5. 完成判据（gate）

证明读真被 cap 检查的测试（按 `feedback_completion_requires_invariant_test`）。按 codex review，
不只是缺 cap 的拒/允许对——完整集：
1. **拒（负向）：** 自读 cap 缺失的 Kind 从 `ctx.read_slice.(key)` 得 `{:error, :unauthorized}`。
2. **允许（正向对照）：** cap 在则返回 `{:ok, slice}`。
3. **撤销：** 授予 → 读成功 → **撤销自读 cap** → 同一读现在 `:unauthorized`。证明 cap 每次调用
   都实时检查、不是解析一次（这正是 `reads_siblings` 结构上做不到的）。
4. **谁的权威：** 进程内自读基于 **Kind 自己** caps 成功/拒绝，且**不受**入站 caller `ctx.caps`
   影响（特权 caller 不能启用、非特权 caller 不能禁用 Kind 自读）。锁定 §2.5。
5. **闭包对等：** admin/系统成员 Kind 的自读经与跨进程派发相同的 `cross_workspace?` 闭包通过（§2.5）。
6. **回归：** 3 个迁移后的 consumer 用被授予的 cap 仍正常工作。

## 6. 排序

- 现在：本 spec → **codex adversarial-review**（已做）→ Allen 决策。
- 实现：基座化 PR-9c 之后。`matches?`/`Kind.Runtime` 在 `core`；3 个 consumer 里 2 个在刚改名的
  session/external_mirror/identity 域，故 9c 后起、低 churn。

## 7. 给 codex/Allen 的开放问题

- `:read` 是对的 action atom，还是每个 slice 声明自己的读 action（更细）？`:read` 最简；per-slice
  读 action 更精确但更多 cap 行。推荐：先用 `:read`。

## 8. 交叉引用

- 分析：`2026-06-14-cap-in-process-op-analysis.md`。
- `Ezagent.Capability` / `Ezagent.Capability.Match` —— 复用的 gate。
- `Ezagent.Kind.BehaviorSet` —— `owning_behavior_of(slice_key)` 解析。
- `Ezagent.Behavior` / `Ezagent.Lifecycle` —— 要删的 `reads_siblings`。
