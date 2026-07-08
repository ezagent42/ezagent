# Return — socialware 部署级 seed 机制 + autoservice 迁入（栈①）

> **Task:** socialware-deploy-seed-mechanism（issue #1226 · spec `docs/superpowers/specs/2026-07-07-socialware-deploy-seed-design.md`）
> **Branch:** `feat/sw-seed-mechanism` · **PR:** #1231 · **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-08 09:14 +0800 · **deadline_status:** on_time
> **栈：** ①（本）→ ② #1233 → ③ #1236，按序合并

## 做了什么
`Ezagent.Home.SocialwareSeed`（core，枚举所有 app `priv/socialware_seed/*` 幂等 copy → `$EZAGENT_HOME/<profile>/socialware/`，不点名上层 app）+ `home.init` 加 `:socialware` skeleton 并调 seed + `ManifestSeed.deploy_sources` boot 兜底 + autoservice 整目录迁 `ezagent_web/priv/socialware_seed/`。

## DoD reconciliation
| # | DoD | status | proof |
|---|---|---|---|
| 1 | SocialwareSeed 幂等 copy（跳过已存在，尊重运维手改） | met | `socialware_seed_test` 5/0 |
| 2 | de-smell：core 不点名上层 app | met | `source_dirs/0` 枚举 `Application.loaded_applications()` |
| 3 | home.init += :socialware + boot 兜底 | met | `home_test` 12/0 |
| 4 | autoservice 迁部署级源 + 测试改断言 | met | `manifest_seed_test`+`manifest_yaml_test` 17/0 |
| 5 | 机器返还闸：CI 绿 + rebased on main | **partial** | rebased on `403a7e2ee`（含 #1230/#1234）✓；CI 快速 check（gate deterministic/gitleaks/…）pass，**full-suite pending** |

**Method friction:** rebase 到含 #1230(requires) 的 main 时 `manifest_yaml_test.exs` 双方都改但 hunk 不重叠、git 自动合，已跑测试确认语义 OK（17/0）。此前 subagent 提交未走 dev-together return——本轮补齐。

## Merge request
栈首个，先合。合后 ②#1233 rebase 到 main 即只剩 hello delta。
