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

### 3.2 `views: [view_actionset]` —— views-as-behavior（核心设计，Allen 定 + codex 验证）
- **view = 渲染类 ActionSet**（T1 改名后；沿用现有 `ActionSet.Surface`/`ActionSet.HelloBuilder` 那一类）。声明一个 view → 它进 `shape` 成为一个 render ActionSet。
- **该 ActionSet 就是权限 handler**：它的 `required_caps` 决定谁能看/操作这个 view。
- **匿名可见如何成立**（codex blocker #1 的解，已核 `anon_user.ex`）：匿名访客不是独立路径——它 **mint 一个真实 anon User，born with 一个真实 cap**（现在是 `session.join`，`anon_user.ex:142-151`），然后**以自己身份走正常 dispatch**。→ 要让匿名看某 view，**mint 时多授一个该 view-ActionSet 的 read cap**（同一 create-time 机制）。**view-behavior 的 cap 天然 gate 匿名**，无需独立可见性机制。
- **openness（能不能进来）与 view-cap（进来看哪个 view）分两层**：openness 在 Definition.visibility_policy（§2，是否 mint anon），view-cap 在 view-ActionSet.required_caps（mint 时授哪些 view）。不合并。
- **退役隐式推导**：现 `ui_surface_provider`（World 前端 plugin-push + per-session condition）→ 可见性权威收归 **Definition.views + CapBAC**。**前端 tab/nav 改读 Definition.views 拆成独立前端 PR**（依赖 #1118 定稿）。

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

## 5. 分 PR

- **PR-1 `roles` 字段** + gate 骨架（roles/caps/adapters/URI-parse/routing-receiver 可解析校验）。
- **PR-2 `views` = view-ActionSet**（后端）：Definition.views 字段 + anon mint 时授 view read-cap + gate view 校验。
- **PR-3 `mix ezagent.socialware.check` conformance gate**（8 条，挂 CI）。
- **PR-4 package.yaml → Definition loader**（与 gaga 一起；复用 `AgentManifest.load/1` 的 YamlElixir + `FsResolver.read_yaml/1` 既有 seam，**不新造 YAML 访问路径** —— codex #8）。
- **（独立前端 PR）** ui_surface_provider → 读 Definition.views（依赖 #1118）。

依赖：PR-1/PR-2 并行 → PR-3（需字段就位）→ PR-4（与 gaga）。前端 PR 最后。

## 6. 不变式
- 引用不内联（role-as-data）：roles/views 都是 ref。
- openness 留 Definition.visibility_policy（per-socialware，不回退 P4）。
- SessionTemplate 不动。
- views 可见性单一权威：Definition.views + CapBAC，退役 ui_surface_provider push+condition。
- anon = 真实用户 + mint 时授 cap；不新建独立匿名可见路径。

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
- [ ] `mix ezagent.socialware.check` 8 条全绿 + 挂 CI；给一个坏 definition（不存在的 recipe/view）→ 红。
- [ ] kanban + 官网当 2 个 conformance example 过同一 gate。
- [ ] 全套 arch + precommit 绿。
