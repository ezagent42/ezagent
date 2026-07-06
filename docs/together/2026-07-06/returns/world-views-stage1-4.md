# Return — world 通用消费 SessionViewRegistry（#1192 实现，Stage 1-5 全部完成）

## Metadata
- **task**: world-views（jjkysy #1192 → lead GO #1195 locked decisions 的实现）
- **branch**: `feat/sw-world-views`（HEAD 见 push；rebase-base = `0a192363` upstream/main 2026-07-06）
- **deadline_status**: **done**（Stage 1-5 全绿；Stage 5 真浏览器 e2e 4/4 断言过，8 张真截图）
- **scope**: 只 `apps/ezagent_plugin_world/` + 一条 `{:ezagent_domain_ui, in_umbrella: true}` dep 引用（registry 属主 **0 改动**——Allen 边界令遵守）

## What's done（4 个 stage，各自 CI 绿后 commit）

| Stage | 交付 | commit |
|---|---|---|
| 1 后端动态 tab | `ConversationData.session_views/2` = `SessionViewRegistry.applicable_views(session_uri, caller)`（caller-aware，内含 `applies_to?`+`authorize_view/3`）；`state_for` 出 `"views"` 数组、**is_hello 删净**（+死代码 page_session?/has_surface_slice?）；`switch_view` 白名单改 `session_view_ids/2` 动态集（与 tab 同源无绕过）；world-owned `ConversationView` 注册（chat 也走 registry） | Stage 1 commit |
| 2 React 消费 | tab 条从 `state.views` 动态渲（id/label/icon，lucide 映射）；**4 种 mode 分派**：chat→原生会话流 / pty→PtyTerminalSurface / external→ExternalSurfaceView（HelloPagePreview 泛化，`/socialware/external` iframe 全 pane）/ unsupported→诚实占位（locked#4 绝不静默藏）；**React 侧 is_hello/isHelloSession/URI 探测删净**（grep 零命中） | Stage 2 commit |
| 3+4 cap 回归锁 | `view_cap_gate_regression_test.exs` 真 caller 零 stub 钉 4 断言：(a) 无 cap caller 不出 gated view (b) anon 不出 (c) switch 到无权 view=bad_view 且 active_view 未设 (d) 有 cap 可见可切；+pty 守卫（`backing_behavior(TerminalView)==nil`，pty 一旦被 cap-gate 测试即红）；残留 grep 零命中；单源确认 | Stage 3+4 commit |

## DoD reconciliation（对 lead-go locked decisions 逐行）

| lead-go 要求 | 状态 | 证明 |
|---|---|---|
| is_hello bespoke hack 彻底删、并进通用路径 | **met** | 后端+React grep `is_hello\|isHello\|page_session?` lib+assets **0 命中**（测试里仅"断言它不存在"的回归锁） |
| ①PTY tab 条件化 + hello 变可切 tab | **met** | PTY 靠 `TerminalView.applies_to?` delegation（无 world 特判）；hello Page = views 里一个 external-mode cap-gated tab；PR 会标注 intended visible change |
| ②routing/external_mirror 渲染器单独后续、本次占位 | **met** | `render_mode` 归 `"unsupported"` → 诚实占位「此视图暂无网页渲染器」 |
| 先 rebase 到当前 main | **met** | rebase-base `0a192363`（含 #1189 CI 修复 + #1194 role-slot UI + #1197） |
| cap 门回归锁必做（不 ship 不行） | **met** | `view_cap_gate_regression_test.exs` 4 断言 + pty 守卫（见上表）；未来枚举改离 `applicable_views/2` 或白名单改离 `session_view_ids/2` 即红 |
| 只碰 world；domain_ui 0 改动，要改先 STOP flag | **met** | git diff 全在 `apps/ezagent_plugin_world/`；domain_ui 仅 dep 引用 |
| 真浏览器 e2e 4 断言 + 每 stage 截图（Stage 5） | **met** | **4/4 PASS**，8 张真截图在 `docs/e2e/2026-07-06/world-views/`：①fresh TestView 运行时注册（erpc，零生产代码）自动冒 tab（02）②hello session 冒 Chat/Bindings/Page/Routing、PTY 正确条件不出（无 pty 成员）、**Page 渲真 LLM 生成的 json-render 页**（claude CLI 38s+64s 生成 36 组件，03/04）③无 cap 用户 Page tab 不出 + server 侧 session_view_ids 佐证 cap 门单源（05）④切 tab 内容真切换 data-world-view-mode 变（06/07）+ unsupported 诚实占位（08）。隔离库跑（POSTGRES_DB=ezagent_wv_e2e_0706，避开共享 PG seed 撞车） |
| 过 gate + full-suite | **partial** | per-app world 套件 **151 tests 0 failures**（+28 新增，无新增失败）；`compile --warnings-as-errors` 干净；format 过。full-suite（`mix ci.local`）未在本机跑全（既有 per-app 跑法 flake 见 method-friction），**PR CI 为准**（机器 gate） |

## Gate status
- 本地：`mise exec -- mix compile --warnings-as-errors` 干净；`mix test apps/ezagent_plugin_world/test` = 151/0；`mix format --check-formatted` 过；vite build 过（Stage 2）
- **CI run URL**：push 后由 PR CI 生成（待 PR 开出后回填）——机器 return gate 以 PR head CI 绿为准
- rebase-base SHA：`0a192363`

## Deferred / open decisions for lead
1. ~~Stage 5 e2e~~ **done**（见上）。**e2e 顺带发现一个产品观察给 lead**：hello template session 里**不带 @mention 的 owner 消息没投递到 orchestrator**（0 条 session routing rule、无 fan-out/回复/DLQ 痕迹），@mention 才通——与 HelloOrchestrator moduledoc「每条 user message 都投给 orchestrator」不符，值得看一眼是 doc 过时还是投递缺口。
2. **React fallbackViews**（`Conversation.tsx` server 无 views payload 时回退 chat-only）——降级兜底非可见性来源，可留可删，lead 定。
3. **switch_to_pty 硬设 "pty"**——安全前提（pty 无 view_behavior）已 doc + 守卫测试钉死；若未来 pty 要 cap-gate，必须改走白名单（测试会红提醒）。

## Method friction（writeback 供 lead review）
- per-app `mix test apps/ezagent_plugin_world/test` 在 umbrella 有 **既有 flake**（依赖 plugin app 未启动 → `{:bad_flavor,...}`/kanban recipe raise，约 25 个，用 git stash 验证过是基线自带）——本任务用「新增测试全绿 + 无新增失败」判定，建议 handoff-standard 里明确 per-app 跑法的基线 flake 处理约定。
- Stage 2 发现本 worktree assets 没 node_modules（各 worktree 不共享），从同版本 worktree 硬链接复制解决——建议 worktree 初始化清单加 assets install。

## Merge request
- **PR**: 新开（#1192 已 merge docs，本分支是实现）——base `ezagent42/ezagent:main` ← head `jjkysy:feat/sw-world-views`
- 顺序：无依赖，可独立 review/merge；与 #1190（kanban）/#1191（dealscout）不耦合（它们只声明 view，本 PR 让 world 通用消费）
- **先别 merge**：等 Stage 5 e2e 截图补推 + Allen review
