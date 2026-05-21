# Phase 0 — PLAN

> 任务清单。`SPEC.md` 定义"做什么",本文件定义"按什么顺序做"。`VERIFICATION.md` 是验收契约。
> Phase 0 是单块 phase(无 sub-step),按以下顺序一次跑完。

## 工作顺序

### 1. Phoenix umbrella 脚手架
- `cd ~/Workspace/ezagent`(已有 `.git` + 5 文档奠基提交 commit `c73d3d9`)
- `mix phx.new . --umbrella --app ezagent_core --no-mailer`
- phx.new 提示 3 个冲突文件:`.gitignore` / `.formatter.exs` 用 phx.new 的;`README.md` 标记为待替换(步骤 9 处理)
- **重命名** `apps/ezagent_core_web` → `apps/ezagent_web`:目录名 + `mix.exs` app name(`:ezagent_core_web` → `:ezagent_web`)+ 模块前缀(`EzagentCoreWeb` → `EzagentWeb`)+ `config/*.exs` 里所有引用 + umbrella 根 `mix.exs` 的 apps 列表

### 2. Deps
- umbrella 根 + 各 app 的 `mix.exs` 对齐 ARCHITECTURE.md §15 的依赖清单(SQLite-only;不要 postgres / oban)
- `mix deps.get`
- `mix compile` —— 必须无 warning

### 3. `/_health` + endpoint 绑定 + migration 框架
- `ezagent_web` 加 `/_health` route + Plug,返回 `{"status":"ok"}` 200(纯 Plug,不走 dispatch)
- **dev endpoint 绑定 tailnet**(P0-D8):`config/dev.exs` endpoint `http: [ip: {0, 0, 0, 0}, port: 4000]`(不是默认 `127.0.0.1`);`check_origin` 放行 tailnet IP 或 dev 期 `check_origin: false`(dev-only)—— Allen 从 `100.x.x.x` 访问,localhost 默认会拒 WS
- 配 `ecto_sqlite3` repo;`mix ecto.create`;建一个空 migration;`mix ecto.migrate`

### 4. 空 LiveView 首页
- phx.new 默认 LiveView 首页改文字成「Ezagent v0.4 — phase 0 complete」(不做别的,不是 ezagent_web_liveview plugin)

### 5. GLOSSARY.md finalize
- review 架构师 `GLOSSARY_DRAFT.md`(在老 esr workspace `~/Workspace/esr/`):确认 Decision Log #1-83 完整、术语表 + 易混淆词表无误
- 移进 ezagent 根作 `GLOSSARY.md`

### 6. `.claude/` 迁移
- 见 `DECISIONS.md` 的 P0-D5 清单
- 从老 esr `.claude/skills/` 迁 5 个:`elixir-phoenix-helper` / `erlexec-elixir` / `commit-work` / `grill-me` / `grill-with-docs`
- **不迁**:`project-discussion-esr` / `erlexec-elixir-workspace` / `hookify.pre-merge-dev-gate.local.md`
- `.claude/settings.json` **全新写**:保留 `channelsEnabled` / `enableAllProjectMcpServers` / `enabledPlugins` 结构;hooks 换成 ezagent 的(步骤 8 的 git-hook)

### 7. `mix ezagent.check_invariants` 骨架
- 在 `apps/ezagent_core/lib/mix/tasks/` 下建 `ezagent.check_invariants.ex`
- Phase 0:输出「Phase 0: no invariants apply yet」,exit 0

### 8. B git-hook 骨架
- `scripts/hooks/sub-step-gate.sh`:Phase 0 版只跑 `mix test` + `mix format --check-formatted`,任一红 → exit 非 0
- `chmod +x scripts/hooks/sub-step-gate.sh`
- `.claude/settings.json` 加 PreToolUse hook(matcher `Bash`,拦 `git tag` / `git commit` —— 具体 matcher 写法实施时定)

### 9. README.md + 验收 + 提交
- `README.md` 替换为 Ezagent-specific(简介 + 怎么读文档 + 关键 commands)
- 跑 `VERIFICATION.md` 全 checklist,逐项打勾
- 全绿 → `git add . && git commit -m "phase 0: phoenix scaffolding + toolchain"`
- `git tag phase0`

## 注意

- Phase 0 **不写任何 Ezagent 业务代码**。撞到「要不要顺手做 dispatch / Kind」→ 停,那是 Phase 1。
- `AGENTS.md` 由 phx.new 生成,**不重写**(`CLAUDE.md` 已 supplements 它)。
- 撞到架构问题 → 暂停,标 issue,等 Allen(CLAUDE.md「grill 文化」),不自作主张。
- 实施期的具体判断点(phx.new flag 细节、老 skill 报错处理)见 `DECISIONS.md`「实施期决策点」。
