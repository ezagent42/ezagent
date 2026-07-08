# Return — socialware 部署级 seed 车道（三 PR 栈：机制 / hello / gate）

> **Task:** socialware-deploy-seed（issue #1226 决策 + spec `docs/superpowers/specs/2026-07-07-socialware-deploy-seed-design.md`）
> **Stack（按序合并 ①→②→③）:**
> - ① `feat/sw-seed-mechanism` — PR #1231 — seed 机制 + autoservice 迁入 + de-smell
> - ② `feat/sw-hello-deploy-seed` — PR #1233 — hello 迁部署级车道（含 e2e 证据）
> - ③ `feat/sw-seed-gate` — PR 待开 — gate（两条 socialware gate cap=0，真不挂账）
> **Dev:** agent（Claude，jjkysy 席位）
> **returned_at:** 2026-07-08 02:04 +0800 · **deadline_status:** on_time

## 一句话

Allen #1226 拍板方案 3：非框架 socialware 的 canonical 住址 = `$EZAGENT_HOME/<profile>/socialware/`。本栈建部署级 seed 机制（仓库源 `<app>/priv/socialware_seed/` → `Home.SocialwareSeed.seed!` 幂等 copy → 部署目录 → 晚扫描车道发布），把 autoservice + hello 迁过去，并加 arch gate 禁"非框架直接 seed"（cap=0）。

## DoD reconciliation（逐行，源自 spec §1-8 + 用户纪律）

| # | DoD line | status | proof |
|---|---|---|---|
| 1 | SocialwareSeed 幂等 copy 源→部署目录 | met | `socialware_seed_test` 5/0 |
| 2 | de-smell：core 不点名上层 app（枚举所有 app priv/socialware_seed） | met | `socialware_seed.ex` `source_dirs/0` 枚举 `Application.loaded_applications()`；`layer_purity` 绿 |
| 3 | home.init += :socialware + boot 兜底 | met | `home_test` 7/0；`manifest_seed_test` deploy 缺失→seed→发布 |
| 4 | autoservice 迁 `ezagent_web/priv/socialware_seed/` | met | git mv + `manifest_seed_test` 改断言 |
| 5 | hello reference→YAML，Demo.Hello 收敛测试驱动，删 boot 自发布 | met | `demo_hello_test`+`manifest_yaml_test` 8/0；drift gate 5/0（parse 逐字段==reference，`^\[need-build\]` 逐字节一致） |
| 6 | gate 禁 priv/socialware manifest + 非框架自发布，**cap 双 0** | met | arch.scan `socialware_priv_manifest_files 0/0` + `socialware_self_publish_unsanctioned 0/0`（真删 Demo.Hello.publish，非 allowlist 挂账） |
| 7 | #162 改走真车道（不再 Demo.Hello.publish） | met | #162 `seed! → scan_dir! → :published/:exists`，40/0 |
| 8 | **e2e 证明正常启动**（迁移必须） | met | `docs/e2e/2026-07-08/deploy-seed/`：home.init seed → boot `autoservice-tier1 (deploy)/hello (deploy) → published`（DB pointer 印证）→ world 可发现 → hello 匿名 public 页 200 渲染不跳 login。含 2 截图 + README |
| 9 | 组合态①②③正常 | met | e2e 在②(=①+hello)组合态取证；③ 仅删测试驱动+加 gate（不改运行时）→ arch.scan 全 PASS exit 0 |
| 10 | 机器返还闸 CI 绿 + rebased on main | **partial** | rebased on `404f43ca6`；#1231/#1233 快速 gate 全 pass、full-suite 跑中；③ CI 待 PR 开 |

**Method friction:**
- 三 PR 栈是同一任务拆分；DoD 从 spec 反推。
- e2e 撞三个**环境坑**（均非被测特性，README 记录）：① 共享 PG 库致 cc `orchestrator role_seed_collision`（换 scratch 库绕过——这是 main 上 pre-existing check-task 回归，值得单独修）；② 前端资产需 `npm install`+esbuild 才能起 SPA；③ py sidecar 5s 超时（builder/responser 是 py agent）但会话已落库+public 页渲染，不影响验证。
- `mix ezagent.socialware.check` 在 main 上因坑①崩，本轮用 `manifest_yaml_test` + 真 e2e 覆盖 autoservice/hello 正确性。

## 开放项（交 Allen）

- **gate cap=0 无挂账**：hello 的 boot 自发布已真删、`Demo.Hello.publish` 原语已删、#162 改走车道；kanban/dealscout 的自发布在**各自分支**、不在本栈树里，它们迁移时各自清零（届时 gate 仍 0）。
- **pre-existing 坑**（非本栈）：cc `Jason` 缺 `:jason` dep；`socialware.check` orchestrator collision。建议各开 issue。
- cleaner（清死路径）issue #1227 已开；M3 依赖 #1228 与本 lane 正交（其 spec 明言让位于本 lane）。

## Merge request

- 按 **①#1231 → ②#1233 → ③（待开）** 顺序合并。②/③ 跨 fork 栈，diff 在前序合入前累积；前序合了各自 rebase 即只剩 delta。
- 本栈内闭环 autoservice + hello 两个 flagship 迁移；kanban/dealscout 迁移是后续（rebase 采纳本 lane）。

## 更新（2026-07-08 09:14）

- 三栈已 **rebase 到 `403a7e2ee`**（含 #1230 requires + #1234 entrypoint）。新 sha：① `736521fd6`(#1231) / ② `e2547f3b6`(#1233) / ③ 本分支(#1236)。
- **整合 #1230**：hello YAML + drift 冻结 shape 补 `requires:[orchestrator]`（rebase 时 git 无文本冲突但语义漏，现读补回）；#162 40/0 证带 requires 经车道 publish 正常。
- **机器返还闸**：三栈 rebased on main ✓；CI 快速 check（gate deterministic/gitleaks/…）全 pass，**full-suite pending**（Monitor 盯着）。
- **补齐 dev-together**：①#1231 / ②#1233 已各补 per-PR return（`returns/socialware-deploy-seed-{mechanism,hello}.md`）；此前 subagent 提交未走 return 流程，本轮按纪律补齐。
