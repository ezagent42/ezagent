# dev-together 计划 — 2026-06-25（团队开发计划）

```yaml
日期: 2026-06-25
本周目标: 让团队能日常使用 ezagent（目标①）。官网（目标②）本周期搁置。
方向: 把"已落地但端到端不完整"的产品能力补完整 —— hello/json-render 渲染、agent
  console（含配置）、Feishu 日用入口；并把 agent 运行时后端做一次整合。
```

## 本周目标（调整）

1. **团队日常使用 ezagent（目标①）** —— 本周期唯一近期重点。缺的是产品完整度，不是新功能面。
2. **官网（目标②）—— 本周期搁置**。`zhaomaota97` 改为夯实 hello 与官网共用的 json-render 渲染底座。

## 今日 track

| github | 中文名 | 任务 | 今日交付（DoD） | 分支 | 负责面 |
|---|---|---|---|---|---|
| `zhaomaota97` | 张宁 | hello / json-render 底座 | 前端 json-render catalog/渲染器**对齐后端 shadcn 目录**（`catalog.ts`/`registry.tsx` == `spec.ex` 的 36 个 shadcn 组件，用真 shadcn/Tailwind 实现、复用 world 设计 token）；**验证 style 切换**；**稳定 hello 整体结构**。验收：生成页在 `/socialware/customer` 正确渲染（agent-browser 截图）+ 一次 per-session 样式切换生效。 | `feat/hello-jsonrender-align` | `apps/ezagent_plugin_hello/assets/*`（`spec.ex` 只读） |
| `gagameow` | 黄佳佳 | **整个 agent console** + 后端 handoff | **接管整个 agent console**：UI 界面 + **config 面板**（结构化每字段编辑）+ **对接 `domain.agent`**（下探不了的显式标"还没接线"）。并先给 `allenwoods` 的后端整合任务写一份**后端现状分析 handoff**（cc-headless sidecar + protocol_api + LocalRuntime 现在怎么拼、接缝、未决问题）。 | `feat/agent-console`（+ handoff 文档） | `apps/ezagent_plugin_world`（agent console 全部）；handoff 于 `docs/together/2026-06-25/handoffs/` |
| `allenwoods` | 林懿伦 | agent 运行时后端整合 | 把 **LocalRuntime + agent 后端（cc-headless sidecar + protocol_api）整合为一个完整任务**（含 hello/protocol_api/world 迁 LocalRuntime、echo→Entity.Agent 的 LocalRuntime 决策、sidecar 生命周期）。**从 `gagameow` 的现状 handoff 开始**（先厘清再动手）。 | `feat/agent-runtime-consolidation` | `apps/ezagent_core`、`apps/ezagent_plugin_cc`、`apps/ezagent_plugin_protocol_api` |
| `zyli-developer` | 李震宇 | 产品日用缺口 + e2e 场景文档 | **①** 实现人肉验证暴露的缺口：**F9**（Feishu chat→session 绑定 UI）+ **F12**（Feishu `@` 解析成 agent mention）。**②** 把人肉测试沉淀为 `docs/e2e/`（`scenario-<no>.md` + `guide.md` + evidence example，**agent 拿 agent-browser 能照着自动跑通**）。 | `feat/product-gaps-f9-f12` + `docs/e2e-scenarios` | Feishu 适配器 + session 接线 + `docs/e2e/`（触及 world 遵守 world-coordination） |
| `jjkysy` | 姚升悦 | dev-together skill 改进（**owner**） | 分析并查看当前的 review/plan，**完善 dev-together skill 并提交改进 PR**：让分析强制走**系统功能层面 + 按人完成 + 待办**，plan 强制声明 **off-plan/越界预算**，产出**可外发**标准版式。 | `chore/dev-together-skill-improve` | `.claude/skills/dev-together/**`（单一写者） |
| `ruihuachen-designer` | 陈瑞华 | 协助 `jjkysy`（设计） | **协助** `jjkysy`：设计 review/plan 的**可外发版式**（章节结构、可读性、团队同步需要哪些信息），作为设计输入交给 `jjkysy` 落进 skill；**不直接改 skill 文件**。 | （设计输入） | 版式设计稿 |

## 休息
- **`FatNine`（戴明）今日休息**，不派任务（@林懿伦 2026-06-25）。echo→Entity.Agent（#918）的 LocalRuntime 决策并入 `allenwoods` 的整合任务（A+B+C）。

## `allenwoods` 任务范围已定（A+B+C 三条并行；详见 handoffs/allenwoods-*）
- **A（大/L）** 配置统一 → `domain.agent`：**Entity.Agent 从存储 flavor 统一解析 config+behaviors**（curl 去 spawn-thread、echo 接入#918），保持 `AgentConfig` facade 契约。
- **B（中-大/M-L）** 4 个 sidecar（`Cc.SdkSidecar`/`Codex.AppServer`/`Codex.BridgeSidecar`/`Feishu.WsClient`）从 `Port.open` **迁 erlexec** + 统一封装 + **arch gate 禁裸 Port.open**（不改普通 cc PTY）。
- **C（小/S-M）** LocalRuntime 收口（#99，6 处 URI-only swap）；**LocalRuntime 保持 URI-only / behavior-agnostic**（behaviors 归 A，不加 arity）。
- **排序**：C、B 现可并行开工；A 等 lead brainstorm 定稿。**B 与 C 串行改 `arch_baseline_manifest.exs`**。
- 详见 `handoffs/allenwoods-agent-runtime-consolidation-plan.md`。

## 依赖与顺序
1. **`gagameow` 的现状 handoff → 解锁 `allenwoods` 的后端整合任务**（厘清后再动手）。`gagameow` 先出 handoff，再做 console。
2. `zhaomaota97`（hello 前端）、`zyli-developer`（Feishu 缺口）、`jjkysy`（skill）相互独立，可并行。

## 协作约束
- **CI 闸已生效**：每个进 main 的 PR 需 `precommit + check_invariants` 绿 + rebase 到当前 main（分支保护）。**返还前先 rebase 并自测绿。**

## off-plan（`allenwoods` 自做，非 dev track）
- **部署/上线流程（`allenwoods` 自己做）**：用当前 docker 部署方案（#942 的 PG + mihomo + cloudflared stack）搭三套环境 —— **`app.ezagent.chat`**（生产，公网）/ **`test.ezagent.chat`**（灰度，仅内网，测 main）/ **`dev.ezagent.chat`**（开发，仅内网，测 dev）。（#942 全容器化 stack 即此部署底座，scope 不再存疑。）

## 不在今日范围（已登记）
- 邮件入站（依赖外部适配器）
- Protocol API 命名/拆分、sidecar 生命周期治理（`allenwoods` 分析后定）
- codex-remote live 抽查、ExternalMirror 测试串扰修复

---

# dev-together plan — 2026-06-25（review + merge 阶段）

> **Lead:** allenwoods（allen / 林懿伦）· **Mode:** 两个已提交 PR 的 review+merge，不是新开发
> **Base for both:** `origin/main` @ `e3b6ffba`（= 内容线 `a56ca149` / #962；`rev-list a56ca149..e3b6ffba`=0，两者同一内容线）
> **Author of both PRs:** `jjkysy`（姚升悦，human-dev，GMT+8）— team.md 标 "no active track"，本日是收尾两个昨天 late-return 的 PR
> **Status:** 两 PR 互不依赖、可任意顺序独立合（real conflict map 见下，已核对）

## 1. 今日两任务

| # | task | PR | branch | dev | DoD（可展示） | lead 动作 |
|---|------|-----|--------|-----|----------------|-----------|
| A | `kanban-merge` | #964 | `kanban-clean` | jjkysy | 浏览器 e2e 4 截图 + 全量 `mix test` 绿（**CI 已绿，含 Plan B**） | review + merge → main |
| B | `watcher-merge` | #963 | `watcher-fix` | jjkysy | 重启后 vite ppid=erl_child_setup、无孤儿；CI 全绿 | review + merge → main |

两任务都是 review+merge，不是 build。handoff 写给"接手 review/merge 的独立 dev（human + cc/codex）"。

## 2. 分支事实（已核对 git，勿凭 return 文档转述）

- **kanban-clean**：tip `5f5de0fa`，9 commit（`4b625023` feat → `580ca519` docs → `2315bf7f` 解耦 → `95a383fb` e2e+spec → `56ab78ba` CI 修1(6 失败) → `fb2b18d6` handoff 清理 → `beebdfdd` CI 修2(DocCoverage+EffectDiscipline)+docs/discuss 排除 → **`9b2ede5b` Plan B**(resource:// spawn 归属重构，解掉 #964 唯一真阻塞) → **`5f5de0fa` e2e 截图**(Plan B 后真浏览器跑通)）。**已 rebase 在当前 main `e3b6ffba`**。
- **watcher-fix**：tip `58b27374`（parent `a56ca149`），单提交，只动 `config/dev.exs`（8+/7-）。**含当前 main `e3b6ffba`**（merge-base 检查 = YES）。
  - ⚠️ **return 文档与实际 SHA 不一致**：`returns/2026-06-24/watcher-fix.md` 写 commit `dd2421eb`，但 watcher-fix 分支 tip 是 `58b27374`。两者 **同一 diff、同一 subject**，`dd2421eb`（parent `e2807c0c`，21:14）是早一版 rebase 变体，`58b27374`（parent `a56ca149`，23:07）是分支真正的 tip。**以分支 tip `58b27374` 为准。**

## 3. Conflict map —— 两 PR 互不依赖、可独立合（已核对，非转述）

按各 PR **自身 commit** 的真实改动文件集求交（不是 `git diff main..branch`——那个会被 worktree 的 `.claude/` skill 漂移污染成 1446 文件假冲突）：

| | 文件集来源 | 真实改动文件 | 关键文件 |
|---|---|---|---|
| A kanban | 5 commit `git show --name-only` | 114 个（43 在 apps/config/mix） | `apps/ezagent_plugin_kanban/**`、`apps/ezagent_plugin_world/**`、`apps/ezagent_web/lib/ezagent_web/router.ex`、`apps/ezagent_core/test/{architecture,invariants}/**` |
| B watcher | 1 commit | **1 个**：`config/dev.exs` | `config/dev.exs` |

**交集 = ∅**（`comm -12` 为空）。kanban **自身 commit 不碰 `config/dev.exs`**；watcher **只碰** `config/dev.exs`。
→ **结论：零真实冲突，任意顺序合，互不阻塞。**

> 反例澄清：直接 `git diff e3b6ffba..kanban-clean` 会列 1533 文件、`git diff e3b6ffba..watcher-fix` 列 1446 文件、二者"交集"含 `config/dev.exs` + 大量 core 文件——**全是 worktree 跨分支 `.claude/` skill 历史漂移的 artifact，不是 PR 内容**。判冲突必须按 per-commit change-set，不是 branch-vs-main diff。

## 4. 合并顺序

无依赖。建议先合 **B watcher-merge**（1 文件、dev-only、零产品风险、CI 已绿——最快清空），再合 **A kanban-merge**（#964 整个 CI 已绿、含 Plan B）。顺序非强制，可颠倒。

## 5. 决策归属（阻塞 vs 非阻塞，分清）

- **A kanban**
  - **阻塞本次合并**：CI 必须绿（8 个 architecture/invariant 失败已在 `56ab78ba`+`beebdfdd` 修 + Plan B `9b2ede5b` 解掉 spawn 真阻塞）。**#964 整个 CI 已绿**（全量 arch+invariants 串行 329/0）。lead review+merge。
  - **spawn = Plan B 已落地（不阻塞）**：原 kanban `after_boot` 注册 `resource://` scheme spawn fn（擦不变式 8 边缘）的后门**已删**，走 **Plan B**（commit `9b2ede5b`）：**workspace domain 拥 `resource` dispatcher + core `ResourceKindRegistry`（`{type→Kind}` 注册表，照 `AgentFlavorRegistry`）**，kanban 只声明 `resource_kinds/0`。CI 已绿。**剩 3 个归属决策待 Allen 确认（不阻塞合并）**：dispatcher 归 workspace 对不对 / `resource_kinds/0` 契约扩展进 Decision Log / `ConfigSurface` 搭车抽出。详见 `handoffs/spawn-ownership-planb.md` §6。
- **B watcher**：**无架构决策**。无依赖、纯 dev config、lead review+merge 即可。

## 6. Deferred（不在本日两 PR）

- **kanban agent 自动改图（Track 2，分支 `kanban-agent-mcp`，暂停中）**：通用 Kind-MCP 桥已建[暂停]，**不在 #964、不影响合并**。落地 handoff：`docs/superpowers/handoffs/2026-06-25-kanban-agent-mcp-build-handoff.md`（在 `kanban-agent-mcp` 分支）。
- **world→kanban umbrella 依赖下沉**：为过 UndeclaredDep gate，world 现声明 kanban umbrella dep；若架构上认为 world 不该依赖具体 plugin，后续更大重构（本 PR 未做）。

## 7. 产出

- `handoffs/kanban-merge.md`、`handoffs/watcher-merge.md` + 各一个 paste-ready dev prompt。
- 本 plan **不 commit**，交回 lead review。
