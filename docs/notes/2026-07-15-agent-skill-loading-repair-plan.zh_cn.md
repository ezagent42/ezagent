# Agent skill 加载修复方案(提案,待 Allen 拍板)

- **日期**:2026-07-15
- **状态**:proposal —— R0 盘点脚本已附(`scripts/audit_agent_skill_homes.exs`,只读);R1/R2 未实施;两个决策点(D1/D2)等 Allen
- **背景调查**:团队反馈"agent 无法 load skill,agent 读取 config dir 启动的路径不通"。根因排查结论见下 §1(gaga 2026-07-15,memory `project-headless-skill-loading-gap`)
- **关联**:PR #1323(open,headless MCP 半边修复)、#1294(PTY 早于 config_dir 物化,已修)、#1405(bridge join 静默悬案,PTY 侧)、#1266(skill 分发 P1-P3)、#1332(builtin reseed 的 no-clobber + 显式 reseed 先例)

---

## 1. 根因摘要(调查结论,已核实)

skill 分发管线的**写入侧是通的**:recipe `skills: [ref]` → `attach_role_sandbox_content`(cc_agent.ex:522 → orchestrator_bootstrap.ex:162)→ `HomeRuntime.materialize_sandbox_skills`(core credential/home_runtime.ex:358)在原子换目录时把 `$EZAGENT_HOME/<profile>/skills/<ref>` 拷进 `<config_dir>/skills/<ref>/`。断点在**读取侧**和**存量**两处:

### 断点 A(主因):cc-headless worker 的 `setting_sources=[]`

`apps/ezagent_plugin_cc/priv/python/ezagent_cc_sdk_worker.py:101` 以 `ClaudeAgentOptions(setting_sources=[], strict_mcp_config=True)` 启动。Agent SDK 官方文档(code.claude.com/docs/en/agent-sdk/skills,Troubleshooting 节)钉死:**skills 只经 `user`/`project` setting source 发现,空列表 = 不加载**;User Skills 即 `$CLAUDE_CONFIG_DIR/skills`。worker 正确设置了 `CLAUDE_CONFIG_DIR`(:94-97),但 SDK 被告知无视文件系统 —— skill 字节物化了,没人读。

同一个 `setting_sources=[]` 还屏蔽了 config home 里的 `CLAUDE.md`(headless role agent 的 persona / skill-load hint 一并丢失;recipe `prompt` 只有 curl flavor 走 `system_prompt` env,`agent_create.ex:566`)。受影响 agent:kanban-team 的 kanban-assistant / dev-together(`apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml:41,66`,flavor cc-headless)。

**PR #1323 只修同一断路的 MCP 半边**(route B:显式 `.mcp.json` 路径,刻意保留 `setting_sources=[]`)—— 合并后 skill 依然不通。

### 断点 B(存量 agent,PTY 也中):marker 短路 + respawn 不重物化

- `materialize_single_reference` 见到 home 已存在且带 `.ezagent-config-complete` marker 就跳过物化(home_runtime.ex:303-304);
- respawn 路径 "deliberately does NOT re-materialize the config_dir"(cc spawn.ex:312)。

两者叠加:**skill 只在 config home 首次物化时落盘**。#1266(7-08)之前建的 home、或 DB 重建后同名 agent 命中磁盘幸存旧 home(config home 路径由 agent URI 决定,`Sandbox.ConfigDir.path/2`),永远没有 `skills/`。这两处短路是 #1096/#1294 之后**有意设计**("运行中进程脚下不许换目录"),不是疏忽 —— 所以修法不能是"顺手去掉短路"。

### 断点 C(次要):registry 未 ready 时的 quiet no-attach

`orchestrator_bootstrap.ex:189-194`,只影响没起 web app 的环境(测试/legacy),不在本方案范围;registry ready 但 ref 解析失败已是响的(telemetry `[:ezagent, :skill, :resolve_miss]` + `role_degraded`)。

---

## 2. 修复方案(三件事,按序)

### R0 — 盘点(只读,先行,已附脚本)

`scripts/audit_agent_skill_homes.exs`:枚举 `kind_snapshots` 里的 agent(复用 `mix ezagent.snapshot.list` / `Home.Migration` 的解码惯例,deep-walk `state_binary`),对每个 agent 求出 flavor / role / 期望 skill refs(优先当前 `RecipeRegistry`,回退快照里的 `sandbox_content.skills`),再查磁盘:

| 分类 | 含义 |
|---|---|
| `ok` | 期望的 refs 齐且与 seed 同 hash(`SkillRegistry.dir_hash/1` 对比) |
| `missing` | home 存在(带 marker)但期望 ref 缺失 —— 断点 B 存量 |
| `outdated` | ref 在但内容 hash 与当前 seed 不一致 |
| `no_expected_skills` | 该 agent 的 recipe 不带 skill(如 hello 各 role、native)—— 无需处理 |
| `no_home` | 快照有 config_dir 记录但磁盘目录不存在(信息项) |
| `orphan_home` | 磁盘 `*-agents/<ws>/<name>` 目录无快照认领(信息项,不处理) |

跑法:dev `mix run scripts/audit_agent_skill_homes.exs`(boot 失败时兜底 `--no-start`,只起 ezagent_core);canary 在 running node 的 remote console 里 `Code.eval_file("scripts/audit_agent_skill_homes.exs")`。脚本自报保真度:RecipeRegistry / SkillRegistry 未 ready 时降级(期望值回退快照、只查存在性),**正式盘点请在全量 booted 节点上跑**。**输出决定 R2 的 sweep 范围**——如果 canary 的 agent 随 re-bootstrap 重建、存量集合很小,R2 可以缩成手工处理个位数目录。

已在本机 dev 库正式跑过(2026-07-15,全保真:recipe_registry=live / skill_registry=ready;boot 需 `EZAGENT_SIGNING_SEED_V1`,见 #1401 runbook):19 个 durable agent → **2 `ok`**(期望 refs 齐且 hash 与当前 seed 一致,过期检测路径验证工作)、17 `no_expected_skills`(recipe 不带 skill)、0 missing / 0 outdated —— 本地无存量欠账。**orphan home 6929 个**(`~/.ezagent/default/cc-agents/admws-*/<uuid>`,快照无认领)——正是 §1 断点 B 描述的"DB 清空/重建后磁盘 home 幸存"现象的实证(本地来源多为测试跑残留);orphan 不在 R2 范围(§4),处置另议。canary 上的数字才是 R2 范围的决策依据。

### R1 — headless skill 加载(跟 #1323 同车道)

目标:cc-headless / cc-headless-deepseek 的 claude 子进程能加载 `<config_dir>/skills/`(以及 persona 所在的 `CLAUDE.md`)。两条候选路线,**最终选择 = D1,待 Allen**:

**路线 1a:`setting_sources=["user"]`**(worker 一行改动 + `skills`/Skill tool 启用)

- user source 读的是 `$CLAUDE_CONFIG_DIR` = 我们**自己物化的 per-agent 隔离 home**。注意这与 #1323 拒绝的 route A 不同:route A 拒的是 *project* source(读 cwd、依赖未文档化的 `.mcp.json` 加载);user source 指向受控目录,不引入 cwd 语义。
- 一次性带回三样:skills + `CLAUDE.md`(persona/hint)+ user settings.json。`strict_mcp_config=True` 继续兜住 MCP 面(user source 不影响 #1323 的显式 mcp_servers 路径)。
- 代价:home 里**所有** user-scope 配置都生效(将来往 home 里放的任何 settings 都会被 headless 吃进去)—— 面变宽,需要接受"物化 home 即权威配置"的立场。

**路线 1b:SDK `plugins` 选项显式指路径**(文档明示可从指定路径装 skill)

- 与 #1323 route B 哲学一致:显式路径、最小开口、不打开任何 setting source。
- 代价:只解决 skills,**CLAUDE.md persona 仍然不加载**(需另配 `system_prompt` 线:把 recipe prompt 从 tmpl 一路穿到 `EZAGENT_CC_SDK_SYSTEM_PROMPT`,cc-headless 目前只透传 `tmpl["system_prompt"]`,cc_headless_agent.ex:268);且需**先验证 pinned SDK(`claude-agent-sdk>=0.2.94,<0.3`,worker PEP-723 头)是否支持 `plugins`/`skills` 选项** —— 文档是 current docs,不代表 0.2.x 已有。
- 两条路线共同的实现要点:按 SDK 文档,设置 `skills` 选项时 SDK 自动把 Skill tool 加进 allowed_tools;若显式传 `tools`/`allowed_tools` 列表则必须包含 `"Skill"`(与 #1323 的 `mcp__<server>` allowlist 合并时注意)。

**倾向**:若 pinned SDK 的 `plugins` 不支持 skills-from-path,直接 1a;若支持,1b + 单独补 persona 线,与 #1323 的隔离哲学更一致。验证成本低(worker 单测 + 一次真 SDK 冒烟),建议实现者先做 5 分钟验证再回 D1。

### R2 — 存量一次性 reseed(operator mix task)

新任务 `mix ezagent.agents.reseed_skills [--all | --agent <uri>] [--dry-run]`,行为契约:

1. **只动 `<config_dir>/skills/` 子树**,不 rename home 本体、不动 marker、不碰凭证/CLAUDE.md 之外的任何文件 —— 不踩 #1096 类"脚下换目录"的雷(claude 启动时读 skill,刷完等下次重启自然生效)。
2. 每个 ref 用 staging + rename 原子替换(仿 `SkillSeed` 的 `.staging-` 模式);来源 = `SkillRegistry.resolve(ref)`。
3. 需要时幂等补 `CLAUDE.md` hint(复用 `OrchestratorBootstrap.install_role_sandbox/2` 的语义,"re-appends only if absent")。
4. **default no-clobber、显式 operator 触发** —— 与 `mix ezagent.socialware.reseed_builtins <名> --force`(#1332)同一哲学,不发明新 Decision。
5. headless agent 的 home 一并刷,但注明:**R1 未落地前刷了也读不到**,只是提前把字节备齐。

执行顺序:**R0 盘点 → R1(#1323 车道)→ R2 sweep**。PTY 侧(orchestrator=cc-deepseek 等)不依赖 R1,R2 可先行受益。

---

## 3. 待 Allen 决策

- **D1**:R1 路线选择(1a user-source vs 1b plugins 显式路径),本质是"物化 home 即权威配置"与"最小显式开口"两种立场的取舍。见上文两侧代价。
- **D2(defer,本方案不实施)**:长期机制 —— config-home 物化"三态化"(absent→写 / same→跳 / outdated→升级,类比 #1242 ConfigStore seed 契约),让 recipe skill 变更自动传播到存量 agent。它要动 marker 短路(home_runtime.ex:303)和 respawn 不重物化(spawn.ex:312)两个 #1294 之后钉死的语义,必须走完整 grill;在 recipe skill 变更频率不高的现状下,"每次变更后手动跑一次 R2"够用。登记不做。

## 4. 边界(本方案刻意不做)

- 不改 spawn / respawn 语义,不移除 marker 短路;
- 不做任何自动重物化(那是 D2);
- 不动 `ARCHITECTURE.md`;
- 不处理 orphan home(盘点只列出,处置另议);
- 断点 C(quiet no-attach)不在范围。

## 5. 验证方式

- **R1**:cc-headless e2e —— 起一个带 `skills: [ref]` 的 role agent,让它自述可用 skills / 实际 invoke 一次(可挂在 `scripts/cc_headless_sdk_sidecar_e2e_seed.exs` 之后);worker 侧加单测断言 options 携带 skills 配置。
- **R2**:sweep 前后各跑一次 R0 盘点,`missing`/`outdated` 归零(headless 项在 R1 前允许保留标注);抽查一个 PTY agent 重启后 claude 内可见 skill。
