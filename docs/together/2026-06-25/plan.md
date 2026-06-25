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
| `zyli-developer` | 李震宇 | 产品日用缺口 | 实现人肉验证暴露的缺口：**F9**（Feishu chat→session 绑定 UI）+ **F12**（Feishu `@` 解析成 agent mention）。 | `feat/product-gaps-f9-f12` | Feishu 适配器 + session 接线（触及 world 遵守 world-coordination） |
| `jjkysy` | 姚升悦 | dev-together skill 改进（**owner**） | 分析并查看当前的 review/plan，**完善 dev-together skill 并提交改进 PR**：让分析强制走**系统功能层面 + 按人完成 + 待办**，plan 强制声明 **off-plan/越界预算**，产出**可外发**标准版式。 | `chore/dev-together-skill-improve` | `.claude/skills/dev-together/**`（单一写者） |
| `ruihuachen-designer` | 陈瑞华 | 协助 `jjkysy`（设计） | **协助** `jjkysy`：设计 review/plan 的**可外发版式**（章节结构、可读性、团队同步需要哪些信息），作为设计输入交给 `jjkysy` 落进 skill；**不直接改 skill 文件**。 | （设计输入） | 版式设计稿 |

## 休息
- **`FatNine`（戴明）今日休息**，不派任务（@林懿伦 2026-06-25）。echo→Entity.Agent（#918）的 LocalRuntime 决策并入 `allenwoods` 的整合任务（A+B+C）。

## `allenwoods` 任务范围已定（A+B+C）
- **A** 配置统一 → `domain.agent` 统一入口 + registrar（cc/codex/curl/echo 全收拢）。
- **B** 把 3 个 sidecar（`Cc.SdkSidecar` / `Codex.AppServer` / `Codex.BridgeSidecar`）从 `Port.open` **迁到 erlexec**（根治孤儿进程；不改普通 cc PTY）。
- **C** LocalRuntime 收口（#99）+ 加带-behaviors 的 spawn arity（解锁 #918）。
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
