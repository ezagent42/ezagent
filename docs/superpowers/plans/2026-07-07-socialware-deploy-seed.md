# socialware 部署级 seed 机制 + seed-path gate 实施计划

> **For agentic workers:** 用 workflow / subagent-driven-development 逐 task 实施。步骤用 `- [ ]`。
> 设计源：`docs/superpowers/specs/2026-07-07-socialware-deploy-seed-design.md`。

**Goal:** 建 socialware 部署级目录 seed 机制，autoservice 迁入并经该目录发布；加 arch gate 禁止非框架 socialware 直接 seed（gate-first）。

**Architecture:** 仓库源 `ezagent_web/priv/socialware_seed/<name>/` → `Ezagent.Home.SocialwareSeed.seed!/0` 幂等 copy → `$EZAGENT_HOME/<profile>/socialware/` → 已在 main 的晚扫描车道 `ManifestSeed.scan_all!` 发布。gate 走 `mix ezagent.arch.scan` 扩展。

**Tech Stack:** Elixir/OTP 27 · Ecto/PG · mix tasks · ExUnit。

## Global Constraints

- 所有 mix：`mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix ...`（裸 mix 落 brew OTP28，毁验证）。
- 改 core(Home)/新 gate → 全套 `apps/ezagent_core/test/architecture` 重测。
- 幂等：seed copy `unless File.exists?` 跳过（尊重运维手改），沿用 `ezagent.home.init.ex` 现有模式。
- 本 PR 内闭环 **autoservice**（main-resident）；kanban/dealscout 各自分支随后。
- 框架内置 allowlist：`chat` / `socialware` / `orchestrator`（gate 放行代码 seed）。

---

### Task 1: gate-first — 写 seed-path gate（预期红）

**Files:**
- Modify: `mix ezagent.arch.scan` 的规则源（先读定位：`apps/ezagent_core/lib/mix/tasks/ezagent.arch*.ex` 或其 rule 模块）
- Test: arch gate 自己的 test（若有）+ `apps/ezagent_core/test/architecture/*`

**Interfaces:**
- Produces: 一条新 arch 规则 `socialware_seed_path`（名字实施时定），检测 (a) `apps/*/priv/socialware/*/manifest.yaml` 存在；(b) 非框架 app 在 Application boot 调 `ConfigGovernance.Socialware.publish_or_upgrade` / `Demo.publish`。allowlist：core 框架内置。

- [ ] Step 1: 读 `mix ezagent.arch.scan` 现有规则结构（AST/grep gate 怎么注册的），找扩展点。
- [ ] Step 2: 加规则 (a)：grep `apps/*/priv/socialware/*/manifest.yaml`，非空即违规。加规则 (b)：扫非-core Application 模块 boot 路径里的 `publish_or_upgrade`/`Demo.publish` 调用。
- [ ] Step 3: 跑 `mise exec ... -- mix ezagent.arch.scan`，**预期红**：列出 `ezagent_domain_session/priv/socialware/autoservice/manifest.yaml`（本分支唯一 priv/socialware）。记录报错。
- [ ] Step 4: commit（gate 红是预期的 gate-first 状态；若 arch.scan 是 CI gate 需允许本 commit 红或用标记，实施时按现有 gate 惯例处理）。

### Task 2: seed 机制 — SocialwareSeed 模块 + 源目录骨架

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`（`Ezagent.Home.SocialwareSeed`）
- Create: `apps/ezagent_web/priv/socialware_seed/.keep`（源目录）
- Test: `apps/ezagent_core/test/ezagent/home/socialware_seed_test.exs`

**Interfaces:**
- Produces: `Ezagent.Home.SocialwareSeed.seed!/0 :: :ok`（幂等 copy `ezagent_web` priv `socialware_seed/*` 每个 `<name>` 目录 → `Ezagent.Home.path("socialware")/<name>`，`unless File.exists?` 跳过）；`source_dir/0`（`:code.priv_dir(:ezagent_web)/socialware_seed`）。

- [ ] Step 1: 写 failing test：临时 EZAGENT_HOME + 一个 fixture 源目录，`seed!/0` 后目标目录出现；再调一次 = 幂等不覆盖已改内容。
- [ ] Step 2: 跑 test 验证 fail。
- [ ] Step 3: 实现 `SocialwareSeed`（`File.cp_r` 每个 name 目录，`unless File.dir?(dest)`）。
- [ ] Step 4: 跑 test 通过。
- [ ] Step 5: commit。

### Task 3: home.init 加 :socialware + seed 调用

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/home.ex`（`skeleton_dirs` += `:socialware`）
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex`（skeleton 后调 `SocialwareSeed.seed!/0`）
- Test: home.init / home test

- [ ] Step 1: failing test：`skeleton_dirs` 含 `:socialware`；home.init 后部署目录有 seed 内容。
- [ ] Step 2: 跑 fail。
- [ ] Step 3: 实现：`skeleton_dirs` 加 `:socialware`；home.init `run` 末尾 `Ezagent.Home.SocialwareSeed.seed!()`。
- [ ] Step 4: 跑通过。
- [ ] Step 5: commit。

### Task 4: boot 兜底 — 车道扫描前确保部署目录已 seed

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`（`deploy_sources` 取 dir 前调 `SocialwareSeed.seed!/0`）**或** `apps/ezagent_web/lib/ezagent_web/application.ex:36` 触发点前调。实施时择一（就近原则 + 依赖方向：core 的 SocialwareSeed 可被两者调）。
- Test: `manifest_seed_test.exs` 加"deploy 目录缺失时 scan_all! 先 seed 再发布"

- [ ] Step 1: failing test：清空部署目录，`scan_all!` 后 autoservice 从部署目录发布。
- [ ] Step 2: fail。
- [ ] Step 3: 实现兜底调用（幂等）。
- [ ] Step 4: 通过。
- [ ] Step 5: commit。

### Task 5: 迁移 autoservice → socialware_seed（修 gate 绿）

**Files:**
- Move: `apps/ezagent_domain_session/priv/socialware/autoservice/` (整目录 manifest.yaml+package.yaml+kb/+persona/) → `apps/ezagent_web/priv/socialware_seed/autoservice/`（`git mv`）
- Modify: `apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_test.exs:102`（原"publishes autoservice from domain_session priv via default app enumeration" → 改为"经 seed! + deploy_sources 发布"）
- 检查其它引用 autoservice priv 路径的代码/测试（grep）

- [ ] Step 1: `git mv` 整目录；grep 所有引用旧路径处（`priv/socialware/autoservice`）逐个改指新源 / 经 seed 的部署目录。
- [ ] Step 2: 改 `manifest_seed_test:102` 断言。
- [ ] Step 3: 跑 `arch.scan` → **gate 应转绿**（apps/*/priv/socialware 无 manifest 了）。
- [ ] Step 4: `mix ezagent.socialware.check autoservice-tier1` → 13 断言绿（经部署目录发布）。
- [ ] Step 5: commit。

### Task 6: 全套验证 + skill-1 审查

- [ ] Step 1: `mix ezagent.arch.scan` 绿。
- [ ] Step 2: `mix test apps/ezagent_domain_session/test/ezagent/socialware/manifest_yaml_test.exs apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_test.exs` 全绿。
- [ ] Step 3: `mix test apps/ezagent_core/test/architecture` 全绿。
- [ ] Step 4: skill-1 agent 审查：迁移合理性 + 依赖方向（core SocialwareSeed 被 web/session 调是否符合三层）+ 有无遗漏引用。
- [ ] Step 5: `compile --warnings-as-errors` + `format --check-formatted`。

## Self-Review 覆盖

spec §4 seed 机制→Task2/3/4；§5 gate→Task1；§6 迁移 autoservice→Task5；§8 验证→Task6。kanban/dealscout（spec §6 后两条）在各自分支，不在本计划。
