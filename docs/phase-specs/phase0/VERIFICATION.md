# Phase 0 — VERIFICATION

> **先于 PLAN.md 写**(M1 / Decision #80)。VERIFICATION 是 phase 完成的验收契约。
> Phase 0 是单块 phase(无 sub-step),所以这是 **phase 级验收 gate**。
> 配套:`SPEC.md` / `PLAN.md` / `DECISIONS.md`

## Phase 0 验收 checklist

全绿才能 tag `phase0`:

> **验收执行记录**:全部 checklist 项已执行,全绿(2026-05-15)。`phase0` tag = `5199f36`;
> Allen 已 sign-off。下方 `[x]` 是 agent 可验证项的执行勾;「人 review 关键点」一节归 Allen。

### 结构
- [x] ezagent 是 Mix umbrella;`apps/ezagent_core/` + `apps/ezagent_web/` 存在
- [x] `ezagent_core` app 的 `mix.exs` deps **不含 `:phoenix`(框架)** 也不含 `:phoenix_live_view` / `:bandit` / `:plug` 这些 web-transport 依赖。**允许**含 `:phoenix_pubsub` / `:telemetry*` / `:ecto_sql` / `:ecto_sqlite3` / `:jason` 等独立 OTP 生态库(它们不需要 Phoenix 框架)
- [x] phx.new 默认的 `ezagent_core_web` 已重命名为 `ezagent_web`(目录 + mix.exs app name + `EzagentWeb` 模块前缀 + config 引用全部同步)
- [x] 奠基提交的 5 个文档在根:`ARCHITECTURE.md` / `GLOSSARY.md` / `IMPLEMENTATION_ROADMAP.md` / `CLAUDE.md` / `ARCHITECTURE_GRILL_v0.3.md`
- [x] `AGENTS.md` 存在(phx.new 生成,未被重写)
- [x] `docs/phase-specs/phase0/` 4 文件在版本控制里

### 编译 + 测试
- [x] `mix deps.get` 成功
- [x] `mix compile` 无 error、无 warning
- [x] `mix test` 绿(只有 phoenix 自带 test)
- [x] `mix format --check-formatted` 通过

### 运行(从 tailnet IP 验,不是 localhost)
- [x] `mix phx.server` 起得来,dev endpoint 绑 `0.0.0.0:4000`(不是 `127.0.0.1`)
- [x] 从 tailnet `curl http://<tailnet-ip>:4000/_health` 返回 200 + `{"status":"ok"}`
- [x] `mix ecto.create && mix ecto.migrate` 跑通,SQLite 文件生成

### 🔴 agent-browser 真实浏览器 gate(强制 — curl 不够)

> **为什么强制**:curl 验证 HTTP 层,但验证不了 LiveView WS 真正建连、JS 执行、页面真正"活"。
> Phase 0 出过这个教训:`curl /` 200 不代表测试员浏览器里看到的是可用页面。
> **任何 phase 的 web/UI deliverable,验收必须包含 agent-browser 真实浏览器步骤** —— 不是
> "curl 通了就算"。这是 roadmap-wide 验收 convention(见 `IMPLEMENTATION_ROADMAP.md`
> §1.2 同构 track / e2e flow track 的执行机制)。

- [x] `agent-browser open http://<tailnet-ip>:4000/` —— 用真实 headless Chrome 打开,不是 curl
- [x] `agent-browser snapshot -i` —— 快照里有 `heading "Ezagent v0.4 — phase 0 complete"`
- [x] `agent-browser screenshot` —— 截图人眼确认页面真正渲染(不是静态死页 / 不是错误页)
- [x] LiveView WS 真连上:`home_live_test.exs` 用 `live/2` 通过(测试层证明)+ 截图页面是活的(浏览器层证明)
- [x] **明确**:`/` 是唯一的首页路由。`/<任何不存在的路径>`(含 `/dev/dashboard**` 这类带 `**` 的)返回 404 是**正确行为**,不是 bug —— 404 页会列出可用路由,那是 Phoenix dev 模式在帮忙

### 工具链
- [x] `.claude/skills/` 有迁移过来的 5 个 skill(elixir-phoenix-helper / erlexec-elixir / commit-work / grill-me / grill-with-docs),spot-check 一个能正常 invoke
- [x] `.claude/settings.json` 是 ezagent **全新写**的 —— 没有指向不存在的老 esr 脚本(grep 确认无 `pre-merge-dev-gate.sh` / `openclaw-channel-postcheck.sh` / `replay-guide-reminder.sh` 死引用)
- [x] `mix ezagent.check_invariants` 能跑,输出「Phase 0: no invariants apply yet」,exit 0
- [x] B git-hook:`scripts/hooks/sub-step-gate.sh` 存在 + 可执行;`.claude/settings.json` 的 PreToolUse hook 配好;手动触发能跑 `mix test` + `mix format --check-formatted`

### 不变式 grep checklist
Phase 0 **无 dispatch 路径,8 条硬不变式都不适用**。本 phase 的 `check_invariants` 是骨架。
8 条不变式的真实 grep 检查从 **Phase 1** 起建立(那时有 dispatch / Kind / Behavior / 路由)。

### e2e flow
Phase 0 **无 e2e flow**(没有 dispatch,`FLOWS.md` 的 F1-F8 一条都跑不了)。e2e flow track 从 **Phase 1** 起(F1 — 文本往返,LiveView + Echo)。

## 人 review 关键点(Allen)

- 空首页从 tailnet IP 可访问?LiveView WS 连得上?
- `mix test` 绿?
- 迁过来的 5 个 skill 在新 repo 工作?
- ezagent 的 `settings.json` 没有残留 esr-specific 的死引用?
- `ezagent_core` 的 `mix.exs` 没有 `:phoenix`(框架)依赖?(架构纯度的第一道关 —— 见下)

## 为什么「ezagent_core 不依赖 `:phoenix` 框架」是第一道关

1. **依赖方向**:ARCHITECTURE.md §2.3/§12 把 Phoenix 定为 **transport**,transport 可插拔(Feishu/CC/CLI/LiveView 都是 adapter)。依赖箭头必须 `transport → core`,绝不 `core → transport`。core 一旦依赖 `:phoenix`,箭头就反了。
2. **结构性强制**:依赖物理上不在,就**不可能**手滑把 transport 代码塞进 core —— 编译器替你守架构,比纪律可靠。
3. **core 可纯 OTP 单测**:dispatch / Kind / registry 应该不起 web 栈就能测。core 依赖 `:phoenix` 的话,每个 core 测试都拖着 Endpoint/Bandit。
4. **plugin 隔离北极星的前提**:core 必须 transport-agnostic;跟某一个 transport 的框架绑死,正好是反面。
5. **federation 留口**(§17.3):节点是「SQLite + 单 BEAM」,core 是纯 OTP 才可能跑 headless relay。

**为什么是「第一道」**:这是最容易手滑犯(phx.new umbrella 脚手架可能把 `:phoenix` 接到错的 app)、又最难回头的违规 —— Phase 0 没接住,后面每个 phase 都建在错的依赖图上。Phase 0 验收接住 = 在任何上层代码写之前接住。

**精度**:守的是不依赖 `:phoenix`(**框架**),不是「不沾 Phoenix 任何东西」。`:phoenix_pubsub` 是独立 hex 包(无 `:phoenix` 依赖),ezagent_core 的 `:subscribe` mode 合法用它;`:telemetry` / `:ecto` 同理。
