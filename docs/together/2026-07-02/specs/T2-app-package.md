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
- **该 ActionSet 声明一个 view 读动作**（`:render` / `:read`）+ 其 `required_caps` —— 现有 `Surface` 只有 put_version/approve 等**写**动作、读是普通函数（`surface.ex:114-128`），**必须新增一个受 cap 门控的 view 读动作**（codex T2 #2）。
- **匿名可见如何成立**（已核 `anon_user.ex`）：匿名访客 **mint 一个真实 anon User，born with cap**（`create_read_only` 写进 caps_json，`anon_user.ex:119-127`）。→ 要让匿名看某 view，**mint 时多授该 view 的读 cap**。机制可行（codex 确认）。

#### 3.2.1 统一 view 授权点（Allen 定 —— 消灭直读绕过，不是特例）
**问题（codex T2 #1）**：当前 view 渲染**全部直读 `:surface` slice、绕过 cap**——内部 `PageView`（`page_view.ex:24-43,66-69` 直读）+ 外部 `ExternalFeed`（`external_feed.ex:46-55` 只按 `Membership.authorize` 成员级授权，`:392-407`）。**光 mint view-cap 是惰性的**：没有任何入口检查它。

**决定（不是给 ExternalFeed 加特例，而是统一）**：
- 建一个**共享 `authorize_view(view, caller)`** —— 检查 caller 是否持有该 view 的 read cap（复用 CapBAC）。
- **每个 view 渲染入口**（内部 `PageView` / 外部 `ExternalFeed` / World tab）**在返回内容前统一调它**，一视同仁,**没有特例**。
- **保留投影旁路读**（不把渲染改成 full dispatch —— 尊重 `ExternalFeed` moduledoc "auth/projection 正交" 的性能设计）：只把**授权维度**从"成员 / 直读无检查"**升级**成"持有该 view 的 cap"。授权点统一、projection 不变。
- **两层门**：openness（Definition.visibility_policy，决定是否 mint anon = 能不能进 session）是粗粒度；view-cap（`authorize_view`，进来后看得到哪些 view）是细粒度,**对所有 view 统一强制**。
- **淘汰旧模型**：旧的"一个 session 整体可见/不可见"（membership-only 授权）**被 per-view 授权取代**（Allen：hello 对外 / kanban 对内，同 session diverse）。

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

## 5. 分 PR

- **PR-1 `roles` 字段** + gate 骨架（roles/caps/adapters/URI-parse/routing-receiver 可解析校验）。
- **PR-2a `views` = view-ActionSet**（后端字段 + view 读动作 + required_caps）：Definition.views + `Surface`/render ActionSet 新增受 cap 门控的 `:render`/`:read` 动作。
- **PR-2b 统一 `authorize_view`**（§3.2.1）：共享授权函数 + PageView/ExternalFeed/World-tab **所有** view 渲染入口在返回前调它 + anon mint 时授 view read-cap + arch gate 断言无直读绕过。
- **PR-3 `mix ezagent.socialware.check` conformance gate**（9 条，挂 CI）。
- **PR-4 package.yaml → Definition loader**（与 gaga 一起；复用 `AgentManifest.load/1` 的 YamlElixir + `FsResolver.read_yaml/1` 既有 seam，**不新造 YAML 访问路径** —— codex #8）。
- **PR-5 skill 同步**（见 §9）：更新 ezagent-socialware + ezagent-developer skill 反映新模型。
- **（独立前端 PR）** ui_surface_provider → 读 Definition.views（依赖 #1118）。

依赖：PR-1 // PR-2a → PR-2b（需 view 动作就位）→ PR-3（需字段+授权就位）→ PR-4（与 gaga）→ PR-5（收尾，全部落地后）。前端 PR 最后。

## 6. 不变式
- 引用不内联（role-as-data）：roles/views 都是 ref。
- openness 留 Definition.visibility_policy（per-socialware，不回退 P4）。
- SessionTemplate 不动。
- **view 可见性单一授权点**：所有渲染入口过 `authorize_view`(view-cap)，**无直读 slice 绕过**；退役 ui_surface_provider push+condition + 旧 membership-only 整体可见模型。
- anon = 真实用户 + mint 时授 cap；不新建独立匿名可见路径。
- **两层门正交**：openness（进不进 session）粗粒度 + view-cap（看哪些 view）细粒度，对所有 view 统一。

## 7. codex 评审对账（前轮 blocker → 本 SPEC 处置）
- **#1 views-as-behavior 匿名** → §3.2 解（anon 真实用户 + mint view read-cap）。
- **#2 openness 在 template** → 假阳性（codex 跑错分支；main 已 Definition-backed，§2）。
- **#3 config://** → 移到 T1（去 URI 化 + gate 兜底）。
- **#4/#5/#6 改名迁移** → 移到 T1（stale-cap/snapshot 迁移 + grep gate）。
- **#7 gate 不全** → §4 补 members/routing/prompt/legend/URI-parse。
- **#8 package loader** → §5 PR-4 复用既有 YAML seam。

## 8. DoD
- [ ] Definition 有 roles + views 字段（ref 式）；`body/1` JSON 序列化 + `new/1` 校验覆盖。
- [ ] anon 打开 public socialware 能看被授权的 view、看不到未授权 view（cap-gated，测试证明）。
- [ ] **每个 view 渲染入口过 `authorize_view`；arch gate 断言无直读 slice 绕过。**
- [ ] `mix ezagent.socialware.check` 9 条全绿 + 挂 CI；坏 definition（不存在的 recipe/view）→ 红。
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
