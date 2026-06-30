# Return: kanban PR #1020 grill-driven refactor

> **Task:** kanban-grill-refactor（recipe 统一入口 + boot-order + nav→World）
> **Branch:** `feat/kanban-agent-e2e`
> **PR:** #1020 (ezagent42/ezagent)
> **Dev:** Claude (FP5) + cc 大脑(pm/dev e2e)
> **returned_at:** 2026-06-30 +0800
> **deadline:** 2026-06-30 +0800
> **deadline_status:** on_time

## 做了什么
按 handoff §2 的 7 条 locked decisions 全做完：
- **统一入口**：新建 `Ezagent.Agent.DefaultRecipes`（pm/dev recipe role-as-data 数据，kanban behavior 用 STRING 解耦 domain）+ `DefaultRecipeSeed`（boot seeder）。删 `ezagent_plugin_dev_together` 整个 app。kanban `roles/0` 只剩 `kanban-manager`。
- **boot-order 修**：`DefaultRecipeSeed` 拆两半——recipe-seed 在 domain_agent `start/2`、template-seed（`seed_templates_all`）在 **cc plugin `after_boot`**（cc flavor spawn fn 已发布后，与 cc-orchestrator seed 同位）。
- **nav→World**：core `Ezagent.Plugin` 移除 `nav_surfaces/0`+`session_tabs/0` callback + surface_validator/ezagent_plugin_check 瘦身（**config_surface 留**）。World 新建 `UISurfaceProvider`（duck-type 读 plugin plain 函数）。kanban 改成 plain `session_tabs/0`（看板会话 tab 保住；左栏 nav 早 demoted、删）。
- materialize 触发 + board-scoping + domain_agent 3 引擎：不动（留 kanban / 通用引擎复用）。

## DoD reconciliation（逐行，closed set）
| DoD line | status | proof |
|---|---|---|
| pm/dev recipe 经统一入口注册、materialize 照常 | **met** | `docs/e2e/kanban-pm-flow/t14-boot-seed-forensics.txt`（recipe ConfigObject 经 DefaultRecipeSeed seed）+ t14 materialize JOIN（pm 490µs/dev 285µs，zero timeout） |
| boot-order：template-seed cc after_boot，no_spawn_fn=0 | **met** | t14 forensics（server.log `no_spawn_fn` 计数=0，标准 template ALIVE） |
| dev_together plugin 删干净无 dangling | **met** | grep 全库：app 目录删 / `@role_plugins=[:ezagent_plugin_kanban]` / web dep 移 / 无悬空调用（编译干净） |
| nav 不在 core 契约（config_surface 留）、kanban UI 保住 | **met** | grep core plugin.ex（@callback nav_surfaces=0/session_tabs=0/config_surface=1）+ World tests 18-0 + kanban `def session_tabs` |
| relay 全链照跑 | **met** | t14 relay-back-audit（zero admin→pm sends，dev 无 mention return 唯独靠 relay-back 唤醒 pm）+ dev-board-zero |
| 全 gate 集绿 | **met** | 全套 umbrella test 0 real failures（arch test isolation 假象在全套跑消失）；compile -w-a-e clean |
| CI green on PR head + rebased on main | **deferred → push 时** | rebase #1096 + push 后 watch CI（见 merge request） |

## DoD proofs
全在 `docs/e2e/kanban-pm-flow/t14-*`（boot-seed forensics / relay-back-audit / dev-board-zero / pm·dev caps / 截图 t14-01..09 / dev artifact md）。

## Method-friction（写回，lead 在 review 提升）
1. **rebase loop 不严格 = 根因**：我 rebase 时只跑 gate 验证、**没主动扫库**找 main 既有通用路，于是 carry 了错的 dev_together 空壳 plugin + recipe 塞 plugin。漏的东西在 fork 点之前的既有 infra（`seed_role_if_absent`）、不在新 commit 里——**光扫新 commit 不够**。
2. **arch test 单独跑会假失败**：oversized/god-function def-count test 用 `Module.definitions`，单独跑 2 个文件时 tracked 模块没 load → 读错。要全套跑或 `--max-cases` 全 load。
3. **workflow verify e2e harness 局限**：cc-headless 浏览器 e2e 在 workflow agent 上下文里跑不动（agent-browser/vite），要主进程用完整 cdp.py harness 亲自跑。

## Merge request
- 收口：**rebase 到 #1096 → 重整批次（squash 按层拆）→ push force-with-lease → watch CI**（machine return gate 在此满足）→ 刷 PR + Allen handoff（config_surface）。
- verdict（B3）：**mergeable + 2 minor follow-ups**（Allen config_surface 审 + deferred surfaces）。
- 安全分支 `safety-pre-squash`(0d5f2e98) + `backup/...-pre-rebase`(d2a78708) 可回滚。
