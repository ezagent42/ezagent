# DealScout Stages A–D return（爬取后台 plugin + 纯配置 Definition）

> Workstream: dealscout socialware（发现腿地基 + Stage D Definition seed）
> Date: 2026-07-06
> Branch: `feat/sw-dealscout` · PR: #1191（CI = PR checks，https://github.com/jjkysy/ezagent-biz/pull/1191/checks）
> Rebase base: `0a192363`（upstream/main）
> Spec/plan: `docs/together/2026-07-05/handoffs/dealscout/spec.md` + `plan.md`（含 2026-07-06 返工 banner）
> Status: Stage A/B/C（含返工）/D 完成 + **boot 自动发布（governance publish，接替 seed）+ crawl_auto 接进 live 路径** 完成；Stage E/F（两条腿 e2e）deferred
>
> **注（后续 commit 改动，见下方 §Boot 自动发布 / §crawl_auto 接线）**：本文档里 Stage D 节的
> `definition_seed.ex` / `maybe_seed_dealscout_definition` / `DealScoutConformanceTest` 描述是
> point-in-time——之后已被 `demo.ex`（`EzagentPluginDealScout.Demo`，governance publish）整体替换，
> `definition_seed.ex` 删除；`visibility_policy` 也从 `scope: :private` 改成 `scope: :public` +
> `publish_policy: :supervised`（admin-gated publish ctx 已带 `admin_genesis_cap`）。

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

## Boot 自动发布（照 kanban/hello 黄金样板，接替 Stage D 的 imperative seed）

**单一真相进 `demo.ex`**（`apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/demo.ex`，
`EzagentPluginDealScout.Demo`，照 `EzagentPluginKanban.Demo` / hello #162 样板）；
`definition_seed.ex` 成死代码**已删**（kanban 删 `kanban_team.ex` 同款决策），其测试迁移见下。

- **`manifest_attrs/1`**：string-keyed、`ManifestResolver.resolve/1`-ready 的 config-authored
  manifest。opts：`:name`（per-run 唯一，测试隔离）+ `:flavor`（**只换 discover 槽**的
  cc-headless；`page` 槽是 hello 组合的一部分（`hello.builder × native`）不随 stub 换——与
  kanban"两槽都换"的差异，因 kanban 两槽本来都是 cc-headless）。
- **manifest 内容 vs seed 的差异**：`views: ["hello_render"]`（string ref，经 hello 注册的
  `PageView` 解析到 `Ezagent.ActionSet.HelloRender`）；`visibility_policy` 改
  `%{scope: "public", publish_policy: "supervised", web_anon_access: true}`——scope public
  全域可发现（admin 门由 publish ctx 的 `admin_genesis_cap` 过）+ **`web_anon_access: true`
  跟 kanban 的 false 不同**（dealscout 公开面给匿名访客看线索页，产品语义）；新增
  `legends`（`member_set: ["discover","page"]` fronting `dealscout-update` rule_set，kanban 同款）；
  roles / routing_rules（只有 `__dealscout_update__` → `page` 那条，**绝无 hello 的
  `always → chat`**）/ adapters（`external_feed`）/ uses 照 seed 原样转 string-keyed。
- **`publish/0`** 经 `Governance.publish_or_upgrade/2`（真 governance flow：open_cr → stage →
  publish）发进 `workspace://system`；`published?/0` 幂等谓词；admin_ctx = `user://system/admin`
  + manage cap + `admin_genesis_cap`（public scope 的 admin 门）。
- **boot 调用点**：`application.ex` 的 `maybe_seed_dealscout_definition`（boot-safe 降级 log）
  **整体替换**成 `maybe_publish_dealscout_demo`——**fail-loud**（publish 失败 raise、boot 拒起，
  dogfood 真发布路径）+ `:test` 跳过（Ecto sandbox 争用，ExUnit 在 sandbox 里驱动同一个
  `Demo.publish/0`），照 kanban `maybe_publish_kanban_demo` / hello `maybe_publish_hello_demo`。
- **测试迁移**（`definition_seed_test.exs` 删，拆成两份照 kanban）：
  - `demo_test.exs`（9 条，无 DB）：manifest 过 `ManifestResolver.resolve/1`、per-run 唯一名 seam、
    `:flavor` 只换 discover 槽、hello 公开面组合（Surface+Turn/external_feed）、两角色槽零实例
    URI、recipe 名可解析到两家 plugin `roles/0`、只有 update rule（无 always）、
    public+supervised+**anon-readable**+installer owner、legends。
  - `demo_publish_test.exs`（2 条，DataCase sandbox）：**幂等三态** `:published` →
    `:exists`（同 revision，obj.id 不变）→ `:upgraded`（改 description 后新 revision +
    content_hash 对上）；PUBLIC 跨 workspace `DefinitionRegistry.list/1` 可发现（且唯一一条）+
    发布后 **conformance 12/12**（同 `mix ezagent.socialware.check dealscout` 保证）。
- **gate 证据**：`mix test apps/ezagent_plugin_dealscout/test` → **51 tests, 0 failures**；
  `POSTGRES_DB=ezagent_dealscout_boot_check_dev mix ezagent.socialware.check dealscout`（**全新
  scratch DB**，ecto.create+migrate 后直接跑）→ `✓ dealscout: all 12 assertions pass`——fresh DB
  上 mix task 能 lookup 到 Definition **只可能**来自 boot 的 `Demo.publish/0`（seed 路径已删），
  即 boot 自动发布真的在 dev 起效。

## crawl_auto 接进 live 路径（Stage B 尾巴收口）

之前 `Fetch.crawl_auto/1`（source 有无自动分流决策点）已写好已测，但 live 路径
（`DealScoutCrawl.handle_crawl_now` / `Poller`）仍调纯公开的 `Fetch.crawl/0`。本次接线：

- **`Config` 补 sources 存取**：`set_sources/2` → `{:set, :sources, list}` slice effect
  （每项 `%{url, source}`，**任一坏条目 fail-closed 拒整批**）；`sources/1` / 
  `normalize_sources/1` 读回归一（slice 经 snapshot round-trip 后可能 string-keyed，
  atom/string 双读，坏条目丢弃）。token 仍走 `system://credentials` 凭证文件（不进 slice）。
- **`handle_crawl_now`**：`fetch_fun().(config_sources(ctx))`——sources 从 **config slice** 的
  `:sources` key 读（framework 注入的 `ctx[:read]` reader，kb.ex 同款契约；无 reader 降级 `[]`
  纯公开）。`:fetch_fun` seam 从 arity-0 `Fetch.crawl/0` 改 **arity-1 `Fetch.crawl_auto/1`**。
  `:search` 不走 crawl_auto（query 参数化检索是 `search_fun` 独立腿，moduledoc 已注明）。
- **`Poller` 同步**：`poll_once` → `fetch_fun().(configured_sources())`；Poller 是无 session 的
  全局 timer（无 slice），sources 读 **operator 级 app env `:sources`**（同形状，同
  `normalize_sources/1` 归一）——moduledoc 写明两条路 sources 来源的差异。
- **TDD 接线测试**（`dealscout_crawl_test.exs` 新 describe 4 条 + `poller_test.exs` +1 +
  `config_test.exs` +4）：
  - seam 层：slice 配了 string-keyed source → 归一成 `%{url:, source:}` 进 crawl seam；
    无 `:read` / 空 sources → seam 收 `[]`（纯公开）。
  - **REAL path**（不 stub `:fetch_fun`，走真 `Fetch.crawl_auto/1`，只 stub 底层 `:httpc` +
    写真 token）：配 source + token → 注入同时含 `[public]` 和 `[directed]` 条目 + 更新信号；
    没配 source → 全 `[public]` 无 directed。
  - Poller：app-env `:sources`（含一条坏条目）→ 归一后进 seam，坏条目丢弃不 crash timer。

## Deferred（Stage E/F）

- **Stage E 发现腿 e2e**：信号→hello 页面刷新的 runtime 腿（上文 open decision：`HelloBuilder` `from_user?` 门放行方案，需 hello 侧小改或 dealscout 侧 user-authority 转发，等拍板）+ 真浏览器 e2e（爬完 → hello 页更新 + 按 source_type 分类展示 + 每步 `ab_shot` 截图）。
- **Stage F 撮合腿 e2e**：install → world 路径建 session（`ensure_session_orchestrator` 补 `orch_<name>`）→ 匿名只读 / 登录自助 join+发言 → concierge 回帖 → founder 看身份 invite 深聊，全链真浏览器 e2e + 截图（spec §4 两个硬前提验证）。

## Method friction

- **共享 dev DB drift 挡 bare `mix ezagent.socialware.check`**：dev DB 里有一条陈旧的 `recipe:kanban-manager` ConfigObject（body 与本分支 kanban 代码不同）→ kanban 插件 boot 时 `RoleSeedHook` 撞 `{:role_seed_collision, "kanban-manager"}`、整个 `app.start` 起不来——**pre-existing（HEAD 上 stash 掉本次改动复现同样失败），与 dealscout 无关**。本次绕行 = 用 `POSTGRES_DB` env seam 起干净 scratch DB 跑 gate。建议：conformance gate 在 CI/本地都对 disposable DB 跑（或 RoleSeedHook 对同名旧 body 提供显式 migrate 路径），否则任何 recipe body 演进都会把共享 dev DB 变成 gate 障碍。
- **bare `mix ezagent.socialware.check`（无参数）在 `DefinitionRegistry.list_names/1` 缺失时只静默验 chat+socialware**（kanban return 已报过）——所以照 kanban 先例把 **自包含 conformance ExUnit 测试** 落进套件常驻（`DealScoutConformanceTest`），CI 不依赖按名跑 mix task。
- **plan 里的示例代码需现读矫正**：plan Task 10 示例的 `uses: [:ezagent_plugin_hello]`（atom）、`match/receiver` key 形态与实际校验边界不一致；实际按 `Definition.new/1` + conformance 现读落成 `uses: ["hello","dealscout"]`（plugin slug 字符串）+ kanban 的 string-keyed rule 形态。spec/plan 的"实现期现读确认"标注是对的，照做即可。
