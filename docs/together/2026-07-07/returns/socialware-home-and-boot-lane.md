# Return — socialware 的"家"与 boot seed 车道（统一晚扫描）

> **Task:** socialware-home-and-boot-lane（实现 #1218 提案）
> **Branch:** `feat/sw-home-lane-impl`
> **PR:** https://github.com/ezagent42/ezagent/pull/1224
> **Dev:** agent（Claude，jjkysy 席位）
> **returned_at:** 2026-07-07 18:44 +0800
> **deadline:** 2026-07-07 23:59 +0800
> **deadline_status:** on_time

## 一句话

按 #1218 提案（Allen 已放行）落地"统一晚扫描车道"：所有 OTP app 启动完成后跑**一趟**扫描，把 (a) 部署级 `system://socialware` 目录 和 (b) 每个已启动 app 的 `priv/socialware/*/manifest.yaml` 走**同一条治理链**收编。文件位置一个没动、autoservice 发布逻辑没删，唯一可观察差异是它的发布时点从 boot 中段挪到 boot 尾。

## 做了什么（7 文件）

- `ManifestSeed` 重构：`scan_all!/1`（晚扫描入口，`enabled?`/test-skip 语义沿用）+ `scan_dir!/2`（参数化核心）；删掉 `scan_boot_manifests!`/`scan_priv_manifests` 与 domain_session `Application.start` 里的早扫描特例（不留 shim，发布逻辑本身原样保留）
- 触发点搬到 `EzagentWeb.Application.start` 末尾（web 是 umbrella 依赖闭包里最后启动的 app，依赖全部 19 个插件；带 P13 例外注释——它只是触发器，扫描逻辑归 session 域）
- 部署目录走 `Ezagent.System.FsResolver` 的 `system://socialware` 新 catalog 条目（OI-3 seam，不引入 raw `Home.path`；home-path anchor 118→122 重锚）
- `uses` 缺 plugin → 人话错误：`socialware manifest <名> requires plugin "crawler" which is not installed`；manifest 内容坏保持 fail-loud 炸 boot
- 日志逐条：来源 app + 名 + 三态结果（published / upgraded / exists）

## DoD reconciliation

DoD 从 #1218 提案的验收点派生（提案是设计文档，非逐行 build handoff；下表按提案"三个家+晚扫描+错误分层"目标枚举）。

| # | DoD line（源自 #1218 提案） | status | proof / open decision |
|---|------|--------|-----------------------|
| 1 | 扫描时机挪到全部 app 启动完成之后（时序问题整体消失） | met | 触发点 `EzagentWeb.Application.start` 末尾（web 依赖闭包最后启动）；`arch` 82/0 含 boot 序不变式 |
| 2 | 部署级 seed 目录不在任何 app 源码树内 | met | `FsResolver` `system://socialware` catalog 条目 + `fs_resolver_test.exs`；不引入 raw `Home.path` |
| 3 | 部署级 + 各 app priv + registry 三条家走同一治理链 | met | `scan_all!/1`→`scan_dir!/2` 统一入口，末端仍是 `publish_or_upgrade`；`manifest_seed_test` 15/0 |
| 4 | 错误分层：内容坏 fail-loud 炸 boot；缺 plugin 给可读 uses 错误 | met | 缺 plugin 人话错误串 + `manifest_seed_test` 覆盖坏内容 raise / 缺 plugin 分支 |
| 5 | autoservice（domain 侧引用）在晚扫描下仍正常发布（迁移正确） | met | `mix ezagent.socialware.check autoservice-tier1` → 13 断言全绿；boot 日志实证 `autoservice-tier1 (ezagent_domain_session) → exists` |
| 6 | 既有测试不回归 | met | manifest 套件 15/0、`apps/ezagent_core/test/architecture` 82/0（均在 rebase 到 main@#1221 后重跑） |
| 7 | 机器返还闸：CI 绿 + rebased on main | **partial**（见 gate 状态） | 快速 gate 全绿；`full-suite (self-hosted macOS)` 仍 pending，监控中 |

**Method friction:** 提案文档（#1218）本身不含逐行 DoD——它是设计输入而非 build handoff，DoD 是我从提案的验收目标反推的。若要严格走 dev-together 全环，这类"提案→实现"任务理应先出一份带闭集 DoD 的 build handoff 再开工。另：`manifest_seed_test.exs` 依赖 sibling `manifest_yaml_test.exs` 里的 fixture 模块，单文件跑会全挂，必须两文件同跑——这个跨文件依赖不显眼，值得在测试头部注一句。

## Gate 状态（机器返还闸）

- **rebase base:** `3b1782bd9a4f`（= 当前 `upstream/main` tip，含 #1220/#1217/#1221）✓ rebased on main
- **CI run:** https://github.com/ezagent42/ezagent/actions/runs/28860092852
  - `gate (deterministic)` → **pass**（2m9s）
  - `gitleaks secret scan` → **pass**
  - `Only repo owner may edit dev-together skill` → **pass**
  - `Return file advisory` → **pass**
  - `full-suite (self-hosted macOS)` → **pending**（监控中，绿了更新此处 + PR）
- **本地 re-verify（mise pin OTP27/1.18.4，rebase 后）：** conformance 13/13 · manifest 15/0 · arch 82/0 · `compile --warnings-as-errors` + `format` 干净

## 延后 / open decision（交 lead 裁定）

- **无 DoD 行延后。** 提案 §"对在途工作的影响"明确：#1190（kanban）/#1191（dealscout）的 flagship YAML 目前维持"出厂预装"形态；本 PR 落地晚扫描车道后，二者各一个 commit 完成迁移（挪文件 + 删薄加载器）——这是**后续任务**，不在本 return 范围，也不是延后的 DoD 行。

## Merge request

- 请把 `feat/sw-home-lane-impl`（PR #1224，head `6a2a392fc`，base `main`）纳入今日 stack。
- 无跨 PR 冲突：本 PR 只碰 socialware boot-seed 车道 + FsResolver catalog；已 rebase 到含 #1221 的最新 main 并全绿重验。
- 建议合并次序：本 PR 先落 → 然后 #1190/#1191 各自 rebase + 迁移 commit（依赖本车道）→ 最后 kanban-v2。
