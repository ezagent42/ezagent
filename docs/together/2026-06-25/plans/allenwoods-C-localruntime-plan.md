# 执行 plan — C: LocalRuntime 收口（#99）

> Dev 执行计划（非 lead 的 `plan.md`）。Handoff: `handoffs/allenwoods-C-localruntime-migration.md`。
> 主文档: `handoffs/allenwoods-agent-runtime-consolidation-plan.md`。

- **分支**: `feat/localruntime-migration-c`，**off `origin/main`**（本地 `main` 是 stale 的，缺 #95 的 LocalRuntime + 06-25 前置；origin/main = aa9be1d1）。
- **性质**: 机械迁移，设计已锁死（handoff = spec），无新决策。
- **流程**（用户 06-25 拍）: 轻量 plan（本文）→ `/goal` 自驱实现 → 对 **diff** 跑 codex 对抗评审 → 修 → CI 绿 + rebase → PR + return 交 lead（allenwoods）统一合并。

## 设计锚点（不可违反）

- LocalRuntime 维持 **URI-only / behavior-agnostic**，**不加 arity**（behaviors 归子任务 A）。
- `kind_alive?/1`、`ensure_started/1` 都 guard `%URI{}`，被迁的 uri 全是 `%URI{}`（已核）。
- 单节点 WorkspaceOwnerGate 为 **no-op**，行为必须**不变**。

## 范围 —— 7 处调用点（4 文件）

| 文件:行 | before | after |
|---|---|---|
| `ezagent_plugin_hello/.../template/hello_session.ex:41` | `KindRegistry.lookup(session_uri) == :error` | `not Ezagent.LocalRuntime.kind_alive?(session_uri)` |
| `ezagent_plugin_protocol_api/.../protocol_api/conversation_registry.ex:53` | `SpawnRegistry.spawn(session_uri)` | `LocalRuntime.ensure_started(session_uri)` |
| `…/conversation_registry.ex:90` | `SpawnRegistry.spawn(session_uri)` | `LocalRuntime.ensure_started(session_uri)` |
| `ezagent_plugin_protocol_api/.../openai_chat_plug.ex:109` | `case Ezagent.KindRegistry.lookup(agent_uri) do {:ok,_}->:ok; :error->sleep/retry end` | `if Ezagent.LocalRuntime.kind_alive?(agent_uri), do: :ok, else: sleep/retry`（语义等价；`{:ok,_pid}` 即 alive） |
| `…/openai_chat_plug.ex:195` | `case SpawnRegistry.spawn(agent) do …` | `case LocalRuntime.ensure_started(agent) do …`（返回同形 `{:ok,pid}\|{:error,_}`，`{:error,:already_started}` 仍可达） |
| `ezagent_plugin_world/.../world/workspace_plugin_data.ex:122` | `live_pid = case KindRegistry.lookup(ws.uri)…`；`"live"=>is_pid and alive?` | `"live" => Ezagent.LocalRuntime.kind_alive?(ws.uri)`（删 `live_pid` 绑定；pid 无他用） |
| `…/workspace_plugin_data.ex:164`（`workspace_live?/1`） | `case KindRegistry.lookup(uri) do {:ok,pid}->is_pid and alive?; :error->false end` | `Ezagent.LocalRuntime.kind_alive?(uri)` |

### alias 处理
- hello: `alias Ezagent.KindRegistry` 仅用于 :41 → 改为 `alias Ezagent.LocalRuntime`。
- conversation_registry: `alias Ezagent.{SpawnRegistry, WorkspaceRegistry}` → `Ezagent.{LocalRuntime, WorkspaceRegistry}`；moduledoc 里 `SpawnRegistry.spawn` 字样同步更新。
- openai_chat_plug: alias 内 **保留 `SpawnRegistry`**（:240 `ensure_live` 仍用），**加 `LocalRuntime`**。
- workspace_plugin_data: 全 fully-qualified；`Ezagent.KindRegistry.list_all()`（:206）保留 → `Ezagent.KindRegistry` 仍被引用，无 alias 清理。

### 明确不碰（范围外）
- `openai_chat_plug.ex:240` `SpawnRegistry.ensure_live/1` —— 契约 gate 正则只抓 `.spawn(_detailed)?`，不抓 `ensure_live`；LocalRuntime 无对应 arity（URI-only 守约）。
- `workspace_plugin_data.ex:206` `KindRegistry.list_all()` —— gate 只抓 `.lookup(`，不在 allowlist。
- scanner `@spawn_registry_sanctioned_files` 里 `cc/orchestrator/mcp_server.ex` 那条 stale（已不 spawn）—— 先于我的既存小债，知会 lead，不碰。

## 连带改动（被 gate 强制，纳入本 PR）

1. **`apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`** —— 删除对应的 **7 条 `@allowlist`**（hello:41 / conv_reg:53 / conv_reg:90 / openai:109 / openai:195 / world:122 / world:164）。保留 5 条 cc/codex 的。否则 `allowlist entries remain exact` test 红（源码行不再含 `line_substring`）。
   - 注：`workspace_locality_debt_warning` 的 `total=` 由 `length(@allowlist)` 自动重算，无需手动改。
2. **`apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`** —— `@spawn_registry_sanctioned_files` 删除 conv_reg、openai 两条 stale（迁移后不再 spawn）。

## manifest ratchet —— `arch_baseline_manifest.exs`（lowering 免注解）

| key | 现 cap | 新 cap | 依据 |
|---|---|---|---|
| `spawn_registry_call_sites` | 30 | **27** | 删 3 处 spawn 调用（conv_reg×2 + openai×1） |
| `spawn_registry_modules` | 26 | **24** | conv_reg、openai 两文件离开 spawn-set |
| `spawn_registry_off_chokepoint_modules` | 16 | **16（留）** | 见下；按构造不降 |

**off_chokepoint 为何不降（据实记入 return）**: conv_reg/openai 此前被塞进 sanctioned（算 on-chokepoint），从未计入 off_chokepoint。把它们移出 SpawnRegistry + 移出白名单是「一进一出」，其它*未授权* spawner 数量未变 → 仍 16。**架构收益真实存在**（白名单 11→9，「有资格绕 owner-gate 直接 spawn」的面积缩小），只是这条 counter 量的是「白名单*外*的违规者」，量不到白名单本身收紧。收益体现在 call_sites/modules 两条真降。

> 提醒：scan 在 `:dev` env、test 在 `:test` env，**分开的 `_build`**。改完务必各自 fresh compile 再核（`MIX_ENV=dev mix compile && mix ezagent.arch.scan`）；branch-switch 残留的 stale `_build/dev` 会给假读数。

## 测试 —— 盘点 + 缺口

| 改动路径 | 现有覆盖 | 动作 |
|---|---|---|
| hello :41 `fresh?` | ✅ `hello_session_test.exs` 断言 `fresh?: true`（首次）/`false`（幂等重建） | 跑通即可 |
| conv_reg :53（stateless spawn）+ openai :109/:195 | ✅ `openai_chat_plug_integration_test.exs` 「202 stateless」走 join_agent spawn + kind 轮询 | 跑通即可 |
| conv_reg :90（bound spawn） | ⚠️ 同 `ensure_started` 调用，间接 | 视成本补一条 bound-path 用例（次要） |
| world :122/:164 liveness | ❌ **无** test 触及 `live` 字段 | **补最小用例**：经公有 `WorkspacePluginData.state_for/2`（`component: "workspace_detail"` → `workspace_live?` :164；`"workspace"` → list :122）断言 live workspace 的 `"live"==true`、未起的 `"live"==false` |

## 验证命令（DoD 证据）

```bash
# 契约 gate（核心证据：7 条 allowlist 撤后仍绿）
mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
# arch ratchet（dev env fresh compile 后）
MIX_ENV=dev mix compile && mix ezagent.arch.scan
mix test apps/ezagent_core/test/architecture/spawn_chokepoint_test.exs
# 受影响 plugin 测试 + 新增 world liveness
mix test apps/ezagent_plugin_hello apps/ezagent_plugin_protocol_api apps/ezagent_plugin_world
# 全量
mix test
# 格式（仅触碰文件）
mix format <touched files> && mix format --check-formatted
```

## DoD 四性质对账（return 时逐条填 met/deferred/not-met + 证据）

- **目标派生**: 6 处直调 SpawnRegistry/KindRegistry → 走 owner-gated LocalRuntime。
- **可验证带证明**: 契约 gate test 由 allowlisted→绿（无 allowlist）；arch.scan call_sites 30→27、modules 26→24。
- **在用户面**: world workspace liveness 显示 / protocol_api 起 agent / hello app 创建 freshness —— 单节点行为不变（owner-gate no-op），有测试覆盖。
- **闭集**: ensure_live / list_all / mcp_server-stale 明确划在范围外并说明；A 边界（behaviors）不碰。
- **off_chokepoint**: not-lowered-by-construction（带上面证据说明），非 deferred。

## 风险 / 中途暂停触发点

- 若某处 spawn/lookup 实际**不是 URI-only（需传参）** → 按默认假设标注实现 + 完成后上报（A 的边界），不中途卡。（已核：全 URI-only，预计不触发。）
- 若 B 先合并改了 `arch_baseline_manifest.exs` → rebase 后重新 ratchet。
