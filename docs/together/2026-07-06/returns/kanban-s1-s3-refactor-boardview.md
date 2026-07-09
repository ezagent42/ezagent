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
5. **一处越出 kanban 包的 gate 维护（显式声明）**：core 的 G2 p4 probe（`cap_check_only_at_chokepoint_test.exs`，禁手写 `def cap_subjects` 出现在非允许路径）把 `kanban_render.ex` 打红——cap-only view read ActionSet 必须手写 `cap_subjects/0`（HelloRender 落地时同样在该 probe 加了 hello behavior 目录的 allowlist 条目）。按同一先例加了**单文件精确 allowlist**（只列 `kanban_render.ex`，不放行整个 kanban behavior 目录）+ 注释标同类。这是 arch-gate allowlist 维护（同 dealscout CI fix 的类别），不是 core 语义改动。

## 本片：boot 自动发布（Allen 2026-07-06 handoff，照 hello #162 黄金样板）

Handoff 原文入库：`docs/together/2026-07-06/handoffs/kanban-boot-publish-handoff.md`。要点：kanban socialware 每次 boot 自动发布成 public（真 governance 流），新库冷起后"新建会话 → Socialware 下拉"直接出现 kanban，跟 hello 一模一样。

1. **`EzagentPluginKanban.Demo`**（`lib/ezagent_plugin_kanban/demo.ex`，新）— 一比一照 `Ezagent.Socialware.Demo.Hello`（#162），改名 + 三处数据：
   - `manifest_attrs/1` — string-keyed、`ManifestResolver.resolve/1`-ready 的 config-authored manifest：`name "kanban"` / title·description 看板的 / `uses ["kanban"]` / `views ["kanban_render"]` / **roles = #1190 的两槽**（`kanban-assistant`×cc-headless + `dev-together`×cc-headless，string 形态照 hello 的 roles 键写法）/ **routing_rules = 只有 #1190 的 relay-back 规则**（`text_contains "__done__"` → `kanban-assistant`，**没照抄 hello 的 always→chat**，handoff 标红项）/ legends `member_set` 用我们两个角色名（fronting `relay-back` rule_set）/ `visibility_policy %{scope: public, publish_policy: supervised, web_anon_access: false}`（看板不匿名）。opts：`:name`（测试 per-run 唯一名，照 hello）+ `:flavor`（集成测试 bare-spawn stub 换 flavor 的 seam，替代原先对 `definition_body().roles` 的手工 map）。
   - `publish/0` = `ManifestResolver.resolve(manifest_attrs())` → `Governance.publish_or_upgrade(definition, ctx)`，发进 `workspace://system`、scope public；`published?/0` + 私有 `admin_ctx`（`user://system/admin` + `manage_cap` + `admin_genesis_cap`）逐行照 hello。
2. **boot 调用点**（`application.ex`）— 旧 `maybe_seed_kanban_team`（imperative `seed_definition_if_absent`、boot-safe 吞错）**整体替换**为 `maybe_publish_kanban_demo`：照 hello `application.ex:71` **fail-loud**（发布挂 → raise 崩 boot，dogfood 真 governance 路径）+ `:test` skip（Ecto sandbox 争用，ExUnit 驱动 publish）。**旧 seed 模块 `kanban_team.ex` 删除**（判"只走 publish 最干净"，hello 同款只有 publish 一条路；`KanbanTeam.definition_body/relay_done_marker` 的单一真相并入 `Demo`，测试 fixture 全改从 `Demo.manifest_attrs/1` resolve 派生——manifest 与 boot demo 永不 drift，hello 的 one-source-of-truth play）。`relay-signal-check.sh` 第 3 检查点路径同步 `kanban_team.ex` → `demo.ex`。
3. **幂等三态单测**（`test/demo_publish_test.exs`，新，DataCase）— `resolve` 成功；`Demo.publish()` 第一次 `:published`、第二次 `:exists`（**同一 revision，不开新 CR**）、改 manifest（description）后 `publish_or_upgrade` → `:upgraded`（新 immutable revision，content_hash 对上）；外加 PUBLIC 跨 workspace `DefinitionRegistry.list/1` 可发现 + **发布后的 Definition 全 12 条 conformance assertion 绿**（= `mix ezagent.socialware.check kanban` 的同一保证）。manifest 形态单测（`test/demo_test.exs`，新）锁两槽/零实例 URI/relay-only（显式断言无 `always` matcher）/public+supervised+non-anon/legends 角色名。
4. **⚠️ roles 差异（open decision，给 Allen 判）** — handoff 示例写 `kanban-manager×native` 进 roles；实施**保持 #1190 两槽、没塞 kanban-manager**。证据：`kanban-manager` recipe 是 `passive: true`（`application.ex` `kanban_manager_recipe/0`），RF-6 硬门禁在 `session.join` 拒 passive actor（`{:error, {:passive_actor_cannot_join, member_uri}}`，`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:729-731`；`test/e2e/role_native_create_test.exs:119` 锁死）；现读确认 materialize 路径（`definition_agents.ex`/`template_team.ex`）**无 passive 特例**（grep "passive" 零命中），Definition 里放 kanban-manager 槽 → materialize 对每个 agent 槽都 `session.join` → 必炸。这正是 S2 board 建模修正修过的 bug（`cfa2cddc`）。board 维持 workspace 级 actor（`entity://<ws>/agent/<id>` URI dispatch），pm 持 kanban action caps 驱动。`demo_test.exs`「kanban-manager is NOT a role-slot」回归锁。**若 Allen 仍要 board 进 roles，需要先给 RF-6/materialize 开 passive 槽语义（平台改动，非本片自包含范围）。**

## DoD 对账（对 spec 硬要求逐行）

| spec 硬要求 | 出处 | 状态 | 证据 |
|---|---|---|---|
| routing 只搬消息、协议住 skill、**唯一契约点 = 完成标记字面 == matcher `arg` 逐字一致** | §0.1 | ✅ | `Demo.relay_done_marker/0 == "__done__"` 单一常量进 matcher（boot-publish 后单一真相并入 `demo.ex`）；协议文档在 `.claude/skills/kanban-assistant/references/kanban-team-collaboration.md`（+ dev-relay overlay 同侧持有）；`relay-signal-check.sh` 锁字面一致 |
| relay-back = **内容协议**：`text_contains "__done__"`（或 legend）+ `{:role,"kanban-assistant"}` receiver，routing 里**零时序/身份判断**、零 sender-lock | §4.2/§4.0 | ✅ | `demo.ex` manifest routing_rules（原 `kanban_team.ex`）；`demo_test.exs`「relay-back rule … zero instance URIs」；集成测试断言 RuleStore matcher/receiver/position + 命中/不命中两向 |
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

boot-publish 片（2026-07-06 handoff）复验：

```text
mix compile --warnings-as-errors             # 干净（0 warning）
mix test apps/ezagent_plugin_kanban/test     # 76 tests, 0 failures (7 excluded)
mix test .../demo_publish_test.exs demo_test.exs  # 11 tests, 0 failures（幂等三态 + 12 条 conformance + manifest 形态）
mix ezagent.socialware.check kanban          # ✓ kanban: all 12 assertions pass（dev boot 走新 publish 路径把 kanban 发进 registry，任务本身即冷起自证）
mix format --check-formatted                 # 干净
relay-signal-check.sh                        # OK（__done__ 对齐 pm protocol + dev overlay + demo.ex manifest）
```

- TDD 红基线：新增 3 个测试文件先跑出 16 failures（模块未定义 + `views == []`），实现后 23/23 绿。
- **PR #1190**：本片 push 后 CI 重跑；上一轮（`d8267685`）已把 dev-together guard + undeclared-dep 两个红修绿。rebase-base 保持 `0a192363`。

## 收口批次补记（2026-07-06，rebase 到 `e8d9fd11` 后）

1. **world 死派发清理（gh 动作删除的爆炸半径配套，同 world_conversation_test 先例）**——本分支删了 kanban ActionSet 的 GitHub 主动连接器（sync_github / save_github_creds / sync_prs / push_pr），world 侧对应死派发本轮清掉：
   - `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`：删 4 个死 `handle_dispatch` 子句（原 :115-124 sync_github/save_github_creds、:144-148 sync_prs/push_pr）+ moduledoc 连接器清单改写为现状（gh 连通 = agent 的 CLI 行为）+ act_board 注释同步。
   - `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex`：**`github` 连接状态字段整体退役**（原 :62 / :99 / :157 / :166 四处读）——现读确认 `handle_get_tree`（kanban.ex:523）早已不返回 `:github`，这四处永远是 `%{"configured" => false}` 死占位，且前端唯一消费点（GH token 面板）同轮删除，故整体退役而非留占位。`config.github_repo` 保留（纯数据，拼 git 链接用）。
   - `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`：`@kanban_actions` 白名单删上述 4 项（:268）。
   - React `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx`：删 GitHub token 配置面板（KanbanList）、「PR 同步」按钮（sync_prs）、issue 棒「登记 issue」按钮（sync_github）、pr 棒「出站 GitHub」按钮（push_pr，连带死变量 `hasPr`）、`KanbanState.github` 类型字段、5 条不再可产生的错误码（github_token_missing / unauthorized / not_found / unreachable / no_pr_registered）；保留「登记 PR」/「挂代码文件」（纯数据动作）+ `github_repo_missing` / `bad_pr_number`。`vite build` 绿。
   - 验证：`mix test apps/ezagent_plugin_world/test` → 151 tests, 0 failures；`mix test apps/ezagent_plugin_kanban/test` → 83 tests, 0 failures（7 excluded）。

2. **cross_file_duplicate_fn baseline bump 43→45（+2，请 Allen review）**——`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` 按既有 arch-cap-bump 注释惯例 bump：Demo.Kanban boot-publish 照 hello 黄金样板一比一照抄（Task #162 boot-publish handoff 明确指示照抄 hello 流程），其 publish/admin_ctx 与 `Ezagent.Socialware.Demo.Hello` 结构性同形——sanctioned 模式的有意镜像，非 copy-paste fork。定点 `mix test apps/ezagent_core/test/architecture/cross_file_duplicate_fn_test.exs` 绿。

## Deferred（不在本片，显式挂起）

1. **S6 agent 自驱板真浏览器 e2e** — pm/dev 两个 cc-headless agent 自驱推板需要真 brain 凭证（**Q10 凭证问题**，等拍）；`docs/e2e/2026-07-06/kanban-team/` 里已有的人驱截图不当自驱证据（e2e 纪律：禁 stub 当 e2e）。
2. **S5 动态加入/admission + relay 硬锁** — (a) admission 复用 #1178 机制、等 Allen 拍 Q3 档位；(b) `{:from_role}` matcher 要改 core 路由原语，**不可自包含**，已按 §11 判定移平台 track。
3. **存量环境的 kanban-team body 升级** — boot seed 是 `seed_definition_if_absent`（by-design 不 clobber override），所以**已 seed 过旧 body（`views: []`）的环境不会自动拿到 S4 view**；fresh stack 无此问题。本地 dev DB 本轮经 `write_definition(authority: :system_seed)` 重写为新 body 后复验 gate。正式升级路 = registry P0 的版本化 promote（#1173/#1176），非本片发明新机制。

## Method friction（流程教训）

- **dev-together guard 撞了一次**：S1 曾把 relay overlay 写进 `.claude/skills/dev-together/references/`，被 PR CI 的 "Only repo owner may edit dev-together skill" guard 打红——dev-together 是 owner-only 团队契约，**任何分支不许改，哪怕是加薄 reference**。教训：给别人的 skill 加协作 overlay 时，overlay 归**自己这侧**的 skill 持有（现落 `.claude/skills/kanban-assistant/references/dev-together-relay-overlay.md`，指向同一份协议文档），对方 skill 保持零 diff。这与 §5.0「能力技能 vs 协作协议两层分开」是同一个原则的 CI 化。
- 顺手被同一轮 CI 揪出的第二课：lib/ 里硬引某 domain 模块时，`only: :test` 依赖是 latent "module not available" 炸弹（#57 gate）——`kanban_team.ex` 引 `DefinitionRegistry` 的当下就该把 `ezagent_domain_session` 提 prod dep（hello 先例），别等 CI。
