# Loom 坑与债 — 事故根因 + 已知欠账

按"碰到症状先查这里"组织。每条都有出处，别重新踩。

## 事故根因（已修，但模式会复发）

### 1. Ghost session 复活（"删了模板，session 还在下拉框里"）
死 session 的 Kind snapshot 还在盘上，**任何 in-flight dispatch 都会
lazy-spawn 复活它**：`Invocation.attempt_lazy_spawn_and_redispatch`、还开着的
loom iframe 继续 POST chat.send、飞书 webhook 到达——堵不完。
`LoomSession.cleanup/3`（terminate + snapshot 删除）是 fire-and-forget，
与复活路径有竞态。**最终规则：session 可见 iff 当前 workspace 某模板声明了它**
（`admin_live.ex` 的 `list_visible_sessions_for/1`，订阅循环仍用未过滤版保持
Task #55 收件箱语义）。改 cleanup/可见性逻辑前先读这个函数头注释。

### 2. 双 instantiate → 成员数翻倍
`Workspace.add_template/3` 的 facade **内部已触发 instantiate**；LiveView 里
再调一次 `trigger_instantiate` 会让 `Team.ensure_team` 重复 spawn + join。
该函数已整段删除（workspace_detail_live.ex，2026-06-01 注释保留了完整论证，
含对 main 侧 provision_and_instantiate 重构的取舍）。**不要"顺手"加回来**。

### 3. 切视图回 Chat 空白
Phoenix LiveView 的 stream 不会在容器 remount 时 replay items。切到 Loom/PTY
等视图再切回 `:conversation` 必须 restream（`maybe_restream_messages_on_view_switch`，
admin_live.ex）。新加 SessionView 时同样的坑。

## 已知债（未修，动手前要知道）

### 4. 23 个 main 侧架构 gate 欠账（2026-06-10 rebase 后确认）
feat/loom rebase 到 main（bf9525b2）后，main 在 loom 分叉后新加的
fitness/不变式 gate 全亮红（跑 `mix test apps/ezagent_core/test` 可复现）：
- **P0.5 home_path gate**：loom 4 处 `Home.path()`（claude_code.ex:526、
  prompts.ex:511、web_plug.ex:248/540）不在 HomePathBaseline/Exceptions
- **URI canonicalization**：loom 用了 stdlib `URI.parse` / `URI.new!`
- 各类 frozen baseline（oversized modules、duplicate fn、spawn chokepoint、
  `{:set,...}` effect surface、LV↔CLI parity 表）
- **warnings-as-errors dead-code gate**：loom 的 handle_event clause 分组
  warning 会触发

**这些 baseline 是冻结的，加豁免 = 架构决策，走 Allen，不要自行加白名单。**

### 5. Plugin 契约违规（SPEC §3.2 grep gate）
`saved_classes.ex`（`TemplateRegistry.register/table` 直调）和
`application.ex`（`SessionViewRegistry.register` 等）直接碰 `*Registry` API。
`ezagent_plugin_check` 编译器在 app 目录单独跑测试时硬失败（umbrella 根目录跑
不触发）。迁移时按 migration-map 重做；feat/loom 上不要扩散这个模式。

### 6. worker_label 测试失败（分支既有）
fixture `loomworker_policy` 无 sid 段，不匹配 `loomworker_<sid>_<theme>` 正则。
见 `agent-roles.md` 末节。

## 环境 / 运维注意

### 7. `EZAGENT_NO_DISTRIBUTION=1`
WSL 上没起 epmd 时 `:net_kernel.start` 会 etimedout 干等数十秒——这个开关
完全跳过分布式启动（`ezagent_core/runtime.ex`）。代价：CLI 的 `:rpc.call`
命令不可用。**默认不开，行为不变**。这是 loom 在 core 层唯一的改动，
进 core 是否合规（LOC budget / P22）待 Allen 裁决。

### 8. `.env` 加载顺序
`config/runtime.exs` 在 dev/test 加载仓库根 `.env`，**已存在的真实环境变量优先**
（`EZAGENT_HOME=/x mix phx.server` 仍覆盖文件值）。prod 不读 `.env`。
模板见 `.env.example`。

### 9. Stitch/AiSpot 不走 LLM 开关
即使 `LOOM_LLM_BACKEND=claude_code`，Stitch/AiSpot 仍直连 DeepSeek，
需要 `DEEPSEEK_KEY`。见 `llm-backends.md`。

## 分支管理注意

- feat/loom **不会整体 merge 进 main**（迁移定调 "rewrite directly"）。
  给 main 提的修复要单独 cherry-pick/salvage，别指望随 PR #480 进去。
- 历史上 main 回滚 + salvage 造成过 ghost-commit 困惑（PR #480 review
  4465154750 的污染清单就是按回滚期旧状态算的）；判断"脏数据"永远以
  `git merge-base` + 三点 diff 对最新 origin/main 为准，别信旧 review 的文件数。
