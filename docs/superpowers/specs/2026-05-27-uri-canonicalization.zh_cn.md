# SPEC — URI 跨边界规范化 (Bug 2)

**状态:** r1 — DRAFT,等待 codex adversarial-review。2026-05-27。

**层级:** `apps/ezagent_core/` (`Ezagent.URI` 解析器 / 规范化器) + 扫除所有构造 `%URI{}` 的 Domain + Plugin。

**触发:** 测试失败 `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66` — wizard `create_session` 流程因 `caller == owner` 严格相等比较在同一规范字符串的 `URI.parse` 形式 (authority:"user") 与 `URI.new!` 形式 (authority:nil) 之间失败,返回 `:grant_owner_orchestrator_admin_cap_failed`。

**英文版:** `2026-05-27-uri-canonicalization.md` (按 `feedback_bilingual_docs_convention`)。

**先验记忆 (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — 不允许双路径。已有规范化助手;生产者经它路由;边界站点的非规范构造器被**删除** (不是 deprecated,不是 alias,不是 feature-flag)。
- `feedback_completion_requires_invariant_test` — 合并门是一个不变量测试,当未来的贡献者重新引入边界 `URI.parse/1` 或 `URI.new!/1` 调用时会失败 (§5)。
- `feedback_register_lookup_key_parity` — 这个 bug 就是 register/lookup-key-parity 教训在 URI 结构表示上的重演。
- `feedback_north_star_plugin_isolation` — Plugin 作者写新的 Behavior 时**不**需要知道 `URI.parse` vs `URI.new!`。规范化助手是唯一边界 chokepoint。
- `feedback_uuid_is_canonical_identifier` — 规范形式不能依赖于显示可变字段。URI 的身份是其字符串规范化,`%URI{}` 结构的 `:authority` 字段是伪装成身份的解析器 quirk。
- `feedback_subagent_must_load_project_skills` — impl 子代理 dispatch 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_review_every_pr` — 此 SPEC + impl PR 的 codex review 携带原文 "no mix" 子句。
- `feedback_destructive_migration_anti_pattern` — 见 §4.1/§9:持久化 URI 字符串已经通过 `Ezagent.Ecto.URI.load/1` 用 `URI.new/1` (strict, RFC 3986) 往返,所以 DB 序列化保持字节相同。**本 SPEC 不需要破坏性 DB 迁移**。

**父级 / 历史上下文:**
- `docs/notes/uri-design.md` §5 — SPEC v3 URI 形状规则。本 SPEC 向该文件追加结构化规范化规则 (§5.15 — 在 impl PR 中追加)。
- `apps/ezagent_core/lib/ezagent/uri.ex:124-143` — `Ezagent.URI.parse!/1` **已存在** 且**已使用** strict `URI.new/1`。本补救只是将这个已有函数从"进入系统的字符串的 scheme-allowlist 验证器"**提升**为"代码库任何位置 Ezagent-scheme URI 的唯一规范 `%URI{}` 构造器"。**不引入新模块**。
- `apps/ezagent_core/lib/ezagent/capability.ex:320-348` — `Capability.instance_match?/2` 对两个具体 URI **已经**通过 `URI.to_string/1` 比较。匹配器路径已免疫。Bug 表面是在到达匹配器之前做原始结构 `==` 的调用点 (如 `EzagentDomainChat.grant_owner_orchestrator_admin_cap/3` 的 `has_equiv?` 检查;`Behavior.Identity.check_grant_authorized` 的 `caller == owner` 短路)。
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` — 已有的手写 `URI.parse(URI.to_string(uri))` 往返是本 SPEC 形式化规则的局部、未文档化版本。impl PR 删除该往返,改用 `Ezagent.URI.parse!/1`。
- `2026-05-27-capability-action-axis.md` — 并发 SPEC,添加 `:action` 字段。独立。§8 列举。
- `2026-05-27-workspace-cap-based-visibility.md` — 并发 SPEC,基于 cap 的可见性。在 URI 轴独立。§8 列举。

---

## 1. 问题陈述 — 精确分歧

### 1.1 分歧

```elixir
URI.parse("entity://user/system/admin")
# %URI{authority: "user", host: "user", path: "/system/admin", ...}

URI.new!("entity://user/system/admin")
# %URI{authority: nil, host: "user", path: "/system/admin", ...}
```

两者 `URI.to_string/1` 产生**相同**的 8 字节序列 `entity://user/system/admin`。作为 `%URI{}` 结构体它们**不**相等。

stdlib `URI.parse/1` 自 Elixir 1.13 起 deprecated,因为它是非严格的 (RFC 2396)。它将旧的 `:authority` 字段设为主机部分。stdlib `URI.new/1` (及 `!` 变体) 是严格的 (RFC 3986),保留 `:authority` 为 nil — RFC 3986 删除了该字段。两个构造器对同一输入产生结构上不同的 `%URI{}`。

### 1.2 失败路径 (Bug 2 wizard 测试)

`apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66`:

1. `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` 的种子在**编译时**构造 `@admin_uri URI.parse("entity://user/system/admin")` — authority:"user"。
2. wizard 的 `EzagentWeb.LiveAuth.parse_entity_uri/1` 经 `Ezagent.URI.parse!/1` 路由,其使用 strict `URI.new/1` — authority:nil。
3. 两个 `%URI{}` 到达 `grant_owner_orchestrator_admin_cap/3`。
4. `has_equiv?` 检查使用 `cap.instance == want.instance` 原始结构相等。差在 `:authority`,所以为 `false`。
5. grant 进入 `check_grant_authorized/2`,其 `caller == owner` 短路也是原始结构相等。差在 `:authority`,落到 `{:error, :grant_not_owner}`。

`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` 的手写 `URI.parse(URI.to_string(uri))` 往返为 `Session.spawn_from_template/2` 路径修补**同一** bug,但**没有**为直接 `EzagentDomainChat.create_session/3` 路径修补。需要两个补丁,只应用一个 — 这种 parity 漂移**就是** bug。

### 1.3 Bug 类别

代码库任何位置原始 `==` 两个 `%URI{}` 结构体,当生产者可能使用不同构造器时,就是静默的授权拒绝。匹配器 (`Capability.instance_match?/2`) 已加固 (行 347)。非匹配器比较表面 — 等价检查、所有者-短路比较、由原始结构构建的 MapSet 键、`List.member?/2` 成员检查 — **没有**加固。

代码库有 226 个生产 `URI.parse/1` 站点 + 79 个 `URI.new!/1` 站点。没有结构化规则,每个未来添加新 URI 生产站点的 PR 都是该 bug 类的潜在重现。

---

## 2. 决策

**选项 D — 边界处的单一规范构造器。** 采纳。

`Ezagent.URI.parse!/1` 成为**所有** scheme 在 SchemeRegistry allowlist 中的 `%URI{}` 的构造器。所有生产代码通过 `Ezagent.URI.parse!/1` 路由 URI-from-string。直接 stdlib `URI.parse/1` 从生产代码删除。直接 stdlib `URI.new!/1` 从生产代码删除,**除了**构造 `?action=...` query-bearing 形式 (风格化 carve-out,见 §3.4) 和编译时模块属性 (§3.5)。

为什么选 D 而非 A/B/C:

- **A (全部迁移到 `URI.new!/1`)** 是半个解决方案。修了 AUTHORITY 分歧但没建立 SchemeRegistry chokepoint。Plugin 作者仍需记住"用 `URI.new!`,不用 `URI.parse`"。一旦有站点回退,bug 类回归。
- **B (全部迁移到 `URI.parse/1`)** 永远保留非严格 authority quirk。锁定到 deprecated API。被 `feedback_uuid_is_canonical_identifier` 精神拒绝。
- **C (用 `URI.to_string/1` 比较)** 是 workaround — `feedback_let_it_crash_no_workarounds` 明确排除。强制每个比较表面知道"URI 是特殊的"。
- **D (规范化助手)** 锁定生产者侧。每个 Ezagent-scheme URI 的 `%URI{}` 通过单一 chokepoint 构造。

Chokepoint 已存在。SPEC 是**提升**它 (形式化规则、扫除生产者、添加不变量测试) 而非引入它。

---

## 3. 语义 — 规范 URI 规则

### 3.1 规则 (一句)

**对于 scheme 在 `Ezagent.URI.SchemeRegistry` 中的任何 URI (即 Ezagent-domain URI),规范 `%URI{}` 内存表示是 `Ezagent.URI.parse!(string)` 返回的。任何代码路径不得通过其他方式构造 Ezagent-scheme `%URI{}`。**

### 3.2 "规范"保证

给定两个通过 `Ezagent.URI.parse!/1` 在 `URI.to_string/1` 相同字符串输入上产生的 `%URI{}` 值 `a` 和 `b`:

1. **结构相等:** `a == b` 为 `true`。
2. **模式匹配:** `%URI{scheme: s, host: h, path: p} = a` 和 `b` 绑定相同的 `s/h/p`。
3. **`:authority` 字段:** `a.authority == b.authority == nil` (RFC 3986)。
4. **往返:** `URI.to_string(Ezagent.URI.parse!(URI.to_string(a))) == URI.to_string(a)`。
5. **DB 往返:** `Ezagent.Ecto.URI.load(Ezagent.Ecto.URI.dump(a) |> elem(1)) == {:ok, a}`。

(1) 是承载保证。(2)–(5) 是衍生。

### 3.3 谁调用 `Ezagent.URI.parse!/1`

五个边界表面 (字符串进入处):

**B1. CLI 输入。** `apps/ezagent_cli/lib/ezagent_cli/{exec,dispatch,tree_builder,coercion}.ex` 已经将字符串解析为 URI;SPEC 扫除将这里的每个 `URI.parse/1` / `URI.new/1` / `URI.new!/1` 替换为 `Ezagent.URI.parse!/1`。

**B2. HTTP / Phoenix params。** `apps/ezagent_web/lib/ezagent_web/live_auth.ex:341` 已经调用 `Ezagent.URI.parse!/1`。模式:每个 LiveView 中的 `parse_*_uri` 助手都经 `Ezagent.URI.parse!/1` 路由。

**B3. DB load。** `Ezagent.Ecto.URI.load/1` 今天使用 `URI.new/1`。Ezagent-scheme 字符串迁移到 `Ezagent.URI.parse!/1`;非 Ezagent scheme (如外部 `http://feishu.cn`) 回退到普通 `URI.new/1`。见 §3.7 双回退契约。

**B4. Snapshot reload。** `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:160` (`URI.new`), `:361` (`URI.parse`), `:159-164` (`URI.new` in `reconcile_after_load_behaviors`)。全部迁移到 `Ezagent.URI.parse!/1`。失败 (raise) 冒泡到 supervisor;按 `feedback_let_it_crash_no_workarounds` let-it-crash。

**B5. 外部 plugin payload。** Feishu mention parser、MCP socket auth payload 等。今天做 `URI.new/1` (带 case-pattern 错误处理)。迁移到 `Ezagent.URI.parse!/1` 包在 try/rescue 在边界处 (所以畸形入站 payload 产生优雅的 `{:error, _}` 到外部表面,**不是**进程崩溃 — Invariant #9 "无静默丢弃在用户面对的表面")。

### 3.4 构造 query-bearing dispatch target

代码库模式 `URI.new!("#{URI.to_string(uri)}?action=behavior.action")` (89 个生产站点) 从规范实例 URI 构建 action-bearing URI。两种等价形式:

- **A:** `URI.new!("#{URI.to_string(uri)}?action=#{behavior}.#{action}")`
- **B:** `Ezagent.URI.parse!("#{URI.to_string(uri)}?action=#{behavior}.#{action}")`

两者都产生 `:authority == nil`。B 额外通过 SchemeRegistry 重新验证 scheme。SPEC 强制 B 在生产站点 (89 个扫除目标)。测试 fixture 和 mix task 可使用任一。`URI.new!/1` 的 carve-out 是风格:这是生产中**唯一**允许 stdlib `URI.new!/1` 的情况,且仅因为 `URI.to_string(uri)` 在构造上是规范形式字符串。

### 3.5 编译时常量

像 `@admin_uri` 这样的模块属性需要编译时可调用的形式。`Ezagent.URI.parse!/1` 调用 `Ezagent.URI.SchemeRegistry.registered?/1` 读取 ETS — 模块编译期间 ETS 不可用。

**路由 1:** 在编译时使用 `URI.new!/1` (严格规范形式,因为对硬编码常量不需要 SchemeRegistry 验证)。在属性上加注释引用本 SPEC。

Carve-out:**编译时**模块属性持有硬编码 URI **可以**使用 `URI.new!/1`。不变量测试 (§5) 捕获 `@constant URI.parse(...)` 但允许 `@constant URI.new!(...)`。

### 3.6 dispatch 内的生产者 (`Invocation` 等)

`Ezagent.URI.instance/1` 从规范输入 (dispatch target) 派生 `%URI{}`。产生 `:authority == nil` 因为输入规范。`instance/1` 无需更改。

`Capability.workspace_of/1` 通过 `URI.new!("workspace://" <> workspace_name)` (行 592) 构造新 `%URI{}`。按构造规范。保持 `URI.new!/1` 按 §3.4 carve-out。

`Ezagent.URI.entity_workspace_uri/1` (行 305) 使用 `URI.new!/1`。按构造规范。无需更改。

### 3.7 非 Ezagent-scheme URI

外部 URI (Feishu webhook、http URL) **不是** Ezagent-scheme。它们经普通 stdlib `URI.new/1` (或遗留 plugin 代码中的 `URI.parse/1`) 路由。

```elixir
# in Ezagent.Ecto.URI.load/1
def load(s) when is_binary(s) do
  try do
    {:ok, Ezagent.URI.parse!(s)}
  rescue
    ArgumentError -> URI.new(s)  # 外部 scheme — 严格但无 allowlist
  end
end
```

### 3.8 什么保持原始 `URI.parse/1`

**仅**文档/注释/inspect/模块级 docstring 中为教学目的说明 deprecated 形式的。不变量测试 (§5) 排除 `.md` 文件和注释 / `@moduledoc` 字符串中的行。

---

## 4. 迁移计划

### 4.1 阶段顺序

PR-1 (本 SPEC): 无代码。SPEC 合并供 codex adversarial-review。

PR-2: 删除-并-扫除,一次一个生产 app。顺序:

1. `apps/ezagent_core/` — 基础。33 个生产调用点。
2. `apps/ezagent_domain_identity/` — 修 `@admin_uri`, `@system_bootstrap_uri` 常量。8 个调用点。
3. `apps/ezagent_domain_chat/` — 删除 303-307 手写;89 个 query-target 站点。
4. `apps/ezagent_domain_workspace/` — 6 个调用点。
5. `apps/ezagent_domain_agent_bridge/` — 4 个调用点。
6. `apps/ezagent_domain_python/` — 已规范。0 个更改。
7. `apps/ezagent_domain_external_mirror/` — 已规范。0 个生产更改。
8. `apps/ezagent_domain_ui/` — 修 `primitives.ex`。1 个调用点。
9. `apps/ezagent_web/` — 3 个调用点。
10. `apps/ezagent_cli/` — 7 个调用点。
11. `apps/ezagent_plugin_*/` — 扫除所有 plugin。约 30 个调用点。

PR-3: 不变量测试 (§5)。

PR-4: 追加 `docs/notes/uri-design.md` §5.15。

**无 DB 迁移。** 持久化字符串无论构造器都按字节相同往返 `URI.to_string/1`。Bug 仅在内存中。

### 4.2 删除-不-保留契约

按 `feedback_let_it_crash_no_workarounds`:每个生产 lib/ 的 `URI.parse/1` 和 `URI.new!/1` 调用站点被**替换**,不保留共存。无 `if Application.get_env(:legacy_uri_parse, false), do: ...`。无过渡 shim。

### 4.3 编译时常量迁移

具体更改:

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` — `@admin_uri URI.parse("entity://user/system/admin")` → `@admin_uri URI.new!("entity://user/system/admin")`。
- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:30` — `@system_bootstrap_uri URI.parse("system://bootstrap/default")` → `URI.new!(...)`。
- `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:98` — `@bootstrap_granted_by URI.parse("system://bootstrap/default")` → `URI.new!(...)`。
- `apps/ezagent_core/lib/ezagent/entity/system.ex:47` — `URI.parse("system://routing/default")` (在 `def routing_default_uri` 内) → `URI.new!(...)`。

### 4.4 测试 fixture 迁移

测试文件 (`test/**/*.exs`) **可以**自由使用 `URI.parse/1` 或 `URI.new!/1`。不变量测试 (§5) **仅**扫描 `apps/*/lib/`,不扫描 `test/`。

可选后续扫除:标准化测试到 `URI.new!/1`。本 SPEC 范围外。

### 4.5 已经正确的站点 (无更改)

- `apps/ezagent_core/lib/ezagent/uri.ex` — 规范化助手本身。
- `apps/ezagent_core/lib/ezagent/routing/resolver.ex:353, 388` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_python/lib/ezagent/domain/python.ex:56` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.{user,agent,workspace}.*.ex` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_user_admin.ex:204` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex:246` — 已用 `Ezagent.URI.parse!/1`。

---

## 5. 不变量测试

**文件:** `apps/ezagent_core/test/invariants/uri_canonicalization_test.exs` (新)。

**目的:** 捕获未来贡献者在 Ezagent-scheme 边界生产代码中引入 `URI.parse/1` 或 stdlib `URI.new!/1`。

四个正交断言:

### 5.1 生产 lib/ 无 `URI.parse/1`

正则 `~r/\bURI\.parse\(/`。注释检测启发式。允许列表仅含 `apps/ezagent_core/lib/ezagent/uri.ex`。

### 5.2 生产 lib/ 无 stdlib `URI.new!/1` 除 §3.4/§3.5 carve-out

`is_query_target_idiom?/1`: 行同时包含 `URI.new!(` 和 `?action=`。`is_module_attribute?/1`: `~r/^\s*@\w+\s+URI\.new!\(/`。

### 5.3 规范 URI 往返

```elixir
for s <- [
  "entity://user/system/admin",
  "entity://agent/team-alpha/cc_demo",
  "session://default/system/main",
  "workspace://team-alpha",
  "system://bootstrap/default"
] do
  a = Ezagent.URI.parse!(s)
  b = Ezagent.URI.parse!(URI.to_string(a))
  assert a == b
  assert a.authority == nil
  assert URI.to_string(a) == s
end
```

### 5.4 Bug 2 特定表面的 parity 测试

```elixir
test "admin_uri canonical-equal across constructors" do
  from_const = Ezagent.Entity.User.admin_uri()
  from_parse = Ezagent.URI.parse!("entity://user/system/admin")
  {:ok, from_load} = Ezagent.Ecto.URI.load("entity://user/system/admin")
  assert from_const == from_parse
  assert from_const == from_load
  assert from_const.authority == nil
end
```

这是会**捕获** Bug 2 的测试 (在 wizard 测试重现之前)。固定为不变量防止重新引入。

### 5.5 为什么这四个一起通过 `feedback_completion_requires_invariant_test` 门

§5.1 + §5.2 + §5.3 + §5.4 各捕获不同的重新引入形态。部分迁移 (95% 站点用规范但 1 个边界跳过) 被 §5.1 或 §5.2 捕获。

---

## 6. Plugin 隔离分析

### 6.1 Plugin 作者今天看到什么

Plugin 作者在三个上下文构造 URI:slice 初始化、dispatch target 构造、外部 payload 反序列化。

SPEC 下:Plugin 作者**不**需要知道 `URI.parse/1` 存在、产生不同结构、`:authority` 是字段。

skill `ezagent-developer/anti-patterns.md` 获得新条目:"不要在 lib/ 中使用 stdlib `URI.parse/1`。对所有 Ezagent-scheme URI 使用 `Ezagent.URI.parse!/1`。不变量测试强制执行。"

### 6.2 Chokepoint 留在 core

`Ezagent.URI.parse!/1` 在 `apps/ezagent_core/` (core 层)。无 plugin 拥有规范化逻辑。

### 6.3 新 scheme 的前向兼容

当 plugin 通过 `Ezagent.SpawnRegistry.register/2` 注册新 scheme 时,`Ezagent.URI.parse!/1` 自动接受 — 无需 `parse!/1` 更改。

---

## 7. 权衡 / 替代考虑

### 7.1 选项 A — 全部迁移到 `URI.new!/1`

**优:** 简单。纯 stdlib。
**劣:** 无 SchemeRegistry chokepoint。一个站点回退,bug 回归。
**拒绝。**

### 7.2 选项 B — 全部迁移到 `URI.parse/1`

**优:** 处处保留现有 `:authority == "user"` 形式。
**劣:** `URI.parse/1` 自 1.13 deprecated。锁定到 deprecated API。违反 RFC 3986。被 `feedback_uuid_is_canonical_identifier` 精神拒绝。
**拒绝。**

### 7.3 选项 C — 通过 `URI.to_string/1` 比较

**优:** 局部修复。匹配器修复是先例。
**劣:** 违反 `feedback_let_it_crash_no_workarounds`。强制每个比较表面知道"URI 特殊"。对 MapSet/struct-keyed map 不工作。
**拒绝。**

### 7.4 选项 D — 规范化助手 (选定)

**优:** 单一 chokepoint。Plugin 隔离。RFC 3986 对齐。通过 §5 测试强制。
**劣:** 迁移触及约 226 个生产站点。§3.4 / §3.5 的 `URI.new!/1` carve-out 在生产引入两种"ok"形式。
**净:** 优大于劣。Carve-out 在 §5.2 精确形式化。

### 7.5 子选项 D' — 引入 `Ezagent.URI.canonical/1`

normalize-from-struct 变体:取**任何** `%URI{}` 并经 `URI.to_string/1` 往返返回规范形式。

SPEC 选择**不**引入,因为今天无生产站点有此需要,且添加 `canonical/1` 创建第二个助手做几乎相同的事 — 两个助手邀请漂移。出 §10 OQ-1。

---

## 8. 与并发 SPEC 的交互

### 8.1 `2026-05-27-capability-action-axis.md` (#410)

该 SPEC 向 `%Capability{}` 添加 `:action` atom 字段。独立。capability 的 URI 字段由本 SPEC 治理。`identity_key/1` 已经通过 `URI.to_string/1` 路由。无代码级交互。

### 8.2 `2026-05-27-workspace-cap-based-visibility.md` (#423)

该 SPEC 引入 `list_workspaces_for(caller_uri, caps)`。两个参数都是 URI。本 SPEC 下两者规范。

### 8.3 前向兼容

任何引入新 URI-shape 约束的未来 SPEC 都在规范形式之上分层。

---

## 9. 向后兼容 / 外部 API

### 9.1 持久化数据

DB 行 (`kind_snapshots`, `users.caps_json`, `messages.sender`, `routing_rules`, `template_tags`, `workspaces.member_uris`) 都存储 URI 字符串 (通过 `Ezagent.Ecto.URI.dump/1` = `URI.to_string/1`)。无论内存结构是 `URI.parse`-built 还是 `URI.new!`-built,字符串形式字节相同。**无需 DB 迁移。**

### 9.2 `:erlang.binary_to_term/2` 在旧序列化 %URI{}

如果 `kind_snapshots` 行在本 SPEC 迁移之前以 `URI.parse`-built `%URI{}` 烘焙到 snapshot 二进制中写入,SPEC 后回放该行重现旧结构。

**缓解:** `Kind.Snapshot.reconcile_after_load_behaviors/3` 是 post-load reconcile 钩子。impl PR 添加 slice 级规范化 pass:遍历解码状态,将任何 `%URI{authority: a}` 且 `a != nil` 且 `scheme ∈ SchemeRegistry` 的 URI 替换为 `Ezagent.URI.parse!(URI.to_string(uri))`。

这是首次重载时每进程一次的成本。无在盘迁移。

**Codex review 问题 (§11):** 该 reconcile-on-load 是否足够,还是部署时需要强制 "rewrite all snapshots" mix task?§11 Q4。

### 9.3 操作员面对的 URI

脚本 (`scripts/*.sh`)、文档 (`docs/**/*.md`)、scenario (`scenarios/*.yaml`)、mix-task 帮助文本 — 全部引用 URI **字符串**,不引用 struct 形式。**无更改**。

### 9.4 外部 plugin payload (Feishu, MCP)

Feishu webhook 事件交付裸字符串,在 plugin 中转为 URI。已经在 case/rescue 中优雅降级。迁移到 `parse!/1` 保留包装。

### 9.5 API v1 controller

`api_v1_controller.ex:201` query-target 形式。保持 `URI.new!/1`。

---

## 10. 给 Allen 的开放问题

**OQ-1.** §7.5 — 现在引入 `Ezagent.URI.canonical/1` 还是推迟?当前选择:推迟。

**OQ-2.** §3.4 — 现在引入 `Ezagent.URI.with_action(uri, behavior, action)` 完全消除 `URI.new!/1` carve-out?当前选择:推迟。

**OQ-3.** §5.1 — 不变量测试依赖正则。注释检测启发式是否够稳健?当前选择:正则 + `# uri-canonical-allow` 抑制注释。

**OQ-4.** §9.2 — reconcile-on-load 还是强制 snapshot 重写?当前选择:reconcile-on-load 足够。Codex 可能挑战;§11 Q4 标记。

**OQ-5.** §4.4 — 测试 fixture 扫除是否在范围内?当前选择:**不** (单独跟进)。

---

## 11. Codex adversarial review 问题

调度 `codex:codex-rescue` 时明确问:

**Q1 (根因).** 选项 D 是否真正解决根因,还是转移它?具体:`URI.new!/1` 在两个 carve-out 中允许 (§3.4 query-target, §3.5 编译时常量),是否保留一个更小但相似的 bug 类?(预期答案:§5.2 通过正则捕获;用三个对抗示例手动验证。)

**Q2 (枚举完整性).** SPEC 是否枚举**所有** `URI.parse/1` 和 `URI.new!/1` 生产调用点?Codex 应针对 §4.1 阶段顺序 grep 仓库找出遗漏。特别检查 `apps/ezagent_domain_external_mirror/` 和 `apps/ezagent_plugin_*/` SPEC 草绘"约 30 个站点"而非枚举的。

**Q3 (不变量测试).** §5 不变量测试是否捕获部分迁移 (95% 用规范但 1 个边界跳过)?具体:
  - 若贡献者向 `apps/ezagent_plugin_feishu/lib/foo.ex` 添加 `URI.parse("entity://...")`,§5.1 是否捕获?(预期是。)
  - 若贡献者向 `apps/ezagent_domain_chat/lib/bar.ex` 添加 `URI.new!("entity://user/system/admin")` (**不在** `?action=` 形式中,**不是**模块属性),§5.2 是否捕获?(预期是。)
  - 若贡献者添加 `URI.new("entity://...")` (注:**非**-bang 变体,返回 `{:ok, _}`),§5 测试是否捕获?(预期**否** — 这是缺口。Codex 应标记。)

**Q4 (snapshot 跨版本).** §9.2 描述 `Kind.Snapshot.reconcile_after_load_behaviors/3` 中的 reconcile-on-load 步骤。是否足够?具体:
  - 若 Kind 已 live 数周无 slice-change (cold-but-alive),其进程内状态仍有 SPEC 前 URI。这是否要紧?(Kind 通过 `Ezagent.URI.instance/1` 构造 needed-cap,其输出规范 — 所以仅对 slice 内 state-state 比较要紧。枚举哪些 Behavior 做 state-state URI `==` 比较。)
  - `:erlang.binary_to_term` 在从不同 Elixir 版本序列化的 `%URI{}` 上是否保留 `:authority` 字段?(跨 OTP 风险。Codex 应验证。)

**Q5 (`URI.to_string` 字节 parity).** §9.1 断言 `URI.to_string/1` 对相同规范字符串的 `URI.parse`-built 和 `URI.new!`-built 产生字节相同输出。验证:
  - 对 `entity://user/system/admin`:两种形式 `to_string` 到 `"entity://user/system/admin"`。
  - 边缘:嵌入 `?action=...` 查询的 URI — `URI.to_string` 可能排序或重新编码查询。验证字节相同。
  - 边缘:`%` 编码路径段。验证字节相同。
  - **若任何 URI 形式在两个构造器间序列化为不同字符串,本 SPEC 的"无 DB 迁移"断言失败,impl PR 需要强制 snapshot/DB 重写步骤。**

**Q6 (并发 SPEC).** §8 断言与 cap-action-axis (#410) 和 workspace-cap-visibility (#423) 独立。验证:三个 SPEC 是否有共享代码路径且合并顺序要紧?

**Q7 (plugin 契约).** §6 声称 plugin 作者无需知道 URI quirk。验证:跟随"添加新 Behavior" recipe 的贡献者是否自然写出规范代码,还是 recipe 需明确说明?

**Q8 (let-it-crash 合规).** §3.3 B5 外部 payload 解析将 `Ezagent.URI.parse!/1` 包在 try/rescue 中。这是 let-it-crash 违规吗?(辩护:按 Invariant #9,入站传输**必须**将畸形输入转换为用户可见的错误反应。rescue 是结构化翻译,不是 workaround。)

原文子代理约束:**"Do NOT run mix test, mix compile, mix deps.get, or any mix command. Static analysis only."**

---

## 12. 回滚计划

若 impl PR 落地并引起生产回归:

**步骤 1.** 还原 impl PR。持久化数据字节相同 (§9.1),所以还原内存结构形状不会让任何 DB 行搁浅。

**步骤 2.** 恢复 `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` 的手写往返。Bug 2 回归。

**步骤 3.** 临时删除不变量测试。代码库回归到 SPEC 前状态。

**步骤 4.** 提交带回归重现的跟进 issue。重新规范。

**验收:** 还原是机械的 (单次 git revert + 删除不变量测试文件)。无数据迁移要撤销。无外部 API 更改要与操作员协调。

---

## 附录 A — 调用站点枚举 (生产 lib/,总计约 226)

(Codex Q2 挑战目标 — 验证穷尽性。)

(详细列表见英文版 §Appendix A — 内容相同,此处略以避免重复。)

---

## 附录 B — 不变量测试伪代码

(详细列表见英文版 §Appendix B — 内容相同,此处略以避免重复。)
