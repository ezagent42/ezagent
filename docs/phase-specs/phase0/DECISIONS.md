# Phase 0 — DECISIONS

> Phase 0 brainstorm 阶段已决的判断点 + 实施期可能撞到的决策点 + 决策原则。
> 已决项实施完后 append 进 `GLOSSARY.md` Decision Log(impl 期 #84 起)。

## 已决(Phase 0 brainstorm,Allen 批准「按推荐来」)

### P0-D1 — umbrella 结构
ezagent 是 Mix umbrella。`apps/ezagent_core`(纯 OTP,**不依赖 `:phoenix` 框架** —— 但可用 `:phoenix_pubsub`/`:telemetry`/`:ecto` 等独立 OTP 库)+ `apps/ezagent_web`(Phoenix transport)。否决 single-project。
**理由**:plugin 模型本身就是 OTP app 的 umbrella(ARCHITECTURE.md §8/§13);`ezagent_core` 按 §1.1「就是 OTP」不依赖 `:phoenix` 框架(依赖方向必须 transport→core,不能反 —— 详见 `VERIFICATION.md`「为什么这是第一道关」)。single-project 跟这两条直接冲突。

### P0-D2 — 不加 `--binary-id`
`mix phx.new` 不加 `--binary-id`。
**理由**:Ezagent 用 text URI 作主键(ARCHITECTURE.md §15.3「主键用 text URI 字符串,不用 bigserial」)。`--binary-id` 设的是 UUID 默认,跟 text-URI-PK 约定冲突。schema 里按需显式声明 text PK。

### P0-D3 — phx.new app naming + `ezagent_web` 重命名
`mix phx.new . --umbrella --app ezagent_core` → 生成 `apps/ezagent_core` + `apps/ezagent_core_web`;实施时把 `ezagent_core_web` 重命名为 `ezagent_web`。
**理由**:ARCHITECTURE.md §12.2 用 `ezagent_web/endpoint.ex`,§13 命名 convention 是 `:ezagent_web_<name>`。`ezagent_core_web` 是 phx.new 默认,跟架构命名不一致,Phase 0 一次性改对,避免后面所有 phase 带着错名字滚雪球。

### P0-D4 — sub-step tag 命名
格式 `phaseNa`(如 `phase1a` / `phase3d`)。
**理由**:否决 `phaseN/Na`(斜杠让 tag 看起来像 branch ref,git 允许但易混)、`phase-N-Na`(冗余)。`phaseNa` 干净、排序正常、无特殊字符。

### P0-D5 — `.claude/` 迁移清单
- **迁**:`elixir-phoenix-helper` / `erlexec-elixir`(带 PTY→web 章节更新版)/ `commit-work` / `grill-me` / `grill-with-docs`
- **弃**:`project-discussion-esr`(建在老 esr `.artifacts/` 上,对 ezagent 是 stale —— ezagent 自己长自己的项目知识)、`erlexec-elixir-workspace`(skill-creator 的 eval 工作台,不是可用 skill)、`hookify.pre-merge-dev-gate.local.md`(esr-specific 的 hookify 规则)
- **`settings.json` 全新写**:保留结构(`channelsEnabled` / `enableAllProjectMcpServers` / `enabledPlugins`),hooks 换成 ezagent 的(P0-D6);老 esr 的 hooks 指向不存在的脚本(`pre-merge-dev-gate.sh` 等),permission / marketplace 也是 esr-path-specific,不能 verbatim 迁

### P0-D6 — 强制机制:agent 纪律 + B git-hook 兜底
不变式 + sub-step gate 双保险:
1. **agent 纪律**:`/goal` prompt + `CLAUDE.md` 贯穿条款(agent 自查 8 不变式、跑 e2e flow、不绿不 tag)
2. **机器兜底**:`scripts/hooks/sub-step-gate.sh` + `.claude/settings.json` PreToolUse hook(拦 `git tag` / `git commit`,机器跑检查)
git-hook **随 phase 演化** —— Phase 0 只跑 `mix test` + `mix format --check-formatted`(无 invariant / 无 e2e flow);每个后续 phase 的 brainstorm 扩展这个脚本。
**理由**:老 esr 的 `refactor-lessons.md` 证明机器 gate 真的拦下过东西(daemon-state 不匹配);纯 agent 纪律少一道防线。

### P0-D7 — `mix ezagent.check_invariants` 在 Phase 0 定义
`CLAUDE.md` 提到的「Phase 0 brainstorm 时定义」的 task。Phase 0 是骨架(8 不变式都不适用 —— 无 dispatch 路径),Phase 1 起逐条加 grep 检查、有真牙。

### P0-D8 — dev endpoint 绑定 tailnet,不是 localhost
Allen 从 tailnet 内网 IP(`100.x.x.x`)访问 ezagent,不是 localhost。`config/dev.exs` 的 `ezagent_web` endpoint:
- `http: [ip: {0, 0, 0, 0}, port: 4000]` —— 绑 0.0.0.0,tailnet 可达(phx.new 默认 `127.0.0.1` 从 tailnet 连不上)
- `check_origin` 放行 tailnet IP,或 dev 期 `check_origin: false`(**仅 dev** —— prod 不这样)。否则 LiveView WS 从 `100.x.x.x` origin 会被拒,页面变成静态死页
**理由**:Allen 是远程测试员,所有 phase 的「测试员体验」都是从 tailnet IP 访问。Phase 0 一次配对,后面 phase 不用重踩。

## 澄清:为什么 roadmap 不用 `phx.gen.*` 生成 schema

「大部分 Phoenix 应用用生成器搭骨架」对 **typical CRUD 应用**成立 —— Ezagent 不是。Ezagent 的持久化形态(ARCHITECTURE.md §10)是**一小撮固定的通用基础设施表**,不是「每个业务实体一张表」:

- `kind_snapshots` —— **单张**通用表(`uri / kind_type / state(JSONB) / version / updated_at`),所有 Kind 的 state 是 JSONB blob,**不是 per-Kind 表**
- `invocations` / `messages` / `dlq` / `attachments` —— 各一张固定表

`phx.gen.*` 各自的适配性:
- **`phx.gen.html` / `phx.gen.live` / `phx.gen.json` —— 永不用。** Ezagent 的 web 层是 `@interface` 自动派生(Decision #8/#58:LiveView slash + CLI 都从 `@interface` 来),不是生成的 CRUD 页面。用这些直接违背架构。
- **`phx.gen.context` —— 不用。** Ezagent 的数据访问不是 CRUD —— `MessageStore` 是 `append/2` + `query/1`(7 维),`Snapshot` 是 `load`/`save` 按 kind_type。生成的 `list_x`/`get_x!`/`create_x` CRUD context 形状不对,会被重写。
- **`phx.gen.schema` —— 可选、低价值、仅限那 ~5 张通用基础设施表。** 它生成 migration + 薄 schema,但这些表只有 5 个字段且要手调(text URI 主键 per P0-D2 —— 生成器默认 bigserial/binary_id;JSONB 用 `:map` 字段;§10 的索引)。对 5 字段的通用表,手写 migration 跟用生成器再改差不多快,且手写对 text PK / JSONB / 索引有完全控制。**用不用都行,不是结构性决策。**

roadmap 没提 `phx.gen` 不是疏漏 —— 是 Ezagent 的持久化形态(固定通用表 + JSONB state blob + 领域专属访问模式)跟生成器的用途(per-业务实体 CRUD 脚手架)不匹配。这正是 `CLAUDE.md` §1「Ezagent 不是 typical Phoenix app」的一个具体体现。

## 实施期决策点(/goal 撞到时按原则定)

### phx.new flag 细节
`--no-html` / `--no-assets` 等对 phx 1.8 + LiveView 的精确影响,实施时核 phx_new 1.8 文档。
**原则**:`ezagent_core` 无 web;`ezagent_web` 用 LiveView 但不用 controller / 传统 view。flag 组合要服务这个目标。

### 老 skill 迁过来报错
**原则**:能小修就修;如果一个 skill 深度耦合老 esr 结构(像 `project-discussion-esr` 那种),弃,不勉强修。迁移目标是「干净的 skill 到新 repo 能用」,不是「不惜代价保留所有 skill」。

### Phoenix 1.8 + LiveView 1.1 版本配对
有兼容问题时,以 ARCHITECTURE.md §15 的版本为准;真冲突 → 暂停,标 issue,等 Allen。

### `.claude/settings.json` 的 PreToolUse hook matcher 写法
拦 `git tag` / `git commit` 的 matcher 具体怎么写(matcher 是 `Bash` 然后脚本内部判断 git 命令,还是更精确的匹配),实施时定。
**原则**:宁可宽(脚本内部判断)也不要漏(漏拦 = gate 失效)。

## 不发明新 Decision

Phase 0 实施期如果识别到架构问题,**暂停 → 标 issue → 等 Allen**,不自作主张(`CLAUDE.md`「grill 文化」)。任何架构决策走 Allen review,加进 `GLOSSARY.md` Decision Log。
