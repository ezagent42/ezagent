# Phase 0 — SPEC

> Phase 0:项目骨架 + 工具链就位
> 本文件是 Phase 0 brainstorm 的产出之一。配套:`VERIFICATION.md` / `PLAN.md` / `DECISIONS.md`
> 上游:`IMPLEMENTATION_ROADMAP.md` §3

## 目标

能跑 `mix test`,`mix phx.server` 起空架构,Claude Code 能在 ezagent repo 里正常工作。**Phase 0 是纯脚手架** —— 没有任何 Ezagent 业务逻辑(dispatch / Kind / Behavior / Invocation 全部 Phase 1+)。

## 测试员体验

浏览器打开 `localhost:4000` → 看到空 LiveView 首页「Ezagent v0.4 — phase 0 complete」;`curl localhost:4000/_health` 返回 200。基建起来了。

## umbrella 结构

ezagent 是 Mix umbrella(plugin 模型本身就是 umbrella —— ARCHITECTURE.md §8/§13)。`ezagent_core` 不依赖 **`:phoenix` 框架**(§1.1「ezagent_core 就是 OTP」)—— 注意是「框架」:`ezagent_core` **可以**依赖 `:phoenix_pubsub` / `:telemetry` / `:ecto_sql` / `:ecto_sqlite3` 这些**独立的 OTP 生态库**(它们不需要 Phoenix 框架),但**不能**依赖 `:phoenix`(Endpoint/Router/Controller/Channel/LiveView 的全套 web 框架)。所以 ezagent **不是**标准 phx 的 business+_web 二分,而是:

```
ezagent/  (umbrella root)
├── apps/
│   ├── ezagent_core/      ← 纯 OTP app,无 :phoenix 框架(但可用 :phoenix_pubsub/:telemetry/:ecto)
│   └── ezagent_web/       ← Phoenix app(Endpoint / Socket / Plug,ARCHITECTURE.md §12 transport 层)
│                        (esr_plugin_* 从 Phase 1 起逐个加进 apps/)
├── config/
├── ARCHITECTURE.md / GLOSSARY.md / IMPLEMENTATION_ROADMAP.md / CLAUDE.md / ARCHITECTURE_GRILL_v0.3.md
│                        ← 奠基提交已在(commit c73d3d9)
├── AGENTS.md            ← phx.new 1.8 生成
├── docs/phase-specs/
└── .claude/             ← 迁移自老 esr(审视后)
```

## Deliverables

### D1 — Phoenix umbrella 脚手架
`mix phx.new . --umbrella --app ezagent_core --no-mailer`
- `.` 形式脚手架进当前目录(ezagent/ 已有 `.git` + 奠基提交的 5 个文档)
- `--app ezagent_core` → 生成 `apps/ezagent_core` + `apps/ezagent_core_web`;实施时把 `ezagent_core_web` **重命名为 `ezagent_web`**(ARCHITECTURE.md §12.2 用 `ezagent_web/endpoint.ex`,§13 命名 convention)
- **不加 `--binary-id`** —— Ezagent 用 text URI 作主键(ARCHITECTURE.md §15.3),`--binary-id` 设的 UUID 默认跟这个约定冲突
- 3 个冲突文件(`README.md` / `.gitignore` / `.formatter.exs`):留 phx.new 的 `.gitignore` + `.formatter.exs`,`README.md` 替换为 Ezagent-specific
- `--no-html` 等其余 flag:实施时按 phx_new 1.8 文档核 —— ezagent_web 用 LiveView 但不要 controller/传统 view(见 DECISIONS.md 实施期决策点)

### D2 — Deps
`mix.exs`(umbrella 根 + 各 app)对齐 ARCHITECTURE.md §15 的依赖(SQLite-only):phoenix / phoenix_live_view / phoenix_pubsub / bandit / plug / ecto_sql / ecto_sqlite3 / telemetry 系列 / opentelemetry 系列 / req / jason。具体清单以 ARCHITECTURE.md §15 为准。

### D3 — `/_health` endpoint + dev 绑定 tailnet
`ezagent_web` 加一个 `/_health` route(Plug,返回 `{"status":"ok"}` + 200)。**不走 dispatch**(Phase 0 没 dispatch 路径)。
**dev endpoint 绑定**:Allen 从 tailnet 内网 IP(`100.x.x.x`)访问,不是 localhost。`config/dev.exs` 的 endpoint 必须 `http: [ip: {0, 0, 0, 0}, port: 4000]`(绑 0.0.0.0,tailnet 可达),不是 phx.new 默认的 `127.0.0.1`。

### D4 — SQLite migration 框架
`ecto_sqlite3` repo 配好;`mix ecto.create` + 一个空 migration + `mix ecto.migrate` 跑通。SQLite 文件落 umbrella 约定位置。

### D5 — 空 LiveView 首页
phx.new 默认生成一个 LiveView 首页;改文字成「Ezagent v0.4 — phase 0 complete」。**这不是 `ezagent_web_liveview` plugin** —— 那个是 Phase 1。Phase 0 只是把 phx.new 默认页留着 + 改字。
**tailnet 访问注意**:LiveView 的 WS 连接受 `check_origin` 约束。从 `100.x.x.x` 访问时,phx.new 默认的 `check_origin`(只认 host)会拒掉 WS。`config/dev.exs` 的 endpoint 要把 tailnet IP 加进 `check_origin`,或 dev 期设 `check_origin: false`(dev-only,prod 不这样)。

### D6 — GLOSSARY.md
review + finalize 架构师的 `GLOSSARY_DRAFT.md`(在老 esr workspace),移进 ezagent 根作 `GLOSSARY.md`。draft 已经很全(Decision Log #1-83 + ~40 术语 + 易混淆词表 + 维护流程),Phase 0 只需 review 一遍 + 落位。

### D7 — AGENTS.md
phx.new 1.8 自动生成 `AGENTS.md`(Phoenix/Elixir idioms)。ezagent 的 `CLAUDE.md` 已经写明 supplements 它。Phase 0 **确认 phx.new 生成的 AGENTS.md 在位即可,不重写**。

### D8 — `.claude/` 迁移
见 `DECISIONS.md` 的「P0-D5 — .claude/ 迁移清单」。迁 5 个 skill,弃 3 个,`settings.json` 全新写。

### D9 — `mix ezagent.check_invariants` task 骨架
自定义 mix task,Phase 0 阶段近 no-op(8 条硬不变式都不适用 —— Phase 0 无 dispatch 路径)。骨架:能跑、输出「Phase 0: no invariants apply yet」、exit 0。Phase 1 起逐条加 grep 检查。

### D10 — B git-hook 骨架
`scripts/hooks/sub-step-gate.sh` + `.claude/settings.json` 的 PreToolUse hook(拦 `git tag` / `git commit`)。Phase 0 的 hook 只跑 `mix test` + `mix format --check-formatted`(Phase 0 无 e2e flow、无 invariants)。每个后续 phase 的 brainstorm 扩展这个脚本。

## 不在 Phase 0 范围(boundary)

- ❌ 任何 Ezagent 业务逻辑:dispatch / Kind / Behavior / Invocation / RoutingRegistry / ReadyGate / PendingDelivery / Idempotency —— 全部 Phase 1+
- ❌ `ezagent_web_liveview` plugin —— Phase 1。Phase 0 只有 phx.new 默认 LiveView 首页
- ❌ `esr_adapter_cli` —— Phase 2
- ❌ 真实的不变式检查 —— Phase 0 的 `check_invariants` 是骨架,Phase 1 起有牙
- ❌ `FLOWS.md` 详细化 —— 那是 Phase 1 依赖,可并行但不属 Phase 0 spec
- ❌ 任何 plugin app —— Phase 1 起逐个加
