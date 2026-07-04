# SPEC (v3 · 讨论稿): socialware app 收口 — fatten Definition + Behavior 改名

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** main `adf5fad5` · **分支:** `integration/app-package`
> **Status:** 讨论稿 v3 —— 经多轮 Allen grill + 代码调研收敛。**先定形态再动代码。**
> **窗口:** 下周上生产 → 这是**最后能改基础概念命名**的时间（cap 身份一旦铸进生产数据，迁移代价高）。

## 1. 结论（已定）

**不新建 "app" 概念。** 三层模型（emacs 类比）：

| 层 | 是什么 | emacs 类比 | 寻址 | 用户可见 |
|---|---|---|---|---|
| **socialware Definition**（发布单元，**变胖**）| 一个可发布的对外交付单元 | 一个 major/minor mode | `config://<ws>/socialware/<名>` | 否 |
| **SessionTemplate**（**不动**）| 这个 session 装哪些 socialware | "这个文件加载哪些 mode" | `template://session/<ws>/<名>` | 否（建会话选的类型）|
| **session** | 运行实例 | 打开的 buffer | `session://<ws>/<名>` | **是**（具名对话）|

- **发布单元 = socialware Definition**（不是 SessionTemplate、不是 app）。
- **fatten 的是 Definition**，SessionTemplate 保持原名/原状（它已能 `installs` 多个 def）。
- **用户面**：左栏永远是具名对话（AutoService/官网/kanban），不引入 "app" 字眼。

## 2. Definition 现状（核过 main）

`definition.ex:11-20` 已有 10 字段：`name · bases · shape · members · routing_rules · prompt_templates · legends · orchestrator_template_uri · adapters · visibility_policy`。`behaviors/0`（`:67`）= `[Session] ++ shape ++ bases`（加载的 mode 集）。**开放性已在 `visibility_policy`（per-socialware，不提到 template —— P4 决定，Allen 确认：hello 对外 / kanban 对内 diverse）。**

## 3. 要加的 2 个字段 + views-as-behavior 模型

**`roles: [recipe_ref]`** —— 这个 socialware 带哪些 agent 配方（引用 RecipeRegistry；agent 配置在 agent 内部，Definition 只引用）。含 `requested_caps`。**现在 package.yaml 有、Definition 和 SessionTemplate 都无家 —— 真正的缺口。**

**`views: [view_behavior]`** —— **具体视图 = 渲染类 Behavior**（声明式）。核心设计（Allen 定）：
- view 声明成 Behavior（沿用现有 `Behavior.Surface`/`Behavior.HelloBuilder` 那一类）。声明一个 view → 它进 `shape` 成为一个 render behavior。
- **该 behavior 就是权限 handler**：它的 `required_caps` 决定谁能看/操作这个 view。对外 view（hello）的 cap 对匿名开放；对内 view（kanban）的 cap 只给内部成员。
- **不走隐式推导**（弃用现 `ui_surface_provider` 的 plugin-push + condition）；**可见性权威从 plugin 收归 Definition.views + CapBAC**。

**为什么这补上了 gate 的洞**：view 塌缩成"一个 behavior"，其校验 = "behavior 可解析 + 其 cap 已注册" —— 与其余字段同一种断言。views 不再是特例。

## 4. Gate 定义（完整）

`mix ezagent.socialware.check <definition>` —— 一条规则：**所有声明的引用都能解析**：
1. `bases`/`shape` behavior 模块存在（编译期）
2. `views` 的每个 view-behavior 存在 + 其 `required_caps` 已在 CapabilityRegistry 注册
3. `roles` recipe 经 RecipeRegistry 按名解析成功（#1116 fail-closed）
4. `roles.requested_caps` 每个 cap 已注册
5. `adapters` 在 AdapterRegistry 注册
6. `orchestrator_template_uri` 可解析
7. 可安装性：`Installation.resolve_definitions` 能物化（现有 `{:unknown_socialware_install}` 失败模式）

**gate 完整性 = 方案完整性的证明**（Allen 方法论）：v2 时 views 卡住 → 暴露 views 未设计；v3 views-as-behavior 后，7 条全塌缩成"引用可解析"，gate 清晰 = 设计收口。

## 5. Behavior → ActionSet 改名（pre-prod 窗口，本 SPEC 纳入）

**为什么现在**：Behavior 名不副实——它是"某领域的一组 action handler"（moduledoc `behavior.ex:1` 自述），不是单个行为；且撞 Elixir 内建 `@behaviour`。**下周上生产后 cap 身份进生产数据，迁移代价高 → 现在是最后窗口。**

**改名面**：`Ezagent.Behavior` 在 lib 里 212 文件 / 777 处。

**关键坑（非纯机械）**：
1. **cap 身份嵌 module**：cap = `{scope, module, action}`（`Capability.cap/3`）。改 behavior 模块名 → **所有 cap 身份变**。pre-prod 无存量生产 cap → **现在改零迁移成本**；上线后改要 cap 迁移。**这就是"最后窗口"的技术含义。**
2. **`:kind_base` 存 behavior 模块 atom**（快照/DB）。pre-prod 的 dev 数据可重建 → 现在改无痛。
3. 撞名 `@behaviour`：改名**消除**歧义（好事）。

**做法**：全局 `Ezagent.Behavior.X` → `Ezagent.ActionSet.X`（机械）+ 更新 `required_caps` 三元组 + `:kind_base` 重建 + arch gate 的 `"Behavior" => [{:required_caps, 0}]`（`arch.scan.ex:184`）等元数据同步。**在 pre-prod 一次性做，无迁移。**

## 6. 分 PR（依赖序）

- **PR-0 Behavior→ActionSet 改名**（pre-prod 窗口，**最先做**，纯机械+元数据，无功能变更）。**先做因为它动 777 处，越晚越冲突。**
- **PR-1 `roles` 字段** + gate 骨架（roles/caps/adapters 可解析校验）。
- **PR-2 `views` = view-behavior** + Definition.views 字段（**后端**：view-behavior + cap；ui_surface_provider→Definition.views 的**前端可见性迁移拆独立 PR**，依赖 #1118）。
- **PR-3 `mix ezagent.socialware.check` conformance gate**（7 条引用可解析，挂 CI）。
- **PR-4 package.yaml → Definition loader**（YAML decode → 校验 → 写 Definition；现无 loader，从零写）。

依赖：**PR-0 先**（改名，避免后续 PR 全冲突）→ PR-1/PR-2 并行 → PR-3 gate（需 1/2 字段就位）→ PR-4（package loader，可与 3 并行）。

## 7. 不变式

- **引用不内联**（role-as-data）：roles/views 都是 ref。
- **openness 留 Definition.visibility_policy**（per-socialware diverse，不提 template —— P4 决定不回退）。
- **SessionTemplate 不动**（保留名 + URI 段）。
- **改名零迁移**：必须在 pre-prod 窗口完成（PR-0），上线前 merge。
- **views 可见性单一权威**：Definition.views + CapBAC，退役 ui_surface_provider push+condition。

## 8. 决策（Allen 2026-07-02 定）

1. **改名目标词 = `ActionSet`**（`Ezagent.Behavior.X` → `Ezagent.ActionSet.X`）。准 + 短（777 处手敲）。
2. **views 可见性迁移 = 独立 PR 实施**：PR-2 只落后端 `Definition.views` + view-behavior + cap；`ui_surface_provider`（World 前端 tab/nav）改读 Definition.views 拆成独立前端 PR（依赖 #1118 定稿）。
3. **package.yaml loader（PR-4）= 我们和 gaga 一起做完**（他的文件格式 + 我们的 Definition/校验）。

## 9. 评审门

SPEC 定稿后 → **先 codex 对抗性评审**（带 ezagent skill + 架构上下文）→ 通过再实施 PR-0。（feedback_spec_codex_adversarial_review）
