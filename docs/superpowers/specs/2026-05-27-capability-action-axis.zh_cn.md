# SPEC — Capability struct 加入 action 维度

**状态：** r1 (draft, 等待 codex 审核). 2026-05-27.
**层级：** `apps/ezagent_core/` 框架级修整 + 全 umbrella grant 站点、`required_caps/0`、构造 cap 的测试统扫。
**触发：** Allen 2026-05-27 Feishu 指令——「显然应该恢复 action 字段」。PR #408 + #409 暴露了长期已知的 over-grant：workspace member 拿到 `Behavior.Workspace :create_session` cap 后同时满足 `add_member`、`remove_member`、`set_routing_rules`、`create_agent` 等所有 action 的 cap 检查，因为 cap struct 把 action 参数丢弃了。
**对照：** `2026-05-27-capability-action-axis.md` (per `feedback_bilingual_docs_convention`).

**承重 memory：**
- `feedback_let_it_crash_no_workarounds` — 不允许 shim、不允许 dual-path。action 作为真实 struct 字段加入；默认 `:any` 是通配符，不是「被丢弃的占位值」。
- `feedback_completion_requires_invariant_test` — 合并门：一个 invariant 测试证明给定 workspace 的 `:add_member` cap **不能**通过同 workspace `:create_session` 的 cap 检查（今天能，那是 bug）。
- `feedback_north_star_plugin_isolation` — plugin 作者 API 保持 `Capability.cap(:chat, __MODULE__, :send)` 形式；第三个参数从「文档用」变「承重」。
- `feedback_subagent_must_load_project_skills` — 实现 subagent dispatch 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_companion_no_mix` — SPEC + impl PR 的 codex review 都带「no mix」逐字句。

**父级 / 历史背景：**
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` r4 §0d — PR-CC-2a/2b string-cap 实验回滚后确立「保留 struct」决策。当时讨论过 action 维度但**最终未实现**。
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 — 该 SPEC 示例 struct 构造（line 73 signature block）已经写了 `action: :send`，**SPEC 意图存在，代码从未实现**。
- `docs/futures/todo.md` §"Capability struct lacks an action axis (codex PR #356 r1 CRIT)" — PR #356 codex r1 揭示；PR #408 round-3 再次确认；本 SPEC 解决。

---

## 1. 问题一段话讲清

今天一条 capability 是 4 维匹配：kind × behavior × instance × workspace。behavior 维度记录模块名（`Ezagent.Behavior.Workspace`），所以「针对 Workspace Behavior 的 cap」对该 Behavior 的所有 action 形态等价。今天的大部分 Behavior 在一个模块里混合了不同权限层级——`Behavior.Workspace` 有 `list_members`（只读）、`add_member`（admin）、`create_session`（member-ok）。给非 admin member 任意一个 Workspace cap 等于打开该 workspace 上所有 Workspace action 的 cap 检查闸门。这个陷阱存在于 umbrella 里每个 multi-action Behavior（Routing、ApiKeys、UserTokens、Feishu UserBinding 等）。修复就是给 cap 匹配加显式 action 维度，让一个针对 `:create_session` 颁发的 cap 只匹配 `:create_session` 的检查，不匹配 `add_member`。

## 2. 为什么不能再等

| 表面 | 今日权限混合 | 已暴露风险 |
|---|---|---|
| `Behavior.Workspace` | list × admin × member | PR #408 round-3 — workspace member 事实上获得 admin 权 |
| `Behavior.Routing` | declare × set rules × list | 低（今天没有 member 级 grant 站点） |
| `Behavior.IdentityAdmin` | grant × revoke × list | 高——「仅 list」grant 也会授权 grant/revoke |
| `Behavior.ApiKeys` | mint × revoke × list | 高——形态同 IdentityAdmin |
| `Behavior.FeishuUserBinding` | bind × unbind × list | 中——暴露给 plugin 作者误用 |
| `Behavior.Template`（AgentTemplate + SessionTemplate） | read × write × instantiate × delete | 高——instantiate 是 operator 层，read 是 plugin 层 |

PR #356 的 carve-out workaround（把每个特权 action 拆成独立 Behavior 模块）是部分缓解但臃肿 Behavior 数量、把模块名漏到 UX 层。**不是结构性答案**。

## 3. 设计——一个字段，真比较

### 3.1 struct 增至 7 个 enforce_keys

```elixir
@enforce_keys [:kind, :behavior, :action, :instance, :workspace_uri, :granted_by, :granted_at]
defstruct kind: nil,
          behavior: nil,
          action: :any,
          instance: nil,
          workspace_uri: nil,
          granted_by: nil,
          granted_at: nil
```

默认 `:any` 沿用现 kind/behavior/instance/workspace_uri 通配符约定。旧 grant 站点未传 action 时变 `action: :any`——即通配——保留现 admin / system-principal 语义。

### 3.2 构造函数停止丢弃 action

```elixir
def cap(kind, behavior, action) when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,            # ← 从前是 `_action`，这是第三参数丢弃的洞
    instance: :any,
    workspace_uri: :any,
    granted_by: @plugin_declared_granter,
    granted_at: @compile_time_granted_at
  }
end
```

签名不变——只是 body 不再把第三参数扔到地板上。

### 3.3 `matches?/2` 加 action 作为第五匹配维度

```elixir
def matches?(%__MODULE__{} = cap, %{kind: k, behavior: b, action: a, instance: i, workspace_uri: w}) do
  field_match?(cap.kind, k) and
    field_match?(cap.behavior, b) and
    field_match?(cap.action, a) and
    instance_match?(cap.instance, i) and
    workspace_match?(cap.workspace_uri, w)
end
```

needed-cap 形态（第二参数）加 `:action`。今天 needed-cap 由 `Ezagent.Kind.Runtime` 的 `authz_check` 用 dispatch target + action atom 构造；那个调用点加一字段（`action: <the action atom>`）即可。

### 3.4 持久化：`caps_json` 变 7 字段 JSON，向后兼容读取路径

| 读方向 | 旧行（6 字段，无 `action`） | 新行（7 字段） |
|---|---|---|
| Load → struct | 解析时注入默认 `action: :any` | 原样读取 |
| Save → JSON | 7 字段全部序列化 | 7 字段全部序列化 |

向后兼容读取路径**不是 let-it-crash 违反**——这是旧行的规范解释：6 字段 cap 在语义上一直就是「该 Behavior 上的任意 action」，而 `:any` 正是新形态对此的拼写。读取路径仅一行：`Map.put_new(parsed_map, "action", "any")`（在 atomization 之前）。无需迁移；旧行在首次读取时自动升级。

### 3.5 `Behavior.required_caps/0` 语义——action 现在承重

每个 Behavior 的 `required_caps/0` 已经按 action 枚举一个条目。今天 *map key* 区分 action 但 *cap struct* 形态等价。本 SPEC 后，struct 的 `action` 字段 == map key——它们双重编码 action，没问题（map key 是 dispatch 查找，struct 字段是 matcher 输入）。

plugin 作者 API 不变：

```elixir
def required_caps do
  %{
    send: Capability.cap(:chat, __MODULE__, :send),
    receive: Capability.cap(:chat, __MODULE__, :receive)
  }
end
```

第三参数从此承重，零 plugin 作者迁移。

### 3.6 Wildcard grants 仍为 wildcard

`User.admin_uri()` 和 `system://bootstrap` 已经拿到 `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap。本 SPEC 后再加 `action: :any`——同 wildcard 语义。Catalog 中点名指定 action 的条目（`SystemPrincipal.Catalog` 的 14 项）获得真实 action 值；其窄化效果变得结构性有效。

## 4. 迁移策略

### 4.1 单 coordinated PR——无 dual-path

Allen 的 `feedback_let_it_crash_no_workarounds` 禁止 dual-path。PR 一次性落地：

1. Capability struct + helpers + matches?/2 —— 一个 commit
2. 所有 `required_caps/0` action 串接审核 —— 一个 commit（多数是验证第三参数和 map key 一致；预计 ≤5 处 typo 修复）
3. 所有 grant 站点（`Identity.grant_cap`、`IdentityAdmin`、`SystemPrincipal.Catalog`）—— 一个 commit
4. `caps_json` 向后兼容读取（`Map.put_new(..., "action", "any")` + `Capability.from_map/1` 审核）—— 一个 commit
5. Invariant 测试 + 每 Behavior 覆盖测试 —— 一个 commit
6. over-grant 回归测试（PR #408 round-3 精确案例：拿 `:create_session` cap 的 workspace member 被拒 `:add_member`）—— 一个 commit

### 4.2 Compile-time check 10

`:ezagent_plugin_check` 现有 check 10（「每个 action 必须有 required_caps 项」）加兄弟 check 11：`required_caps[action].action == action`——保证 map key 和 struct 字段不漂移。

### 4.3 无 DB schema 迁移

`caps_json` 是 JSONB 列。新行写 7 字段；旧行用 `:any` 默认读取。无需 `alter table`。本 PR 的 schema migration 列表为空——这是设计如此。

## 5. 验收标准

| # | 测试 | 通过条件 |
|---|---|---|
| A1 | `Capability.cap(:chat, Chat, :send).action == :send` | 单元测试 |
| A2 | `Capability.matches?/2` 持有 `action: :send` 检查 `action: :join` → false | 单元测试 |
| A3 | `Capability.matches?/2` 持有 `action: :any` 检查 `action: :send` → true（通配保留） | 单元测试 |
| A4 | 旧 JSON 行（6 字段）加载为 `action: :any` | 单元测试 |
| A5 | `required_caps/0` 条目：每个 Behavior `entry[action].action == action` | umbrella 级属性测试 |
| A6 | Compile-time check 11 对故意破坏的 fixture（`%{send: cap(.., .., :join)}`）失败 | plugin-check 测试 |
| **B1** | **PR #408 回归测试**：workspace member 持 `Capability.cap(:workspace, Behavior.Workspace, :create_session)` 被**拒** dispatch 到 `workspace://X?action=workspace.add_member` | invariant 测试（合并门） |
| B2 | 同 member 被授权 dispatch 到 `workspace://X?action=workspace.create_session` | invariant 测试 |
| C1 | admin wildcard cap（`kind: :any, behavior: :any, action: :any, …`）仍满足所有 action | 回归测试 |
| C2 | `SystemPrincipal.Catalog` 14 项各得真实 action；`system://chat-router :send` 被拒同 Session 的 `:receive` | catalog 审核测试 |

## 6. 受影响文件（估计）

**核心改动（小）：**
- `apps/ezagent_core/lib/ezagent/capability.ex` — struct + helpers + matches?/2
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — authz_check needed-cap 构造（加一字段）
- `apps/ezagent_core/lib/ezagent/identity/admin.ex` — grant_cap / revoke_cap 可能需要在入口规范化 action
- `apps/ezagent_core/lib/ezagent/ecto/identity_slice.ex`（或 caps_json 反序列化处）— 读取路径 `Map.put_new("action", "any")`

**统扫（机械，~100 站点）：**
- 每个 Behavior 的 `required_caps/0` — 验证 map key 和第三参数一致（预计 ≤5 处 typo 修复）
- 每个直接构造 `%Capability{}` 的测试 — 加 `action:` 字段（搜索替换 + 手工审核 `:any` 还是具体 action）
- `SystemPrincipal.Catalog` 14 项 — 验证或修正 action atom

**新测试：**
- `apps/ezagent_core/test/ezagent/capability_action_test.exs` — A1–A4 + C1
- `apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs` — A5
- `apps/ezagent_core/test/integration/cap_action_axis_invariant_test.exs` — **B1 + B2**（合并门）
- `apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs` — C2

## 7. 范围外

- Cryptographic cap 字段（signature、nonce、issued_at）—`2026-05-25-caps-cleanup-v1.md` r4 §44 提及为「additive future extensions」；本 SPEC 一次只加一字段。
- `Capability.matches?/2` 返回结构化拒绝原因（今天：布尔）。诊断有用，单独 PR。
- 重命名 `cap_subjects/0` 或任何 registry API。现有 UI / catalog 流程不变。
- 移除 PR #356 `WorkspaceUserAdmin` carve-out——该模块为不同原因存在（按注册做特权隔离）保留。

## 8. 风险 / 已考虑的失败模式

| 失败 | 行为 |
|---|---|
| grant 站点忘记指定 action 不传任何东西 | `cap/3` 默认仅在公开构造器位通过 `:any` 默认；直接 struct 构造必须指定（enforce_keys）。plugin-check 11 抓 `required_caps/0` 漂移。 |
| 两个调用者同时写 caps_json 重叠 cap 形态 | 现有 Ecto 乐观并发 / slice revision-CAS 不变。 |
| 旧行读为 `:any` 但用户原意是窄 cap | 不可能——旧代码从未写过窄 cap（字段不存在）。`:any` 是唯一正确解释。 |
| Plugin 作者的 required_caps map key 和第三参数不一致 | Compile-time check 11 让 build 失败。 |
| `SystemPrincipal.Catalog` 回归破坏启动 | §5 C2 catalog 审核测试在 merge 前抓住。 |
| Action atom 拼写错误编译通过但运行时 cap-check 失败 | 与今天 `actions/0` 里 action atom 拼写错误一致——集成测试抓。 |

## 9. Codex 对抗审查问题

1. **向后兼容边界**：`Map.put_new("action", "any")` 真是旧 6 字段行的规范解释，还是静默扩大了原本窄的 grant？对一个运行中 dev DB 的实际 `caps_json` 行做核对。
2. **Wildcard 级联**：`action: :any` + `behavior: :any` + `instance: :any` 的 cap 是 admin wildcard。本 SPEC 后，是否有办法构造一个 cap 授权 admin wildcard 的 behavior 但不是所有 action？应该有吗？
3. **`SystemPrincipal.Catalog` 14 项**：全部 14 项的 action atom 是否对应该 Behavior 的真实 `actions/0` 条目？跑 grep + 交叉验证。
4. **`Behavior.required_caps/0` 隐式不变量 `entry_key == cap.action`**：compile-time check 11 在现 `:ezagent_plugin_check` 结构中可执行，还是需要新 AST walker？
5. **跨 Behavior cap**：是否有 Behavior 的 `required_caps/0` 引用*另一个* Behavior 的 action（罕见但可能——例如内部 dispatch 另一个 Kind 的派生 action）？action 维度必须匹配*外层* action，不是内层。
6. **测试影响**：多少现有测试直接构造 `%Capability{}` 不走 `Capability.cap/N`？每一处都是手工编辑点。
7. **新代码部署与读取旧 caps_json 行之间的 race**：读取路径的 `Map.put_new("action", "any")` 在加载时进程内运行。有路径绕过吗？（例如 raw Repo.all + `Ecto.Schema.load/2` 在 from_map shim 之外重建 cap struct？）
8. **Catalog 测试 C2 的具体性**：`system://chat-router :send` 被拒同 Session 的 `:receive`——catalog 实际只 grant `:send` 还是也 grant `:receive`？验证 catalog 当前编码。

## 10. 留给 Allen 的开放问题

1. **诊断用 cap-axis 排序**：cap-check 失败时，错误消息可点名是哪个维度不匹配（`action mismatch: held :send, needed :join`）。对 plugin 作者调试有用。默认：仅 log debug 级；UI 显示通用「unauthorized」。本 PR 范围内还是外？
2. **`cap_exempt_actions/0`**——故意绕过 cap-check 的 Behavior（通过 `cap_exempt_actions/0` 声明）。加 action 后，exempt-action 处理仍按 action 维度；不变。确认 OK。
3. **未来 grant 审计**：审计轨迹（`Ezagent.Audit`）是否开始记录被检查的 action 和授权的 cap？今天记录 cap 但不记录 action 匹配——小诊断改进。

## 11. 回滚计划

单 PR 改动。回滚 = revert merge commit。向后兼容读取路径意味回滚后代码仍可读新代码写的行（多一个 `action` 字段；旧代码忽略未知 JSON 键，走现有 parse path）。风险：新代码下用窄 action 写的行在回滚后回归「任意 action」语义——严格更宽，永不拒绝。可接受作为一步回滚安全网。

---

## 附录 A — 为什么本 SPEC 短

per `feedback_explain_problem_not_code_structure`，SPEC 描述问题 + 设计意图。PR 实施 subagent 机械执行 sweep——多数是把一个已传作第三参数的 atom 穿过一百个 call site。有趣的工作在 invariant test（B1）和 catalog 审核（C2）。

## 附录 B — 为什么 PR-CC-2-v2 SPEC 的示例里有 `action: :send` 但 struct 中没有

PR-CC-2-v2 SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 line 73：

```elixir
%Capability{
  kind: :chat,
  behavior: Ezagent.Behavior.Chat,
  action: :send,           # ← SPEC 中有，struct 中从未有
  ...
}
```

这是 2026-05-25 的 SPEC-vs-code 漂移。SPEC 反映了*期望*形态；实现保留了 6 字段 struct。Allen 2026-05-27 指令通过把 SPEC 意图变成实际实现关闭这个漂移。**action 字段从未在 struct 里——SPEC 只是承诺它会在。**
