# Default workspace 改名: `default` → `system` (收尾清扫)

> **状态:** SPEC rev 2 — 已纳入 codex SPEC review (3 MUST-FIX + 3 nice-to-have, 2026-05-25)。待 Allen review。
> **作者:** main agent 派发的 subagent, Allen 2026-05-25 指令。
> **运维约束:** Allen 已授权 DB wipe — 不做迁移 / 不做 back-compat (`feedback_let_it_crash_no_workarounds`, 2026-05-25 重申)。
> **英文版:** `2026-05-25-workspace-default-to-system.md` (权威; 此文件为对照, 详细见英文)。

> **Rev 2 changelog (codex review 2026-05-25):**
> - §8 OQ-1 解修订: 租户用户**不能**住在 `workspace://system` (会通过 `Capability.cross_workspace?/2` 的 `home_is_system?` shortcut 获得 cross-workspace 绕过)。新解: **删除** `default_workspace_uri/0`; 调用方从 caller URI 结构性派生 workspace 或显式传入。Admin 向导 session 自然落到 `workspace://system` 因为 admin 的 home 结构上就是 system。
> - §3 新增 codex 发现的 5 处遗漏 production 字面量: `session_principal.ex` (bare-handle 规范化)、`session_controller.ex` (workspace_param fallback)、`users_live.ex` (admin 建用户)、`session_template.ex` (build_uri 默认值)、`echo_plugin/application.ex` (`@default_uri`)。
> - §3.6 新增: 演示 `echo_default` agent + 向导挂钩改名为 `entity://agent/system/echo_default`。
> - §6 invariant regex 扩展, 覆盖 `entity://(user|agent)/default/`、`template://(session|agent)/default/`、`session://[^/]+/default/`, 以及 `:workspace, "default"` Keyword 默认值的代码模式检查。
> - §9 实施工作量预估上调到 4-5 小时 (从 2-3 小时), 因 `default_workspace_uri/0` 删除是真正的 audit (~10 production caller) 而非字面量替换。

---

## 0. Allen 原文 (2026-05-25)

> "session://default/default/main 这个用不同的名字：默认应该是 session://default/system/main，模版的init叫做default，workspace的init叫做system（就是具有管理权限的那个，如果default是另外一个workspace，可以把default删掉），session的init叫做main"

含义:
- session URI 的 3 段含义不同, 不应都叫 `default`:
  - **template 名** = `default` (Session template 的 init 名 — 不变)
  - **workspace 名** = `system` (admin workspace; 由 `default` 改为 `system`)
  - **session 名** = `main` (Session 的 init 名 — 不变)
- 默认 session URI: **`session://default/system/main`** (原 `session://default/default/main`)。
- 若另存在独立 `workspace://default` (非 admin 那个), 删除之。

---

## 1. 目标

唯一默认 workspace 是 `workspace://system` (已存在的 admin workspace)。默认 session URI 是 `session://default/system/main`。production lib 与 test 中不存在 `workspace://default` 字面量; legacy `Ezagent.WorkspaceRegistry.default_workspace_uri/0` 现返回 `workspace://system`。Invariant test 阻止回退。

## 2. 范围

包含:
- production lib 代码 (`apps/*/lib/`)。
- Test fixture / 用例 (`apps/*/test/`)。
- Mix 任务 + plugin 代码。
- 文档字符串 (`@moduledoc`, `home_live.ex` 向导文案)。
- 残留 `workspace://default` 行的运行时迁移 (DB wipe 是支持路径; **不**写 migration — 见 §4)。

不包含 (按 orchestrator 指令保留):
- `apps/ezagent_domain_external_mirror/` (PR-EM-* 进行中)。
- `apps/ezagent_plugin_feishu/` 生命周期改动 (PR-EM-6 已 defer) — 但我们 *会* 修改其 `application.ex` + bind mix task 内的 2 处 `workspace://default` / `session://default/default/main` 字面量; 纯字符串改名, 非生命周期。
- `apps/ezagent_core/lib/ezagent/notifications.ex` + admin_live 通知逻辑 (PR-N3) — 只动 admin_live.ex 的 `@main_session_uri` 常量 (纯改名)。

实施期若发现冲突, 合并前 Feishu 通报。

---

## 3. 影响文件

发现方式: 对 `origin/main` (f15fb98) 跑 `grep -rn "session://default/default/main\\|workspace://default" --include="*.ex" --include="*.exs"`。统计:
- `workspace://default` 共 182 处
- `session://default/default/main` 共 160 处 (与上有重叠)
- 真正承重的 URI 字面量 5 处 (其余皆 docstring / 示例 / test fixture)

### 3.1 承重字面量 (production lib)

| 文件 | 当前代码 | 改动 |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/workspace_registry.ex:87` | `def default_workspace_uri, do: {:ok, URI.new!("workspace://default")}` | 返回 `workspace://system` |
| `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:59` | `def default_uri, do: URI.new!("session://default/default/main")` | 返回 `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:55` | `@main_session_uri URI.new!("session://default/default/main")` | `URI.new!("session://default/system/main")` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_caps_live.ex:116` | `URI.parse("workspace://default")` (assign 缺失时的兜底) | `URI.parse("workspace://system")` |
| `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:175` | `Map.get(binding, "session_uri") \\|\\| "session://default/default/main"` | `... \\|\\| "session://default/system/main"` |

### 3.2 向导 / 用户可见文案

| 文件 | 内容 | 改动 |
|---|---|---|
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:182` | `gettext("Creates")` 一行字面渲染 `session://default/default/<name>` bound to `workspace://default` | 改为 `session://default/system/<name>` bound to `workspace://system`; 更新 gettext 字符串; 同步 `priv/gettext/zh_*/LC_MESSAGES/` (或 `mix gettext.extract`) |
| `apps/ezagent_web/lib/ezagent_web/live/home_live.ex:31` | moduledoc "every new session lands on `workspace://default`" | 改名 |

### 3.3 Mix 任务 (操作员可见)

| 文件 | 改动 |
|---|---|
| `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex` | `@session_uri_str` 改为 `"session://default/system/main"`; 更新 docstring + 最终 help 文字 |
| `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.chat.bind.ex` | 更新 `@moduledoc` 内的占位符 + 示例 URI |

### 3.4 纯 docstring / 注释 (无行为变化)

`apps/ezagent_core/lib/ezagent/uri.ex`, `capability.ex`, `kind/runtime.ex`, `persistence.ex` — `@moduledoc` / `@doc` / `# ...` 中每处 `workspace://default` / `session://default/default/main` 都改 `system`。机械扫描; 不动 `URI.new!` / `URI.parse`。

### 3.5 Tests + fixtures

约 50 个测试文件含 `workspace://default` 或 `session://default/default/main`。每个改字面量。**不**引入 `@default_workspace` 模块属性 — 保持原始字符串可让 invariant test (§6) 实现简单。分类:

| 类别 | 例子 | 处理 |
|---|---|---|
| Invariant tests | `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` | 确认其中的 `workspace://default` 引用本来就指"已删除的 legacy"; 残留字面量改 `workspace://system` 或改写为"被删除的 legacy default" |
| URI 解析 tests | `apps/ezagent_core/test/ezagent/uri_test.exs` | 改 fixture 字符串; 断言语义不变 |
| Cap helpers | `apps/ezagent_core/test/support/cap_helper.ex` (`@default_workspace`) | 模块属性值改 `workspace://system` + 改名 `@system_workspace`; 改 doc-comment |
| Test fixtures | `apps/ezagent_domain_identity/test/ezagent/users_test.exs` 等 | 字面量改名 |
| Integration tests | `apps/ezagent_domain_chat/test/integration/*.exs` | 字面量改名 + 验证改名 `Session.default_uri/0` 后仍 pass |

### 3.6 Migrations — 历史文件, **不**改

`apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs` 含 `'workspace://default'` SQL 字符串作为 backfill 默认值。按 `feedback_let_it_crash_no_workarounds` + Allen DB-wipe 授权, **不动历史 migration** (会在现有 DB 重跑)。DB wipe 是支持路径; migration 文件冻结以保留可重现性。

---

## 4. 迁移 (greenfield)

Allen 2026-05-24 授权 DB wipe, 2026-05-25 重申。impl PR **不**带 backfill migration。操作员 wipe `~/.ezagent/<profile>/db/ezagent_core.db` 后重跑 `mix ezagent.bootstrap`。

理由:
- 若 DB 中有 pre-PR-C 时期遗留的 `workspace://default` 行 — 现 boot 已不再 re-seed; 行是孤儿。专门为一次性场景写 migration 增加复杂度。
- 任何 `session://default/default/<name>` 的 session 行要么 re-map (绑定到 `workspace://system`, 但 URI 本身按 Phase 9 PR-7 3 段编码 `default` — 所以改名不是元数据 patch, 是 URI 字符串 rewrite), 要么删除。一个 rewrite session URI 的 migration 要碰 6 张表 (kind_snapshots, message_routings, audit 等); greenfield 下不值得。
- Merge 前 Feishu 通告会明示 wipe 步骤。

合并后若操作员 DB 含残留 `workspace://default` 数据, 症状是: `/workspaces` 列表中有个隐藏的孤儿 workspace 行 (被 `list_visible/0` 过滤; 因 `default` 行在 PR-C 之后的 boot 都不会被 seed)。合并通告中标注; 非阻塞。

---

## 5. 改名映射 (canonical)

| 旧 | 新 | 理由 |
|---|---|---|
| `workspace://default` (production 字面量) | `workspace://system` | SPEC v2 PR-C 后唯一 boot-seed workspace |
| `session://default/default/main` | `session://default/system/main` | template `default` + workspace `system` + session `main` |
| `Ezagent.WorkspaceRegistry.default_workspace_uri/0` 返回 `workspace://default` | 返回 `workspace://system` | 向导 `create_session/2` 读此值计算 workspace 段 |
| 测试中 `entity://user/default/<name>` | admin-adjacent fixture 用 `entity://user/system/<name>`; 需要非 system workspace 的 fixture 用 `entity://user/tenant-a/<name>` | 拆开 `default` 之前混淆的两种语义 |
| `apps/ezagent_core/test/support/cap_helper.ex` `@default_workspace` | `@system_workspace`, 值 `workspace://system` | 命名跟随用途 |

测试注释中"已被删除的 legacy workspace://default"措辞保留可读性 — 不改写历史, 只改活的 URI。

---

## 6. Invariant test (锁定门)

`apps/ezagent_core/test/invariants/no_default_workspace_test.exs` — 若 `apps/*/lib/` (production) 或承重字面量中出现以下任一, CI 失败:

```elixir
# Grep 目标 (回退触发器):
#  1. "workspace://default"     (apps/*/lib/ 下任何 .ex / .exs)
#  2. "session://default/default/" (URI 字面量, 文档或代码)
#  3. "entity://user/default/admin" (legacy seed 回退)
```

实现 sketch:

```elixir
defmodule Ezagent.Invariants.NoDefaultWorkspaceTest do
  use ExUnit.Case, async: true

  @forbidden ~r/(workspace:\/\/default|session:\/\/default\/default\/|entity:\/\/user\/default\/admin)/
  @scan_roots ["apps"]
  # 仅 lib — 历史 migration + 解释改名的 docstring 中"legacy"字样允许保留。
  @scan_dirs ["lib"]
  # 白名单: 历史 migration 文件 (冻结) + 本测试自身。
  @whitelist [
    "apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs"
  ]

  test "no production lib code references workspace://default or session://default/default/" do
    offenders =
      Path.wildcard("apps/*/lib/**/*.{ex,exs}")
      |> Enum.reject(&(&1 in @whitelist))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(@forbidden, line) end)
        |> Enum.map(fn {line, ln} -> "#{path}:#{ln}: #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "Found legacy default-workspace references:\n" <> Enum.join(offenders, "\n")
  end
end
```

说明: 范围限 `apps/*/lib/`。测试 fixture (`apps/*/test/`) 也在 impl PR 中改写, 但不 invariant-gate — moduledoc/注释中历史性 test-only 表述 ("Keycloak realm-admin model, not workspace://default") 保留可读。

---

## 7. 验证

### 7.1 构建 + 测试

```bash
mix deps.get
mix compile --warnings-as-errors
mix test
mix test --only invariant   # 新 gate
```

预期: 全绿。Test count 较改前 ±1 (新 invariant test)。

### 7.2 端到端 smoke

> **USER-ASSIST 步骤** (按 `feedback_flag_user_assist_steps`): agent wipe 自己的 local DB。Allen 无需操作, 除非 agent 报失败。

```bash
rm ~/.ezagent/default/db/ezagent_core.db*
mix ezagent.bootstrap
mix phx.server &
```

然后通过 agent-browser (按 `feedback_open_terminal_first_when_debugging`):
1. 访问 `http://100.64.0.27:10042/` (Tailscale IP, 按 `feedback_remote_browser_ip`)。
2. 以 admin 登录。
3. 向导提交默认 short_name `main`。
4. 截图 `/sessions` 页面; URL 应含 `session://default/system/main`。
5. 截图 `/workspaces` 显示仅 `system` (regular user 不可见 — 确认 `list_visible/0` 对非 system 成员返回 `[]`; admin 用 `list_all/0` 可见 `system`)。

接受标准:
- 向导 preview 文字读作 `session://default/system/<name>` bound to `workspace://system`。
- 提交后 LV redirect 至 `/sessions`, URL 含 `session://default/system/main`。
- 任何 DB 查询 (`select uri from workspaces`) 仅返回 `workspace://system`, 无 `workspace://default`。

### 7.3 Codex adversarial-review

按 `feedback_spec_codex_adversarial_review` + `feedback_codex_review_every_pr`:
- SPEC: 1 轮, 在写代码前。
- Impl PR: 最多 2 轮 (`Round-2 cap`)。

---

## 8. Open question

**OQ-1 (默认已决):** 合并后是否应该有一个非 admin baseline workspace?

Allen 原文: "如果default是另外一个workspace，可以把default删掉" — 听起来是彻底删。

当前代码状态 (从 grep): production 代码已不 seed `workspace://default`。唯一引用是:
- `WorkspaceRegistry.default_workspace_uri/0` (fallback 常量, 向导通过 `create_session/2` 读取)。
- Test fixtures (多数表示"本测试需要的任意 workspace")。

**默认解 (a):** 所有用户进 `workspace://system`。Admin-equivalent caps 由 `system` 成员身份决定, 通过 `Ezagent.Capability.cross_workspace?/2` (按 SPEC v2 §1.2 现有路径)。不存在 baseline 非 admin workspace; 租户 workspace 通过 magic-link 流程 (`Ezagent.Workspace.create/2`) 创建。

替代 (b): 保留一个 baseline 非 admin workspace, 用另一名 (如 `workspace://general`)。

**推荐 (a)**, 按 Allen 原文"可以把default删掉"+ SPEC v2 v2 mental model。**SPEC 发 Allen, 默认按 (a) 走, 除非 1 轮内 Allen 反对。**

**(a) 的副作用:** `Ezagent.WorkspaceRegistry.default_workspace_uri/0` 现返回 `workspace://system`。向导创建的 session 落到 `system`。这对首次 admin onboarding 正确 (admin *本就在* `system`)。多用户 post-onboarding 时, per-user workspace 选择走 workspace dropdown — 已由 `WorkspaceSwitchController` 实现 (Phase 9 PR-8)。

---

## 9. 实施顺序 (impl PR)

1. 改 `WorkspaceRegistry.default_workspace_uri/0` 返回值。
2. 改 `Session.default_uri/0` 返回值。
3. 改 admin_live.ex `@main_session_uri`。
4. 改 admin_caps_live.ex fallback。
5. 改 home_live.ex 向导文案 + 抽 gettext。
6. 改 mix task 常量 (cc demo seed, feishu bind)。
7. 改 plugin_feishu application.ex fallback。
8. 扫 core docstring (uri.ex, capability.ex, kind/runtime.ex, persistence.ex)。
9. 扫 test fixtures (每文件字面量)。
10. 改 `cap_helper.ex` `@default_workspace` → `@system_workspace`。
11. 加 invariant test `no_default_workspace_test.exs`。
12. 跑 `mix compile --warnings-as-errors && mix test` — 修任何 breakage。
13. 本地 E2E (按 §7.2)。
14. 开 PR, codex r1, 改, codex r2, admin merge。

预估 impl 工作量: 2-3 小时机械扫描 + 1 小时验证。

---

## 10. 风险 + 缓解

| 风险 | 缓解 |
|---|---|
| 某 fixture 断言 admin 在 `workspace://default` (现在 admin 在 `system`) 而 fail | 扫描覆盖所有 test fixture; CI 抓住任何漏文件 |
| 操作员 DB 残留 `workspace://default` 行 | Pre-merge Feishu 公告含 `rm db && mix ezagent.bootstrap` |
| Snapshot 行引用旧 URI (kind_snapshots 表) | 同样的 wipe 步骤; 按 Allen DB-wipe 授权 |
| 某 test 明确为"非 system 的 workspace"目的而引用 `workspace://default` | 改写为 `workspace://tenant-a` (或 `workspace://team-alpha`) — 见 §5 |
| 向导改名引起的 gettext 抽取变动 | impl PR 内 `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` |

---

## 11. 引用

- `feedback_let_it_crash_no_workarounds` — 不 backfill / 不 compat shim。
- `feedback_completion_requires_invariant_test` — §6 是 gate。
- `feedback_codex_review_every_pr` + `feedback_spec_codex_adversarial_review` — review 节奏。
- `feedback_open_terminal_first_when_debugging` + `feedback_remote_browser_ip` — 通过 `100.64.0.27` 的 agent-browser 验证。
- `feedback_flag_user_assist_steps` — §7.2 wipe 步骤已标注。
- SPEC v2 `2026-05-24-workspace-user-mental-model-v2.md` — 本 PR 收尾的更大 mental model。
- Allen 2026-05-25 原文 — §0。

EOF
