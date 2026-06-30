# Handoff: kanban PR #1020 grill-driven refactor（recipe 统一入口 + nav→World）

> **Date:** 2026-06-30 · **From:** Allen/jjkysy grill review · **To:** Claude (FP5) + cc 大脑(e2e)
> **Tracking:** PR #1020 / status-snapshot B3 · **Base:** `origin/main` @ behind #1096
> **Status:** confirmed — grill 质询后的架构收敛，逐项 Allen/用户拍板

## 0. Mission
PR #1020（kanban 团队开发流）能跑且 e2e 证过，但 review 质询出**架构 layering 问题**：dev-together 被做成空壳 plugin、pm/dev recipe 塞在 plugin `roles/0`、nav_surfaces 加进了 core Plugin 契约。socialware（#1069）+ recipe 通用 ConfigObject 模型（#1071）已落 main，PR 该对齐它们、去掉这些冗余/跳层。

## 1. Required reading
1. Skill `ezagent-developer` — invariants。
2. `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex`（main #1071：recipe = `config://<ws>/recipe/<name>` ConfigObject，`seed_role_if_absent/2` plugin-free 通用原语）。
3. `docs/guide/kanban-development-pitfalls-and-decisions.md` + this dir 的 review.md。
4. The `dev-together` skill。

## 2. Locked decisions（grill settled — 不再 re-litigate）
| # | Decision | Value |
|---|----------|-------|
| 1 | recipe 本质 | 通用 agent 配置 ConfigObject，非 plugin 专属 |
| 2 | pm + dev recipe | 走**统一通用入口**（DefaultRecipes 数据 + DefaultRecipeSeed boot seeder），非 plugin roles/0 |
| 3 | kanban-manager | 留 kanban plugin roles/0（flavor=native，plugin 自身 board agent） |
| 4 | 配置 vs 落地 | recipe 配置走统一入口；materialize 触发 + board-scoping grant（kanban-aware）留 kanban |
| 5 | domain_agent 3 引擎 | 留（materialize/grant/seed 通用引擎，FF-1 禁 per-plugin fork） |
| 6 | nav_surfaces/session_tabs | 搬 **World 层**（World 自建 UISurfaceProvider duck-type 读 plugin plain 函数）；**config_surface 留**（Allen 既有） |
| 7 | dev_together 空壳 plugin | 删 |

## 3. Architecture primer
- recipe 注册：`RecipeRegistry.seed_role_if_absent/1`（plugin-free）→ system-ws ConfigStore。materialize 经 `RecipeRegistry.lookup`（dev）或显式传 recipe（pm board-scoping）。
- AgentTemplate：cc-flavor template 要 cc spawn fn（cc plugin boot 时注册）→ template-seed 必须在 cc `after_boot`（不是 domain start/2）。
- World UI surface：World 的 `UISurfaceProvider` 扫 installed plugin 的 plain `nav_surfaces/0`/`session_tabs/0` 函数（duck-typed，core 契约不认识）。

## 4. Design & phased plan
T-recipe（统一入口 + 删 dev_together）→ T-boot（boot-order 拆 seed）→ T-nav（搬 World）→ T-docs → T-review。每步全 gate + 真 e2e/RPC 证。

## 5. Definition of Done（closed checklist）
- [ ] pm/dev recipe 经 DefaultRecipeSeed 统一入口注册（非 plugin），materialize 照常 — **proof: 真 e2e boot-seed forensics + materialize JOIN**
- [ ] boot-order：template-seed 在 cc after_boot，`no_spawn_fn=0` — **proof: server.log forensics**
- [ ] dev_together plugin 删干净无 dangling — **proof: grep 全库**
- [ ] nav_surfaces/session_tabs 不在 core 契约（config_surface 留）；kanban UI（session_tabs）保住 — **proof: World tests + grep core**
- [ ] relay 全链照跑（pm 派活→dev 产→relay-back 唤醒 pm→接力）— **proof: t14 relay-back-audit + dev-board-zero**
- [ ] 全 gate 集绿（arch.scan/doc.scan/uri_query/check_invariants/format/test/plugin_check）
- [ ] CI green on PR head + rebased on main（machine return gate）

## 6. Discuss-first vs Deferred
- **Clarify-first**：本就是 grill review 驱动（逐项 Allen/用户拍板），等价 research-first。
- **Deferred**（不在本 refactor）：forward pm→dev @mention 规则化、participation send cap durability、agent 配置 UI、config_surface 是否整体重构（留 Allen）。
