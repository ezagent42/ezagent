# Return — socialware 部署级 seed 机制 + seed-path gate

> **Task:** socialware-deploy-seed（issue #1226 决策 / spec `docs/superpowers/specs/2026-07-07-socialware-deploy-seed-design.md`）
> **Branch:** `feat/sw-deploy-seed`（HEAD `70c7e3a82`，rebased on `upstream/main` @ `404f43ca6`）
> **PR:** 待 Allen 开（agent 不开 PR）
> **Dev:** agent（Claude，jjkysy 席位）
> **returned_at:** 2026-07-07 23:37 +0800
> **deadline:** 2026-07-07 23:59 +0800
> **deadline_status:** on_time

## 一句话

按 Allen #1226 拍板（部署级目录为 canonical）落地 socialware 部署级 seed 机制：仓库源 `ezagent_web/priv/socialware_seed/<name>/` → `Ezagent.Home.SocialwareSeed.seed!/0` 幂等 copy → `$EZAGENT_HOME/<profile>/socialware/` → 已在 main 的晚扫描车道发布。gate-first 加 arch gate 禁"非框架 socialware 直接 seed"，autoservice 迁入闭环。kanban/dealscout 随后各自分支采纳。

## 做了什么（5 commit）

- `dc79ce6f2` gate-first：arch.scan 加两 counter——`socialware_priv_manifest_files`(target-zero) + `socialware_self_publish_unsanctioned`(ratchet cap=1) + gate 测试。打开即红（抓 autoservice priv）。
- `99fd3914d` `Ezagent.Home.SocialwareSeed`（core）：`source_dir/0`(运行时 `:code.priv_dir(:ezagent_web)`，无 compile-dep) + `seed!/1` 幂等 `File.cp_r`（`unless File.exists?` 跳过）。
- `871f6dd14` `Home.skeleton_dirs` += `:socialware`；`home.init` 调 `seed!/0`。
- `33aefb36f` boot 兜底：`manifest_seed.ex` `deploy_sources` 无 `:deploy_dir` override 时先 `seed!/0` 再扫（CI/dev 不跑 home.init 也有 flagship）；有 override 跳过（测试隔离）。
- `42f97770e` 迁 autoservice：`git mv` 整目录（manifest/package/kb/persona）domain_session priv → `ezagent_web/priv/socialware_seed/`；改所有引用（seed 脚本、manifest_yaml_test、manifest_seed_test:102/116）；moduledoc 标 app-priv 车道 DEPRECATED；gate 转绿。

## DoD reconciliation（源自 spec §1-8）

| # | DoD line | status | proof |
|---|---|---|---|
| 1 | SocialwareSeed 幂等 copy 源→部署目录 | met | `socialware_seed_test` 5/0（copy/幂等不覆盖/缺源 no-op/源解析） |
| 2 | home.init += :socialware + seed 调用 | met | `home_test` 7/0 |
| 3 | boot 兜底扫描前 seed | met | `manifest_seed_test` 16/0（deploy 缺失→seed→发布） |
| 4 | gate 禁 priv/socialware manifest + 非框架自发布 | met | arch.scan `socialware_priv_manifest_files 0/0` + `self_publish 1/1` |
| 5 | gate-first 流程 | met | `dc79ce6f2` 红 → `42f97770e` 绿 |
| 6 | autoservice 迁 socialware_seed + 改 manifest_seed_test:102 | met | `42f97770e` git mv + 测试改断言 |
| 7 | core 不 compile-dep web/session | met | skill-1 核实 + `layer_purity_test` 3/0（运行时 atom `socialware_seed.ex:40`） |
| 8 | 验证全绿 | met | arch.scan exit0 / architecture 87/0 / manifest 16/0 / core gate+seed+home 17/0 / format 干净 |
| 9 | autoservice 经部署目录发布正确 | met（经测试） | `manifest_yaml_test:170` conformance→import→install→materialize→route 绿。**注**：`mix ezagent.socialware.check autoservice-tier1` 本轮跑不通——非本改动，见下 |
| 10 | 机器返还闸 CI 绿 + rebased | **partial** | rebased on `404f43ca6` ✓；CI 待 Allen 开 PR 后跑 |

**Method friction:**
- 这是"issue 决策 → 实现"任务，无逐行 build handoff，DoD 从 spec 反推。
- `mix ezagent.socialware.check` 本轮**在 main 上就崩**（`{:role_seed_collision, "orchestrator"}`，cc 插件 boot，#1223/#1225 后 check-task 回归），无法用作 autoservice 验收闸——退回 `manifest_yaml_test` 覆盖。这条 check-task 回归值得单独修（与本 PR 无关）。

## 与 #1228（M3 requires）对齐

正交。#1228 spec 明确："The deploy-seed mechanism (#1226, jjkysy's lane). M3 doesn't touch how socialwares are deployed to the node." 本 PR 不影响 M3。

## 开放决策（交 Allen）

- **gate 拆两 key**（计划名单 gate）：`socialware_self_publish_unsanctioned` 把 `hello`（插件自发布，`hello.ex:203`）记 ratchet `cap=1`，设计 §5 严格应为 0。hello/kanban/dealscout 是**别分支** scope 的 plugin 自发布——设为文档化 burn-down（记录现状，同 manifest 处理在途债的方式）。要 hello 迁移/框架 sanctioned 则改此 cap。
- **分层 smell**（skill-1 minor）：core 运行时引用 `:ezagent_web` 作 seed 源，无 compile-dep 违规、有 `Credential.Adopt` 先例，但存运行时耦合。
- **两个 pre-existing 红**（非本 PR）：cc `Jason` 缺 `:jason` dep（`cc_agent.ex:739`）；上面的 orchestrator check-task 回归。
- **cleaner**（已开 issue #1227）：app-priv 扫描/退役自发布成死路径，待定期清。

## Merge request

- 请把 `feat/sw-deploy-seed`（`70c7e3a82`，base main）纳入 stack。本 PR 内闭环 **autoservice**。
- 次序：本 PR 先落 → kanban(#1190)/dealscout(#1191) rebase 采纳（各把 manifest 迁 `ezagent_web/priv/socialware_seed/` + 删自发布 + 测试接线，其 plugin 自发布随之从 gate ratchet burn-down）。
