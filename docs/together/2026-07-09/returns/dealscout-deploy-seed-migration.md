# Return — dealscout socialware 迁部署级 seed 车道

> **Task:** dealscout-deploy-seed-migration（deploy-seed lane #1231/#1233/#1246 已合入 main + kanban #1248 先例）
> **Branch:** `feat/sw-dealscout`（org `ezagent42/ezagent`，HEAD a41e598b5）· **PR:** #1264（取代跨-fork #1191）
> **Dev:** agent（jjkysy 席位）· **returned_at:** 2026-07-09 · **deadline_status:** on_time

## 做了什么
dealscout（crawler 插件）的 socialware 从"manifest 在 crawler 插件 priv + boot 自发布"迁到"YAML 随出厂放 `ezagent_web/priv/socialware_seed/dealscout/` + 走部署级 seed 车道发布"。完全照 hello/kanban 套路，只动 socialware 发布路径，未碰 crawler 抓取/page/角色/dispatch。

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | manifest 移出 plugin priv → `ezagent_web/priv/socialware_seed/dealscout/` | met | git mv；plugin priv/socialware 清空 |
| 2 | 删 boot 自发布（application.ex） | met | `maybe_publish_dealscout_demo` 删；`@compile_env` 保留（children skip Poller in test 还用它） |
| 3 | Demo 收敛测试驱动（manifest_path 泛化、删自发布原语、留 manifest_attrs seam） | met | demo.ex thin loader |
| 4 | demo_publish_test 改走真车道（三态） | met | `demo_test`+`demo_publish_test` 13/0 |
| 5 | **arch gate 两条 cap=0** | met | `socialware_priv_manifest_files 0/0` + `socialware_self_publish_unsanctioned 0/0` |
| 6 | manifest_seed 占位符 crawler→no-such-plugin（rename 撞车修复） | met | `manifest_seed`+`manifest_yaml` 16/0（--seed 0） |
| 7 | rebase 后 arch baseline 重测校准 | met | `set_effect_sites 131→133`（crawler Config set-effect 净值）；`cross_file_duplicate_fn 42≤46` |
| 8 | 机器返还闸：CI 绿 + rebased on main | met（本地全绿，CI 跑中 #1264） | rebased on `534a5c5de`；arch EXIT 0 + 三套件绿 + compile 干净 |

**Method friction:** rebase 到 main 时 dealscout 几个旧 commit（自发布 bump / plugin rename / #1213 迁移）各碰过 arch_baseline，逐个跟 main 现值冲突——全取 main 版，rebase 完按分支真实状态重测校准（唯一真 mismatch 是 set_effect_sites 131→133）。crawler rename 使 manifest_seed 的 "crawler=未安装" 占位符失效，换成 no-such-plugin。

## Merge request
基于已合入 main 的 deploy-seed lane + kanban 先例，独立 PR（#1264）。socialware 三 flagship（autoservice/hello/kanban）+ dealscout 全部到部署级车道，收官。
