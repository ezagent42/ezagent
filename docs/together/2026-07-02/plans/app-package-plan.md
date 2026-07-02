# PLAN: socialware app-package (T1 基建 → T2 app-package)

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** origin/main `adf5fad5` · **分支:** `integration/app-package`
> **SPECs:** `T1-preprod-foundation.md`（基建）+ `T2-app-package.md`（app-package）,均经 3 轮 codex 对抗性评审收敛。
> **执行者:** codex（handoff 见 `handoffs/app-package-codex-handoff.md`）。
> **闸门:** 本 plan 也过一轮 codex 对抗性评审（Allen 定）→ 通过 → codex 实施。

## 0. 总原则
- **pre-prod 窗口**：下周上生产前必须完成 T1（cap/subject/behavior 命名一旦铸进生产数据,迁移代价高）。
- **顺序**：T1 全绿 merge → T2 rebase 到 T1 上做。文件重叠仅 `definition_registry.ex`(不同函数)。
- **每个 PR 独立可测 + 全套 arch gate（300s）+ precommit 绿才 merge**。
- **dev 数据 pre-prod 可 wipe+reseed**（无生产 cap/snapshot,规避大部分迁移）。
- **codex 交付纪律**（feedback_codex_handoff_self_merge_target）：codex 自 commit/push 到 `integration/app-package`,**不 merge main、不开 PR**,每 PR 逐个交回,coordinator（我）验收 + 合。

## 1. T1 — pre-prod 基建（先做，4 条 PR 链 + 1 独立）

### PR-T1-A1 · Behavior → ActionSet 机械改名
- **改**：`Ezagent.Behavior.*` → `Ezagent.ActionSet.*`（212 文件/777 处 module 定义 + 引用）；`use Ezagent.Behavior`/`@behaviour Ezagent.Behavior`（`lifecycle.ex:195-200`）；`Module.concat([:Ezagent,:Behavior,...])`（`ezagent.stress.ex:95`）;`Ezagent.Behavior.new_style?`（`runtime.ex:768`）;arch 元数据 `"Behavior"→"ActionSet"`（`arch.scan.ex:184`）。
- **不改**：cap 里 `behavior` 字段名（那是 struct 字段,不是模块名）——只改它的**值**（模块名字符串）见 A2。
- **验证**：`mix compile -w-a-e` 0 warning；全套 arch+precommit 绿。
- **DoD**：`grep "Ezagent.Behavior\b" apps test docs` = 0（除迁移注释）。

### PR-T1-A2 · stale-string 迁移 + grep gate（依赖 A1）
- **迁移**（Repo 级扫描重写）：`users.caps_json`（`normalize.ex:7,17`）+ `kind_snapshots` **全 term 解码**（含 identity 切片 caps,参 `grant_migration.ex:16,162`）+ `socialware_config_objects.body`（recipe & definition body 的 behavior 字符串,`recipe_registry.ex:361`/`definition.ex:75`）。旧 `Ezagent.Behavior.*` → `Ezagent.ActionSet.*`。**pre-prod dev 直接 wipe+reseed 兜底**。
- **grep gate**（防回归,挂 CI）：拒绝 `Ezagent.Behavior\b` + `:Behavior` atom + `Module.concat([:Ezagent,:Behavior` + 持久化 body/caps 字符串;扫 `apps`+`test/support`+`docs/scenarios`。
- **DoD**：Repo 扫描 3 表无 `Ezagent.Behavior.` 字符串;grep gate 绿。

### PR-T1-B · config:// → 结构化 subject + 迁移（独立于 A）
- **scope**：**仅 definition/recipe 的伪 URI subject**（`definition_registry.definition_subject_uri` + recipe registry 对应函数）→ `"<kind>:<name>"`（冒号串,opaque）。**agent/session 用真 entity URI 当 subject 的不碰**（`agent/config.ex:197`/`installation.ex:177,230`）。
- **拆 normalize**（codex T1 v3 #1）：`ConfigStore.normalize_uri/2`（`config_store.ex:321`）现对任何 binary 调 `Ezagent.URI.new!` → 拆成"workspace URI 规范化"vs"opaque subject 规范化",新 subject 不进 URI 解析。
- **迁移**（三处）：`socialware_config_objects.subject_uri` + `socialware_config_pointers.subject_uri` 列;`ConfigPointer.id` 主键重建（`config_pointer.ex:31`,碰撞预检,先例 `20260627..._rename_advisor...`）;`socialware_config_objects.body` 内嵌 `definition_subject_uri`（`installation.ex:240,244`）;`socialware_config_change_requests` + staged objects（`config_change_request.ex:34` 唯一约束）。**pre-prod wipe+reseed 兜底**。
- **DoD**：`grep config:// apps` = 0;上述表/body 无 `config://`。

### PR-T1-C · URI gate 兜底（依赖 B）
- **改** `uri_query/scan.ex`：从"只查 6 scheme"→"任何 `<scheme>://` 裸构造/解析都报,除非在 allowlist"。
- **两 allowlist**：① ezagent 一等 scheme(6,走 Ezagent.URI) ② 外部 URL 唯一权威表 = `postgresql/unix/http/https/ws/test/cc-bridge`（**排除已删 `feishu://`**——feishu 用 `https://`）。只对 ezagent-like 未知 scheme 硬拦。
- **DoD**：未知 `foo://bar` → CI 红;7 个外部 scheme 不误报;加新 scheme 必须同进 registry+allowlist。

### PR-T1-D · role(配方义) → recipe 收尾改名（独立）
- **改**：`Ezagent.Role` 模块退役→并入/别名 `Ezagent.Agent.Recipe`;`template://<ws>/role/<name>`→`template://<ws>/recipe/<name>`（持久化段,存量 kind_snapshots/template 迁移）;`orchestrator_role.ex`→`orchestrator_recipe.ex`+符号;配方义变量 `role`→`recipe`。
- **不改**：路由义 `role_name`/`{:role,name}`/`$role:`（`receiver.ex:9`）+ per-session 唯一 role_name（`membership.ex:31-35`）。
- **grep gate**：无 `Ezagent.Role`/`template://.../role/`/`config://.../role/`;保留 `role_name`/`{:role`/`$role:`。
- **DoD**：配方义 role 清零;路由义保留;`template://.../recipe/` 迁移无丢失。

### PR-T1-Skill · skill 同步（收尾，全 T1 落地后）
- `ezagent-developer` 全 references：`Ezagent.Behavior`→`Ezagent.ActionSet`、配方义 `role`→`recipe`、`config://`→结构化 subject 表述。
- grep skill 目录无残留旧引用。

**T1 依赖图**：A1→A2；B→C；A/B/D 并行；Skill 最后。**T1 全绿 merge 到 `integration/app-package` 后开 T2。**

## 2. T2 — app-package（rebase 到 T1 上）

### PR-T2-1 · `agents:[%{recipe,role_name}]` 字段 + gate 骨架
- Definition struct（`definition.ex:11`）+ `new/1`（`:37`,校验 recipe ref 可解析 + role_name 非空）+ `body/1`（`:77` JSON 序列化）加 `agents`。
- gate 骨架（`mix ezagent.socialware.check`）：recipe 解析/caps 注册/adapters/URI-parse/routing-receiver/prompt_template_ref/role_name 唯一。
- **DoD**：坏 definition（不存在 recipe / 重复 role_name / 坏 prompt_ref）→ gate 红。

### PR-T2-1b · agents 物化消费者（§4b，依赖 T2-1）
- materialize（`definition_editor.ex:250` reduce + `materializer.ex`）新增 `agents` 分支：每项 → RecipeRegistry 解析 recipe → `SessionAgentMaterialize.materialize`（`session_agent_materialize.ex:144`,分配 role_name,per-session 唯一）→ `GrantRecipeCaps` 授 recipe.requested_caps。
- **DoD**：Definition.agents → 活的 per-session agent（带 role_name）+ caps 授予,测试证明。

### PR-T2-2a · views = view-ActionSet（后端字段 + 唯一动作）
- Definition `views: [view_actionset]` 字段（进 `Definition.behaviors/1` = `[Session]++views++shape++bases`,codex T2 v3 #1——保证 view 真进 behavior set）。
- 每个 view ActionSet 声明唯一 `<sw>_render` 动作（决策1=a,避 `{Session,action}` 冲突）+ required_caps。
- **DoD**：多 view 注册无 `{kind,action}` 冲突;view 动作解析在 spawned session 上。

### PR-T2-2b · 统一 authorize_view 下沉 SessionView 契约（决策2，依赖 2a）
- `Ezagent.UI.SessionView` 契约扩 caller 维度 + 每 view 声明 backing ActionSet;`SessionViewRegistry.applicable_views/render/external_render` 全经共享 `authorize_view(view,caller,session_uri)`（检查 `<sw>_render` cap）。
- anon mint（`anon_user.ex:119`）：加 `Installation.anon_view_caps(session_uri)` 只授**公开** definition（`visibility_policy.web_anon_access==true`,`installation.ex:115`）的 view read-cap（codex T2 v3 #2——混合 public/private session 不泄露 kanban）。
- arch gate 扫 SessionViewRegistry 路径,断言无 renderer 绕过 `authorize_view` 直读 slice。
- **DoD**：anon 只看被授权 view、看不到未授权（混合 session 测试）;arch gate 绿。

### PR-T2-3 · conformance gate 挂 CI（10 条，依赖字段+授权就位）
- `mix ezagent.socialware.check` 10 条断言（SPEC §4）挂 CI,与现有 gate 并列。
- **DoD**：kanban + 官网 2 个 conformance example 过同一 gate。

### PR-T2-4 · package.yaml → Definition loader（与 gaga 协同）
- YAML decode（复用 `AgentManifest.load/1` 的 YamlElixir + `FsResolver.read_yaml/1` seam,不新造）→ 校验 → 写 Definition。gaga 出文件格式,我们出 Definition/校验映射。
- **DoD**：AutoService package.yaml 经 loader → Definition,过 gate。

### PR-T2-5 · skill 同步（收尾）
- `ezagent-socialware`：Definition 含 `agents`(recipe+role_name)+`views`;view=渲染 ActionSet + authorize_view;两层门。
- `ezagent-developer` capbac/architecture-invariants：view read-cap、authorize_view 强制、无直读绕过。

### （独立前端 PR，依赖 #1118）ui_surface_provider → 读 Definition.views
- World tab/nav 从 plugin-push+condition 改读 Definition.views。前端,最后,依赖 #1118 定稿。

**T2 依赖图**：1→1b；1→2a→2b；(1b,2b)→3→4；5 收尾;前端 PR 最后。

## 3. 验证矩阵（每 PR 必过）
- `mix compile --warnings-as-errors` 0。
- 全套 arch gate（`mix test --only architecture`,**300s timeout**——arch scan 60s 会环境性超时）。
- `mix precommit`（每 suite 0 failures,gate on EXIT=0 AND grep "0 failures"）。
- 相关 invariant test（cap parity / uri_query scan / doc scan / plugin check）。
- pre-prod disposable stack wipe+reseed 后端到端起（cc/socialware/recipe/anon-view）。

## 4. 风险 & 缓解
- **迁移遗漏**（最大风险）：pre-prod wipe+reseed 兜底 + Repo 级扫描断言零残留。
- **arch scan 超时**：统一 300s（已知坑）。
- **T2 rebase 冲突**：仅 `definition_registry.ex` 不同函数,低;T1 先全绿再开 T2。
- **前端 #1118 未定**：前端 PR 独立、最后,不阻塞后端 T2。

## 5. DoD（整体）
- [ ] T1 4+1 PR 全绿 merge;pre-prod 三概念（ActionSet/结构化 subject/recipe）残留清零 + gate 防回归。
- [ ] T2 6 PR 全绿 merge;Definition 有 agents+views;authorize_view 单一授权点;conformance gate 挂 CI。
- [ ] kanban + 官网过同一 app-package gate（2 conformance example）。
- [ ] skill 全同步;grep 无旧表述。
- [ ] 上线前 T1 完成（pre-prod 硬窗口）。
