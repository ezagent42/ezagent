# Return — kanban socialware 迁部署级 seed 车道

> **Task:** kanban-deploy-seed-migration（deploy-seed lane #1231/#1233/#1246 已合入 main）
> **Branch:** `feat/sw-kanban`（org `ezagent42/ezagent`）· **PR:** #1248（取代跨-fork #1190）
> **Dev:** agent（jjkysy 席位）· **returned_at:** 2026-07-08 17:19 +0800 · **deadline_status:** on_time

## 做了什么
kanban 的 socialware 从"manifest 在 kanban 插件 priv + boot 自发布"迁到"YAML 随出厂放 `ezagent_web/priv/socialware_seed/kanban/` + 走部署级 seed 车道发布"。完全照 hello/autoservice 套路，只动 socialware 发布路径，未碰看板/connector/dev-together/角色/dispatch。

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | manifest 移出 plugin priv → `ezagent_web/priv/socialware_seed/kanban/` | met | git mv；plugin priv/socialware 清空 |
| 2 | 删 boot 自发布（application.ex） | met | `maybe_publish_kanban_demo` + `@compile_env` 删，roles/BoardView 保留 |
| 3 | Demo 收敛测试驱动（manifest_path 泛化、删自发布原语、留 manifest_attrs seam） | met | `demo_test` 断言更新到新位置 |
| 4 | demo_publish_test 改走真车道（三态 published/exists/upgraded） | met | `demo_test`+`demo_publish_test` 12/0 |
| 5 | **arch gate 两条 cap=0**（迁移前红=1） | met | `socialware_priv_manifest_files 0/0` + `socialware_self_publish_unsanctioned 0/0` |
| 6 | boot-fallback 不被 kanban.yaml 破 | met | `manifest_seed`+`manifest_yaml` 17/0（剪枝到 autoservice） |
| 7 | integration 不回归 | met | `kanban_team_roundtrip`+`relay_back` 2/0（manifest_attrs 保留） |
| 8 | 机器返还闸：CI 绿 + rebased on main | **partial** | rebased on `b95f6d6bb`（org main，含全套 lane+gate）；CI full-suite 跑中（#1248） |

**Method friction:** 库从 fork 移到 org（避免跨-fork rebase/push 麻烦）；本 PR 是同库 #1248，取代跨-fork #1190。conformance 断言数 main-side 从 13→15，同步更新了 demo_publish_test 断言。

## Merge request
基于已合入 main 的 deploy-seed lane，独立 PR（#1248）。dealscout 同套路随后（另一 PR）。
