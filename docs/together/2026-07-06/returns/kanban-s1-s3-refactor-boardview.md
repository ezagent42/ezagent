# Return — kanban 迁 socialware（S1-S3 + board 修正 + 重构 + S4 board view）

- **Date**: 2026-07-06
- **Branch**: `feat/sw-kanban`（PR **#1190**）
- **Base**: rebase 在 `origin/main` @ `0a192363`（含 world-views #1192 开工参考 + lead GO #1195/#1196）
- **Handoff**: `docs/together/2026-07-05/handoffs/kanban/`（spec.md / plan.md / restart-review-and-plan.md）
- **范围纪律**: 只碰 `apps/ezagent_plugin_kanban/` + 纯配置（Definition code-seed）+ `.claude/skills/kanban-assistant/`；`.claude/skills/dev-together/` 对 upstream/main **零 diff**；world / hello / core / domain 零代码改动

## What landed（按 commit）

| commit | 内容 |
|---|---|
| `92b29472` | docs：kanban 迁 socialware 开工参考 |
| `b5f612c4` | **S1** — `kanban-assistant` + `dev-together` recipes 进 `roles/0`（cc-headless，kanban action caps 单一来源 `Kanban.actions/0`）+ pm persona skill（skill-creator 规范，协议独立成可切出 `references/kanban-team-collaboration.md`） |
| `21e71cca` | **S2** — `socialware:kanban-team` Definition（config-as-data，`KanbanTeam.definition_body/0`）+ boot code-seed（照 hello 的 `seed_definition_if_absent` play，`:test` skip + boot-safe）+ 自包含 conformance gate（ExUnit 直跑 `Conformance.check/2`） |
| `634068d8` | **S3** — relay-back **内容协议** routing_rules（`{:text_contains,"__done__"}` + `{:role,"kanban-assistant"}` receiver，零实例 URI）+ relay-back 集成测试 + round-trip 闭环 gate |
| `cfa2cddc` | **board 建模修正** — board（`kanban-manager` × native，passive）**非 session 成员**：去掉第三角色槽（撞 RF-6 passive-join gate `{:passive_actor_cannot_join,_}`），roles 收敛为 pm+dev 两槽；board 是 workspace 级 actor，pm 持 kanban action caps 对 board URI dispatch 驱动 |
| `e68dc1e6` | **重构** — pm-coordinator → **看板助手（kanban-assistant）改名**贯穿（recipe/skill/Definition/测试）+ 拿掉 GitHub 主动连接器（节点留 git-ref 纯数据）+ 看板助手 skill 教 ezagent CLI 操作 |
| `d8267685` | **CI 修复** — dev-together 目录恢复 upstream 原样（overlay 移到 kanban-assistant 侧持有）+ `ezagent_domain_session` 提 prod dep（#57 undeclared-dep gate） |
| （本片） | **S4 board view（用户拍板后从 §9 Q2 gated 转正，声明侧）** — 见下节 |

## 本片：S4 board view（plugin 声明 → world 通用消费 → 自动接入）

用户已拍：kanban-team 声明一个 board SessionView——**kanban 插件 ship render ActionSet + SessionView，Definition `views` 引它，渲染由 world-views（#1199 已实现 world 通用消费 registry）自动接**；不搞旧 bind_session，零 world 改动。dealscout 的教训（Stage C 过度建 view 后删除）在这里不适用：board 数据归 kanban 自己（display ownership 正确），这正是该由 kanban 出 view 的场景。

1. **`Ezagent.ActionSet.KanbanRender`**（`lib/ezagent/behavior/kanban_render.ex`，新）— cap-only view read ActionSet（`use Ezagent.Lifecycle`，`dispatchable?/0 → false`，唯一 `:kanban_render` action，照 `HelloRender`）+ 只读 board 投影：`render_tree/2` 纯函数（`:kanban` slice tree + recipe stages → string-keyed JSON-safe json-render map，每 stage 一列 + `unstaged` 兜底列，root 非卡片）；`external_tree/1` 按 session workspace 经 `AgentRecipeResolver.list_by_recipe("kanban-manager", ws)` 枚举 board（快照来源覆盖 dormant，`LocalRuntime.ensure_started` 先起活——`KanbanData.board_snapshot` 同款），无 board → `nil`。**零写**（无 `{:set,…}`、无 dispatch 写路径）。
2. **`EzagentPluginKanban.BoardView`**（`lib/ezagent_plugin_kanban/board_view.ex`，新）— `@behaviour Ezagent.UI.SessionView`：`id :kanban_board` / `label "看板"` / `icon "square-kanban"` / `applies_to?/1`（session 装了 kanban-team Definition（`views` 含 KanbanRender）才 true，**fail-safe** 任何异常 → false）/ `view_behavior/0 → KanbanRender`（T2-2b cap-gated，`authorize_view/3` 查 `{Session, :kanban_render}`）/ `external_render?/0 → true` + `external_render/1`（json-render tree）/ `render/1`（internal HEEx 列/卡只读渲染）。`Application.start/2` 里 `SessionViewRegistry.register/1` 注册（照 hello PageView）。
3. **`kanban_team.ex`** — Definition `views: [Ezagent.ActionSet.KanbanRender]`；**`application.ex`** — `behaviors/0` 回归一条静态绑定 `{Ezagent.Entity.Session, :kanban_render, KanbanRender}`（cap subject，conformance 断言 2/9 的要件）；**`mix.exs`** — `{:ezagent_domain_ui, in_umbrella: true}` prod dep（registry ETS 先 init 再注册，照 hello 的启动次序）。
4. **TDD**：`test/behavior/kanban_render_test.exs` + `test/board_view_test.exs` + `kanban_team_test.exs` views 断言，先红（16 failures：模块缺失 + `views == []`）后绿。

## DoD 对账（对 spec 硬要求逐行）

| spec 硬要求 | 出处 | 状态 | 证据 |
|---|---|---|---|
| routing 只搬消息、协议住 skill、**唯一契约点 = 完成标记字面 == matcher `arg` 逐字一致** | §0.1 | ✅ | `KanbanTeam.relay_done_marker/0 == "__done__"` 单一常量进 matcher；协议文档在 `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md`（+ dev-relay overlay 同侧持有）；`relay-signal-check.sh` 锁字面一致 |
| relay-back = **内容协议**：`text_contains "__done__"`（或 legend）+ `{:role,"kanban-assistant"}` receiver，routing 里**零时序/身份判断**、零 sender-lock | §4.2/§4.0 | ✅ | `kanban_team.ex` routing_rules；`kanban_team_test.exs`「content-triggered relay-back rule … zero instance URIs」；集成测试断言 RuleStore matcher/receiver/position + 命中/不命中两向 |
| **round-trip 闭环**：materialize → 快照回 Definition → `Definition.new/1` 不报 `:socialware_definition_declares_instance_uri` | §4.4/§6 | ✅ | `test/integration/kanban_team_roundtrip_test.exs`（kanban test 树，非 domain） |
| 两个 agent 角色槽（pm+dev，cc-headless）；**board 非成员**（passive，RF-6） | §3.2 | ✅ | `cfa2cddc` 修正 + `kanban_team_test.exs`「kanban-manager is NOT a role-slot」回归锁 |
| conformance gate 12 条全过（`views` 加了则 2/9 要求 render cap 注册） | §6 | ✅ | ExUnit 自包含 gate「passes all 12 socialware conformance assertions」绿；`mix ezagent.socialware.check kanban-team` → `✓ kanban-team: all 12 assertions pass`（本地 dev DB 已按新 body 重写后复验，见 deferred 第 3 条） |
| **自包含**：只碰 kanban 包 + 纯配置，测试只住 kanban test 树，经 domain public API（`seed_definition_if_absent` / `SessionViewRegistry.register` / core `DataCase`） | §11 | ✅ | 全部落点 `apps/ezagent_plugin_kanban/` + skills + docs；`git diff upstream/main -- .claude/skills/dev-together/` 为空；S4 的 T4 审查行本就判 🟢 GREEN（gated），本片按它落 |
| **CI**：PR checks 全绿 + `pr` 阶段 CI-gated（板机制） | §6/§7 | ✅ | `d8267685` 修掉 PR #1190 两个 CI fail（dev-together guard + undeclared dep）；本片 push 触发 CI 重跑（见 Gate）；板的 `ci_stage: :pr` 在 recipe config（layer-2 数据） |
| 测试跑法纪律：umbrella 根、绝不 per-app cd | §6 | ✅ | 全部命令 `mise exec -- mix test apps/ezagent_plugin_kanban/test/...` 自 umbrella 根 |

## Gate（本片验证记录）

```text
mix compile --warnings-as-errors --force     # 干净（0 warning）
mix test apps/ezagent_plugin_kanban/test     # 73 tests, 0 failures (7 excluded)
mix ezagent.socialware.check kanban-team     # ✓ all 12 assertions pass（新 body：views=[KanbanRender]）
mix format --check-formatted                 # 干净
```

- TDD 红基线：新增 3 个测试文件先跑出 16 failures（模块未定义 + `views == []`），实现后 23/23 绿。
- **PR #1190**：本片 push 后 CI 重跑；上一轮（`d8267685`）已把 dev-together guard + undeclared-dep 两个红修绿。rebase-base 保持 `0a192363`。

## Deferred（不在本片，显式挂起）

1. **S6 agent 自驱板真浏览器 e2e** — pm/dev 两个 cc-headless agent 自驱推板需要真 brain 凭证（**Q10 凭证问题**，等拍）；`docs/e2e/2026-07-06/kanban-team/` 里已有的人驱截图不当自驱证据（e2e 纪律：禁 stub 当 e2e）。
2. **S5 动态加入/admission + relay 硬锁** — (a) admission 复用 #1178 机制、等 Allen 拍 Q3 档位；(b) `{:from_role}` matcher 要改 core 路由原语，**不可自包含**，已按 §11 判定移平台 track。
3. **存量环境的 kanban-team body 升级** — boot seed 是 `seed_definition_if_absent`（by-design 不 clobber override），所以**已 seed 过旧 body（`views: []`）的环境不会自动拿到 S4 view**；fresh stack 无此问题。本地 dev DB 本轮经 `write_definition(authority: :system_seed)` 重写为新 body 后复验 gate。正式升级路 = registry P0 的版本化 promote（#1173/#1176），非本片发明新机制。

## Method friction（流程教训）

- **dev-together guard 撞了一次**：S1 曾把 relay overlay 写进 `.claude/skills/dev-together/references/`，被 PR CI 的 "Only repo owner may edit dev-together skill" guard 打红——dev-together 是 owner-only 团队契约，**任何分支不许改，哪怕是加薄 reference**。教训：给别人的 skill 加协作 overlay 时，overlay 归**自己这侧**的 skill 持有（现落 `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`，指向同一份协议文档），对方 skill 保持零 diff。这与 §5.0「能力技能 vs 协作协议两层分开」是同一个原则的 CI 化。
- 顺手被同一轮 CI 揪出的第二课：lib/ 里硬引某 domain 模块时，`only: :test` 依赖是 latent "module not available" 炸弹（#57 gate）——`kanban_team.ex` 引 `DefinitionRegistry` 的当下就该把 `ezagent_domain_session` 提 prod dep（hello 先例），别等 CI。
