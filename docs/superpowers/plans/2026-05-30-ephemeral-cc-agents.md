# 临时 cc agent 不累积(Approach A)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 customer-chat 的 per-conversation cc 回复 agent 在创建后从 `workspaces.session_templates` 注销,使其不再于 server boot 时被重放(消除 boot 风暴),同时提供一个幂等清扫 mix task 清除已累积的 cruft。

**Architecture:** 纯插件层改动。`ensure_cc_agent` 在 `Ezagent.Workspace.create_agent` 成功后调用既有公开 API `Ezagent.Workspace.remove_template/2` 注销刚注册的临时模板(只删 boot 恢复用的注册,不杀运行中的 Kind)。清扫逻辑放进可单测的纯函数 + 一个薄 mix task。不改 core/domain 运行时代码。

**Tech Stack:** Elixir / OTP umbrella;`Ezagent.Workspace`(domain facade)、`Ezagent.Workspace.Store`、`Ezagent.Ecto.KindSnapshot`(Ecto schema)、ExUnit。

**Spec:** `docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md`

**前置:** 在分支 `poc/phase-2-customer-service` 上工作。本机 server 命令见 `CLAUDE.local.md`。跑该 app 测试:`mix cmd --app ezagent_plugin_customer_chat mix test`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex` | 运行期:创建 cc agent 后注销其临时模板 | 修改 `ensure_cc_agent`,新增 `ephemeral_template_name/1`(`@doc false def`)+ `deregister_ephemeral/2`(`defp`) |
| `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/ephemeral_gc.ex` | 清扫逻辑:纯过滤函数 + run/0(Store+Repo IO) | 新建 |
| `apps/ezagent_plugin_customer_chat/lib/mix/tasks/ezagent.customer_chat.gc_ephemeral.ex` | 薄 mix task,委托给 EphemeralGc.run/0 | 新建 |
| `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs` | `ephemeral_template_name/1` 纯单测 | 修改(追加) |
| `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/ephemeral_gc_test.exs` | `EphemeralGc.ephemeral_keys/1` 纯单测 | 新建 |
| `docs/notes/2026-05-30-ephemeral-agents-allen-note.md` | B 方案给 Allen 的 note | 新建 |
| `docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md` | 设计(已存在) | 验收后更新「已知遗留」 |

---

## Task 1: 运行期 deregister-after-create

**Files:**
- Modify: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex`(`ensure_cc_agent` ~line 144-166)
- Test: `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs`

- [ ] **Step 1: 写失败测试**(追加到 `bootstrap_test.exs` 末尾,`end` 前):

```elixir
  test "ephemeral_template_name derives the cc.agent key from the agent_uri (keeps the cc_ flavor prefix)" do
    uri = URI.parse("entity://agent/cinnox/cc_cust_abc123")
    assert Bootstrap.ephemeral_template_name(uri) == "cc.agent.cc_cust_abc123"
  end

  test "ephemeral_template_name handles a bare entity path" do
    uri = %URI{path: "/cc_cust_x"}
    assert Bootstrap.ephemeral_template_name(uri) == "cc.agent.cc_cust_x"
  end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mix cmd --app ezagent_plugin_customer_chat mix test test/ezagent_plugin_customer_chat/bootstrap_test.exs`
Expected: FAIL — `function EzagentPluginCustomerChat.Bootstrap.ephemeral_template_name/1 is undefined`

- [ ] **Step 3: 实现 `ephemeral_template_name/1` + `deregister_ephemeral/2` 并接入 `ensure_cc_agent`**

在 `bootstrap.ex` 把现有 `ensure_cc_agent/5` 整体替换为:

```elixir
  defp ensure_cc_agent(workspace, agent_name, cwd, soul_path, ctx) do
    ws_uri = URI.parse("workspace://#{workspace}")
    args = %{flavor: "cc", name: agent_name, cwd: cwd, with_pty: true}
    args = if soul_path, do: Map.put(args, :soul_path, soul_path), else: args

    result =
      case Ezagent.Workspace.create_agent(ws_uri, args, ctx) do
        {:ok, %{agent_uri: u}} ->
          {:ok, u}

        {:error, {:already_exists, u_str}} when is_binary(u_str) ->
          {:ok, URI.parse(u_str)}

        {:error, {:already_exists, %URI{} = u}} ->
          {:ok, u}

        {:error, reason} ->
          Logger.warning(
            "customer_chat ensure_cc_agent(#{workspace}, #{agent_name}) failed: #{inspect(reason)}"
          )

          {:error, reason}
      end

    # Per-conversation cc agents are EPHEMERAL: customer-chat re-creates
    # them on demand every time a conversation opens (static-soul model).
    # `create_agent` unconditionally registers a `cc.agent.<name>` spawn
    # template in `workspaces.session_templates`, which the boot loader
    # replays — so every conversation ever opened respawns its claude PTY
    # at boot ("boot storm" that saturates spawn capacity and blocks new
    # conversations). Deregister the template right after create:
    # `remove_template` only drops the boot-restore registration, it does
    # NOT terminate the running Kind, so the agent keeps serving this
    # conversation. Best-effort — a deregister failure only degrades to
    # the old (accumulating) behavior, never to a reply failure. See
    # docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md.
    case result do
      {:ok, agent_uri} ->
        deregister_ephemeral(workspace, agent_uri)
        {:ok, agent_uri}

      err ->
        err
    end
  end

  # Build the `session_templates` key `create_agent` registered for this
  # cc agent: `"cc.agent." <> <entity-name>`. The entity name is the LAST
  # path segment of the agent URI and INCLUDES the `cc_` flavor prefix
  # (e.g. `entity://agent/cinnox/cc_cust_abc` → `cc.agent.cc_cust_abc`),
  # so it must be derived from the returned `agent_uri`, not rebuilt from
  # the bare `agent_name` (`cust_abc`). Mirrors `agent_name/1` in
  # Ezagent.Behavior.Workspace.
  @doc false
  def ephemeral_template_name(%URI{path: "/" <> rest}) do
    entity =
      case String.split(rest, "/", parts: 2) do
        [_workspace, entity_name] -> entity_name
        [entity_name] -> entity_name
      end

    "cc.agent." <> entity
  end

  defp deregister_ephemeral(workspace, agent_uri) do
    tmpl_name = ephemeral_template_name(agent_uri)

    case Ezagent.Workspace.remove_template(workspace, tmpl_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "customer_chat deregister ephemeral template #{tmpl_name} failed: #{inspect(reason)}"
        )

        :ok
    end
  end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `mix cmd --app ezagent_plugin_customer_chat mix test test/ezagent_plugin_customer_chat/bootstrap_test.exs`
Expected: PASS(含原有 5 个 + 新增 2 个)

- [ ] **Step 5: 编译 + 跑全 app 测试套件(无回归)**

Run: `mix do --app ezagent_plugin_customer_chat compile && mix cmd --app ezagent_plugin_customer_chat mix test`
Expected: 编译 exit 0;全部测试 PASS(应为 26 tests, 0 failures)

- [ ] **Step 6: 提交**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/bootstrap.ex \
        apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/bootstrap_test.exs
git commit -m "fix(customer-chat): deregister ephemeral per-conv cc agent template after create

Per-conversation cc agents are recreated on demand; their unconditional
cc.agent.<name> registration in workspaces.session_templates made the
boot loader respawn every conversation's claude PTY (boot storm). Call
Workspace.remove_template after create_agent — drops the boot-restore
registration without killing the running Kind. Best-effort.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 清扫 mix task + EphemeralGc 模块

**Files:**
- Create: `apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/ephemeral_gc.ex`
- Create: `apps/ezagent_plugin_customer_chat/lib/mix/tasks/ezagent.customer_chat.gc_ephemeral.ex`
- Test: `apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/ephemeral_gc_test.exs`

- [ ] **Step 1: 写失败测试**(新建 `ephemeral_gc_test.exs`):

```elixir
defmodule EzagentPluginCustomerChat.EphemeralGcTest do
  use ExUnit.Case, async: true
  alias EzagentPluginCustomerChat.EphemeralGc

  test "ephemeral_keys selects per-conversation cc_cust template keys only" do
    templates = %{
      "cc.agent.cc_cs_main" => %{},
      "cc.agent.cc_cust_abc" => %{},
      "cc.agent.cc_cust_xyz" => %{},
      "echo.agent.something" => %{}
    }

    assert EphemeralGc.ephemeral_keys(templates) |> Enum.sort() ==
             ["cc.agent.cc_cust_abc", "cc.agent.cc_cust_xyz"]
  end

  test "ephemeral_keys keeps provisioned + non-cc agents, returns [] when none match" do
    templates = %{"cc.agent.cc_cs_main" => %{}, "curl.agent.x" => %{}}
    assert EphemeralGc.ephemeral_keys(templates) == []
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `mix cmd --app ezagent_plugin_customer_chat mix test test/ezagent_plugin_customer_chat/ephemeral_gc_test.exs`
Expected: FAIL — `module EzagentPluginCustomerChat.EphemeralGc is not available`

- [ ] **Step 3: 实现 `EphemeralGc`**(新建 `ephemeral_gc.ex`):

```elixir
defmodule EzagentPluginCustomerChat.EphemeralGc do
  @moduledoc """
  One-time cleanup of accumulated EPHEMERAL customer-chat agents.

  Per-conversation cc agents (`cc_cust_*`) and per-session orchestrators
  (`cc_orchestrator-*`) used to register permanent `session_templates`
  entries + leave `kind_snapshots` rows that the boot loader replayed,
  spawning every one's claude PTY at boot (a "boot storm"). Task 1 stops
  NEW accumulation; this module clears what already accumulated.

  Run with the server STOPPED (it mutates the DB directly via Store +
  Repo; a running Workspace Kind would hold a stale in-memory slice).
  Idempotent: running twice is a no-op the second time.

  Scope: removes `cc.agent.cc_cust_*` template registrations and deletes
  `cc_cust_*` / `cc_orchestrator-*` / `session://.../...` snapshot rows.
  Preserves provisioned agents (e.g. `cc_cs_main`).
  """
  require Logger
  import Ecto.Query, only: [from: 2]

  @template_prefix "cc.agent.cc_cust_"

  # kind_snapshots URI LIKE-patterns to delete (ephemeral conversation state).
  @snapshot_like [
    "entity://agent/%/cc_cust_%",
    "entity://agent/%/cc_orchestrator-%",
    "session://%"
  ]

  @doc """
  Pure: given a workspace's `session_templates` map, return the keys that
  are ephemeral per-conversation cc agents (safe to drop).
  """
  @spec ephemeral_keys(map()) :: [String.t()]
  def ephemeral_keys(templates) when is_map(templates) do
    templates
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, @template_prefix))
  end

  @doc """
  Strip ephemeral template registrations from every workspace and delete
  orphaned ephemeral snapshot rows. Returns `{templates_removed, snapshots_removed}`.
  """
  @spec run() :: {non_neg_integer(), non_neg_integer()}
  def run do
    templates_removed = clean_templates()
    snapshots_removed = clean_snapshots()
    {templates_removed, snapshots_removed}
  end

  defp clean_templates do
    Ezagent.Workspace.Store.list_all()
    |> Enum.reduce(0, fn ws, acc ->
      keys = ephemeral_keys(ws.session_templates)

      if keys == [] do
        acc
      else
        kept = Map.drop(ws.session_templates, keys)
        {:ok, _} = Ezagent.Workspace.Store.update_templates(ws.name, kept)
        acc + length(keys)
      end
    end)
  end

  defp clean_snapshots do
    Enum.reduce(@snapshot_like, 0, fn pattern, acc ->
      {count, _} =
        EzagentCore.Repo.delete_all(
          from(k in Ezagent.Ecto.KindSnapshot, where: like(k.uri, ^pattern))
        )

      acc + count
    end)
  end
end
```

- [ ] **Step 4: 实现薄 mix task**(新建 `lib/mix/tasks/ezagent.customer_chat.gc_ephemeral.ex`):

```elixir
defmodule Mix.Tasks.Ezagent.CustomerChat.GcEphemeral do
  @shortdoc "Remove accumulated ephemeral customer-chat cc_cust_* agents (run with server STOPPED)"
  @moduledoc """
      mix ezagent.customer_chat.gc_ephemeral

  One-time cleanup of accumulated per-conversation cc agents that used to
  pile up in `workspaces.session_templates` + `kind_snapshots` and respawn
  at boot. Delegates to `EzagentPluginCustomerChat.EphemeralGc.run/0`.
  Run with the server STOPPED. Idempotent.

  NOTE: dev/PoC maintenance task (NOT a Category A audited operation —
  see the cli-gui-parity audit note on `ezagent.snapshot.clear`). The
  durable fix is the domain `ephemeral:` flag tracked for Allen in
  docs/notes/2026-05-30-ephemeral-agents-allen-note.md.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)

    {templates, snapshots} = EzagentPluginCustomerChat.EphemeralGc.run()

    Mix.shell().info(
      "✓ removed #{templates} ephemeral template registration(s), #{snapshots} snapshot row(s)"
    )
  end
end
```

- [ ] **Step 5: 跑纯单测确认通过 + 编译**

Run: `mix do --app ezagent_plugin_customer_chat compile && mix cmd --app ezagent_plugin_customer_chat mix test test/ezagent_plugin_customer_chat/ephemeral_gc_test.exs`
Expected: 编译 exit 0;2 tests PASS

- [ ] **Step 6: 跑全 app 测试套件**

Run: `mix cmd --app ezagent_plugin_customer_chat mix test`
Expected: 全部 PASS(28 tests, 0 failures)

- [ ] **Step 7: 提交**

```bash
git add apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/ephemeral_gc.ex \
        apps/ezagent_plugin_customer_chat/lib/mix/tasks/ezagent.customer_chat.gc_ephemeral.ex \
        apps/ezagent_plugin_customer_chat/test/ezagent_plugin_customer_chat/ephemeral_gc_test.exs
git commit -m "feat(customer-chat): gc_ephemeral mix task to clear accumulated cc_cust agents

Idempotent one-time cleanup (run with server stopped): strips
cc.agent.cc_cust_* from workspaces.session_templates and deletes
orphaned cc_cust_*/cc_orchestrator-*/session kind_snapshots. Pure
ephemeral_keys/1 unit-tested; IO wrapper verified empirically.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Allen note(B 方案,不实施)

**Files:**
- Create: `docs/notes/2026-05-30-ephemeral-agents-allen-note.md`

- [ ] **Step 1: 写 note**

```markdown
# Note for Allen: ephemeral agents shouldn't accumulate in session_templates

**Date:** 2026-05-30 · from the AutoService→ezagent customer-chat PoC.

## Problem
`Ezagent.Workspace.create_agent/3` for `flavor: "cc"` UNCONDITIONALLY
registers a `cc.agent.<name>` template in `workspaces.session_templates`
(behavior/workspace.ex:988, 1156-1170) and the boot loader replays every
entry (workspace/loader.ex:276-318). customer-chat spawns a per-CONVERSATION
cc agent per chat; these are ephemeral (recreated on demand) but their
permanent registration makes every conversation ever opened respawn its
claude PTY at boot — a "boot storm" that saturates spawn capacity and
blocks new conversations.

## PoC stopgap (shipped, plugin-local)
customer-chat now calls the existing `Workspace.remove_template/2` right
after `create_agent` to deregister its ephemeral cc_cust_* template
(commit on poc/phase-2-customer-service). Plus a `gc_ephemeral` mix task
for already-accumulated cruft. No core/domain change.

## Proposed durable fix (B) — your call
Add `ephemeral: true` (or `persist: false`) to `create_agent` args that
(a) skips `Store.update_templates` and (b) makes the loader skip it (or
the agent never enters session_templates). This is the same direction as:
- the G-12 deprecation already on `session_templates` (store.ex:16-30,
  "retire session_templates once add_template also writes a real Template
  Kind"), and
- curl/np flavors, which already spawn directly via SpawnRegistry with
  NO template registration.

Ephemeral per-conversation/per-session agents (cc_cust_*, the per-session
orchestrator) should travel that non-persistent path. This touches the
core agent-create contract + the invariant test
`agent_create_single_path_test.exs`, so it's an architecture decision for
you, not implementation-phase work.

## Also unaddressed by the stopgap
The per-session orchestrator (created by domain `create_session`) restores
via session snapshots, not session_templates, so the plugin stopgap does
not cover it. If it independently storms at boot it belongs in this same B.
```

- [ ] **Step 2: 提交**

```bash
git add docs/notes/2026-05-30-ephemeral-agents-allen-note.md
git commit -m "docs(note): for Allen — durable ephemeral-agent fix (B) beyond the PoC stopgap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Empirical 验收(手动,非自动化)

**前置:** 本机 server 已停。DB 在 `~/.ezagent/poc-phase2/db/ezagent_core.db`。

- [ ] **Step 1: 清扫旧 cruft 并确认**

```bash
cd /Users/daiming/workspace/ezagent42/ezagent
# server 必须是停的
lsof -tiTCP:10142 -sTCP:LISTEN | xargs -r kill -9
EZAGENT_PROFILE=poc-phase2 mix ezagent.customer_chat.gc_ephemeral
sqlite3 ~/.ezagent/poc-phase2/db/ezagent_core.db \
  "SELECT session_templates FROM workspaces WHERE name='cinnox';"
```
Expected: task 打印移除计数;查询结果只剩 `cc.agent.cc_cs_main`(无 `cc_cust_*`)。

- [ ] **Step 2: 启动 server,开 3 个会话**

启动命令见 `CLAUDE.local.md`。浏览器开 3 个不同 conv:
`http://127.0.0.1:10142/chat/cinnox?conv=gcA&cid=a`、`?conv=gcB&cid=b`、`?conv=gcC&cid=c`,各发一句、各收到回复(首次冷启动可能要刷新一次,见 CLAUDE.local.md)。

- [ ] **Step 3: 重启 server,验证 boot 不再风暴**

```bash
lsof -tiTCP:10142 -sTCP:LISTEN | xargs -r kill -9
for p in $(pgrep -f "poc-sandbox-phase2|cc-orchestrator/.claude|ezagent_mcp_bridge"); do kill -9 $p; done
# 重新启动 server(同启动命令),等 ~40s boot 完
sleep 40
pgrep -f "poc-sandbox-phase2.*esr-system" | wc -l
```
Expected: cc claude 进程数 **≤ 2**(仅 `cc_cs_main`,而非 ~10)。**关键断言:gcA/gcB/gcC 的 `cc_cust_*` 没有在 boot 时被重启。**
对照:`sqlite3 ... "SELECT uri FROM kind_snapshots WHERE uri LIKE '%cc_cust_gc%';"` 不应驱动 boot spawn。

- [ ] **Step 4: 重启后新会话仍正常**

浏览器开一个全新 conv `?conv=gcD&cid=d`,发一句,确认收到 AI 回复(证明 deregister 不影响按需重建)。

- [ ] **Step 5: 记录结果 + 更新 spec「已知遗留」**

把验收结果(boot agent 数、orchestrator 是否仍 spawn)记到 spec 末尾;若 orchestrator 仍在 boot spawn,在 Allen note 里标注「确认 orchestrator 也需 B」。

---

## Self-Review(写计划后自查)

- **Spec coverage:** 组件1 deregister → Task 1;组件2 gc task → Task 2;测试(纯单测)→ Task 1/2 的 Step 1;empirical 验收 → Task 4;B/Allen note → Task 3。已知遗留(orphan snapshots / orchestrator)→ gc task 清快照 + Task 4 Step 5 记录。✅ 全覆盖。
- **Placeholder scan:** 无 TBD/TODO;所有代码步骤含完整代码。✅
- **Type consistency:** `ephemeral_template_name/1`、`EphemeralGc.ephemeral_keys/1`、`EphemeralGc.run/0`、`Ezagent.Workspace.remove_template/2`、`Store.list_all/0`/`update_templates/2`、`Ezagent.Ecto.KindSnapshot`、`EzagentCore.Repo.delete_all` 命名前后一致。✅
- **已知风险:** `EphemeralGc.run/0`(Store+Repo IO)无快速单测(需 seed DB),靠 Task 4 empirical 兜底——纯过滤逻辑 `ephemeral_keys/1` 已单测,IO 包装薄。可接受。

---

## Execution Handoff(实施完成后)

完成后用 superpowers:verification-before-completion 跑全套验证,再决定合并/PR(参见用户「先落 poc 分支、暂不开 main PR」的偏好)。
