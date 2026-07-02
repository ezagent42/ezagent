# SPEC T2 · app-package: fatten socialware Definition (roles + views-as-behavior)

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** origin/main `adf5fad5`, **rebased on T1**
> **依赖 T1**（pre-prod 基建：ActionSet 改名 + config→结构化 subject + gate 兜底）。T2 在 T1 之上做，`definition_registry` 已是新 subject 格式。
> **闸门:** 定稿 → codex 对抗性评审（钉 origin/main）→ plan+handoff → codex 实现。

## 1. 结论（经多轮 Allen grill + 代码调研 + codex 评审收敛）

**不新建 "app" 概念。** 三层模型（emacs 类比）：

| 层 | 是什么 | emacs 类比 | 用户可见 |
|---|---|---|---|
| **socialware Definition**（发布单元，**变胖**）| 可发布的对外交付单元 | major/minor mode | 否 |
| **SessionTemplate**（**不动**）| 这个 session 装哪些 socialware | "文件加载哪些 mode" | 否（建会话选的类型）|
| **session** | 运行实例 = 左栏对话 item | 打开的 buffer | **是**（具名对话）|

- **发布单元 = socialware Definition**（不是 SessionTemplate、不是 app）。
- **fatten 的是 Definition**；SessionTemplate 保留名/原状（已能 `installs: [name]` 多个 def）。
- **用户面**不引入 "app" 字眼——左栏永远具名对话（AutoService/官网/kanban）。

## 2. Definition 现状（核过 main）

`definition.ex:11-20` 已有 10 字段：`name · bases · shape · members · routing_rules · prompt_templates · legends · orchestrator_template_uri · adapters · visibility_policy`。`behaviors/0`（`:67`）= `[Session] ++ shape ++ bases`（加载的 mode 集）。

**openness 已在 `visibility_policy`（per-socialware，NOT template）** —— P4 决定（`public_view.ex` main 版 moduledoc："P4 split the old template boolean into...definition's visibility_policy"），Allen 确认理由：hello 对外 / kanban 对内，一个 session 内 diverse。**不回退、不动。**

## 3. 要加的 2 个字段

### 3.1 `roles: [recipe_ref]`
这个 socialware 带哪些 agent 配方（引用 RecipeRegistry 按名解析，#1116 已有 fail-closed；agent 配置在 agent 内部，Definition 只引用）。含每个 role 的 `requested_caps`。**现在 package.yaml 有、Definition 和 SessionTemplate 都无家 → 真正的缺口。**

### 3.2 `views: [view_actionset]` —— views-as-behavior（核心设计，Allen 定 + 2 轮 codex 验证）
- **view = 渲染类 ActionSet**（T1 改名后；沿用现有 `ActionSet.Surface`/`ActionSet.HelloBuilder` 那一类）。声明一个 view → 它进 `shape` 成为一个 render ActionSet。
- **【决策1 = (a)，Allen 定】每个 view 用唯一动作名 `<sw_name>_<action>`**（如 `:hello_render` / `:kanban_render`），**不是**所有 view 共用 `:render`。原因（codex T2 #1 + 核 `capability_registry.ex:82-96`）：dispatch 路由表是 `{kind, action} → behavior`,**同一 `{kind, action}` 只允许一个 behavior**（`check_conflict!` 冲突即 raise）；views 都挂 Session Kind,若共用 `:render` 则第二个注册撞车。→ 唯一动作名保证 `{Session, :hello_render}` / `{Session, :kanban_render}` 各不冲突。**动作名带 sw 前缀的业务语义活在产品 plugin 里,不进平台层**（符合分层）。
  - **否决 (a')**（view 各自成 Kind、`{Hello, :render}`）：view 是"看一个 session 的一种方式"（`session_view.ex` 契约 + `definition.behaviors` union 进 session set），**不是独立可寻址实体**；提升成 Kind = 过度建模、推翻"view=session facet"模型。
  - **否决 (b)**（cap 加 view 维度）：动 cap 五轴结构,pre-prod 窗口风险过大。
- **该 ActionSet 声明它的 view 读动作 `<sw>_render`** + 其 `required_caps` —— 现有 `Surface` 只有 put_version/approve 等**写**动作、读是普通函数（`surface.ex:114-128`），**必须新增受 cap 门控的 view 读动作**（codex T2 #2）。
- **匿名可见如何成立**（已核 `anon_user.ex`）：匿名访客 **mint 一个真实 anon User，born with cap**（`create_read_only` 写进 caps_json，`anon_user.ex:119-127`）。→ 要让匿名看某 view，**mint 时多授该 view 的 `<sw>_render` 读 cap**（concrete + serializable）。机制可行（codex 确认）。

#### 3.2.1 统一 view 授权点（Allen 定 —— 消灭直读绕过，不是特例）
**问题（codex T2 #1）**：当前 view 渲染**全部直读 `:surface` slice、绕过 cap**——内部 `PageView`（`page_view.ex:24-43,66-69` 直读）+ 外部 `ExternalFeed`（`external_feed.ex:46-55` 只按 `Membership.authorize` 成员级授权，`:392-407`）。**光 mint view-cap 是惰性的**：没有任何入口检查它。

**决定【决策2 = 动 SessionView 契约，Allen 定】（不是给 ExternalFeed 加特例，而是下沉到契约层）**：
- **真正的渲染契约是 `Ezagent.UI.SessionView`**（`session_view.ex`：`applies_to?/render/external_render`）——PageView/ExternalFeed/hello-page 都是它的实现（codex T2 v2 #2）。`SessionViewRegistry.applicable_views/external_renderers` 现在**只按 session_uri 过滤、不看 caller/cap**。
- **建共享 `authorize_view(view, caller, session_uri)`** 检查 caller 是否持有该 view 的 `<sw>_render` read cap，**下沉进 SessionView 契约 + Registry**：
  - SessionView 契约扩一个 caller 维度；每个 SessionView 声明其 backing view ActionSet。
  - `applicable_views` / `render` / `external_render` / adapter render / channel refresh **全部经 `authorize_view` 一条路**——不是包在外面几个入口，而是收进契约层,所有 SessionView 实现天然 caller-aware。
- **保留投影旁路读**（不把渲染改成 full dispatch —— 尊重 `ExternalFeed` moduledoc "auth/projection 正交" 的性能设计）：只把**授权维度**从"成员 / 直读无检查"**升级**成"持有该 view 的 cap"。授权点统一、projection 不变。
- **两层门**：openness（Definition.visibility_policy，决定是否 mint anon = 能不能进 session）是粗粒度；view-cap（`authorize_view`，进来后看得到哪些 view）是细粒度,**对所有 view 统一强制**。
- **淘汰旧模型**：旧的"一个 session 整体可见/不可见"（membership-only 授权）**被 per-view 授权取代**（Allen：hello 对外 / kanban 对内，同 session diverse）。
- **arch gate 扫 SessionView Registry 路径**（不只命名模块）：断言无 SessionView/external renderer/adapter 绕过 `authorize_view` 直读 slice。

**退役隐式推导**：现 `ui_surface_provider`（World 前端 plugin-push + per-session condition）→ 可见性权威收归 **Definition.views + `authorize_view`**。**前端 tab/nav 改读 Definition.views 拆成独立前端 PR**（依赖 #1118）。

## 4. Gate 定义（补全 —— codex #7）

`mix ezagent.socialware.check <definition>` —— 一条规则：**所有声明的引用都能解析**：
1. `bases`/`shape` ActionSet 模块存在（编译期）
2. `views` 每个 view-ActionSet 存在 + 其 `required_caps` 已在 CapabilityRegistry 注册
3. `roles` recipe 经 RecipeRegistry 按名解析（#1116 fail-closed）
4. `roles.requested_caps` 每个 cap 已注册
5. `adapters` 在 AdapterRegistry 注册
6. `orchestrator_template_uri` 可 `Ezagent.URI.new!` 解析（**codex #7**：会 raise，要 catch）
7. `Installation.resolve_definitions` 能物化（现有 `{:unknown_socialware_install}`）
8. **members / routing_rules receivers / prompt_templates / legends 引用可解析**（**codex #7 补**：materialize 实际还解析这些，`template_team.ex:157-327` 的 `{:unknown_rule_receiver}` 等）
9. **每个 view 渲染入口都过 `authorize_view`**（§3.2.1）—— arch gate 断言：没有任何 view 渲染路径直读 `:surface` slice 而绕过 view-cap 检查（消灭直读绕过）。
10. **`routing_rules[].prompt_template_ref` 校验**（codex T2 v2 #4）：每个非-nil `prompt_template_ref` 必须命中 `prompt_templates` 的 key，且经 `PromptTemplate.validate/1`（现在 materialize 只存不验、delivery 缺模板静默降级 `session.ex:966-970`）。

## 4b. roles 物化（补 —— codex T2 v2 #3：roles 不能只存不用）
`roles` 字段光加不物化 = 死字段。**物化规则**：session materialize 时,合入 `Definition.roles` → 经 RecipeRegistry 在 session workspace 解析 recipe → 调**已有的 fail-closed `SessionAgentMaterialize`**（`session_agent_materialize.ex:144-215`,#1116 那个通用机制）逐个物化 per-session role-agent → 经 `GrantRecipeCaps` 卡点授 `requested_caps`。**明确 roles 与 members 关系**：roles = "这个 socialware 自带的 agent 配方"（socialware 侧声明);materialize 后成为 session 的 spawned member。**不重复 members**——members 是"已在 session 里的成员声明",roles 是"socialware 定义要带进来的 agent"。（现 materialize 只 reduce `members/routing/prompt/legend/orchestrator`,`definition_editor.ex:250-268` —— 要新增 roles 分支。）

## 5. 分 PR

- **PR-1 `roles` 字段** + gate 骨架（roles/caps/adapters/URI-parse/routing-receiver/prompt_template_ref 可解析校验）。
- **PR-1b roles 物化消费者**（§4b）：materialize 合入 Definition.roles → RecipeRegistry 解析 → `SessionAgentMaterialize` → `GrantRecipeCaps`。
- **PR-2a `views` = view-ActionSet**（后端字段 + 唯一动作名 `<sw>_render` + required_caps）：Definition.views + render ActionSet 新增受 cap 门控的 `<sw>_render` 动作（决策1=a）。
- **PR-2b 统一 `authorize_view` 下沉 SessionView 契约**（§3.2.1，决策2）：SessionView 契约扩 caller 维度 + `SessionViewRegistry.applicable_views/render/external_render` 全经 `authorize_view` + anon mint 时授 view read-cap + arch gate 扫 Registry 路径断言无直读绕过。
- **PR-3 `mix ezagent.socialware.check` conformance gate**（10 条，挂 CI）。
- **PR-4 package.yaml → Definition loader**（与 gaga 一起；复用 `AgentManifest.load/1` 的 YamlElixir + `FsResolver.read_yaml/1` 既有 seam，**不新造 YAML 访问路径** —— codex #8）。
- **PR-5 skill 同步**（见 §9）：更新 ezagent-socialware + ezagent-developer skill 反映新模型。
- **（独立前端 PR）** ui_surface_provider → 读 Definition.views（依赖 #1118）。

依赖：PR-1 → PR-1b（需 roles 字段）// PR-2a → PR-2b（需 view 动作 + SessionView 契约改）→ PR-3（需字段+授权就位）→ PR-4（与 gaga）→ PR-5（收尾）。前端 PR 最后。

## 6. 不变式
- 引用不内联（role-as-data）：roles/views 都是 ref。
- openness 留 Definition.visibility_policy（per-socialware，不回退 P4）。
- SessionTemplate 不动。
- **view 可见性单一授权点**：所有渲染入口过 `authorize_view`(view-cap)，**无直读 slice 绕过**；退役 ui_surface_provider push+condition + 旧 membership-only 整体可见模型。
- anon = 真实用户 + mint 时授 cap；不新建独立匿名可见路径。
- **两层门正交**：openness（进不进 session）粗粒度 + view-cap（看哪些 view）细粒度，对所有 view 统一。

## 7. codex 评审对账（两轮 blocker → 本 SPEC 处置）
**第一轮:**
- **#1 views-as-behavior 匿名** → §3.2 解（anon 真实用户 + mint view read-cap）。
- **#2 openness 在 template** → 假阳性（codex 跑错分支；main 已 Definition-backed，§2）。
- **#3 config://** → 移到 T1（去 URI 化 + gate 兜底）。
- **#4/#5/#6 改名迁移** → 移到 T1（stale-cap/snapshot 迁移 + grep gate）。
- **#7 gate 不全** → §4 补 members/routing/prompt/legend/URI-parse。
- **#8 package loader** → §5 PR-4 复用既有 YAML seam。

**第二轮（钉 main,真发现）:**
- **v2#1 多 view 撞 `{kind,action}`** → §3.2 决策1=(a) 唯一动作名 `<sw>_render`。
- **v2#2 authorize_view 覆盖面（真契约是 SessionView）** → §3.2.1 决策2=下沉 SessionView 契约 + Registry。
- **v2#3 roles 无物化消费者** → §4b roles 物化（RecipeRegistry→SessionAgentMaterialize→GrantRecipeCaps）。
- **v2#4 gate 漏 prompt_template_ref** → §4 gate 第 10 条。

## 8. DoD
- [ ] Definition 有 roles + views 字段（ref 式）；`body/1` JSON 序列化 + `new/1` 校验覆盖。
- [ ] **roles 物化跑通**：Definition.roles → per-session role-agent（`SessionAgentMaterialize`）+ requested_caps 经 `GrantRecipeCaps` 授予（测试证明）。
- [ ] **view 动作唯一**（`<sw>_render`）；多 view 注册无 `{kind,action}` 冲突。
- [ ] anon 打开 public socialware 能看被授权的 view、看不到未授权 view（cap-gated，测试证明）。
- [ ] **`authorize_view` 下沉 SessionView 契约**：所有 SessionView/external renderer/adapter 经它；arch gate 扫 Registry 路径断言无直读 slice 绕过。
- [ ] `mix ezagent.socialware.check` 10 条全绿 + 挂 CI；坏 definition（不存在的 recipe/view/prompt_ref）→ 红。
- [ ] kanban + 官网当 2 个 conformance example 过同一 gate。
- [ ] skill 已同步（§9）。
- [ ] 全套 arch + precommit 绿。

## 9. Skill 同步（Allen 要求：改动同步 skill）

改动落地后必须更新的 skill（否则未来 dev/agent 照旧模型开发）：

- **`ezagent-socialware/SKILL.md` + `references/local-e2e-recipe.md`**：socialware Definition 现含 `roles` + `views`；**view = 渲染 ActionSet，可见性走 `authorize_view`(view-cap)**，不再是 membership-only 整体可见；openness(visibility_policy) 与 view-cap 两层门；config subject 不再是 `config://`（T1）。
- **`ezagent-developer/references/architecture-invariants.md`**：新增不变式"view 渲染必过 `authorize_view`、无直读 slice 绕过"；"config subject 非 URI"；"未知 scheme 默认被 gate 拦"。
- **`ezagent-developer/references/capbac.md`**：view 可见性 = view-ActionSet 的 read cap（cap 门控从写动作扩到 view 读）。
- **`ezagent-developer/SKILL.md` + 全 references**：`Ezagent.Behavior` → `Ezagent.ActionSet` 全文更新（T1 改名，skill 里的示例/引用同步）。
- **验证**：skill 更新后,grep skill 目录无残留 `Ezagent.Behavior` / `config://` / "membership-only 可见" 旧表述。

（PR-5 执行；T1 的 ActionSet 改名部分同步 skill 里的 `Ezagent.Behavior` 引用——见 T1 §DoD 追加项。）
