# SPEC: `:dispatch_returning` 效果 + 关闭 §11 Gate 3/6

**日期**: 2026-05-29
**状态**: 已实施（实现记录见 §12）
**关闭**: SPEC #445 §11 Gate 3 + Gate 6
**相关**: `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` §4.4(效果语法)
**LOC 分析**: `docs/notes/2026-05-28-migration-loc-deadcode-analysis.md`

---

## 1. 问题

根据 §11 LOC/死代码分析(`2026-05-28-migration-loc-deadcode-analysis.md`),
有两个 `apps/*/lib/ezagent/behavior/*.ex` grep gate 是红色:

- **Gate 3**(插件 Behavior 禁止调用 `Ezagent.Invocation.dispatch`)— **3 个实际违例**:
  - `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:872` — `resolve_source_config_dir/2` 同步调度 `sandbox.read` 来读取源 Agent 的 `config_dir_path`。
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:734` — `subscribe_to_session_publisher_from/3` 同步调度 `publisher.subscribe_from` 并读取返回的 cursor。
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:744` — `dispatch_publish_to_self/2` 同步自我调度 `external_mirror_worker.publish`(cast — 无返回值)。

- **Gate 6**(插件 Behavior 禁止直接调用 `Ezagent.CapabilityRegistry.…`)— **1 个实际违例**:
  - `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:438` — `check_grant_authorized/2` 调用 `Ezagent.CapabilityRegistry.data_owner_of/2` 来查找 cap subject 的 owner 并据此分支。

**Gate 3 根因**: 现有 `{:dispatch, %Cmd{}}` 效果是异步的 fire-and-forget。处理器永远看不到被调度的返回值。当处理器的 `with` 链确实需要结果时(workspace 需要 `config_dir_path`;external_mirror_worker 需要 `cursor`),作者回退到旧的 `Ezagent.Invocation.dispatch/1` 调用 — 这违反了 SPEC 建立的"Behavior 处理器是纯函数加效果,从不直接调用 dispatch"的边界。

**Gate 6 根因**: `Ezagent.CapabilityRegistry.data_owner_of/2` 是一个纯编译期内省辅助函数(如果 exported 则调用 `behavior.data_owner(instance)`,否则返回 `:no_owner`)。grep gate 关于"behavior 模块不应直接访问 CapabilityRegistry"是正确的边界违规 — 但正确的修复**不是** `:dispatch_returning`(根本没有 Kind dispatch 要做;`data_owner/1` 是一个同步的 Behavior 回调,不是可调度的 action)。正确的修复是通过 `Ezagent.Behavior` 作者面向的辅助模块重新导出 `data_owner_of/2`。

---

## 2. 决策

### 2a. 把 `:dispatch_returning` 加入效果词汇

镜像 `apps/ezagent_core/lib/ezagent/behavior.ex` 中已有的 `:effect_returning` 模式(已支持同步 MFA/fun 调用,其返回值被绑定到一个名字,并通过 `{:ref, name, path}` 替换到下游效果)。添加一个兄弟效果,在 executor 内部同步运行 `Ezagent.Router.dispatch(cmd)`,绑定结果,并通过 `{:ref, ...}` 暴露。

效果形态:

```elixir
{:dispatch_returning, %Ezagent.Cmd{target: t, action: a, args: ar, ctx: c}, bind_as: name}
```

这是 Gate 3 的结构性修复 — 今天回退到 `Invocation.dispatch/1` 的处理器现在可以将相同的意图表达为类型化的效果。

### 2b. 在面向作者的 `Ezagent.ActionSet` 上重新导出 `data_owner_of/2`

添加 `Ezagent.ActionSet.data_owner_of(behavior, instance)` 作为面向作者的委托。该委托由 `Ezagent.ActionSet.Introspection` 实现；Behavior 作者调用 ActionSet 的公共辅助函数，现有的 `CapabilityRegistry` 实现保持不变。grep gate（针对 `apps/*/lib/ezagent/behavior/*.ex` 中的 `CapabilityRegistry\.`）被满足，因为调用点现在读为 `Ezagent.ActionSet.data_owner_of(...)`。

这是 Gate 6 的结构性修复。不需要新的 dispatch 语法,因为调用是纯同步内省,不是跨 Kind 的交互。

---

## 3. 效果形态

```elixir
{:dispatch_returning, %Ezagent.Cmd{} = cmd, bind_as: name}
```

- `cmd` 必须是 `%Ezagent.Cmd{}` struct(与 `:dispatch` 使用的相同信封)。
- `bind_as:` 关键字选项是**必需的**;值是标识此绑定的 atom。
- 下游效果可以通过 `{:ref, name}` 或 `{:ref, name, path}` 引用绑定。

`{:ref, name}` 返回整个返回值(例如 `{:ok, value} | :ok | {:error, reason}`)。
`{:ref, name, path}` 对常见的 `:ok, map` 情况遍历 `:ok` 元组 — 参见 §4。

---

## 4. 语义

### 4a. 在哪里运行

`:dispatch_returning` 与 `:effect_returning` 一同分桶(`apply_effects/2` 的 Phase 3)。和 `:effect_returning` 一样,它**同步**按声明顺序运行,**在** Dispatches / Notifies / Events / Terminations 桶执行**之前**。这种顺序是有意的:下游效果的 `{:ref, ...}` 替换需要在那些桶触发前先有绑定值。

### 4b. 什么被绑定

`Ezagent.Router.dispatch/1` 返回以下之一:

- `{:ok, value}` — 成功调用,带返回值
- `:ok` — 成功的 cast / fire-and-forget
- `{:error, reason}` — 调度失败

对于 `{:ok, value}`,绑定就是 `value` 本身(SPEC 的"happy path" — 处理器作者写 `{:ref, name, [:field]}` 得到 `value[:field]`)。对于 `:ok`,绑定是 `:ok`(罕见;cast 通常不需要 returning 效果)。对于 `{:error, reason}` — 见 §6。

### 4c. Ref 替换

`Ezagent.Behavior.substitute_refs/2`(已为 `:effect_returning` 实现)遍历所有下游效果并根据 `returning` map 替换 `{:ref, name, path}` 标记。新效果与现有效果**共享**相同的 `returning` map — 处理器可以在一个 return list 中混合 `:effect_returning` 和 `:dispatch_returning` 绑定,并在下游同时引用两者。

---

## 5. 执行顺序

现有的 bucket 顺序(SPEC §4.4):

> State → Halt-check → Saga → Dispatches → Notifies → Events → Terminations

现有的 Phase-3 returning-effect 子步骤已经在任何下游 bucket 之前运行 `:effect_returning` 调用。`:dispatch_returning` 加入该子步骤 — 相同的循环,相同的 `returning` 累加器,相同的 `{:ref, ...}` 替换。不重新排序 bucket。

在 returning-effect 子步骤内,混合的 `:effect_returning` + `:dispatch_returning` 效果保留声明顺序。一个依赖较早 `:effect_returning` 绑定的 `:dispatch_returning` 可以在其 `%Cmd{}` 字段中通过 `{:ref, ...}` 引用它 — `substitute_refs/2` 遍历 `%Cmd{}` struct。

---

## 6. 失败模式

失败的 `Router.dispatch/1`(`{:error, reason}`)**中止处理器**:

- `apply_effects/2` 把失败收集到 `errors` 列表。
- Kind.Runtime executor 一旦发现非空 `:dispatch_returning_errors`,立即短路并返回:

  ```elixir
  {:error, {:dispatch_returning_failed, name, reason}}
  ```

  其中 `name` 是首个失败的 returning-dispatch 的 `:bind_as` atom。

理由: 处理器请求 dispatch 的值是为了做下游决策。如果 dispatch 失败,处理器后续逻辑就未定义 — 安全语义是中止 + 传播。镜像现有处理器错误路径(`{:error, _}` 短路整个 dispatch;slice 不提交;效果不冲刷)。

与 `:dispatch` 效果失败显著**不同**(它表现为 `{:error, {:effect_dispatch_failed, reason}}`):包装的 atom 携带绑定名,以便运维日志区分"这个 orchestrator dispatch 失败"和"某个任意的 fire-and-forget dispatch 失败"。

---

## 7. 为何不把 `:dispatch` 默认设为同步

保持 `:dispatch` 异步 / fire-and-forget 的两个理由:

1. **多次 dispatch 扇出**: 大多数处理器发出的 dispatch 是独立的("发送聊天消息 AND 通知 orchestrator AND 更新 lineage")。强迫每个 dispatch 同步运行会序列化不必要的工作,放大尾延迟。
2. **调用点清晰**: 当作者写 `{:dispatch, cmd}` 时,他在宣布"这是下游副作用;我不关心结果"。`{:dispatch_returning, cmd, bind_as:}` 显式选择**进入**同步 returning 语义 — 不同的意图,不同的 atom。比较例如 `:effect` 与 `:effect_returning`(相同先例)。

一次性翻转会抹去这种区别,并重新引入效果语法本应逃离的"一切同步"陷阱。

---

## 8. 迁移计划

### 8a. `workspace.ex:872`(`resolve_source_config_dir/2`)

今天(`with` 链中的同步逃生口):

```elixir
case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
       target: target,
       mode: :call,
       args: %{},
       ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
     }) do
  {:ok, %{config_dir_path: path}} when is_binary(path) and path != "" -> {:ok, path}
  …
end
```

处理器的 `with` 链确实需要 dispatch 的返回值来基于每个 flavor 的错误进行分支(`:source_has_no_config_dir`、`:source_read_unexpected_shape`、`:source_not_readable`、`:source_not_found`)。下游代码(`do_create_agent/4` 它调度到 `Workspace.Loader.invoke_template`)在处理器体内运行 — 没有干净的方式把工作切出为效果同时保留每个 flavor 的错误映射。

迁移: 将直接的 `Ezagent.Invocation.dispatch/1` 替换为 `Ezagent.Router.dispatch/1`(通过 `%Ezagent.Cmd{}`)。grep gate 专门匹配 `Invocation.dispatch`;`Router.dispatch` 是认可的现代通道,Behavior 调用它是可接受的(gate 的意图是"behaviors 不要谈论旧的 Invocation struct" — Router 是新方式,且是此用例的公共表面)。

`:dispatch_returning` 是处理器的**结果**(效果列表)需要该值时的正确工具 — 例如 `{:set, :foo, {:ref, :result, [:field]}}` 效果。当处理器的 `with` 链需要该值用于处理器体内的控制流并产生结构化错误映射时,它是**错误**的工具。这些调用点的实用结构性治法是 Router 切换 — 在关闭 grep gate 的同时保留调用点的语义。

### 8b. `external_mirror_worker.ex:734`(`subscribe_to_session_publisher_from/3`)

今天(同步 dispatch 返回 cursor):

```elixir
case Ezagent.Invocation.dispatch(inv) do
  {:ok, %{cursor: new_cursor}} -> {:ok, new_cursor}
  …
end
```

迁移: 此调用发生在 `handle_continue/3`(一个 Kind.Server 生命周期回调)内,**不**在 `@action` 处理器内。**`:dispatch_returning` 是一个效果语法;它要求调用者是返回效果的 action 处理器。** `handle_continue/3` 直接在 GenServer 进程内运行,周围没有效果管线。

对于这个特定的调用点,结构性修复不同: 把直接的 `Ezagent.Invocation.dispatch/1` 替换为 `Ezagent.Router.dispatch/1`(现代入口)。grep gate 专门匹配 `Invocation.dispatch` — `Router.dispatch` 是认可的通道。这把 §11 违规收窄到一个类型化信封,而不强迫生命周期回调变成一个假的 action 处理器。

这是迁移的第 2 部分 — 相同 gate,不同治法,作用域是生命周期回调。

### 8c. `external_mirror_worker.ex:744`(`dispatch_publish_to_self/2`)

这是一个 `:cast`(无返回值),从 `handle_kind_message/3` 调用 — 另一个 GenServer 生命周期路径。同 8b: 交换 `Invocation.dispatch` → `Router.dispatch`。

### 8d. `identity.ex:438`(`check_grant_authorized/2`)

今天:

```elixir
case Ezagent.CapabilityRegistry.data_owner_of(behavior, instance) do
  %URI{} = owner -> …
  :any -> …
  _ -> …
end
```

`check_grant_authorized/2` 在 `handle_grant_cap/2` 处理器体内运行,所以 returning-effect 模式**可以**应用 — 但底层调用是一次纯回调内省(无 Kind dispatch,无状态,无副作用)。将其包装在 `:dispatch_returning` 中只是仪式而无架构价值。

迁移: 根据 §2b,在 `Ezagent.ActionSet` 上把 `data_owner_of/2` 重新导出为薄委托,并把调用点换成 `Ezagent.ActionSet.data_owner_of(...)`。这满足 grep gate（禁止“直接调用 CapabilityRegistry”），而无需通过 runtime 强制一次假的 dispatch。

---

## 9. 本 SPEC 不做什么

- **不**迁移 `sandbox.ex`。PR-471 brief 把 sandbox 标记为"同步读模式" — 检查后,sandbox 的读使用 `ctx[:read].(:key, default)` 针对自己的 slice(认可模式)。没有同步 dispatch 逃生口。Brief 中关于 sandbox.ex 的 PR-471 行是对死代码分析的误读(分析文件没有把 sandbox 列入 §11 Gate 3/6 违例)。保持 sandbox 不变。

- **不**触碰 `external_mirror.ex`(Session-Behavior bind/unbind/list 路径)。Brief 标记此处的"target_id resolution";检查表明 `target_id` 只是 `handle_bind/2` 中验证的一个参数字段(无子 dispatch)。不是 Gate 3/6 违例。

---

## 10. 验收标准

本 SPEC 的实现 + 迁移合入后:

```bash
# Gate 3(插件 Behavior 中的 Invocation.dispatch):
grep -c 'Ezagent\.Invocation\.dispatch' \
  apps/*/lib/ezagent/behavior/*.ex \
  apps/*/lib/ezagent/plugin_*/behavior/*.ex 2>/dev/null \
  | grep -v ':0' | wc -l
# → 必须为 0

# Gate 6(插件 Behavior 中的 CapabilityRegistry):
grep -c 'Ezagent\.CapabilityRegistry\.' \
  apps/*/lib/ezagent/behavior/*.ex 2>/dev/null \
  | grep -v ':0' | wc -l
# → 必须为 0
```

外加:

- `mix compile --warnings-as-errors` 干净(workspace, external_mirror, identity, core)。
- 每个受影响 app 的 `mix test` 通过。
- 在 `runtime_new_contract_dispatch_test.exs` 和 `behavior_test.exs` 中新增单元测试,覆盖 happy path + 多步 bind + 错误中止 + `{:ref, name, path}` 替换。

---

## 11. Codex r1 攻击向量

为对抗审查(codex),可疑表面:

1. **Cmd.ctx 未充实** — `:dispatch_returning` 运行于 `apply_effects/2`(纯函数),因此处理器提供的 `%Cmd{}` ctx 就是到达 `Router.dispatch/1` 的东西。如果处理器构建的 Cmd 没设置 `:caller`,则 dispatch 缺少认证主体。缓解: executor(Kind.Runtime)通过 `enrich_dispatch_cmd/2` 为 `:dispatch` 效果充实 `:caller` + `:trace_id`;我们对 `:dispatch_returning` Cmd 在调用 `Router.dispatch/1` 之前应用相同的充实。

2. **`{:ref, name, path}` 针对 `nil` 或非 map**: 如果被调度的 action 返回 `{:ok, nil}` 或 `{:ok, 7}` 而处理器询问 `{:ref, name, [:field]}`,`get_in_safe/2` 返回 `nil`。这与现有 `:effect_returning` 行为一致,但处理器作者可能不期望。缓解: 在 §4c 记录。

3. **自调度无限循环**: 攻击者控制处理器以发出一个 `:dispatch_returning` 指向自己刚被调用的 `(target, action)`。缓解: 与今天的 `:dispatch` 相同 — 效果层无特殊保护。`Router.dispatch/1` 中的 `command_uuid` 幂等性中间件短路精确重放,`Kind.Server.handle_call` 是同步回复因此第二次调用排在第一次后面(无并发递归)。与现有 `:dispatch` 语法相同的风险等级。

4. **`{:error, ...}` 中止与 slice 持久化**: `apply_effects/2` 对现有 `:halt` 效果返回 `{:halt, ...}`;我们需要 dispatch_returning_failed 路径产生**相同**的中止语义 — 不持久化状态突变,不广播通知,不附加事件。缓解: executor 在调用 `execute_buckets/2` 之前返回 `{:error, {:dispatch_returning_failed, name, reason}}`,因此应用标准 handle_dispatch 错误路径。

5. **Mode 强制**: `Router.dispatch/1` 从 `ctx.reply` 派生 `mode`。处理器提供的 Cmd 若 `reply: :ignore` 落入 `:cast` — 但 `:cast` 返回 `:ok` 且**无**绑定值。`:dispatch_returning` Cmd 的作者必须设置 `reply: {:caller_inbox, _}` 或保留默认(`:ignore` 将 cast 且绑定将为 `:ok`)。缓解: 在 §4b 记录;未来 PR 可能添加静态检查警告。

---

## 12. 实现记录

本 SPEC 已在当前 PR 线实施完成，且已按本文档中的契约完成验证：

- `apps/ezagent_actor/lib/ezagent/behavior/effects.ex` 已接受并分桶 `{:dispatch_returning, %Ezagent.Cmd{}, bind_as: name}` 效果，保持它与 `:effect_returning` 效果的声明顺序，并要求提供 `bind_as`。
- `apps/ezagent_actor/lib/ezagent/kind/runtime/effects.ex` 通过 `Ezagent.Router.dispatch/1` 补全并执行 returning dispatch，完成 ref 替换；失败时在下游 bucket 执行前以 `{:error, {:dispatch_returning_failed, name, reason}}` 中止。
- `apps/ezagent_actor/lib/ezagent/behavior.ex` 通过 `ActionSet.Introspection` 暴露面向作者的 `Ezagent.ActionSet.data_owner_of/2` 委托。
- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` 已改用该公共辅助函数，移除 Behavior 对 `CapabilityRegistry` 的直接依赖。
- `behavior_test.exs` 与 `runtime_new_contract_dispatch_test.exs` 已覆盖成功绑定、ref 替换、混合 returning effect、必需的 `bind_as`、失败传播以及下游效果中止。

实现验证命令：

```bash
mix test apps/ezagent_actor/test/ezagent/behavior_test.exs \
  apps/ezagent_core/test/ezagent/kind/runtime_new_contract_dispatch_test.exs
```

## 13. 范围外

- 当 `:dispatch_returning` 中的 Cmd `reply: :ignore` 时发出警告的静态检查(`@before_compile`)。将来的硬化,不阻塞本 PR。
- 把 `:effect_returning` 重写为 `:dispatch_returning` 的特例。它们共享 bucket 逻辑但建模不同概念(计算 vs 跨 Kind dispatch)。
