# Agent skill 加载修复方案

- **日期**:2026-07-15(同日两轮更新:codex 对抗性 review 11 条 findings 已消化;Allen PR 回复已并入)
- **状态**:**D1、D2 均已裁**(2026-07-15:D1=显式路径/plugin-bundle,Allen;D2 第 3 层=路线 A boot 车道 + 两个策略子项,gaga/#1294 作者)→ R1/R2 转入实施;R0 盘点脚本已按 codex findings 重写并本机复验;新增 §6 gate 调研(Allen 问题)
- **背景调查**:团队反馈"agent 无法 load skill,agent 读取 config dir 启动的路径不通"。根因排查结论见下 §1(gaga 2026-07-15,memory `project-headless-skill-loading-gap`)
- **关联**:PR #1323(open,headless MCP 半边修复)、#1294(PTY 早于 config_dir 物化,已修)、#1405(bridge join 静默悬案,PTY 侧)、#1266(skill 分发 P1-P3)、#1332(builtin reseed 的 no-clobber + 显式 reseed 先例)

---

## 1. 根因摘要(调查结论,已核实)

skill 分发管线的**写入侧是通的**:recipe `skills: [ref]` → `attach_role_sandbox_content`(cc_agent.ex:522 → orchestrator_bootstrap.ex:162)→ `HomeRuntime.materialize_sandbox_skills`(core credential/home_runtime.ex:358)在原子换目录时把 `$EZAGENT_HOME/<profile>/skills/<ref>` 拷进 `<config_dir>/skills/<ref>/`。断点在**读取侧**和**存量**两处:

### 断点 A(主因):cc-headless worker 的 `setting_sources=[]`

`apps/ezagent_plugin_cc/priv/python/ezagent_cc_sdk_worker.py:101` 以 `ClaudeAgentOptions(setting_sources=[], strict_mcp_config=True)` 启动。Agent SDK 官方文档(code.claude.com/docs/en/agent-sdk/skills,Troubleshooting 节)钉死:**skills 只经 `user`/`project` setting source 发现,空列表 = 不加载**;User Skills 即 `$CLAUDE_CONFIG_DIR/skills`。worker 正确设置了 `CLAUDE_CONFIG_DIR`(:94-97),但 SDK 被告知无视文件系统 —— skill 字节物化了,没人读。

同一个 `setting_sources=[]` 还屏蔽了 config home 里的 `CLAUDE.md`(headless role agent 的 persona / skill-load hint 一并丢失)。persona 通路的准确表述(codex 修正):cc-headless **有** `tmpl["system_prompt"]` → sidecar 的现成通路(cc_headless_agent.ex:268),缺的是 recipe `sandbox_content.prompt` → 该键的**映射**(workspace 侧只有 curl flavor 做了 `system_prompt` 参数化,`agent_create.ex:566`)。受影响 agent:kanban-team 的 kanban-assistant / dev-together(`apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml:41,66`,flavor cc-headless)。

**PR #1323 只修同一断路的 MCP 半边**(route B:显式 `.mcp.json` 路径,刻意保留 `setting_sources=[]`)—— 合并后 skill 依然不通。

### 断点 B(存量 agent,PTY 也中):marker 短路 + respawn 不重物化

- `materialize_single_reference` 见到 home 已存在且带 `.ezagent-config-complete` marker 就跳过物化(home_runtime.ex:303-304);
- respawn 路径 "deliberately does NOT re-materialize the config_dir"(cc spawn.ex:312)。

两者叠加:**skill 只在 config home 首次物化时落盘**。#1266(7-08)之前建的 home、或 DB 重建后同名 agent 命中磁盘幸存旧 home(config home 路径由 agent URI 决定,`Sandbox.ConfigDir.path/2`),永远没有 `skills/`。这两处短路是 #1096/#1294 之后**有意设计**("运行中进程脚下不许换目录"),不是疏忽 —— 所以修法不能是"顺手去掉短路"。

### 断点 C(次要):registry 未 ready 时的 quiet no-attach

`orchestrator_bootstrap.ex:189-194`,只影响没起 web app 的环境(测试/legacy),不在本方案范围;registry ready 但 ref 解析失败已是响的(telemetry `[:ezagent, :skill, :resolve_miss]` + `role_degraded`)。

---

## 2. 修复方案(三件事,按序)

### R0 — 盘点(只读,先行,已附脚本;2026-07-15 按 codex review 重写)

`scripts/audit_agent_skill_homes.exs` 的契约(codex 11 条 findings 落地后):

- **零启动零写**:脚本自身不调用 `Application.ensure_all_started`(启动 ezagent_core 会带出 Migrator / system Kind spawn / audit writer 等写路径 —— codex High);`EzagentCore.Repo` 未运行直接报错退出。dev 用 `mix run` 由 mix 负责 boot,canary 在 running node 里 `Code.eval_file`。
- **枚举**:`kind_snapshots.kind_type == "agent"`(权威过滤,`Entity.Agent.type_name`;不再用 URI 子串);解码走官方 `KindSnapshot.decode_state/1`;导航 `:sandbox` slice 的权威形状并剥 Lifecycle `%{state: ...}` 包装(不再盲 deep-walk)。
- **期望 refs**:`RecipeRegistry.lookup(workspace_uri, role)`(tenant-aware,`lookup/1` 只查 system-ws —— codex High);降级回退快照 `sandbox_content.skills`;SkillRegistry 未 ready 时只查存在性。输出头部自报保真度。

| 分类 | 含义 |
|---|---|
| `ok` | 期望 refs 齐且与当前 seed 同 hash(`SkillRegistry.dir_hash/1`) |
| `missing` | home 在(带 marker)但期望 ref 缺失 —— 断点 B 存量,R2 目标 |
| `outdated` | ref 在但内容 hash 与当前 seed 不一致 —— R2 目标 |
| `hash_error` | hash 计算异常(权限/竞态)—— unknown,**不并入 outdated**,人工看 |
| `unresolvable` | home 里有该 ref 但当前 seed/registry 已无此 ref —— 单列,不算 ok |
| `unmarked_home` | home 在但无 `.ezagent-config-complete` marker(半物化/手建)—— 人工看 |
| `no_home` / `no_config_dir` | 期望>0 但磁盘目录不存在 / 快照拿不到 config_dir(异常) |
| `decode_error` | snapshot 解码失败 —— 证据不足,单列,**不并入任何结论** |
| `no_expected_skills` | 期望 refs 为空(py/native/curl 等无 skill flavor 合法落点) |
| `no_sandbox_slice` | 无 `:sandbox` slice(非 config-home Kind 形态) |
| orphan home | 磁盘 `*-agents/<ws>/<name>` 无认领 —— 认领用 config_dir **加** URI 推导的 `{ws,name}` 双通道,decode_error 行不会把自己的 home 误报成 orphan |

**输出决定 R2 的 sweep 范围**——如果 canary 的 agent 随 re-bootstrap 重建、存量集合很小,R2 可以缩成手工处理个位数目录。

本机 dev 库复验(2026-07-15,重写后,全保真 recipe_registry=live / skill_registry=ready;boot 需 `EZAGENT_SIGNING_SEED_V1` + `mix ecto.migrate`,见 #1401 runbook 与 §5):17 个 durable agent(kind_type 过滤比 URI 子串少 2 行)→ **2 `ok`** / 15 `no_expected_skills`,其余 9 类全 0 —— 本地无存量欠账;orphan home 6970(测试残留为主)。orphan 不在 R2 范围(§4),处置另议。canary 上的数字才是 R2 范围的决策依据。

### R1 — headless skill 加载(跟 #1323 同车道)【D1 已裁:显式路径】

目标:cc-headless / cc-headless-deepseek 的 claude 子进程能加载 per-agent skill(以及 persona)。**Allen 2026-07-15 裁定走显式路径**(不开 user setting source)。按 codex 修正,显式路径的准确形态是 **plugin-bundle 路线**:

- **SDK 侧**:`ClaudeAgentOptions` 的 `plugins` 字段接收 **local plugin config**(自 SDK 0.1.5 起支持,pin `>=0.2.94,<0.3` 无版本问题 —— codex 已从 changelog 证实,此前"待验证 0.2.x"的说法作废)。关键差异:**路径必须指向 Claude Code plugin bundle,不能裸指 `<config_dir>/skills/<ref>`**——plugin 需要 `.claude-plugin/plugin.json` manifest + bundle 内 `skills/` 布局。
- **物化侧**:config-dir 物化时(HomeRuntime 或 headless 专属 glue)把 recipe skills 组装成一个 per-agent plugin bundle(如 `<config_dir>/plugins/ezagent-skills/{.claude-plugin/plugin.json, skills/<ref>/...}`),worker 传 `plugins: [<该路径>]` + 启用 Skill tool(设置 `skills` 选项时 SDK 自动把 Skill tool 加进 allowed_tools;若显式传 `tools`/`allowed_tools` 必须含 `"Skill"`,与 #1323 的 `mcp__<server>` allowlist 合并时注意)。**实现前待验证**:pinned SDK 下 bundle 最小布局 + `skills` 顶层参数的确切行为(一次真 SDK 冒烟即可)。
- **persona 线**(随 R1 一并):利用 cc-headless 现成的 `tmpl["system_prompt"]` → sidecar → worker `EZAGENT_CC_SDK_SYSTEM_PROMPT` 通路(cc_headless_agent.ex:268),补上 recipe `sandbox_content.prompt` → `"system_prompt"` 的映射(目前只有 curl flavor 做了参数化,agent_create.ex:566)。
- `setting_sources=[]` 与 `strict_mcp_config=True` **保持不变**(隔离面不动;MCP 半边归 #1323)。

**决策存档**(供后来者理解 D1,非翻案):Allen 顾虑"user 路径是 docker 的 home,所有用户都一样,无法区分"。技术事实是 PTY 与 headless 都已按 agent 导出 `CLAUDE_CONFIG_DIR=<per-agent config_dir>`(worker.py:94;PTY cmd_env),`setting_sources=["user"]` 读的会是这个 per-agent 目录而非共享 `~`;但 user-scope 路线的真实代价是把 home 里**整个 user 面**(settings.json / commands / agents / CLAUDE.md,codex 补充)一并吸入。显式 plugin-bundle 开口最小,与 #1323 route B 哲学一致 —— 裁决成立。

**R1 验收含 G1 读取侧 gate(见 §6)**。

### R2 — 存量 reconcile:一套实现,双触发面【2026-07-15 已裁,含路线 A boot 车道】

一套共享的 skills-reconcile 实现,两个触发面:

- **boot 车道(自动,路线 A,gaga 已裁)**:每次重启在 `SkillSeed.boot!` 之后 sweep 全部 durable agent home;用 skills-manifest hash 戳做 O(1) 跳过未变更 agent;**fail-soft**(telemetry + 继续 boot,绝不挡启动)。镜像 SkillSeed/ManifestSeed 的 boot-lane 惯例。
- **mix task(手动补刀)**:`mix ezagent.agents.reseed_skills [--all | --agent <uri>] [--dry-run]`,覆盖"运行中途 governance 发布 recipe 变更"与定点修复场景。

reconcile 行为契约(两面共用):

1. **只动 `<config_dir>/skills/` 子树**,不 rename home 本体、不动 marker、不碰凭证/CLAUDE.md 之外的任何文件 —— 不踩 #1096/#1294"脚下换目录"的雷;**marker 短路与 respawn 不重物化两个钉死语义零改动**(这是路线 A 的立身之本)。
2. 每个 ref 用 staging + rename 原子替换(仿 `SkillSeed` 的 `.staging-` 模式);来源 = `SkillRegistry.resolve(ref)`,期望 refs 经 `RecipeRegistry.lookup/2`(tenant-aware)。
3. **覆盖策略(已裁)**:per-agent 副本 = 派生缓存,手改不存活 —— 覆盖 + telemetry(hash 三方比对识别手改并上报);定制走 EZAGENT_HOME 母本(SkillSeed 已有"手改保留")。
4. **删除策略(已裁)**:recipe 已不再声明的 ref **保留 + telemetry**,v1 不自动删。
5. 需要时幂等补 `CLAUDE.md` hint(复用 `OrchestratorBootstrap.install_role_sandbox/2` 的语义,"re-appends only if absent")。
6. headless agent 的 home 一并刷(R1 未落地前读不到,只是字节备齐)。

执行顺序:**R0 盘点 → R1(#1323 车道)→ R2 落地(boot 车道 + task)**。PTY 侧(orchestrator=cc-deepseek 等)不依赖 R1,R2 可先行受益。

---

## 3. 决策状态(2026-07-15 更新)

- **D1【已裁,Allen 2026-07-15】**:显式路径。落地形态 = plugin-bundle 路线,见 §2 R1(含决策存档)。
- **D2【已澄清,维持 defer】**:Allen 问"自动重物化机制是指重启后加载 skill 到 EZAGENT_HOME 吗?是的话本次一起修" —— **不是那一层**。分三层说清:
  1. **重启 → EZAGENT_HOME**:已存在且有 gate。这正是 Allen 记忆中"deploy 时不把 skill 装进 docker"那次修复 —— **#1266**(`dd5216bfa` release-bundled skill registry + `234f7a063` seed skills into ezagent home):skills 打进各 app `priv/skills_seed/` 随 release 进 docker,`SkillSeed.boot!` 每次 boot 复制/升级进 `$EZAGENT_HOME/<profile>/skills/`(staging+rename 原子、operator 手改保留 —— 本机日志实证:kanban-assistant 曾被本地改过,release upgrade 被 SKIP 并保留 operator 版本)。gate = `skill_distribution_prod_shape_test.exs`。**本层无需再修**。
  2. **EZAGENT_HOME → per-agent config home(存量)**:断点 B 所在层,**本轮由 R2 修**(一次性 reseed task)。
  3. **本层的"自动传播"【已裁,gaga(#1294 作者)2026-07-15:路线 A(boot 车道)】**:每次重启在 `SkillSeed.boot!` 之后加一步 boot sweep,把每个 durable agent home 的 `skills/` 子树 reconcile 到当前 recipe+seed。选 A 的关键理由:**#1294 钉死的两个语义零改动** —— sweep 不走 spawn 路径(marker 短路原样)、respawn 仍不重物化(spawn.ex:312 原样);boot 窗口里 PTY 尚未拉起,写的又只是 framework 独占的 skills 子树(per-ref staging+rename,**不 rename home 本体**),即使与早起的 respawn 相撞,最坏也只是"这一代进程用旧 skill、下次重启生效",不崩不哑。落选:路线 B(spawn/respawn 时 reconcile —— 要动两处钉死语义、过完整 grill,收益增量只有"运行中途变更+恰好 respawn"的罕见场景)、路线 C(纯手动 —— 存量更新依赖人记得跑 task,正是本次事故"静默 stale"的成因形态)。两个策略子项(gaga 同日拍,均按建议):
     - **删除策略**:recipe 已不再声明的 ref(unresolvable)v1 **保留 + telemetry**,不自动删;
     - **覆盖策略**:per-agent 副本定位为**派生缓存**(类比 node_modules)—— 手改不存活,sweep 覆盖 + telemetry(hash 三方比对识别手改);定制的正确层是 EZAGENT_HOME 母本(SkillSeed 在那层已有"手改保留");per-agent 合法 override 机制 v1 不开口。
     实现与 R2 task 共用同一套 reconcile(见 §2 R2);运行中途(governance CR)发布的 recipe 变更等下次重启或手动 R2 —— 已接受的残留。

## 4. 边界(本方案刻意不做)

- 不改 spawn / respawn 语义,不移除 marker 短路(路线 A 的 boot sweep 不经过这两处,零改动);
- 不做 spawn/respawn 时的 reconcile(路线 B 落选),不做整 home 自动重物化;boot 车道的 skills-子树 sweep **属于**本方案范围(路线 A,已裁);
- 不做 per-agent skill 的合法 override 机制(v1 不开口,见 §3 覆盖策略);
- 不动 `ARCHITECTURE.md`;
- 不处理 orphan home(盘点只列出,处置另议);
- 断点 C(quiet no-attach)不在范围。

## 5. 验证方式

- **R1**:cc-headless e2e —— 起一个带 `skills: [ref]` 的 role agent,让它自述可用 skills / 实际 invoke 一次(可挂在 `scripts/cc_headless_sdk_sidecar_e2e_seed.exs` 之后);worker 侧加单测断言 options 携带 plugins/skills 配置。**含 §6 G1 gate**。
- **R2(task + boot 车道)**:sweep 前后各跑一次 R0 盘点,`missing`/`outdated` 归零(headless 项在 R1 前允许保留标注);抽查一个 PTY agent 重启后 claude 内可见 skill。boot 车道专项:①改母本/recipe 后重启,存量 home 自动对齐(hash 相等);②手改某 agent 副本 → 重启被覆盖 + 手改覆盖 telemetry;③recipe 移除 ref → 副本保留 + telemetry;④注入失败(如权限)不挡 boot,telemetry 可见;⑤未变更 agent 走 manifest-hash 快速跳过(boot 耗时有界)。
- 本地 dev boot 前置:`EZAGENT_SIGNING_SEED_V1`(≥32 字节,#1399 引入,#1401 runbook)+ `mix ecto.migrate`。已写入 `.claude/skills/ezagent-developer` 供测试指引。

## 6. gate 调研:为什么"测试环境 ≠ 部署环境"的 gate 漏过了本次 bug(Allen 问题)

**那个 gate 是** `apps/ezagent_plugin_cc/test/ezagent/template/skill_distribution_prod_shape_test.exs`(#1266 随修复一起引入),它钉两条:①bundle == derivation(每个 recipe 派生的 skill ref 必须能从 release 打包的 SkillRegistry origin 解析,`seed_bundle_refs() == derived_recipe_skill_refs()`);②**非 dev 环境禁止回退 repo tree**(runtime registry 为空时必须 fail `{:skill_source_not_found, ref}`,不许走 `.claude/skills/` 目录树)——第②条正是上一次"本地能过(repo tree 在)、docker 不过(repo tree 不在)"事故的直接钉子。

**为什么这次漏了**:gate 的覆盖终点是"**字节可从运行时 origin 解析**"。本次断点在覆盖终点**之后**的读取侧 —— 字节一路正确走到 `<config_dir>/skills/`(写侧各段都有测试),但 **claude 进程是否真的加载**从来没有任何 gate。headless worker 的 `setting_sources=[]` 恰好住在这个无人区。

**放大器(正是 Allen 猜的形态)**:headless 的 e2e 面存在系统性的"测试环境 ≠ 部署环境":
1. `scripts/cc_headless_sdk_sidecar_e2e_seed.exs` **默认用 fake worker**(`fake_cc_sdk_worker.py`,不启动真 claude)—— 读取侧永远不被行使;
2. 开 `CC_HEADLESS_E2E_REAL_SDK=1` 时,`config_dir` 默认取 **`~/.claude`(开发者宿主机 home)** —— 本机个人 home 里有 skills/登录态,本地测试"能过";docker 里的 per-agent 隔离 dir 则完全是另一个世界。"真 SDK × 真隔离 config_dir"这个组合从未被自动化验证过。

**建议(随 R1 落地)**:
- **G1 读取侧 gate**:(a) worker 单测断言 `ClaudeAgentOptions` 携带 plugins/skills 配置(防止 `setting_sources=[]` 这类"配置即断路"回归);(b) 真 SDK e2e 变体:在**隔离** config_dir(绝不允许 `~/.claude`)放一个探针 skill,断言 agent 能列出/invoke 它;CI 至少跑 (a),(b) 进 nightly/canary 冒烟。
- **顺手修**:e2e seed 脚本 REAL_SDK 模式的 `config_dir` 默认值从 `~/.claude` 改为隔离临时目录 —— 这个默认值本身就是掩盖环境差异的坑。
