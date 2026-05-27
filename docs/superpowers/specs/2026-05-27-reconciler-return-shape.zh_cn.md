# SPEC — Reconciler `:partial` vs `:ok` 返回形态漂移（Bug 3）

**状态：** r2 — 草稿，已应用 codex 评审后的订正。2026-05-27。

**r2 改动**（基于 codex NEEDS-ATTENTION 评审 r1 的反馈）：
- §1.3 新增 — 真正根因是**测试 helper URI 派生 bug**，不是生产代码 regression。PR #422 观察到的 `{:ok, _}` 是真实的，但是经 `:not_live → spawn_orchestrator_via_template_content → {:ok, _, _}` 路径产生，不是 `:partial → :ok` collapse。
- §4.2 重写 — 测试改动不是 "none"；impl PR 必须修 `derive_orch_uri_for_test/1` 中硬编码的 `ws_name = "default"`，让它用 `@workspace_uri.host`。
- §5 invariant 重写 — 用对 `Session.ensure_orchestrator_with_meta/3` 的行为测试替换脆弱的 `Code.Typespec` 反射测试。
- §9 补充 — `docs/notes/evidence/pr49-demo-rpc-script.sh` 44+69 行也 pattern-match `{:ok, _}`（pinned artifact 提示）。
- §10 OQ-1 由 codex 调查解决。

**关联：** PR #422 batch 修复了 umbrella 范围内的过时断言，但标记了 3
个需要 **单独 SPEC** 的 bug。本文档是其中 **Bug 3**。

**范围：** 窄。一个集成测试中的一条断言；SPEC 主要在 **重新确认** 现
有的、已 ratified 的三臂返回形态，并定位失败的根因是**测试 fixture**
中的 URI 派生 mismatch，不是生产代码 regression。

---

## §1 问题陈述

### 1.1 失败的断言

`apps/ezagent_domain_chat/test/integration/reconciler_test.exs:523`：

```elixir
test "ownership-pending retry exhaustion → :partial (NOT :error)" do
  # …… 预先 spawn orch_uri 为 "limbo" 进程，不记录 lineage，
  # 也不绑定 workspace，所以 `check_orchestrator/3` 会持续返回
  # `{:ownership_pending, _}` ……
  result = Session.spawn_from_template(st, owner)

  assert match?({:partial, _}, result), ...
end
```

PR #422 的描述说测试失败时返回的是 `{:ok, ...}`，而期望是 `{:partial, _}`，
并提出问题：

> "要么 SPEC 改了（测试应该更新），要么生产侧回归了（应该恢复
> exhaustion 路径的 `:partial`）。翻转断言前需要 SPEC 校验。"

### 1.2 为什么这很关键（更大的契约）

`Ezagent.Entity.Session.spawn_from_template/2` 是 SPEC
[`docs/superpowers/specs/2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
定义的 **Generator-Reconciler**。其返回形态是 **三臂标签元组**，由
SPEC §1.2 ratify，并经 codex 对抗性评审后由 §7-2 再次确认。每个臂语义
不同、且都是 load-bearing：

- `{:ok, %{...}}` — 完全收敛。
- `{:partial, %{...}}` — 可完成的失败；调用方 **可以** 重试。
- `{:error, _}` — 预检拒绝，**没有创建 Session**。

把 `:partial` 折叠进 `:ok` 会破坏调用方的判别能力 —— 无法区分
"session 活着但 orchestrator 还在 pending" 和 "session 已完全就绪"。
而这两者今天就被 LiveView 的 session 面板和
`EzagentDomainChat.create_session/3` 门面 **分别 pattern-match**。

### 1.3 实际根因 — 测试 helper URI 派生 mismatch（codex r1 发现）

PR #422 作者的经验观察（"production returns `{:ok, _}`"）**是真的，但
根因是测试 bug，不是生产 regression**。逐步追踪当前代码：

1. **测试 fixture 设置**：
   - `reconciler_test.exs:119` — SessionTemplate 的
     `default_workspace_uri: URI.parse("workspace://team-alpha")`
   - `reconciler_test.exs:146` —
     `@workspace_uri URI.new!("workspace://team-alpha")`（模块级常量）

2. **生产代码的 URI 派生**：
   - `spawn_from_template/2` 用
     `entity://agent/<workspace_uri.host>/cc_orchestrator-<session_name>`
   - 对这个测试的 workspace 来说：
     **`entity://agent/team-alpha/cc_orchestrator-...`**

3. **测试 helper bug**：
   - `reconciler_test.exs:595-611` —
     `defp derive_orch_uri_for_test(%URI{} = session_uri)` 硬编码
     `ws_name = "default"`（第 597 行）—— 在 `default_workspace_uri`
     从 `"default"` 迁移到 `"team-alpha"`（PR #399 / PR #408 时代）
     之前留下来的。
   - 测试预先在 **`entity://agent/default/cc_orchestrator-...`**
     创建 "limbo" 进程。

4. **运行时实际发生**：
   - `check_orchestrator/3` 查找
     `entity://agent/team-alpha/cc_orchestrator-...`（生产派生）
   - 找不到对应 Kind（limbo 在 `default/` 下，不是 `team-alpha/`）
   - `check_orchestrator` 返回 `:not_live`，不是预期的
     `:ownership_pending`
   - `spawn_from_template/2` 走 `spawn_orchestrator_via_template_content/5`
     新生路径（PR #408 加的）
   - 该路径完成成功，返回
     `{:ok, %{session_uri: _, orchestrator_uri: _}}` ——
     **不是** `{:partial, _}`

所以生产代码里 `:partial` 通过 `retry_after_race/3` 耗尽路径**仍然
可达**；只是测试因为预 spawn 的 limbo 在错的 URI 前缀下，没有真正
exercise 这条路径。

**对 §4.2 的含义**：测试改动不是 "none"。impl PR 必须修
`derive_orch_uri_for_test/1`（或接受 workspace 参数，或调公开的
`Session.derive_orchestrator_uri/2` 如果有），让测试 helper 的 URI
前缀对齐测试 SessionTemplate 的 `default_workspace_uri`。

---

## §2 决策：**A — `:partial` 是 canonical 的；保留 / 恢复**

调研后：

1. **已 ratify 的 SPEC** [`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
   §1.2 + §7-2 在权衡过双臂 `:ok | :error` 替代方案后，**明确选择**
   了三臂形态，理由（§7-2，1167-1180 行）：

   > **推荐：三臂 `:ok / :partial / :error`**。代价是多一个返回形态；
   > 收益是消除"把 partial 默默当成 success"的整类 bug。

2. **失败站点的生产代码仍然返回 `:partial`**：通过
   `retry_after_race/3` →
   `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:984-986`：

   ```elixir
   defp do_retry(%URI{} = uri, _owner_uri, _workspace_uri, 0) do
     {:partial, %{orchestrator_pending: uri}}
   end
   ```

   `reconcile_loop/4`（362-369 行）把上面的结果传给
   `partial_report/1`（1921 行）→ 返回 `{:partial,
   %{session_uri, orchestrator_uri, completed, pending, errors}}`。

3. **多个生产调用方都 pattern-match `:partial`**（详见 §3.3）：
   - `EzagentDomainChat.create_session/3` 的 `ensure_orchestrator_meta/3`
     门面 — `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:350`
     把 `{:partial, _}` 映射为 `orchestrator_status: :pending`。
   - `Ezagent.Orchestrator.MCPServer.to_mcp_result/2` —
     `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_server.ex:548`
     在 MCP tool 输出中专门渲染 `:partial`。
   - `EzagentPluginLiveview.AdminDashboardLive.cc_seed_badge/1` —
     `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_dashboard_live.ex:233`。
   - `Ezagent.Orchestrator.Tools`（spawn / update_agent_template /
     remove 流）— 自有三臂协议，与此契约一致。

4. **测试的 `@moduledoc`（15-22 行）明确把 `:partial` 列为 PR-A 烘焙
   的 3 个 codex 残余修复之一**：

   > 1. retry_after_race REAL implementation + tests
   >    (exhaustion → :partial; same-owner concurrent never returns
   >    :orchestrator_foreign).

   测试 docstring 在 528 行明确写："`retry_after_race must EXHAUST
   and return `{:partial, _}`, NOT `{:error, _}`" — 这是从 PR-A
   带过来的、有意为之的、已 ratify 的文本，不是过时漂移。

**因此：** 契约 **没有** 改。`:partial` 仍然是 ratified 形态。测试正
确地断言了 SPEC。如果生产真的在测试场景下返回 `{:ok, _}`，那是 **回
归**，由实现阶段定位，而不是 SPEC 变更。

### 2.1 对结论的置信度

**高**（SPEC 问题）：SPEC 表述无歧义；生产代码结构仍然带 `:partial`
路径；多个生产调用方都在分支它。

**中**（"生产返回 `:ok`" 的实证主张）：本 SPEC 仅在
`/private/tmp/esr-spec-bug3-reconciler` 工作树做静态分析（范围规则
不允许 `mix deps.get`）。PR #422 作者的 "生产返回 `{:ok, ...}`" 主
张从代码阅读无法复现 —— 可见代码路径是 `check_orchestrator →
:ownership_pending → retry_after_race → :partial`。实现阶段
**必须**：

1. 在已经 `mix deps.get` 的工作树中复现失败。
2. 定位实际返回 `{:ok, _}` 的路径。
3. 在回归站点修复，或者确认测试因 **其他** 原因失败（例如
   567-570 行那一组关于 `partial.pending` 内容的同级断言），而
   PR #422 的 "返回 `{:ok, _}`" 描述是近似的、不精确的。

§10 把这个作为 OQ 留给 Allen。

### 2.2 为什么不选 B（删 `:partial`）

决策 B 意味着："生产统一在 `:ok`；测试更新；SPEC 移除 `:partial`。"

错误方向，因为：

1. **多个生产调用方今天就在分支 `:partial`**。移除需要触 4+ 个调用
   站 + 改动用户可见的 UX（LV 的 "pending" 徽章需要换一个数据源）。
   改动成本高，收益为零。

2. **SPEC 明确考虑并 REJECTED 了双臂替代方案**（§7-2）。反转那个
   决策需要原 SPEC 没看到的新证据 —— 没有。

3. **`EzagentDomainChat.create_session/3` 的 meta map**（对外可见
   的 `:orchestrator_status` 字段）有三个值：`:ready | :pending |
   :failed`。把 reconciler 的 `:partial` 删掉就切断了 `:pending`
   的数据源 —— 每一条 `:partial` 路径都是这个门面 `:pending` 的
   来源。

### 2.3 为什么不选 C（信息不足）

决策 C 意味着："SPEC 有歧义；问 Allen。"

错误方向，因为：

1. **SPEC 没歧义**。§1.2 + §7-2 + `spawn_from_template/2` 的
   @spec 本身全部对齐。

2. **bug 报告的措辞是不对称的**。原文是 "test should update OR
   production should restore"。选 "production should restore" 已经
   回答了 SPEC 问题 —— SPEC ratify 这个答案。

§10 留给 Allen 的只是回归位置的剩余问题（见 §2.1），**不是** "要不
要保留 `:partial`"。

---

## §3 语义 — 每个返回形态的含义

本节从 [`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
的 §1.2 拷贝并收紧，因为测试 docstring 528 行直接调用 "`:partial` not
`:error`" —— load-bearing 的对比是 `:partial` vs `:error`，不是
`:partial` vs `:ok`。

### 3.1 三个形态（@spec 原文）

```elixir
@spec spawn_from_template(URI.t(), URI.t()) ::
        {:ok,
         %{
           session_uri: URI.t(),
           orchestrator_uri: URI.t(),
           slots: [{String.t(), URI.t()}]
         }}
        | {:partial,
           %{
             session_uri: URI.t() | nil,
             orchestrator_uri: URI.t() | nil,
             completed: [atom()],
             pending: [atom()],
             errors: [{atom(), term()}]
           }}
        | {:error, term()}
```

### 3.2 各自何时触发（语义）

- **`{:ok, %{session_uri, orchestrator_uri, slots}}`** — 完全收敛。
  所有 slot 收敛 + orchestrator owned-by-us + 路由规则装好 + owner
  caps grant 好。**`orchestrator_uri` 已填充且 owned**。

- **`{:partial, %{...}}`** — 本次 pass 至少一步没收敛，但失败是
  **可完成的**（再用相同 `(template, owner)` 调用一次能收敛）。
  map 的 `pending` 字段枚举未收敛的步（`:orchestrator`、
  `:slot, "<name>"`、`:rule`，……）；`errors` 携带每步诊断。关键
  子例：
  - `pending: [:orchestrator]` + `errors: [{:orchestrator,
    {:orchestrator_ownership_pending, candidate_uri, ev}}]` ——
    `retry_after_race/3` exhaustion 路径。外层 map 的
    `orchestrator_uri` 为 `nil`（因为我们拒绝认领 limbo URI），但
    `errors` 条目把 candidate URI 暴露出来供 operator 排查。
  - `pending: [{:slot, "name"}]` — 某个 slot 的 AgentTemplate Kind
    还没起来（plugin 没 boot）。

- **`{:error, reason}`** — 预检拒绝，**没有创建 Session**。
  `2026-05-23-generator-reconciler.md` §1.2 枚举了 reason：
  `:unauthorized`、`:cross_workspace_denied`、
  `:session_template_not_populated`、`:invalid_routing_matcher`
  等。注意 **包含** `{:orchestrator_foreign, uri, evidence}` ——
  POSITIVE foreign evidence（lineage 或 workspace 正向不匹配），是
  数据损坏 / 跨租户冲突，不是可重跑的 race。

### 3.3 今天的调用方 pattern-matching（生产）

| 调用方 | 分支 `:partial`？ | 做什么 |
|---|---|---|
| `EzagentDomainChat.create_session/3`（经 `ensure_orchestrator_meta/3`） | 是 | 把 `{:partial, %{orchestrator_pending: uri}}` 映射为 `%{orchestrator_uri: uri, orchestrator_status: :pending}`（350-355 行） |
| `Ezagent.Orchestrator.MCPServer.to_mcp_result/2` | 是 | 把 `:partial` 渲染为独立的 MCP result 变体（548 行） |
| `EzagentPluginLiveview.AdminDashboardLive.cc_seed_badge/1` | 是 | 渲染 "partial" 徽章（233 行） |
| `Ezagent.Orchestrator.Tools` | 是（自有三臂协议） | spawn / update_agent_template / remove 各自分发 `:partial` 形态 |
| Reconciler 集成测试（`reconciler_test.exs`） | 是 | 多条断言（523、561-570 等） |

净结论：**`:partial` 是 load-bearing 的**。移除需要在 4+ 个生产站做
breaking change。SPEC 确认保留。

---

## §4 迁移方案

### 4.1 生产代码

**SPEC 层面没有改动**。SPEC 再次确认既有契约。

**实现阶段（下一个 PR）**：

1. 在已经 `mix deps.get` 的工作树中复现测试失败。
2. 定位测试场景下返回 `{:ok, _}` 而非 `{:partial, _}` 的路径（或
   确认 PR #422 的描述近似、测试因别的原因失败 —— 见 §2.1）。
3. 在回归站点针对性修复。优先排查：
   - `check_orchestrator/3`（session.ex:1007）—— 确认 lineage 和
     workspace 都是 `:absent`（而非一个 absent + 一个 match）时
     才走 `:ownership_pending` 分支。
   - `retry_after_race/3`（session.ex:980）—— 确认 3 次重试 exhaust
     走到 985 行 `{:partial, _}`，没有因测试 interleaving 被早期的
     `{:owned, _}` 短路。
   - `reconcile_loop/4`（session.ex:330）—— 确认 362 行
     `{:partial, %{orchestrator_pending: candidate_uri} = ev}` 子句
     成功 pattern-match，并调用 363 行的 `partial_report/1`。
   - PR #408 新增的 `spawn_orchestrator_via_template_content/5` 路
     径 —— 确认 URI 已经活着时不会误路由（即 limbo 进程预 spawn 时，
     `check_orchestrator` 应该分类为 `:ownership_pending`，**不是**
     `:not_live`）。

### 4.2 测试

**一处必修的测试 helper 修复**（基于 §1.3 根因分析）：

`apps/ezagent_domain_chat/test/integration/reconciler_test.exs:595-611` —
`derive_orch_uri_for_test/1` 硬编码 `ws_name = "default"`，跟测试
SessionTemplate 的 `default_workspace_uri: "workspace://team-alpha"`
mismatch。预 spawn 的 limbo 进程落在错的 URI 前缀，生产
`check_orchestrator` 因此走新生路径返回 `{:ok, _}`，而不是测试设计
要 exercise 的 `:ownership_pending → retry_after_race → :partial` 路径。

**修法选项**（impl PR 选一）：

(a) **对齐 `@workspace_uri.host`**（最小 diff）：
```elixir
defp derive_orch_uri_for_test(%URI{} = session_uri) do
  ws_name = @workspace_uri.host  # 原本: "default"
  session_name = ...              # 不变
  URI.new!("entity://agent/#{ws_name}/cc_orchestrator-#{session_name}")
end
```

(b) **接受 workspace 作参数**（更可复用，方便未来跨 workspace 测试）。

(c) **把 `Session.derive_orchestrator_uri/2` 提为 public**，让测试直接
调，避免两套派生逻辑再次漂移。代价是 Session 模块 API 面多一个公开函数。

**推荐：(a)** 给 impl PR。同时记一个 follow-up TODO 关于 (c)，下次有
新测试要派生 orch URI 时就不会重复实现。

修完之后，523 行的测试就能按原设计 exercise
`:ownership_pending → retry → :partial` 路径，应该不需要生产代码改动
即可通过。

**测试隔离备注**：模块是 `async: false`，chat domain
`test_helper.exs` 无条件启动 `:ezagent_plugin_echo`；没有
`@tag`/`@moduletag` mask（codex r1 已 audit 确认）。任何 chat 集成
umbrella run 都会触达这条断言。

### 4.3 调用方

**不改**。所有调用方已经在正确分支 `:partial`。

### 4.4 文档

- 从
  [`2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
  的 "Status" 头部交叉链接到本 SPEC，方便未来读者看到再次确认。
- 更新 `docs/futures/todo.md`，加入实现 PR 占位 + 回链到本 SPEC。

---

## §5 不变量测试（漂移守卫）

按项目备忘 `feedback_completion_requires_invariant_test`，每次多
PR 改动都需要一个 **不变量测试**，能在架构目标失败时挂掉 —— 不只是
症状。

**不变量：** *reconciler 返回形态是三臂 `{:ok, _} | {:partial, _} |
{:error, _}` 元组，且 `:partial` 可从 `retry_after_race` exhaustion
路径触达。*

**测试**（加到
`apps/ezagent_domain_chat/test/integration/reconciler_test.exs` 或
兄弟文件 `reconciler_shape_invariant_test.exs`）：

```elixir
describe "return-shape invariant (SPEC 2026-05-27-reconciler-return-shape)" do
  test "ensure_orchestrator_with_meta 对不可转的 limbo orch 表面化 :partial" do
    # 行为不变量：直接 exercise ensure_orchestrator_with_meta/3 路径，
    # 用一个 check_orchestrator 能分类为 :ownership_pending 的 limbo
    # orch URI。retry-exhaustion 路径必须返回
    # {:partial, %{orchestrator_pending: _}}，
    # 不是 {:ok, _} 也不是 {:error, _}。
    #
    # 比反射 @spec 强，因为能抓：
    #   - 未来重构在 retry 耗尽前加个 :ok 短路
    #   - 未来重构在 ensure_orchestrator_with_meta/3 边界把
    #     :partial 映射成 :ok（:partial 本来就是为了防这一类 bug）
    #   - 未来重构把 :partial 变成异常

    workspace_uri = URI.new!("workspace://team-alpha")
    owner = URI.new!("entity://user/team-alpha/alice")
    session_uri = URI.new!("session://default/team-alpha/test-#{System.unique_integer([:positive])}")
    orch_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

    # 预 spawn limbo（workspace 和 lineage 都 :absent，
    # check_orchestrator 返回 {:ownership_pending, _}）。
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(orch_uri)

    # 用 retries: 0 强制 retry 耗尽。
    result = Session.ensure_orchestrator_with_meta(session_uri, owner, retries: 0)

    assert match?({:partial, %{orchestrator_pending: ^orch_uri}}, result),
           "ensure_orchestrator_with_meta 必须在 ownership-pending exhaustion " <>
           "时返回 :partial；折成 :ok 会破坏 EzagentDomainChat.create_session/3 + " <>
           "LV 'Retry instantiation' 的分支。实得：#{inspect(result)}"
  end

  test "retry-exhaustion :partial 通过 spawn_from_template/2 表面化" do
    # 经过公共 Session.spawn_from_template/2 门面的端到端测试。
    # 镜像 line 523 的集成测试，但用正确的 workspace URI 前缀
    # （见 §4.2 — 历史 bug 是与 SessionTemplate 的 default_workspace_uri
    # 不匹配）。
    #
    # 作为快速回归守卫；集成测试保留更广覆盖。
  end
end
```

**这个不变量为什么比反射 @spec 强**（r1 设计）：

- `Code.Typespec.fetch_specs/1` 在测试环境下并不可靠地走通 `mix compile` 的 erlang 查找——反射测试在 Elixir 版本/beam-state 温度间脆弱
- 未来重构可能保留 `@spec` 声明（声明 `:partial`）却悄悄删除产 `:partial` 的生产路径——反射抓不到，行为测试能抓
- 按 `feedback_completion_requires_invariant_test`，gate 必须在 **架构目标** 不达时挂掉。这里的架构目标是"调用方能区分 pending 和 ready"，行为测试直接 exercise 这个边界

---

## §6 插件隔离分析

**N/A**。`Ezagent.Entity.Session` 是 infra 层 chat-domain 代码，不
是插件扩展点。reconciler 是 Generator —— cc-orchestrated session
的 authoritative 方，不委托给插件。

唯一与插件隔离相关的考虑：cc Template Class（`ezagent_plugin_cc`）
提供 orchestrator role-bootstrap；其 `role_degraded` flag 通过
`ensure_orchestrator_with_meta/3` 的 4-元组变体
（`{:ok, uri, outcome, %{role_degraded: true, …}}`）暴露。这与
`:partial` 臂 **正交** —— degraded role-bootstrap 是 `:ok` 带 meta，
不是 `:partial`。SPEC 变化不影响插件契约。

---

## §7 权衡 / 替代方案

### 7.1 替代：把 `:partial` 折成 `:ok` 加 flag

`{:ok, %{...status: :partial}}` 能不能替代 `{:partial, %{...}}`？

**拒绝**。`:ok` 里塞 flag 意味着每个调用方都得检查 flag 才知道是不
是真的 OK。Elixir 习惯的第三种结果暴露是 **第三个标签**，不是双臂
里塞 flag。原 SPEC §7-2 恰好作了这个论证：

> 三臂的优点：调用方可以 pattern-match 结果；"完全收敛了吗" 是 1
> 行 case。双臂的缺点：每个调用方必须检查 result map AND 记得
> pattern-match `:partial`，否则就把 partial 当 success。

### 7.2 替代：把 `:partial` 折成 `:error`

`{:error, {:partial, _}}` 能不能替代 `:partial` 标签？

**拒绝**。`:partial` 本质上 **不是** error —— session 活着、slot 收
敛了、operator 可以重试。把它打成 `:error` 会强迫每个调用方区分
`:error, :cross_workspace_denied`（不可完成）和 `:error, {:partial,
...}`（请重试我）。三臂的全部意义就是让这个区分变成结构性的。

### 7.3 替代：翻转测试

PR #422 的描述把这当作一个选项。拒绝，因为：

1. 测试就在断言 SPEC。翻转断言等于让 SPEC 在没有 SPEC 层决策的情
   况下悄悄改了。
2. 测试 docstring（524-528 行）是有意的、ratified 文本，从 PR-A 带
   过来。

---

## §8 与并行 SPEC 的交互

### 8.1 [2026-05-27-capability-action-axis](2026-05-27-capability-action-axis.md)

并行 landing。触 `%Capability{}` 形态，但 **不触**
`Session.spawn_from_template/2` 的返回形态。独立。

### 8.2 [2026-05-26-session-create-orchestrator-unified](2026-05-26-session-create-orchestrator-unified.md)

PR #408 已 landed。引入了 `ensure_orchestrator_with_meta/3` 的 4-
元组变体（`{:ok, uri, outcome, %{role_degraded: ...}}`）。新的 4-
元组形态与 `:partial` 正交，共存：

- 3-元组 `{:ok, _, _}` — orchestrator 就绪（角色未降级）。
- 4-元组 `{:ok, _, _, %{role_degraded: true, ...}}` — orchestrator
  活着但 skill-copy 失败（Invariant #9 表面化）。
- `{:partial, %{orchestrator_pending: _}}` — orchestrator URI 尚未
  分类（lineage+workspace 尚未记录）。
- `{:error, _}` — 拒绝或 POSITIVE foreign。

PR #408 完整 **保留** 了 `:partial` 臂。在 session.ex:843-845、877、
985 行确认。

### 8.3 Bug 1（Feishu binding policy）+ Bug 2（Wizard cap grant）

都与 Bug 3 独立。无跨 PR 耦合。

---

## §9 向后兼容

### 9.1 持久化状态

reconciler 返回形态 **不持久化**（是函数调用的运行时结果）。没有
JSON / SQLite / ETS schema 依赖标签。**不需要迁移**。

### 9.2 外部调用方

确认：Elixir 代码库 **之外** 没有 ops 脚本、CLI、web HTTP endpoint
pattern-match `:partial`。形态是纯内部 Elixir。

LV 的 "Retry instantiation" 按钮（按
`2026-05-23-generator-reconciler.md` §1.4）在最近一次结果是
`{:partial, _}` 时渲染 —— 那条分支在 Elixir 代码里，没外部表面。

**Pinned-artifact 备注**（codex r1 发现）：
`docs/notes/evidence/pr49-demo-rpc-script.sh` 44 + 69 行包含
pattern-match 断言：

```bash
{:ok, %{session_uri: s1, orchestrator_uri: orch1}} =
  Ezagent.Entity.Session.spawn_from_template(...)
```

这是 PR #49 验证用的一次性 demo 脚本，不是回归 gate。脚本的 `{:ok, _}`
match 是故意的——它记录的是"happy path" demo，不是 retry-exhaustion
case。**Action: 不需要改**——但在这里记下，让未来把脚本扩成回归 gate
的作者知道要加 `:partial` 臂。

### 9.3 Snapshot

这里没有 `%Capability{}` 类型的 snapshot 关切。reconciler outcome
不被 snapshot；每次 `spawn_from_template/2` 调用都重新计算。

---

## §10 留给 Allen 的开放问题

### OQ-1 — 核实 PR #422 的实证主张 ✅ 已解决（r2）

**解决（codex 调查，折进 §1.3）**：
PR #422 的 "返回 `{:ok, _}`" 观察是 **真的**。原因不是生产里 `:partial → :ok`
collapse，而是 **测试 helper URI 派生 mismatch**，把测试场景路由到
新生路径（`{:ok, _, _}`）而不是 retry-exhaustion 路径（`:partial`）。
impl fix 在 test helper，不在生产。详见 §1.3 + §4.2。

### OQ-2 — 确认决策 A

本 SPEC 推荐决策 A（保留 `:partial`）。SPEC 问题置信度高；实证回归
位置置信度中（§2.1）。

**确认 / 反对？**

---

## §11 Codex 对抗性评审问题

codex 应该对抗性追问：

1. **本 SPEC 真的必要吗？** 既有 SPEC 已经规定了 `:partial`。本 SPEC
   再次确认，没改东西。和直接在 `docs/notes/` 加一段交叉链接到既
   有 SPEC 比，单独立 SPEC 有什么价值？

2. **SPEC 作者漏了回归向量吗？** 静态阅读说生产仍然返回 `:partial`。
   PR #422 作者看到 `:ok`。差在哪？需要 probe 的可能回归向量：
   - PR #408 之后的
     `spawn_orchestrator_via_template_content/5` 路径，可能在 limbo
     URI 上成功 spawn（注册 lineage + workspace），早于
     retry_after_race 执行 —— 即预 spawn 的 URI 被绕过
     check_orchestrator 的 ownership_pending 分类直接 adopt。
   - `Ezagent.SpawnRegistry.spawn_detailed/1` 对 `:already_started`
     的处理可能变了，让预 spawn 的 URI 作为副作用注册
     lineage/workspace，导致 check_orchestrator 在重试时返回
     `:owned` → `{:ok, _, _}` → 全 ok。
   - 测试 helper 改了（例如 `register_inert_flavor` 现在不小心注册
     了一个会在 init 时记录 lineage 的 Template Class），改变了测试
     场景的语义。

3. **不变量测试（§5）是对的吗？** 反射 @spec AST 是脆的（Elixir
   typespec 解析）。有没有更强的结构性不变量 —— 例如 property
   test 驱动 `spawn_from_template/2` 走一系列状态，断言返回标签
   始终在 `{:ok, :partial, :error}` 里？

4. **调用方穷举性**。§3.3 列了 4 个站点，会不会有 **其他** 调用方
   也 pattern-match `:partial`？未来重构新增调用方不会被本 SPEC 抓
   到。

5. **测试隔离 gap**。这个测试从 PR-A（350e9c3）到现在，跨了多轮 PR
   都没人修复 —— 为什么？是不是有 `@tag :skip` 或 `setup` 门在掩
   盖？如果是，修复本 SPEC + 实现需要 **取消** 那个掩盖。

6. **`:partial` 形态内部一致性**。map 装
   `{session_uri, orchestrator_uri, completed, pending, errors}` ——
   `orchestrator_pending` 是唯一 pending 步时，`orchestrator_uri`
   是 `nil`，candidate URI 在 `errors`。有没有更易读的形态（例如
   即使 pending 也用 candidate 填 `orchestrator_uri`）？SPEC 可以
   澄清，但 **不提议** 改它（不在范围内；如必要作为未来 polish 跟
   踪）。

---

## §12 回滚方案

如果实现 PR 发现决策 A 错了（即 SPEC 改动其实应该是 B 或 C）：

1. **回滚本 SPEC**：把 §2 的判决换成新方向，保留 §1-§3 的调研记录。
2. **不回滚生产代码** —— 本 SPEC 不要求改生产代码（§4.1）。要回滚的
   是实现 PR 的修复（如果有）。
3. **不变量测试**（§5）很小，方向变就删掉。

回滚成本：低（一个 SPEC + 一个可选测试）。

---

## 附录 A — 为什么本 SPEC 短

按 `feedback_main_agent_for_single_tasks` 以及用户对 ergonomic
SPEC 的偏好，本 SPEC 是 **再次确认** 既有 ratified 契约，不引入新
契约。实质工作在 `2026-05-23-generator-reconciler.md`；本 SPEC 的
角色是：

1. 回答 PR #422 Bug 3 "需要 SPEC 校验" 的问题是 "保留" 还是
   "改变" —— 答案：保留。
2. 提供一个紧致的不变量测试（§5），让未来漂移被结构性抓到。
3. 文档化实现阶段定位实际回归（如果有）的步骤。

长度预算有意控制在 ~450 行。

---

## 附录 B — 交叉引用

- [`docs/superpowers/specs/2026-05-23-generator-reconciler.md`](2026-05-23-generator-reconciler.md)
  — 原始三臂 SPEC。
- [`docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`](2026-05-26-session-create-orchestrator-unified.md)
  — PR #408 unified session create；完整保留 `:partial`。
- PR #422 — umbrella 测试 batch（4 提交），标记了 Bug 3。
- PR #408（bd968a2）— unified session create；触 orchestrator-ensure
  路径但保留返回形态。
- PR-A #259（350e9c3）— 原始 Generator-Reconciler 重构；引入
  `:partial`。
