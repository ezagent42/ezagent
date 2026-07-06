# kanban 迁 socialware Definition Implementation Plan

> **实施对齐说明（2026-07-06 收口）**：本文档是开工时的 point-in-time 规划。实施与之的偏差以代码与 PR body 为准：①角色槽收敛为 2（kanban-assistant + dev-together），board=workspace 级 URI-dispatch actor 不进 roles（RF-6）；②pm-coordinator 更名 kanban-assistant；③gh 连接器整体退役（联通=agent 用 gh/git CLI 的行为，协议在 kanban-assistant skill 的 gh-protocol 模块）；④新增 boot-publish（Demo 照 #162 黄金样板）与 BoardView/KanbanRender view 声明侧。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 kanban 迁成一支可安装的 socialware team（`socialware:kanban-team`：**kanban-assistant + dev-together 两 agent 角色槽**预配 + **内容触发（legend/header）relay-back**），走 code-seed 发布，最小闭环 S1→S2→S3，Playwright 真浏览器 e2e 收口。**看板（`kanban-manager` × `native`）不进 Definition 成员**——它是 workspace 级被动 URI-dispatch 数据 actor（S2 建模修正，见下方 ⚠️），由 world/owner 建、pm 用 kanban action caps dispatch 驱动。

> ⚠️ **S2 建模修正（board 非成员，2026-07-06）**：早先草稿把 `kanban-manager` 当第三个 agent 角色槽塞进 `roles` = **建模 bug**。根因：看板 `passive: true`（`application.ex kanban_manager_recipe/0`），是 workspace 级被动数据 actor 按 `entity://<ws>/agent/<id>` dispatch，从来不是 session 成员；塞进角色槽 → materialize `session.join` 撞 RF-6 被动 join 门 `{:passive_actor_cannot_join, _}`（`session.ex:723`）。修正（自包含解法 a）：`roles` 只留 pm+dev（都 cc-headless 主动、过 join 门）；board 由 world/owner 经既有 `/plugins/kanban`（`KanbanActions.create_kanban` → `Workspace.create_agent`）建，pm 用既有 kanban action caps dispatch 到 board URI。全文「三角色槽」按此读作「两 agent 角色槽 + board 非成员」。

> ⚙️ **件①②③ 修订（2026-07-06，三件自包含重构）**：**件①** `pm-coordinator` → 看板助手（`kanban-assistant`）全套改名（旧名 → 新名：recipe slug / role_name / skill 目录 / persona；`__done__` 契约点不变）——本 plan 下方设计与代码片段的旧名 `pm-coordinator` / `pm_coordinator_recipe` / `pm_persona` 均已按新名校准，仅历史/决策段保留旧名作换轨记录。**件②** 删 GitHub 主动连接器（`sync_github` / `push_pr` / `sync_prs` / `save_github_creds` + `EzagentPluginKanban.Github`），保留节点 git 定位数据（`register_pr` / `attach_code_file` / `artifacts` / `set_board_config.github_repo`，纯数据）；action 数 24 → 20。**件③** 看板助手 skill `references/kanban-team-collaboration.md` §(d) 加「用现成 ezagent CLI 驱动板」教学（动作面 = `EzagentCli.Exec` / `Dispatch.run_action`，board URI 经 `AgentRecipeResolver.list_by_recipe("kanban-manager", ws)` 定位；禁改 esr-bridge / core / domain 基建）。

**Architecture:** kanban 插件 `roles/0` 补 `kanban-assistant`（cc-headless，persona skill 用 **skill-creator 规范新建**）+ `dev-together`（cc-headless，skill = **照抄** sw-kanban 现有 `.claude/skills/dev-together/` 全套）两个 recipe（S1，`roles/0` 三 recipe 含 kanban-manager 不变）；新模块 `EzagentPluginKanban.KanbanTeam` 声明 + code-seed `kanban-team` Definition（S2，仿 hello `seed_definition_if_absent`；用 role-slot #1180 的 `roles` 字段声明**两个** agent 角色槽 pm+dev，`agents`/`members` 已退休、owner 只准 `:installer`；board 非成员）；**relay-back 靠 `Definition.routing_rules`（内容触发 matcher `text_contains`/`mention`）+ `legends`（`@handle` → role_name member_set）+ 两个 role 的 skill 软协议表达（S3）——规则里零实例 URI，无 core/session 机制改动**。

> **口径校正（别把 routing 当工作流引擎）：pm↔dev 的真正配合是 dev-together skill 的 git-handoff 工作流（git + markdown + CI：pm 写 `handoffs/<task>.md` 含 DoD → dev `dive` 切 task 分支/TDD/PR → dev `return` 过 CI+rebase gate + DoD 对账 + 写 `returns/<task>.md`），不是 ezagent 消息路由。** §4 的 `routing_rules` **只把"dev 交活了"这条完成信号消息传输到 pm 角色**（等价于交活后 @ 一下 lead），不管分支/CI/DoD。工作流实体住在 dev-together skill（Task 1 照抄那份）。**两层分开**：能力技能（dev-together git-handoff 工作流，可移植、照抄）vs 协作协议（kanban-team 里 pm 怎么跟 dev 配合，pm skill 里独立一薄层）。见 spec §5.0。

> ✅ **relay-back 用内容协议、不用 sender-lock（本次关键决策）**：dev-together→pm 接力**不再**用 `{:from, <dev-URI>}` sender-lock + install-time `planned_agent_uri` URI 解析（旧 S3a 机制**已删**）。改成**内容触发（`{:text_contains, "__done__"}` 头 或 `{:mention, "<legend名>"}` 走 `message.legend_triggers` 符号名，`matcher.ex:52,142-152`）+ `{:role, "kanban-assistant"}` receiver（`receiver.ex:11`）+ skill 协议**。**根本收益 = 规则零实例 URI → 快照回 Definition 不撞 #1180 `reject_participant_instance_uris`（`definition.ex:82,323-366`）→ 「拉取→二次开发→再发布」round-trip 闭环。** sender-lock 会把 dev 的实例 URI 塞进活规则、快照回 Definition 时 read-back 即炸（static poisoned artifact），故弃用。**副作用：S3 无 `template_team` matcher 解析代码改动、无 #1180 落点冲突、无需 Allen re-verify 解析源。**

**Tech Stack:** Elixir/OTP 27 · Elixir 1.18（mise 隔离）· Phoenix（transport）· PostgreSQL @ docker `55432`（disposable 栈 `ezagent-pg-compat-audit-postgres`）· ExUnit · Playwright（真浏览器 e2e，dev server 10042）。

## Global Constraints

- **基准代码：** `upstream/main`（本 worktree `feat/sw-kanban` 代码字节一致）。
- **P14 — Dispatch is the only path between Kinds**：inbound 走 `Ezagent.Router.dispatch/1` / legacy `Ezagent.Invocation.dispatch/1`，禁 `PubSub.broadcast` 到 inbound topic。
- **零实例 URI 铁律（role-slot #1180 已落地，硬 enforce）**：Definition 用 `roles` 字段声明 agent 角色槽（`%{role_name, fill: :agent, recipe, flavor}` 全字符串）；`agents`/`members` 已退休，`Definition.new/1` fail-loud 拒它们（`definition.ex:313-318`）+ 拒 roles/routing_rules 里任何实例 URI（`definition.ex:323-366`）；**routing_rules 的 matcher 用内容触发（`text_contains`/`mention` legend 符号名，零 URI），receivers 用 role_name（→ `{:role,name}`）**；owner_policy 用 `%{type: :installer}`（`:fixed` 被拒）。**永不塞参与者实例 URI —— 这正是 relay-back 走内容协议而非 sender-lock 的原因（round-trip 安全）。**
- **发布走 code-seed**：`DefinitionRegistry.seed_definition_if_absent`（仿 hello `app.ex:238`），**不**打进插件包 manifest（`core/manifest.ex:174-186` 拒 `:socialware` seed 是 Allen 有意）。
- **dev-together skill = 照抄现有、原样搬**：以 sw-kanban 现有 `.claude/skills/dev-together/`（`SKILL.md` 204 行 + `commands/` + `references/` + `scripts/` + `hooks/`）为准，**逐个文件保留、不重写不裁剪**。
- **kanban-assistant skill = skill-creator 规范新建，协议必须独立成可切出 reference（spec §5.3 硬要求）**：`SKILL.md` 主体**只写 pm 通用协调能力** + 一行 `@references/kanban-team-collaboration.md`（**不内联协议**）；kanban-team 协作协议（9-棒环节、派活=写/审 handoff、收活=看 `returns/<task>.md`+CI、完成标记契约）**全部写进独立文件** `references/kanban-team-collaboration.md`，覆盖清单见 spec §5.5 矩阵。**这个 reference 是「可切出模块」**——将来 workflow 编排模块落地（§9 Q5，`feat/ezagent-scout`）整块上移，pm skill 回归纯能力，故必须物理独立、不与主体交织。可选配 `scripts/relay-signal-check.sh` 做契约点自检。
- **能力技能 vs 协作协议两层（spec §5.0 设计原则）**：dev-together = 可移植能力技能（**照抄、自身 skill 一字不改**）；它在 kanban-team 里的参与 = 一个**薄 overlay** `references/kanban-team-relay.md`（**只新增、指向 pm 那份同一协作协议**，不动原 8-command 主体）。**真缺口**：today **无**"per-socialware 常驻协议注入进 agent"的干净入口（常驻只有 socialware-无关的 `recipe.prompt`，`apps/ezagent_core/lib/ezagent/agent/recipe.ex`；`Definition.prompt_templates` 是 per-delivery 非常驻，`template_team.ex:203-211` + PR-4 transform `legend.ex:40`/`resolver.ex:172,251`）——协议 today 只能寄居 skill 的独立 reference。抽象缺口 flag 给 Allen（spec §8 迁移标注 + §9 Q5），**非本切片前置**。
- **routing vs 协议职责分离（spec §0.1）**：`Definition.routing_rules`/`legends` **只承担传输**（matcher + `{:role}` receiver 把完成信号投给 pm 角色，不懂时序/身份/工作流）；协作约定**全住协议 reference**。**唯一契约点**：完成标记字面（`__done__`）必须与 matcher `arg` 逐字一致。**别在 routing 里编码时序/身份判断**（那是把传输写成工作流引擎，sender-lock 即此越界，弃用）。
- **self-containment 铁律（对抗自查，spec §11）**：本切片**只准**动 `ezagent_plugin_kanban` 自己的代码/测试/skill 资产 + 纯配置（Definition/routing_rules/legends 走 code-seed），只经 domain **public API**（`seed_definition_if_absent`/`SessionViewRegistry.register`/`session.join`）交互。**禁碰** `ezagent_core`/`ezagent_domain_*`/别的 plugin/hello 的任何代码。**依赖方向**：kanban→domain 是允许箭头（kanban 有 `{:ezagent_domain_session, only: :test}` 等），domain→plugin 是层级违规——**引用 `EzagentPluginKanban.*` 的集成测试只能住 kanban test 树，绝不放 `apps/ezagent_domain_session/test/`**，`use EzagentCore.DataCase`（core DataCase 对下游可用）+ `setup` `Application.ensure_all_started(:ezagent_domain_session)`（既有模式 `role_native_create_test.exs:26,34-38`）。**T5(b) relay 硬锁要改 core matcher → 不可自包含 → 移平台 track，非本切片。**
- **不改 `ARCHITECTURE.md`**（Allen 维护）。
- **测试从 umbrella 根跑**：先 `docker start ezagent-pg-compat-audit-postgres` + `mise exec -- mix ecto.create && mise exec -- mix ecto.migrate`，再 `mise exec -- mix test apps/<app>/test/...`（绝不 per-app `cd`）。
- **e2e 硬纪律**：真浏览器 Playwright（dev server 10042、真登录、真点），每个有意义步骤截图；**禁止硬编码/stub 当 e2e**。
- **kanban action 单一真相源**：`Ezagent.ActionSet.Kanban.actions()`（现 24 个）——recipe 的 requested_caps 用 `for` 推导，不手抄。

---

## Task 1 (S1): kanban 插件补 kanban-assistant + dev-together 两个 recipe + skill

**Files:**
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（`roles/0` :64 + 新 `kanban_assistant_recipe/0` + `dev_together_recipe/0`）
- Create（skill-creator 新建，pm 通用能力）: `.claude/skills/kanban-assistant/SKILL.md`（主体只写通用协调能力 + **一行 `@references/kanban-team-collaboration.md`**，**不内联协议**）
- Create（**协议独立模块，可切出 —— spec §5.3**）: `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md`（kanban-team 全部协作协议：9-棒环节 + 派活/收活 + 完成标记契约。SKILL.md 只引不复述）
- Create（可选）: `.claude/skills/kanban-assistant/scripts/relay-signal-check.sh`（协议校验/信号脚本：断言完成标记字面 == Definition matcher `arg`，唯一契约点自检）
- Copy（照抄现有全套，一字不改）: sw-kanban 现有 `.claude/skills/dev-together/` → kanban 插件 skill 目录（原样保留每个文件）
- Create（**dev-together 薄 overlay，不改 dev-together 自身 skill —— spec §5.4**）: dev-together skill 目录下新增 `references/kanban-team-relay.md`（只指向 pm 的 `kanban-team-collaboration.md` + 复述完成标记契约；**不动原 8-command 主体**）
- Test: `apps/ezagent_plugin_kanban/test/kanban_role_test.exs`（现有，扩一个 describe）

**Interfaces:**
- Produces: `EzagentPluginKanban.Application.kanban_assistant_recipe/0 :: map()`（`%{name: "kanban-assistant", skills: ["kanban-assistant"], prompt: String.t(), behaviors: [], requested_caps: [%{behavior: Ezagent.ActionSet.Kanban, action: atom()}]}`）；`dev_together_recipe/0 :: map()`（同形，`name: "dev-together"`, `skills: ["dev-together"]`）；`roles/0` 返回 `[kanban_manager_recipe(), kanban_assistant_recipe(), dev_together_recipe()]`。boot 经 `Ezagent.Plugin.boot/1` 注册进 `Ezagent.Agent.RecipeRegistry`。
- Consumes（S2/S3）：`RecipeRegistry.lookup(ws, "kanban-assistant")` / `"dev-together"` 解析成功。

- [ ] **Step 1: Write the failing test**

在 `apps/ezagent_plugin_kanban/test/kanban_role_test.exs` 末尾加：

```elixir
describe "kanban-team roles (S1)" do
  test "roles/0 declares kanban-manager, kanban-assistant, and dev-together" do
    names = Enum.map(EzagentPluginKanban.Application.roles(), & &1.name)
    assert "kanban-manager" in names
    assert "kanban-assistant" in names
    assert "dev-together" in names
  end

  test "kanban_assistant_recipe requests a cap for every kanban action" do
    recipe = EzagentPluginKanban.Application.kanban_assistant_recipe()
    assert recipe.name == "kanban-assistant"
    assert recipe.skills == ["kanban-assistant"]
    assert is_binary(recipe.prompt) and recipe.prompt != ""

    requested_actions =
      Enum.map(recipe.requested_caps, fn %{action: a} -> a end) |> Enum.sort()

    assert requested_actions == Enum.sort(Ezagent.ActionSet.Kanban.actions())
    assert Enum.all?(recipe.requested_caps, &(&1.behavior == Ezagent.ActionSet.Kanban))
  end

  test "dev_together_recipe wires the dev-together skill" do
    recipe = EzagentPluginKanban.Application.dev_together_recipe()
    assert recipe.name == "dev-together"
    assert recipe.skills == ["dev-together"]
    assert is_binary(recipe.prompt) and recipe.prompt != ""
    assert Enum.all?(recipe.requested_caps, &(&1.behavior == Ezagent.ActionSet.Kanban))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_role_test.exs -o line`
Expected: FAIL — `function EzagentPluginKanban.Application.kanban_assistant_recipe/0 is undefined`

- [ ] **Step 3: Write minimal implementation**

在 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` 改 `roles/0`（:64）并加两个 recipe：

```elixir
@impl Ezagent.Plugin
def roles, do: [kanban_manager_recipe(), kanban_assistant_recipe(), dev_together_recipe()]

@pm_skill_ref "kanban-assistant"
@dev_together_skill_ref "dev-together"

@doc """
The `kanban-assistant` role recipe (S1) — a `cc-headless` (real-brain) coordinator
that turns an owner's intent into kanban board moves, assigns work to the
`dev-together` member, and receives dev-together's content-triggered relay-back
(a `__done__` header / `@完成回传` legend routes their message to this role). Its
`skills: ["kanban-assistant"]` persona (built with skill-creator, see spec §5.3) is
installed into the agent's `config_dir` by the cc `OrchestratorBootstrap` at
materialize. It requests a cap for EVERY kanban action (single source of truth =
`Ezagent.ActionSet.Kanban.actions/0`) so it can drive the board.
"""
@spec kanban_assistant_recipe() :: map()
def kanban_assistant_recipe do
  %{
    name: "kanban-assistant",
    skills: [@pm_skill_ref],
    prompt: kanban_assistant_persona(),
    behaviors: [],
    requested_caps: kanban_action_caps()
  }
end

@doc """
The `dev-together` role recipe (S1) — a `cc-headless` developer running the
copied dev-together daily-team-development skill (skills: ["dev-together"]). On
finishing a card it follows the kanban-team relay protocol: emit a `__done__`
header (or `@完成回传`) + the card + target stage; the kanban-team routing_rules
content-trigger that message back to `kanban-assistant`. Declared as a role slot;
the relay carries NO instance URI (role-slot #1180 — round-trip safe).
"""
@spec dev_together_recipe() :: map()
def dev_together_recipe do
  %{
    name: "dev-together",
    skills: [@dev_together_skill_ref],
    prompt: dev_together_persona(),
    behaviors: [],
    requested_caps: kanban_action_caps()
  }
end

# A cap-template for every kanban action (single source of truth).
defp kanban_action_caps do
  for action <- Ezagent.ActionSet.Kanban.actions() do
    %{behavior: Ezagent.ActionSet.Kanban, action: action}
  end
end

@spec kanban_assistant_persona() :: String.t()
defp kanban_assistant_persona do
  """
  # You are the kanban-team PM coordinator

  You run a product-development kanban board with a team. The board's stages are
  the 9-stage product-dev chain (positioning → metric → pain → anchor → ux →
  feature → issue → test → pr), owned by the `kanban-manager` member.

  - Turn the owner's request into board moves via the kanban tools (create a
    card, set its stage). NEVER ask a worker to compute routing.
  - Assign build work through the dev-together git-handoff workflow, NOT a raw
    @mention: write a markdown handoff (`handoffs/<task>.md`, with a DoD) for the
    `dev-together` member. They `dive` (task branch off main, TDD, PR), then
    `return` (CI green + rebased + a per-line DoD reconciliation in
    `returns/<task>.md`) and send a completion signal (`__done__` header or
    `@完成回传`). That signal message is routed to you — it just tells you the
    return is ready to review; it does NOT carry the branch/CI/DoD (those live in
    the return + the git workflow).
  - On the completion signal, review the dev's `returns/<task>.md` (DoD + CI +
    rebased), then advance the relevant card and tell the owner what changed. The
    `pr` stage is CI-gated.
  - Act ONLY within your own session and workspace.
  """
end

@spec dev_together_persona() :: String.t()
defp dev_together_persona do
  """
  # You are the kanban-team dev-together developer

  You run the dev-together git-handoff workflow (see the dev-together skill): you
  `dive` a handoff (task branch off main, TDD, PR into the task branch) and
  `return` it (CI green + rebased on main + a per-line DoD reconciliation in
  `returns/<task>.md`). THAT workflow is the real work — git + markdown + CI.
  When your return is ready, send a short completion signal (`__done__` header or
  `@完成回传`) + the card id + the target stage; that message is routed to the
  kanban-assistant so they know to review your return. Keep it concise. Stay inside
  your session and workspace.
  """
end
```

**创建 kanban-assistant skill（skill-creator 规范新建）—— 两层分开，协议独立成可切出 reference（spec §5.0/§5.3）**：

`SKILL.md` 主体**只写 pm 通用协调能力**，协议细节**不内联**，只用一行 `@reference` 引 `references/kanban-team-collaboration.md`：

```markdown
---
name: kanban-assistant
description: >-
  PM coordinator persona for a kanban-team socialware session — turn an owner's
  intent into kanban board moves, assign build work to the dev-together member,
  receive their relay-back, review and advance cards. Use inside a kanban-team
  session.
---

# kanban-assistant

You coordinate a product-development kanban board for a team. Your general
ability: read the owner's intent, break it into tasks, assign build work,
review returns against a DoD, advance the board, and report back to the owner.

Never ask a worker to compute routing. Express any multi-step flow as static
board state, never a computed next-hop. Stay inside your session and workspace.

## kanban-team collaboration protocol

The team-specific collaboration protocol (how you cooperate with the
`dev-together` member in THIS team) is a separate, extractable module — see
@references/kanban-team-collaboration.md. Do NOT duplicate it here.
```

**协议独立模块** `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md`（**这是「可切出模块」——spec §5.3；将来 workflow 编排模块落地整块上移，§9 Q5**）——按 spec §5.5 覆盖矩阵写全 (a)/(b)/(c)：

```markdown
# kanban-team collaboration protocol (extractable module)

> This file is a SELF-CONTAINED, team-specific collaboration protocol. It lives
> in the kanban-assistant skill for now only because the platform has no workflow-
> orchestration module yet. When that module lands (feat/ezagent-scout, spec §9
> Q5), MOVE THIS FILE WHOLESALE into it and the pm skill reverts to pure ability.
> Keep it physically separable — do not weave its details into SKILL.md.
>
> Routing vs protocol (spec §0.1): routing only transports the completion signal
> to the pm role; THIS file is the協作约定. The single contract point between
> them: the completion marker literal below MUST be byte-identical to the
> kanban-team Definition's routing_rules matcher `arg` (§4.2).

## (a) The board — 9-stage product-dev chain

Owned by the `kanban-manager` member. Stages, in order:
positioning → metric → pain → anchor → ux → feature → issue → test → pr.
`pr` is the CI-gated closing stage. Each card advances one stage at a time; a
stage's entry condition is that the prior stage's artifact exists.

## (b) Assigning work — the dev-together git-handoff workflow (NOT a raw @mention)

- The owner tells you what they want; translate it into board moves + a task.
- Assign build work by writing a markdown handoff (`handoffs/<task>.md`, with a
  DoD) for the `dev-together` member — the dev-together `handoff` artifact. You
  are NOT computing routing for a worker; you are producing a spec.
- dev-together then `dive`s (task branch off main, TDD, PR) and `return`s (CI
  green + rebased + per-line DoD reconciliation in `returns/<task>.md`) and sends
  a completion signal. **The completion marker is the `__done__` header (single
  contract point — must match the Definition matcher `arg`, §4.2).** That signal
  is routed to you by the kanban-team rules — it only tells you the return is
  ready to review; the branch / CI / DoD live in the return + git, not the message.

## (c) Reviewing + advancing

- On the completion signal: review the dev's `returns/<task>.md` (DoD reconciled,
  CI green, rebased), THEN advance the card via the kanban tools
  (`kanban.<action>`), and summarize the change to the owner.
- `pr` is CI-gated: only advance a card to `pr` once CI is green on the return.
```

**（可选）协议校验脚本** `.claude/skills/kanban-assistant/scripts/relay-signal-check.sh`——断言协议里的完成标记（`__done__`）与 `KanbanTeam.definition_body().routing_rules` 的 matcher `arg` 字面一致（唯一契约点自检，§4.2）。非必须，但让「协议 ↔ 传输对齐」可机器验。

**照抄 dev-together skill 全套**（原样 copy，不改一行）：

```bash
# 把 sw-kanban 现有 dev-together skill 全套搬进 kanban 插件的 skill 目录，
# 逐个文件保留：SKILL.md(204) + commands/{init,plan,handoff,dive,return,push,close,review}.md
#            + references/{handoff-standard,handoff-template}.md + scripts/{new_day,validate_skill,install_hooks}.sh
#            + hooks/handoff-deadline-reminder.sh
cp -r .claude/skills/dev-together <kanban 插件约定的 skill 资产目录>/dev-together
# 确认一字未改：
diff -r .claude/skills/dev-together <kanban 插件约定的 skill 资产目录>/dev-together   # 应无输出
```
> **落地注**：kanban 插件 skill 资产的确切安放目录按 cc `OrchestratorBootstrap` 解析根（`.claude/skills`，`orchestrator_bootstrap.ex:66`）对齐 —— 若 pm/dev-together skill 都从 repo 根 `.claude/skills/` 解析，则 dev-together 已在原位（无需 copy，只需 `dev_together_recipe` 引 `skills: ["dev-together"]`）；若插件要自带 skill 资产目录，则原样 copy 进去。**落地前 `grep -n "skills\b\|@skills_root\|config_dir/skills" apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex` 确认解析根，再决定 copy 与否。无论哪种，dev-together 那份内容一字不改。**

**新增 dev-together 薄 overlay（不改 dev-together 自身 skill —— spec §5.4）** `.claude/skills/dev-together/references/kanban-team-relay.md`：只指向 pm 的同一份协作协议 + 复述唯一契约点，**不动原 8-command 主体**：

```markdown
# kanban-team relay overlay (thin — points to the shared protocol)

When running as the `dev-together` member of a kanban-team, follow the shared
collaboration protocol: @../../kanban-assistant/references/kanban-team-collaboration.md

Your only team-specific addition: after a `return` (CI green + rebased + DoD
reconciled in `returns/<task>.md`), send a short completion signal — the
`__done__` header + card id + target stage. **The `__done__` marker MUST be
byte-identical to the kanban-team Definition's routing_rules matcher `arg`
(spec §4.2)** — that single line is the only contract between this protocol and
the routing transport. Nothing else about the dev-together workflow changes.
```

> **可切出保证**：pm 的 `kanban-team-collaboration.md` 是唯一权威协议源；pm SKILL.md 与本 overlay 都只 `@reference` 指过去。协议整块上移到 workflow 编排模块时（§9 Q5），删这两个 overlay 即可，两个 skill 回归纯能力、零残留。

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_role_test.exs -o line`
Expected: PASS（含现有 kanban-manager 测试 + 新 pm/dev-together describe）

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex \
        apps/ezagent_plugin_kanban/test/kanban_role_test.exs \
        .claude/skills/kanban-assistant/ \
        .claude/skills/dev-together/references/kanban-team-relay.md \
        <kanban 插件 skill 资产目录>/dev-together/  # 若采 copy 方案
git commit -m "feat(kanban): S1 — kanban-assistant (skill-creator, protocol as extractable reference) + dev-together (copied) recipes in roles/0

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2 (S2): kanban-team Definition（两 agent 角色槽 pm+dev；board 非成员）+ code-seed + conformance + round-trip gate

**Files:**
- Create: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex`
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（`start/2` :32 加 env-gated seed）
- Test: `apps/ezagent_plugin_kanban/test/kanban_team_test.exs`（新）

**Interfaces:**
- Consumes: `EzagentPluginKanban.Application.kanban_assistant_recipe/0` + `dev_together_recipe/0`（Task 1）；`Ezagent.Socialware.DefinitionRegistry.seed_definition_if_absent/2`（`app.ex:238` 先例）；`Ezagent.Socialware.Definition.new/1`（`definition.ex:77`）。
- Produces: `EzagentPluginKanban.KanbanTeam.definition_body/0 :: map()`；`seed_definition/1 :: {:ok, term()} | {:error, term()}`（`ws \\ Ezagent.URI.workspace(:system)`）。这个 body 是 S3 追加 routing_rules + legends 的地方。

- [ ] **Step 1: Write the failing test**

`apps/ezagent_plugin_kanban/test/kanban_team_test.exs`：

```elixir
defmodule EzagentPluginKanban.KanbanTeamTest do
  use ExUnit.Case, async: true

  alias EzagentPluginKanban.KanbanTeam
  alias Ezagent.Socialware.Definition

  test "definition_body is a valid socialware Definition (round-trips)" do
    body = KanbanTeam.definition_body()
    assert {:ok, %Definition{} = def} = Definition.new(body)
    assert def.name == "kanban-team"
    # #1180: `members` field is retired; participants live in `roles`.
    refute Map.has_key?(Map.from_struct(def), :members)
  end

  test "declares exactly kanban-assistant + dev-together agent role-slots, zero instance URIs" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    agent_slots = Enum.filter(def.roles, &(&1.fill == :agent))
    role_names = Enum.map(agent_slots, & &1.role_name)
    # exactly two members — pm + dev, both cc-headless active.
    assert Enum.sort(role_names) == ["dev-together", "kanban-assistant"]

    Enum.each(agent_slots, fn a ->
      assert a.fill == :agent
      assert is_binary(a.recipe) and a.recipe != ""
      assert is_binary(a.role_name) and a.role_name != ""
      refute String.contains?(a.recipe, "://")
      refute String.contains?(a.role_name, "://")
    end)

    pm_slot = Enum.find(def.roles, &(&1.role_name == "kanban-assistant"))
    assert pm_slot.flavor == "cc-headless"
    dev_slot = Enum.find(def.roles, &(&1.role_name == "dev-together"))
    assert dev_slot.flavor == "cc-headless"
  end

  # S2 建模修正回归守卫：看板是 workspace 级被动 actor，不是 session 成员——
  # 塞进角色槽会撞 RF-6 被动 join 门（session.ex:723）。
  test "kanban-manager is NOT a role-slot (passive board actor, not a member)" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    refute "kanban-manager" in Enum.map(def.roles, & &1.role_name)
    # 但它仍是 kanban 插件 recipe（workspace board actor）。
    assert "kanban-manager" in Enum.map(EzagentPluginKanban.Application.roles(), & &1.name)
  end

  test "private, non-anon visibility with installer owner" do
    {:ok, def} = Definition.new(KanbanTeam.definition_body())
    assert def.visibility_policy.scope == :private
    assert def.visibility_policy.web_anon_access == false
    assert def.owner_policy == %{type: :installer}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_team_test.exs -o line`
Expected: FAIL — `module EzagentPluginKanban.KanbanTeam is not available`

- [ ] **Step 3: Write minimal implementation**

`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex`：

```elixir
defmodule EzagentPluginKanban.KanbanTeam do
  @moduledoc """
  The `socialware:kanban-team` Definition (S2) — a prewired team of TWO session
  participants: a `kanban-assistant` (cc-headless coordinator) and a `dev-together`
  (cc-headless developer running the copied dev-together skill). The board
  (`kanban-manager` × native) is NOT a member — it is a workspace-level passive
  URI-dispatch data actor, created by the world/owner and driven by the pm via
  kanban action caps (S2 modeling fix). Published via code-seed (imperative
  `seed_definition_if_absent`, the hello `EzagentPluginHello.App` play), NOT a
  plugin package manifest (`core/manifest.ex` rejects a `:socialware` seed_ref by
  design). S3 adds the relay-back `routing_rules` + `legends` to this body.

  ## Zero instance URIs (role-slot #1180, enforced) + round-trip safety

  Participants are declared via the `roles` field as agent role-slots
  (`%{role_name, fill: :agent, recipe, flavor}` — all strings, recipe is a
  RecipeRegistry NAME). The retired `agents`/`members` fields are rejected
  fail-loud by `Definition.new/1` (`definition.ex:313-318`), and any participant
  instance URI in `roles`/`routing_rules` is rejected too
  (`definition.ex:323-366`). owner_policy is `%{type: :installer}` (`:fixed`
  rejected, `definition.ex:412-425`). The S3 relay-back rule is CONTENT-triggered
  (a `text_contains`/`mention` matcher) with a `{:role,...}` receiver — it carries
  no instance URI, so this Definition survives a live-session snapshot back into
  a Definition (round-trip) without tripping `reject_participant_instance_uris`.
  """

  alias Ezagent.Socialware.DefinitionRegistry
  alias Ezagent.Entity.User

  @doc "The `kanban-team` Definition body (config-as-data). The single source S3 extends."
  @spec definition_body() :: map()
  def definition_body do
    %{
      name: "kanban-team",
      title: "Kanban Team",
      description: "pm 协调 + dev-together 开发 + 看板数据，内容触发 relay-back。",
      uses: ["kanban"],
      bases: [Ezagent.ActionSet.Session],
      shape: [],
      views: [],
      # Exactly two agent role-slots (pm + dev). The board (kanban-manager × native)
      # is NOT here — it is passive (fails the RF-6 join gate) and lives as a
      # workspace-level URI-dispatch actor, created by the world/owner.
      roles: [
        %{role_name: "kanban-assistant", fill: :agent, recipe: "kanban-assistant", flavor: "cc-headless"},
        %{role_name: "dev-together", fill: :agent, recipe: "dev-together", flavor: "cc-headless"}
      ],
      routing_rules: [],
      legends: %{},
      prompt_templates: %{},
      adapters: [],
      visibility_policy: %{publish_policy: :auto, web_anon_access: false, scope: :private},
      owner_policy: %{type: :installer}
    }
  end

  @doc """
  Code-seed the `kanban-team` Definition into `ws` (default `workspace://system`),
  idempotent (`seed_definition_if_absent`). Mirrors hello's code-seed.
  """
  @spec seed_definition(URI.t()) :: {:ok, term()} | {:error, term()}
  def seed_definition(ws \\ Ezagent.URI.workspace(:system)) do
    DefinitionRegistry.seed_definition_if_absent(
      definition_body(),
      workspace_uri: ws,
      actor_uri: User.admin_uri()
    )
  end
end
```

在 `application.ex` `start/2`（:32）加 env-gated seed（仿 hello `application.ex:59,64-81`）:

```elixir
@impl Application
def start(_type, _args) do
  result = Ezagent.Plugin.boot(__MODULE__)
  :ok = maybe_seed_kanban_team()
  result
end

# Compile-time env (works in stripped OTP releases where Mix is unavailable).
@compile_env Mix.env()

# Code-seed the kanban-team Definition at boot. Skipped in :test (the DB write at
# plugin boot contends with the per-test Ecto sandbox — same reason hello skips
# test; ExUnit seeds inside a checked-out sandbox instead). Boot-safe: a seed
# failure downgrades to a log, never crashes boot.
defp maybe_seed_kanban_team do
  if @compile_env == :test do
    :ok
  else
    case EzagentPluginKanban.KanbanTeam.seed_definition() do
      {:ok, _} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("kanban-team definition seed failed (boot-safe): #{inspect(reason)}")
        :ok
    end
  end
end
```

- [ ] **Step 4: Run unit test to verify it passes**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_team_test.exs -o line`
Expected: PASS

- [ ] **Step 5: Run the conformance gate**

先起 DB（若未起）：`docker start ezagent-pg-compat-audit-postgres && mise exec -- mix ecto.create && mise exec -- mix ecto.migrate`
Run: `mise exec -- mix ezagent.socialware.check kanban-team --workspace workspace://system`
Expected: `✓ kanban-team: all 12 assertions pass`
（task `@reference_apps` 已含 `:ezagent_plugin_kanban`，`ezagent.socialware.check.ex:29-33`；seed_builtins 后 registry 有 kanban-team。若 registry 无枚举则显式传 `kanban-team` 名，如上命令。）

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex \
        apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex \
        apps/ezagent_plugin_kanban/test/kanban_team_test.exs
git commit -m "feat(kanban): S2 — kanban-team socialware Definition (2 role-slots: pm+dev; board non-member) + code-seed + conformance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3 (S3): relay-back — 内容触发 routing_rules + legends + 两 role skill 协议 + 集成/round-trip 测试

> ✅ **无 core/session 机制改动**：relay-back 走**纯配置（内容触发 routing_rules + legends）+ skill 协议**，不改 `template_team` 的 matcher 解析（旧 S3a URI 解析机制**已删**）。matcher `text_contains`/`mention`、receiver `{:role}`、legend member_set(role_name) 全是既有能力（`matcher.ex:52,142-152,170` / `receiver.ex:11` / `legend.ex:20-45` / `tools.ex:719`），materialize 期 `install_template_legends`（`template_team.ex:216-227`）+ `install_template_rule_sets`（`:229`）已能装。

**Files:**
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex`（`definition_body/0` 加 `routing_rules` + `legends`）
- Modify: pm 协议 reference `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md`（已在 Task 1 写含 (b) 派活/回传协议——此处确认 matcher `arg` 字面对齐）+ dev-together overlay `.claude/skills/dev-together/references/kanban-team-relay.md`（Task 1 已建，此处确认标记对齐；**不动原 8-command 主体**）
- Test（集成）: **`apps/ezagent_plugin_kanban/test/integration/kanban_team_relay_back_test.exs`（新）** ⚠️ **必须放 kanban test 树，不放 `ezagent_domain_session`**（self-containment + 依赖方向：kanban 有 `{:ezagent_domain_session, only: :test}`，反之 domain 无 kanban 依赖；放 domain 会逼 domain→plugin 层级违规，见 spec §11）
- Test（round-trip）: **`apps/ezagent_plugin_kanban/test/integration/kanban_team_roundtrip_test.exs`（新）** ⚠️ 同上，放 kanban test 树

**Interfaces:**
- Produces: `KanbanTeam.definition_body/0` 的 `routing_rules`（一条 `rule_set: "relay-back"`, position 0, matcher 内容触发, receivers `["kanban-assistant"]`）+ `legends`（可选 `@handle`）。
- Consumes: `Ezagent.Routing.Matcher.from_json/1` / `.match?/2`（`matcher.ex:170,234`）；`Ezagent.Routing.Receiver`（`{:role,name}`, `receiver.ex:11`）。

### 3a — kanban-team Definition 加内容触发 relay-back

- [ ] **Step 1: Write the failing test（Definition 层）**

在 `apps/ezagent_plugin_kanban/test/kanban_team_test.exs` 加：

```elixir
test "declares a content-triggered relay-back rule to the pm role, zero instance URIs" do
  {:ok, def} = Definition.new(KanbanTeam.definition_body())

  rule = Enum.find(def.routing_rules, fn r ->
    (Map.get(r, "rule_set") || Map.get(r, :rule_set)) == "relay-back"
  end)
  assert rule, "expected a relay-back routing rule"

  matcher = Map.get(rule, "matcher") || Map.get(rule, :matcher)
  # content-trigger: text_contains "__done__" (or a mention legend), never {:from, uri}
  assert (matcher["type"] || matcher[:type]) in ["text_contains", "mention"]
  refute String.contains?(to_string(matcher["arg"] || matcher[:arg]), "://")

  receivers = Map.get(rule, "receivers") || Map.get(rule, :receivers)
  assert receivers == ["kanban-assistant"]   # role_name, not URI

  # whole rule carries NO participant instance URI (round-trip safety)
  refute inspect(rule) =~ ~r{entity://[^/]+/(agent|user)/}
end
```

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_team_test.exs -o line` → FAIL（routing_rules 仍空）。

- [ ] **Step 2: Write minimal implementation（改 `definition_body/0`）**

`kanban_team.ex` `definition_body/0` 把 `routing_rules: []` 换成内容触发规则（首选 header 形态，最小闭环、无 legend 依赖）：

```elixir
      routing_rules: [
        %{
          "matcher" => %{"type" => "text_contains", "arg" => "__done__"},
          "receivers" => ["kanban-assistant"],
          "rule_set" => "relay-back",
          "position" => 0
        }
      ],
      legends: %{},
```

> **可选增强（legend @handle）**：若要 richer 的 `@完成回传` 触发，改成
> ```elixir
> legends: %{"完成回传" => %{member_set: ["kanban-assistant"], bound_rule_set: "relay-back", fold: false}},
> routing_rules: [%{"matcher" => %{"type" => "mention", "arg" => "完成回传"}, "receivers" => ["kanban-assistant"], "rule_set" => "relay-back", "position" => 0}]
> ```
> 两者都零 URI；本 plan 用 header 作最小闭环，legend 作 Allen 可选。**注意 matcher `arg`（`"__done__"` 或 `"完成回传"`）必须与 pm/dev-together skill 里写的回传标记字面一致（spec §5.5）。**

- [ ] **Step 3: Run unit + conformance to verify green**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/kanban_team_test.exs -o line` → PASS
Run: `mise exec -- mix ezagent.socialware.check kanban-team --workspace workspace://system`
Expected: `✓ kanban-team: all 12 assertions pass`（receiver `"kanban-assistant"` 在 declared_roles，断言 8 过；`text_contains`/`mention` 是合法 matcher 类型，`matcher.ex:234-241`，conformance 不拒）。

- [ ] **Step 4: 对齐 skill 协议标记**

确认 pm 协议 reference `references/kanban-team-collaboration.md`（Task 1 已写）与 dev-together overlay `references/kanban-team-relay.md`（Task 1 已建）里的回传标记（`__done__` / `@完成回传`）与 Step 2 的 matcher `arg` **字面一致**——这是协议 ↔ 传输的**唯一契约点**（spec §0.1/§4.2）。**若不一致，dev 发的标记路由不认、消息投不到 pm。** 有 `scripts/relay-signal-check.sh` 时跑它自检。**不改 dev-together 原 8-command 主体。**

- [ ] **Step 5: Commit（声明 + 协议对齐）**

```bash
git add apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex \
        apps/ezagent_plugin_kanban/test/kanban_team_test.exs \
        .claude/skills/kanban-assistant/ \
        .claude/skills/dev-together/references/kanban-team-relay.md
git commit -m "feat(kanban): S3a — content-triggered relay-back routing_rule + skill protocol align (zero URI)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 3b — relay-back 集成测试（内容触发 + role 受端）

- [ ] **Step 6: Write the failing integration test**

`apps/ezagent_plugin_kanban/test/integration/kanban_team_relay_back_test.exs`（跑真 materialize，需 DB sandbox；**住在 kanban test 树** —— `use EzagentCore.DataCase`（core DataCase 对下游 app 可用；domain 的 `EzagentDomainInstanceMessage.DataCase` **不对下游暴露**），`setup` 里 `Application.ensure_all_started(:ezagent_domain_session)` 把 domain 拉进运行时。**这正是 kanban 现有集成测试的既有模式**，见 `apps/ezagent_plugin_kanban/test/e2e/role_native_create_test.exs:26,34-38` 现读）：

```elixir
defmodule EzagentPluginKanban.Integration.KanbanTeamRelayBackTest do
  @moduledoc """
  S3 relay-back integration gate — proves the kanban-team Definition's
  content-triggered relay rule (a) installs into the live session route table at
  materialize and (b) routes a `__done__`-marked message to the pm role while a
  plain message does NOT. Expressed declaratively via a socialware Definition,
  CONTENT-triggered (no sender-lock, no instance URI).

  Lives in the kanban plugin's test tree (NOT domain_session): kanban has a
  `{:ezagent_domain_session, only: :test}` dep; domain must never depend on a
  plugin (spec §11). Uses `EzagentCore.DataCase` (exposed to downstream) and
  starts domain_session at setup — the same pattern as role_native_create_test.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginKanban.KanbanTeam
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam
  alias Ezagent.Routing.{RuleStore, Resolver, Matcher}
  alias Ezagent.Message

  @workspace URI.new!("workspace://system")
  @session URI.new!("session://system/kanban/relay-test")

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    # domain_session URI-query resolvers must be registered in-test (mirrors
    # role_native_create_test.exs:34-38).
    _ = EzagentDomainInstanceMessage.UriQueryResolvers.register()
    # boot seed is skipped in :test, so ExUnit seeds into the checked-out sandbox.
    {:ok, _} = KanbanTeam.seed_definition(@workspace)
    :ok
  end

  test "materialize installs a content-triggered relay-back rule to the pm role" do
    granted_by = Ezagent.Entity.User.admin_uri()
    content = %{installs: ["kanban-team"]}

    assert :ok =
             TemplateTeam.materialize_template_team(@session, @workspace, granted_by, content)

    # #1180 spawns at RANDOM UUIDs — resolve member URIs by role AFTER materialize
    # (NOT a deterministic planned_agent_uri). Use the project's role→URI lookup;
    # grep -n "role_name_to_uri\|def members\|role_uri" \
    #   apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex
    pm_uri = member_uri_for_role(@session, "kanban-assistant")
    dev_uri = member_uri_for_role(@session, "dev-together")

    # (a) the installed rule is content-triggered (fires on the `__done__` marker),
    #     NOT sender-locked — a dev-together message WITH the marker routes to pm.
    rule = RuleStore.find_by_identity(routing_table(), @session, "relay-back", 0)
    assert %RuleStore{} = rule
    assert Matcher.match?(rule_matcher(rule), Message.new(dev_uri, %{text: "card 3 → test __done__"}))
    refute Matcher.match?(rule_matcher(rule), Message.new(dev_uri, %{text: "still working"}))

    # (b) end-to-end: a `__done__` message resolves to the pm role; a plain one does not
    members = [dev_uri, pm_uri]
    assert [{recipient, _ctx}] =
             Resolver.resolve_with_ctx(
               Message.new(dev_uri, %{text: "login card done __done__ → pr"}),
               @session,
               members,
               []
             )
    assert recipient == pm_uri

    assert [] ==
             Resolver.resolve_with_ctx(
               Message.new(dev_uri, %{text: "no marker here"}),
               @session,
               members,
               []
             )
  end

  defp rule_matcher(%RuleStore{} = rule) do
    {:ok, m} = Matcher.from_json(rule.matcher)
    m
  end

  # Resolve a live member's URI by its role_name after materialize (#1180 spawns
  # at random UUIDs, so this is a lookup, not a computation). Wire to the project's
  # role→URI helper (Members.role_name_to_uri or session members read).
  defp member_uri_for_role(_session, _role_name),
    do: raise("wire to Members.role_name_to_uri / session members lookup (see grep above)")
end
```

> **实现者注（跑前 grep 对齐真实 API）**：(1) `member_uri_for_role/2` 接项目真实的 role→URI 反查（`grep -n "role_name_to_uri\|def members" apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex`）——**必须是 materialize 后的实时反查，不是 `planned_agent_uri`**（#1180 随机 UUID）。(2) `routing_table/0`（session-scoped 表句柄）、`RuleStore.find_by_identity/4`、`rule.matcher`（存储形态）、`Resolver.resolve_with_ctx/4` 实参按现有 install 侧对齐 —— `grep -n "def find_by_identity\|def load_into_registry\|default_routing_table\|:matcher" apps/ezagent_core/lib/ezagent/routing/rule_store.ex apps/ezagent_core/lib/ezagent/routing/resolver.ex` +看 `template_team.ex:210,228,240`。(3) DataCase 用 `EzagentCore.DataCase`（对下游 app 暴露；**不要**用 domain 的 `EzagentDomainInstanceMessage.DataCase`，那是 domain test-support、不对下游可见），domain 运行时经 `setup` 的 `Application.ensure_all_started(:ezagent_domain_session)` + `UriQueryResolvers.register()` 拉起——照 `apps/ezagent_plugin_kanban/test/e2e/role_native_create_test.exs:26,34-38` 既有模式。(4) 若用 legend 形态而非 header，构造 message 时置 `legend_triggers: ["完成回传"]` 而非 body 塞 `__done__`。

- [ ] **Step 7: Run integration test to verify green**

先起 DB：`docker start ezagent-pg-compat-audit-postgres && mise exec -- mix ecto.create && mise exec -- mix ecto.migrate`
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/integration/kanban_team_relay_back_test.exs -o line`
Expected: PASS（内容触发规则 install 进活路由；`__done__` 命中 pm，普通消息不命中）。

### 3c — round-trip gate（load-bearing —— 相比 sender-lock 的根本收益证据）

- [ ] **Step 8: Write the round-trip test**

`apps/ezagent_plugin_kanban/test/integration/kanban_team_roundtrip_test.exs`（**kanban test 树，同 relay-back 测试的落点理由**）——证明「materialize → 快照回 Definition → `Definition.new/1` 不报实例-URI 拒绝」（内容协议规则零 URI，round-trip 安全）：

```elixir
defmodule EzagentPluginKanban.Integration.KanbanTeamRoundtripTest do
  @moduledoc """
  Proves the kanban-team relay-back rule is round-trip safe: a live session
  materialized from the Definition can be snapshotted BACK into a Definition
  without tripping #1180 `reject_participant_instance_uris`. This is the concrete
  advantage of the content-triggered relay over a sender-lock: the rule carries no
  participant instance URI, so pull → re-develop → re-publish closes the loop.
  A sender-lock rule (`{:from, <dev-uri>}` in the live RuleStore) would embed a
  concrete member URI, and this snapshot-back would be REJECTED.

  Lives in the kanban plugin's test tree (NOT domain_session) — see spec §11 +
  the relay-back test's rationale. `EzagentCore.DataCase` + domain started at setup.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginKanban.KanbanTeam
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam
  alias Ezagent.Socialware.Definition

  @workspace URI.new!("workspace://system")
  @session URI.new!("session://system/kanban/roundtrip-test")

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    _ = EzagentDomainInstanceMessage.UriQueryResolvers.register()
    {:ok, _} = KanbanTeam.seed_definition(@workspace)
    :ok
  end

  test "a materialized kanban-team snapshots back into a valid Definition (no instance URI)" do
    granted_by = Ezagent.Entity.User.admin_uri()
    assert :ok =
             TemplateTeam.materialize_template_team(
               @session, @workspace, granted_by, %{installs: ["kanban-team"]})

    # Snapshot the live session's config back into a Definition body. Use the
    # project's live-snapshot path (grep for it: DefinitionSync / DefinitionEditor
    # merge_live_config / orchestrator save_template_as). The body's routing_rules
    # + legends must contain NO participant instance URI.
    body = snapshot_live_definition_body(@session, @workspace)

    # (a) re-validating the snapshotted body does NOT trip #1180's URI guard
    assert {:ok, %Definition{}} = Definition.new(body)

    # (b) structural: no entity://.../agent|user/... anywhere in the routing config
    refute inspect(Map.take(body, [:routing_rules, :legends, "routing_rules", "legends"]))
           =~ ~r{entity://[^/]+/(agent|user)/}
  end

  # Resolve the project's actual live-snapshot function during implementation.
  # grep -n "merge_live_config\|save_template_as\|def snapshot\|live_role_slots" \
  #   apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex \
  #   apps/ezagent_domain_session/lib/ezagent_domain_instance_message/orchestrator/*.ex
  defp snapshot_live_definition_body(_session, _workspace) do
    # implementer: wire to the real snapshot path (DefinitionEditor.merge_live_config
    # or orchestrator save_template_as), returning the Definition body map.
    raise "wire to the project's live-snapshot path (see grep above)"
  end
end
```

> **实现者注**：`snapshot_live_definition_body/2` 接到项目真实的「live session → Definition body」快照路径 —— `grep -n "merge_live_config\|save_template_as\|live_role_slots\|def snapshot" apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex apps/ezagent_domain_session/lib/ezagent/orchestrator/*.ex`。该 gate 是 relay-back 内容协议**相比 sender-lock 的根本收益的可执行证据**（§4.4）；若项目当前无「回写 Definition」的 public 路径，退而用 `DefinitionEditor.merge_live_config/…` 组一份 body 再 `Definition.new/1` 断言不报 `:socialware_definition_declares_instance_uri`。

- [ ] **Step 9: Run round-trip test to verify green**

Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/integration/kanban_team_roundtrip_test.exs -o line`
Expected: PASS（快照回的 body `Definition.new/1` 成功、零实例 URI）。

- [ ] **Step 10: Commit（集成 + round-trip）**

```bash
git add apps/ezagent_plugin_kanban/test/integration/kanban_team_relay_back_test.exs \
        apps/ezagent_plugin_kanban/test/integration/kanban_team_roundtrip_test.exs
git commit -m "test(kanban): S3bc — kanban-team content-trigger relay-back + round-trip gate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4 (S4, GATED on Allen Q2): kanban render view（公开 board 投影）

> **仅当 Allen 拍「首版要公开 render view」才做（spec §9 Q2）。** 首版 `views: []`，board 可视化复用 world `/plugins/kanban`。

**Files:**
- Create: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex`（`use Ezagent.ActionSet`，一个 cap-only read action `:kanban_render`，只读投影 board slice）
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/kanban_team.ex`（`definition_body/0` `views: [Ezagent.ActionSet.KanbanRender]`）
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（若 render cap 需注册，走 `Ezagent.Plugin.boot`；SessionView 注册仿 hello `Ezagent.UI.SessionViewRegistry.register`，`application.ex:44`）
- Test: `apps/ezagent_plugin_kanban/test/behavior/kanban_render_test.exs`

**Interfaces:**
- Produces: `Ezagent.ActionSet.KanbanRender.actions/0` 含 `:kanban_render`；render cap 在 Session Kind 注册（conformance 断言 2/9 要求，`conformance.ex:109-143`）。

- [ ] **Step 1: Write failing test** — 断言 `KanbanRender.actions()` 含 `:kanban_render` 且 `handle_kanban_render/2` 返回 board 只读投影（`{:ok, %{columns: ...}, []}`），不产生写 effect。
- [ ] **Step 2: Run → FAIL**（module 未定义）。
- [ ] **Step 3: 实现** render ActionSet（只读，读 `ctx[:read]` 拿 kanban-manager 的 `:kanban` slice 投影；无 `{:set,...}` effect）。
- [ ] **Step 4: 单元 PASS** + **conformance**：`mise exec -- mix ezagent.socialware.check kanban-team`（断言 2/9 render cap 已注册）绿。
- [ ] **Step 5: Commit** `feat(kanban): S4 — kanban_render SessionView (gated)`。

---

## Task 5 (S5, GATED on Allen Q3): join/admission + relay 硬锁

> **仅当 Allen 拍档位（spec §9 Q3）才做。** 两块，任一独立可做：
> (a) **动态申请加入 kanban-team session**：复用 #1178 admission gate（cross-owner → PENDING → owner 审核），`membership.ex do_join :85-86` + `:approve_admission :326`——本 task 只需在 world/e2e 层驱动，机制现成。
> (b) **relay 的硬锁（可选）**：内容协议是软锁（靠 dev-together 遵守 skill，spec §4.3/§4.5）。若要「只有特定角色发才转」的**硬**锁且仍要 round-trip 安全，需一个 **membership-role matcher**（按 session 成员 `role_name` facet 匹配 sender、只存 role_name、零 URI）——新机制：TDD 先在 `Ezagent.Routing.Matcher` 加 `{:from_role, name}` leaf（match 时按成员 role facet 判 sender，序列化只存 role_name），再让 `install_one_rule` 认它。**这块要 Allen 明确要才做**，否则本切片内容协议已够。

**测试方法**：(a) 集成测试驱动 `session.join`（cross-owner）断言落 `:pending_members` + `approve_admission` 后授 cap；(b) matcher 单元测试（`{:from_role, name}` 零 URI 序列化 + 按成员 role facet 命中）+ relay 集成测试。

---

## Task 6 (S6): 真浏览器 Playwright e2e（pm 派活 / dev-together relay / 看板推进）+ 截图

> **最高纪律：真浏览器、真登录、真点、每步截图；禁 stub。** S1-S3 绿后即可做（不依赖 S4/S5）。

**Files:**
- Create: `docs/scenarios/kanban-team/scenario.md`（步骤 + 每步截图路径）
- Create: e2e 脚本（放团队约定的 Playwright 目录；参考现有 socialware e2e 脚本位置 `grep -rl "playwright\|10042\|screenshot" docs/ apps/ | head`）

**Interfaces:**
- Consumes: dev server（`iex -S mix phx.server`，port 10042）；admin `admin@ezagent.chat` / `worlddev`；已 seed 的 kanban-team（dev 环境 boot seed 生效，非 `:test`）。

**e2e flow（每步截图）：**

- [ ] **Step 1: 起 dev server + 登录**

`docker start ezagent-pg-compat-audit-postgres`；umbrella 根 `mise exec -- iex -S mix phx.server`。Playwright 打开 `http://localhost:10042`，用 admin 登录。**截图 01-login。**

- [ ] **Step 2: 发现 + 安装 kanban-team**

在 world sessions_table 的「socialwares」rows 找到 kanban-team（`world_live.ex:676` `socialware_rows/1`）→ 安装（`SocialwareInstall.prepare_create_template/5` → `ConversationActions.create_session/4`）。**截图 02-discover、03-installed（新建的 session，含 kanban-assistant + dev-together 两成员；board 不在成员列表——它是 workspace 级 actor，在 Step 4 由 owner 于 `/plugins/kanban` 建）。**

- [ ] **Step 3: owner 建 board + 对 pm 派活**

先在 world `/plugins/kanban`（`config_surface/0`，`application.ex:133`）由 owner「新建 board」（`KanbanActions.create_kanban` → `Workspace.create_agent`，flavor `native` × role `kanban-manager`）——board 是 workspace 级 actor，不是 team 成员。**截图 03b-board-created。** 再打开该 session 聊天面，owner 发「把『登录页』这张卡推进到 test 阶段，assign 给 dev-together（用刚建的看板）」。pm 用它的 kanban action caps 把 `kanban.<action>` dispatch 到该 board URI 建卡、@dev-together 派活。**截图 04-owner-message、05-pm-assign。**

- [ ] **Step 4: 验证看板推进**

回到 world `/plugins/kanban` 看该 board 状态：卡已建、assign 给 dev-together。**截图 06-board-after-assign。**

- [ ] **Step 5: dev-together relay-back → pm 收敛**

以 dev-together 身份（或触发 dev-together 成员发消息）报「登录页 card 完成，PR 已提 __done__ → pr」→ 内容触发 relay-back 路由到 pm → pm 推进卡到 pr 并回 owner。**截图 07-dev-relay（带 `__done__` 标记的消息）、08-pm-advance、09-board-final（卡在 pr）。**

- [ ] **Step 6: 归档证据 + 写 scenario.md**

把 01-09 截图 + 步骤写进 `docs/scenarios/kanban-team/scenario.md`（每步一句话 + 截图引用）。

- [ ] **Step 7: Commit**

```bash
git add docs/scenarios/kanban-team/
git commit -m "test(kanban): S6 — kanban-team pm-assign/dev-relay/board-advance browser e2e + screenshots

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review（对照 spec）

- **Spec 覆盖**：§3 Definition（两 agent 角色槽 pm+dev；board 非成员）→ Task 2；§4 relay-back（内容触发 legend/header + skill 协议 + round-trip 论证）→ Task 3a/3b/3c；§5 pm recipe（skill-creator）+ §5.4 dev-together recipe（照抄）→ Task 1；§5.5 pm 覆盖矩阵 → Task 1 pm skill；§6 测试策略（含 round-trip gate）→ 每 Task 的 test；§7 代码/配置分类 → Task 标注；§8 迁移标注（role-slot 已落地 / registry / membership-matcher）→ Global Constraints + Task 5；§9 discuss-first → Task 4/5 gated；§10 切片顺序 → Task 1→2→3→(6)。全覆盖。
- **配合=git-handoff 工作流、routing=传输（口径校正）**：pm↔dev 的真正配合是 dev-together skill 的 git-handoff 工作流（handoff/dive/return/CI gate，git+markdown+CI）；§4 routing 只把"dev 交活了"的完成信号传到 pm 角色，**不是工作流引擎**。pm/dev persona + pm SKILL.md 已按此改（Task 1：派活=写/审 handoff、收活=看 `returns/<task>.md`+CI）。**两层分开**（spec §5.0）：能力技能（dev-together，可移植照抄）vs 协作协议（pm skill 里独立薄层）。**真缺口**（无 per-socialware 常驻协议注入入口）标在 Global Constraints + spec §8/§9 Q5。
- **relay-back 已改内容协议**：sender-lock `{:from, dev-URI}` matcher + S3a 确定性 `planned_agent_uri` URI 解析 + 给 Allen 的 `{:from_role}` discuss-first —— **全删**。改成内容触发（`text_contains`/`mention` legend）+ `{:role}` receiver + skill 软协议，**规则零实例 URI → round-trip 闭环**（Task 3c gate 证）。**无 core/session 机制改动、无 #1180 落点冲突、无需 Allen re-verify。**
- **两 agent 角色槽写进 Definition**：kanban-assistant（cc-headless）+ dev-together（cc-headless），Task 2 `definition_body/0` + Task 2 test 断言。**board（kanban-manager × native）非成员**——它 passive、撞 RF-6 join 门（session.ex:723），是 workspace 级 URI-dispatch actor，由 world/owner 建、pm 用 kanban action caps dispatch 驱动（S2 建模修正，见顶部 ⚠️）。
- **dev-together = 照抄现有全套**：Task 1 copy sw-kanban `.claude/skills/dev-together/`（SKILL.md 204 + commands/ + references/ + scripts/ + hooks/）逐个保留，spec §5.4 列了功能清单。
- **pm = skill-creator 规范新建 + 协议独立成可切出 reference**：Task 1 pm `SKILL.md` 主体只写通用协调能力 + 一行 `@references/kanban-team-collaboration.md`；协议全部（spec §5.5 矩阵 (a)/(b)/(c)）写进独立文件 `references/kanban-team-collaboration.md`（标注「可切出模块」，§9 Q5 workflow 编排落地整块上移）；dev-together 薄 overlay `references/kanban-team-relay.md` 指向同一份、不动其 8-command 主体。
- **routing/协议分离（spec §0.1 新增对照表）**：新加 §0.1 一张对照表——routing = 只搬消息（matcher+`{:role}` receiver）；协议 = 协作约定（住 skill 独立 reference）；唯一契约点 = 完成标记字面 == matcher `arg`。plan Global Constraints 同步一条。
- **self-containment 审查（spec §11 新增审查表 + 本轮修正一处 RED）**：逐 Task 核对 `Files:`——**修掉 T3 集成测试落点**（原放 `apps/ezagent_domain_session/test/` = 碰插件外 app + domain→plugin 反向依赖 + 用了不对外暴露的 DataCase）→ 改放 `apps/ezagent_plugin_kanban/test/integration/`、`use EzagentCore.DataCase` + `Application.ensure_all_started(:ezagent_domain_session)`（既有模式 `role_native_create_test.exs:26,34-38`）。T5(b) relay 硬锁改 core matcher = 不可自包含 → 移平台 track。其余 Task（T1/T2/T4/T6）全落 kanban+config，只经 domain public API。净结论：S1-S3+S6 每 Task 零 domain/core/hello 代码改动。
- **占位符扫描**：无 TBD/TODO；每 code step 给真代码；Task 3b/3c 的 API 取值点显式给了「跑前 grep 对齐」的确切命令（`routing_table` / `find_by_identity` / `snapshot_live_definition_body` 路径）。
- **类型一致**：`kanban_assistant_recipe/0`、`dev_together_recipe/0`、`definition_body/0`、`seed_definition/1` 跨 Task 一致；relay receiver 全程 `"kanban-assistant"`（role_name），matcher 全程内容触发（`text_contains "__done__"` / `mention "完成回传"`，零 URI）。

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-05-kanban-socialware-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — 每 Task 派 fresh subagent，Task 间 review，快迭代。REQUIRED SUB-SKILL: superpowers:subagent-driven-development。

**2. Inline Execution** — 本 session 批量执行，checkpoint review。REQUIRED SUB-SKILL: superpowers:executing-plans。

**最小切片先跑 Task 1→2→3，Task 6 收口；Task 4/5 等 Allen 拍 Q2/Q3。**
