# Return: spawn-ownership-planb

> **Task:** spawn-ownership-planb — Plan B（`resource://` spawn 归属重构）· lead handoff `docs/together/2026-06-25/handoffs/spawn-ownership-planb.md`
> **Dev:** jjkysy (@姚升悦)
> **Commit:** `9b2ede5b`（Plan B）+ `5f5de0fa`（e2e 截图，HEAD）· **Branch:** `kanban-clean` · **Base:** `origin/main` @ `a56ca149`
> **returned_at:** 2026-06-25 · **deadline:** 2026-06-25 · **deadline_status:** on_time
> **Status:** ✅ 实现 + 确定性 gate + 真浏览器 e2e **全完成** — **pending Allen review**（§6 三个归属决策）。无 DoD 待办。

## Summary

落地 `kanban-merge.md`(#964) §6 当时列的 **Plan B**：照搬 `entity://` 已验证范式——**domain 拥 `resource://` scheme spawn dispatcher + 按 `URI.type/1` 查 core 注册表路由 plugin Kind，plugin 只声明 `{type, kind_module}`**——拆掉 kanban 原先在 `application.ex` `after_boot` 里 `SpawnRegistry.register("resource", …)` 的"plugin 注册核心 scheme 启动器"后门。这一步同时解掉 **#964 唯一真正的 CI 阻塞**（invariant 8 + `:ezagent_plugin_check` check 7 卡死 plugin 的 `*Registry.register`）。kanban 的 Kind / 24 action / URI / world dispatch **零改动**——纯归属面重构。

## What landed（`git show 9b2ede5b --stat` = 10 文件，+428 / −58）

**core（`ezagent_core`）：**
- **新** `lib/ezagent/resource_kind_registry.ex`（84 行）—— `AgentFlavorRegistry` 的 `resource`-scheme 同构体。bare ETS `:ezagent_resource_kind_registry`（`:set`，key=type 字符串，value=Kind 模块）。`register/2`（幂等；同 type 不同 module → `raise ArgumentError`）/ `lookup/1`（`{:ok, module}` \| `:error`）/ `list_all/0` / `table/0`。
- `lib/ezagent_core/ets_owner.ex` —— `@tables` 加 `{Ezagent.ResourceKindRegistry, :set}`（P22，紧挨 `AgentFlavorRegistry`）。
- `lib/ezagent/plugin.ex` —— 加 `resource_kind_decl/0` typedoc + sanctioned `@callback resource_kinds/0` + `defoverridable` 默认 `[]` + `boot/1` 消费段（`assert_resource_kind!/2` 校 Kind 实现 `Ezagent.Kind` → `ResourceKindRegistry.register/2`）。同 commit 删内联 `assert_config_surface!/2`、改调 `Plugin.ConfigSurface.assert!`。改后 **998 行**（< 1000 红线）。
- **新** `lib/ezagent/plugin/config_surface.ex`（49 行）—— `assert_config_surface!/2` 逐字搬出，行为 byte-for-byte 不变，单 caller=`publish/1`。
- `lib/mix/tasks/compile/ezagent_plugin_check.ex` —— check 3 链尾加 `check_modules(resource_kinds 的 kind_modules, Ezagent.Kind, "resource_kinds/0")`，认它为 sanctioned 声明出口。
- `test/architecture/arch_baseline_manifest.exs` —— `undocumented_public_defs` 392→**393**（+1 = `resource_kinds/0` 的 `defoverridable` 默认 stub，macro-emit 的 public head 挂不了 `@doc`，注释有 `arch-cap-bump` 理由）。

**domain（`ezagent_domain_workspace`）：**
- `lib/ezagent_domain_workspace/application.ex` —— `start/2` 加 `register_resource_spawn_fn/0`，注册 `resource` 的 spawn fn：`URI.type/1` → `ResourceKindRegistry.lookup/1` → `Ezagent.Kind.spawn/2`；type 查不到 → `{:error, {:no_resource_kind, type}}`，URI 无 type → `{:error, {:resource_uri_has_no_type, …}}`。对等 session domain 拥 `entity://`。

**plugin（`ezagent_plugin_kanban`）：**
- `lib/ezagent_plugin_kanban/application.ex` —— 删整个 `after_boot/0`（含旧 `SpawnRegistry.register("resource", …)`）；加 `def resource_kinds, do: [{"kanban", EzagentPluginKanban.Kanban}]`；moduledoc 改述 Plan B 起活路径。

**测试：**
- **新** `apps/ezagent_core/test/ezagent/resource_kind_registry_test.exs`（58 行，**5** tests）。
- **新** `apps/ezagent_plugin_kanban/test/e2e/spawn_via_resource_dispatcher_test.exs`（112 行，**2** tests）。

## Verification（dev-reported，确定性 gate）

- 全量 **architecture + invariants 串行 329 tests / 0 failures**。
- 本 commit 新测试 **7/0**：registry 5（register/lookup/list_all/幂等/冲突 raise）+ dispatcher-e2e 2（经 dispatcher 起活跑 add_node/CapBAC/drop + 未注册 type → `{:error, {:no_resource_kind, …}}` 不误起）。
- `doc.scan` **393/393**、`arch.scan`（`set_effect_sites` **128/128**、spawn / oversized PASS）、`check_invariants` clean、`format` 过、`:ezagent_plugin_check` per-app 过、各 app 0 failures。
- ⚠️ 全量**并行** 20 个失败 = 环境性超时；降并行 `--max-cases 4` → **0 failures**（与 #964 串行基线同性质的预存 flaky，**非本 commit 回归**）。

## 真浏览器 e2e（已完成，commit `5f5de0fa`）

Plan B 后重启 df-tech，真浏览器跑通完整链路——**全程经新 workspace `resource` dispatcher 起活**（不是 per-app 复刻闭包，而是真 workspace domain 真注册的那个）：建板 / 加节点 / 认领 / 改状态 / 挂代码文件出站 / 9 阶段接力链 / drop 全正常。看板经新 workspace dispatcher 起活；drop 截图实锤——节点砍掉 + drop 历史侧栏显示。截图 4 张为本任务最终 DoD 产物，在 `docs/superpowers/evidence/assets/{code-1-config,code-2-file,code-3-stages,drop-history}.png`。reviewer 可重启 phx 复跑确认。

## 已知局限（review 时校准）

- 新**单元/集成** e2e 测试 `spawn_via_resource_dispatcher_test.exs` **不加载真的 workspace domain**——kanban per-app test deps 只 dep core。该测试在 `setup` 里**复刻**了 `register_resource_spawn_fn/0` 的同构闭包（逐字一致）再断言。**真"两域同 boot"的端到端**由上面真浏览器 e2e（commit `5f5de0fa`）+ umbrella `mix test` + `ezagent_web` 覆盖——故那条真浏览器 e2e 是 load-bearing 验证、不是冗余，现已跑通。

## 对抗自审（dev 侧，交付前）

- **交付清单准不准** —— 对照 `git show 9b2ede5b --stat` 核实：10 文件 / +428 −58、新文件 3 + 新测试文件 2、LOC（registry 84 / config_surface 49 / dispatcher-test 112 / registry-test 58）、`plugin.ex` 实测 998 行。✅ 准。**修正一处概括偏差**：原任务概括说 doc cap "392→393"、`plugin.ex` 降回 "<1000"——manifest 实为 392→393 ✓；commit message 写"降回 999"但当前 worktree 实测 998（都 < 1000 红线，不影响结论，return 以实测 998 为准）。
- **DoD 可展示否** —— 确定性 gate 可复跑（✅ 已展示）；真浏览器 e2e **已跑通 + 截图已交**（commit `5f5de0fa`，4 张在 evidence/assets），reviewer 可重启 phx 复跑确认。✅ 全可展示。
- **决策点阻塞 vs 非阻塞分清** —— §6 ①②（dispatcher 归属 + `resource_kinds/0` 契约扩展）= 阻塞固化进 main 的 invariant-8 架构决策；③（`ConfigSurface` 搭车抽出）= 非阻塞风格确认。✅ 显式分级。
- **有没有未核对的断言** —— `entity://` 范式真存在?核实：`AgentFlavorRegistry` 在 `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`；`entity` dispatcher 由 domain 注册（`ezagent_domain_session/.../instance_message/application.ex:674` + `ezagent_domain_identity/application.ex:358`）。✅ 范式真实，"照搬"成立。invariant 8 / check 7 文本核实：`ezagent_plugin_check.ex:646-661`（六 scheme core/domain 拥有）+ `:726`（check 7 拦 `*Registry.register`）。✅。
- **一处主动暴露的风险** —— 范式"对"不等于"归属对":`resource` 该不该承载 live Kind、dispatcher 该不该放 **workspace** domain，是真架构决策（§6 ①），dev 不自行拍板，已升级给 Allen。

## Merge request

- **请求**：Allen review `9b2ede5b` 的 core/domain 改动 + 定夺 §6 ①②③（handoff §6）→ 决定 **cherry-pick `9b2ede5b` 单独成 PR** 或随 `kanban-clean`→main 一起合。
- **合并前置**：§6 ①② 归属决策 confirm。（真浏览器 e2e 已跑通、截图已交 commit `5f5de0fa`；reviewer 可重启 phx 复跑确认。）
- **依赖注意**：本 commit `arch_baseline_manifest` 392→**393** 接在 #964 的 392 基线上;一起合 / cherry-pick 时取 393，确认单调递增链没断。
- **取代关系**：本 Plan B **作废** `kanban-merge.md` §6 的 Plan A（review 时确认）。
- **不 commit**：本 return / handoff 文档由 lead 流程纳管，dev 侧不另起 commit。
