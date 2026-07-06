# DealScout Stages A–D return（爬取后台 plugin + 纯配置 Definition）

> Workstream: dealscout socialware（发现腿地基 + Stage D Definition seed）
> Date: 2026-07-06
> Branch: `feat/sw-dealscout` · PR: #1191（CI = PR checks，https://github.com/jjkysy/ezagent-biz/pull/1191/checks）
> Rebase base: `0a192363`（upstream/main）
> Spec/plan: `docs/together/2026-07-05/handoffs/dealscout/spec.md` + `plan.md`（含 2026-07-06 返工 banner）
> Status: Stage A/B/C（含返工）/D 完成；Stage E/F（两条腿 e2e）deferred

## What's done（按 Stage）

| Stage | Commit | 内容 |
|---|---|---|
| **A 爬取骨架** | `19de173a3` | `apps/ezagent_plugin_dealscout/` 插件脚手架（`use Ezagent.Plugin` + `:ezagent_plugin_check` gate）+ `Poller`（email inbound 轮询 idiom，test-boot skip）+ `Fetch`（`:httpc` + `{:body_format, :binary}` 治中文乱码）+ `Ezagent.ActionSet.DealScoutCrawl`（`:crawl_now`，P14 dispatch 注入 `session.send`，失败 telemetry fail-loud） |
| **B 配置 + recipe** | `040c05cb6` | `Config`（profile/keywords slice effect + token 走 `system://credentials/dealscout_<src>.yaml`，无 token fail-closed 跳过 + telemetry）+ source 自动分流（无 token 只爬公开 `:public`；有 token 加抓定向 `:directed`）+ 发现腿 4 recipe（discover/search/organize/followup，flavor-agnostic，caps 只在 recipe） |
| **C + 返工** | `2348c3ccd` → `d41524f57`/`3f791b63c` | Stage C 曾建 `DealScoutRender`/`DealScoutView`；**2026-07-06 用户拍板返工：显示归 hello，dealscout = 后台 + 信号**——render/view 全删，改为爬完注入新线索后 emit 更新信号 `__dealscout_update__`（`DealScoutCrawl.update_signal/0`，injected=0 不发，dispatch 失败 `[:dealscout, :update_signal, :error]` telemetry）+ `:search` 同链；push/search + `RetentionSweeper` 保留 |
| **D Definition seed（本次）** | 本 return 同 commit | `definition_seed.ex`（**纯配置 config-as-data**，照 kanban `kanban_team.ex` 结构：`definition_body/0` + `seed_definition/1`）+ `application.ex` boot code-seed（`maybe_seed_dealscout_definition`，test 跳过 + try/rescue boot-safe，照 kanban `maybe_seed_kanban_team`）+ 自包含 conformance 测试（`DealScoutConformanceTest`，`EzagentCore.DataCase` 直调 `Conformance.check/2`，12/12）+ 旧文档清（5 份 doc 补返工 banner） |

## Stage D Definition body（关键写法，全部现读判定）

- **uses**: `["hello", "dealscout"]`（依赖声明，非组合轴）。
- **组合 hello 公开面（零改 hello）**：`bases` = `Session` + `Publisher.SessionImpl`、`shape` = `Turn` + `Surface`、`adapters` 含 `external_feed`、`visibility_policy` = `%{publish_policy: :auto, web_anon_access: true, scope: :private}`（匿名可读自助开；scope private 不触发 admin 门）——逐项复制 hello `app.ex` `seed_hello_definition`。
- **views**: `[Ezagent.ActionSet.HelloRender]`——hello `PageView.applies_to?` 以 `"hello" in definition.uses or HelloRender in definition.views` 认领渲染（现读 `page_view.ex:56-62` 确认），dealscout 自己零 view/render。
- **roles（#1180 role-slot，零实例 URI）**：
  - `%{role_name: "discover", fill: :agent, recipe: "dealscout-discover", flavor: "cc-headless"}`（发现副驾，持 crawl cap）；
  - `%{role_name: "page", fill: :agent, recipe: "hello.builder", flavor: "native"}`（更新信号的声明式 receiver；recipe 名现读 hello `application.ex:132-139` 确认是 `hello.builder`，flavor `native`）。
- **routing_rules（内容协议，像 kanban relay `__done__`）**：`text_contains(DealScoutCrawl.update_signal())` → receivers `["page"]`（已声明角色名，conformance `routing_receivers_resolve` 只认这个）、`rule_set: "dealscout-update"`、零实例 URI、无 sender-lock（round-trip 安全）。
- **owner_policy**: `%{type: :installer}`（`:fixed` 被 `Definition.new/1` 拒）。

### hello 页面 agent 怎么接（现读判定 + open decision）

现读确认：**hello 自己的页面前台 `orch_<name>` 不是 role 槽**——hello 的 Definition `roles: []`，orchestrator 由 hello 命令式按名重挂（`EzagentPluginHello.App.ensure_session_orchestrator`，`app.ex:136-152`，对任何经 world 路径建的 page session 都补；world `conversation_actions.ex` 调）。所以本 Definition **不声明（也声明不了）那个 orchestrator 槽**；公开面 concierge 回帖链照 spec §4 的两个硬前提走 world 路径即通。

更新信号的 receiver 改为声明 `"page"` 槽（`hello.builder` × `native`，hello 真实声明的页面生成 recipe）——conformance 下最干净的零 URI 写法。**Open decision（Stage E 收口）**：今天 `HelloBuilder.handle_receive` 有 `from_user?` 门（`hello_builder.ex:56-63`，只对 USER-sender 触发生成，防自环），而更新信号 sender 是爬取 agent——信号到达 "page" 成员后**今天不会自动触发页面重建**。信号→页面刷新的 runtime 腿是 Stage E 的活（候选：hello 侧放行带标记的 agent 信号 / dealscout 侧 user-authority 转发），**本 Stage 不私改 hello**；声明面（roles/routing/views）按目标形态落定、不用返工。已写进 `definition_seed.ex` moduledoc。

## DoD 对账（对 spec 硬要求逐行）

| spec 硬要求 | 状态 | 证据 |
|---|---|---|
| §3.1 两种触发口径（无 token 爬公开 / 有 token 加定向） | ✅ | `fetch.ex` `crawl/0`（`:public`）+ `fetch_directed/2`（读 token 注入 header）；`fetch_directed_test.exs` |
| §3.2-1 每条线索必带 `source_type`（`:public`/`:directed`） | ✅ | `Fetch.parse_items/2` 出口打标；`fetch_test.exs`（含中文不乱码断言） |
| §3.2-2 展示归 hello、按 source_type 分类（dealscout 不渲染） | ✅ | dealscout 零 view/render（`application.ex` 不注册 SessionView/behaviors）；线索 body `format_item/1` 带 `[public|directed]` 标供 hello 分类 |
| §3.2-3 token 缺失 fail-closed（显式跳过 + telemetry） | ✅ | `fetch_directed/2` `:error` 分支 `[:dealscout, :fetch, :skipped_no_token]`；`config_test.exs` |
| §3.2-4 注入走 P14（dispatch 失败 telemetry 不 silent） | ✅ | `dealscout_crawl.ex` `Ezagent.URI.with_action` + `Router.dispatch` seam + `[:dealscout, :inject, :error]`；`dealscout_crawl_test.exs` |
| §3.2-5 爬完 emit 更新信号（injected=0 不发，失败 telemetry） | ✅ | `emit_update_signal/3` + `update_signal/0` 常量；测试断言标记非硬编码 |
| Definition 纯配置（零代码 DATA、17 字段子集、round-trip） | ✅ | `definition_seed.ex` `definition_body/0`；`definition_seed_test.exs` round-trip 过 `Definition.new/1` |
| #1180 role-slot（零实例 URI / 退休字段 / installer owner） | ✅ | 测试断言无 `agents`/`members`、rule 无 `entity://.../agent|user/`、owner `%{type: :installer}` |
| caps 只来自 recipe（Definition 无 caps 字段） | ✅ | caps 全在 `recipes.ex` `requested_caps`；Definition body 无任何 cap 声明 |
| 自包含（只碰 dealscout 包 + docs，零改 hello/world/core） | ✅ | 全部改动在 `apps/ezagent_plugin_dealscout/` + `docs/`；`git diff --stat` 可验 |
| conformance gate 全绿 | ✅ | `mix ezagent.socialware.check dealscout` → `✓ dealscout: all 12 assertions pass`；+ 常驻 `DealScoutConformanceTest`（12/12） |

## Gate 状态

- `mise exec -- mix test apps/ezagent_plugin_dealscout/test` → **39 tests, 0 failures**（含 Definition 单测 7 条 + 自包含 conformance 1 条）。
- `mise exec -- mix ezagent.socialware.check dealscout` → **`✓ dealscout: all 12 assertions pass`**（跑在干净 scratch DB `ezagent_dealscout_check_dev` 上，经 `config/dev.exs` 的 `POSTGRES_DB` seam；boot code-seed 被真实走到——mix task 是从 registry lookup 到 seed 出来的 Definition 的）。
- `mise exec -- mix format --check-formatted` → 过。
- CI：PR #1191 checks（push 后重跑），rebase-base `0a192363`。

## Deferred（Stage E/F）

- **Stage E 发现腿 e2e**：信号→hello 页面刷新的 runtime 腿（上文 open decision：`HelloBuilder` `from_user?` 门放行方案，需 hello 侧小改或 dealscout 侧 user-authority 转发，等拍板）+ 真浏览器 e2e（爬完 → hello 页更新 + 按 source_type 分类展示 + 每步 `ab_shot` 截图）。
- **Stage F 撮合腿 e2e**：install → world 路径建 session（`ensure_session_orchestrator` 补 `orch_<name>`）→ 匿名只读 / 登录自助 join+发言 → concierge 回帖 → founder 看身份 invite 深聊，全链真浏览器 e2e + 截图（spec §4 两个硬前提验证）。

## Method friction

- **共享 dev DB drift 挡 bare `mix ezagent.socialware.check`**：dev DB 里有一条陈旧的 `recipe:kanban-manager` ConfigObject（body 与本分支 kanban 代码不同）→ kanban 插件 boot 时 `RoleSeedHook` 撞 `{:role_seed_collision, "kanban-manager"}`、整个 `app.start` 起不来——**pre-existing（HEAD 上 stash 掉本次改动复现同样失败），与 dealscout 无关**。本次绕行 = 用 `POSTGRES_DB` env seam 起干净 scratch DB 跑 gate。建议：conformance gate 在 CI/本地都对 disposable DB 跑（或 RoleSeedHook 对同名旧 body 提供显式 migrate 路径），否则任何 recipe body 演进都会把共享 dev DB 变成 gate 障碍。
- **bare `mix ezagent.socialware.check`（无参数）在 `DefinitionRegistry.list_names/1` 缺失时只静默验 chat+socialware**（kanban return 已报过）——所以照 kanban 先例把 **自包含 conformance ExUnit 测试** 落进套件常驻（`DealScoutConformanceTest`），CI 不依赖按名跑 mix task。
- **plan 里的示例代码需现读矫正**：plan Task 10 示例的 `uses: [:ezagent_plugin_hello]`（atom）、`match/receiver` key 形态与实际校验边界不一致；实际按 `Definition.new/1` + conformance 现读落成 `uses: ["hello","dealscout"]`（plugin slug 字符串）+ kanban 的 string-keyed rule 形态。spec/plan 的"实现期现读确认"标注是对的，照做即可。
