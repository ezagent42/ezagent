# SPEC (½页 · 讨论稿): app = 变胖的 SessionTemplate

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** main `adf5fad5` · **分支:** `integration/app-package`
> **Status:** 讨论稿 —— 定字段形态 + 分 PR，供 Allen grill。**先定形态再动代码。**

## 1. 目标

不新建概念。把 SessionTemplate 从"瘪的会话形态（永远只有 default）"扩成"完整产品定义"，最后机械改名 `App`。app = 加载了完整声明的 SessionTemplate。

## 2. 现有 schema 已有什么（核过 main `adf5fad5`）

`session_template.ex:34-77` 的 content slice **已携带**：
- `members: [%{uri, role_name, source_template_uri, in_session_template}]` —— 已含"哪些 agent + 什么 role + 从哪个 template recreate"
- `installs: [String.t()]` —— 已含 socialware definition 组合（`config://<ws>/socialware/<名>` refs）
- `routing_rules: [%{matcher, receivers, rule_set, ...}]` —— 已含 agent 接力规则
- `prompt_templates` / `legends` / `orchestrator_template_uri` / 版本 / lineage

→ **"三载体"里的 definition-data 引用（recipe/socialware/routing）绝大部分已经在了。** 之前以为要加的 `agents`/`routing` 其实是现有 `members`/`routing_rules` 的复用。

## 3. 真正缺的字段（诚实的差距 —— 只有 3 个新增）

| 新字段 | 是什么 | 为什么现在没有 | 引用式? |
|--------|--------|----------------|---------|
| `uses: [plugin_id]` | 这个 app 引用哪些能力 plugin（校验 `installs`/`members` 的依赖存在） | 现在 plugin 依赖是隐式的（installs 里的 def 假设 plugin 在） | 是（plugin id 列表） |
| `public_face: %{anon_actions, visibility}` | 匿名/公开面能做什么（CapBAC policy） | 现在从 installed socialware def 的 `visibility_policy` 读（`:767` 注释），**散在 def 里、不在 template 顶层** | 引用/内联小策略 |
| `views: %{embedded, public}` | app 的两种视图声明（对齐 #1118 dual-surface） | 现在视图横跨 Surface/@json-render/ExternalFeed 三处、无统一声明 | 是（surface refs） |

**注意 `agents`**：不新增字段——复用现有 `members`（spawned-agent 成员已带 role_name + source_template_uri）。若要"recipe ref 直接声明"，是给 `members` 项加一个可选 `recipe_ref` 键，不是新顶层字段。→ **待讨论：members 够用，还是要独立 `agents:[recipe_ref]`？**

## 4. 分 PR（每个独立可测）

- **PR-1 `uses` 字段** + 校验（materialize 时 `uses` 引用的 plugin 不存在 → fail-closed）。invariant test: 声明不存在的 plugin → 拒绝。
- **PR-2 `public_face` 字段** —— 把 socialware def 的 visibility_policy 提升为 template 顶层可声明（向后兼容：无 `public_face` 时回落读 def）。invariant test: public_face 声明的 anon_action 未在 CapBAC 注册 → 拒绝。
- **PR-3 `views` 字段** —— 声明 embedded/public，对齐 #1118（依赖 ruihua #1118 定稿，可最后做）。
- **PR-4 机械改名** `SessionTemplate` → `App`（32 文件/165 处），**URI 段 `template://session/` 保留**（零迁移）。GLOSSARY 记 decision。

依赖：PR-1/2 独立并行 → PR-3 等 #1118 → PR-4 最后（改名在字段稳定后）。

## 5. 不变式（别破）

- **引用不内联**（role-as-data）：`uses`/`views` 是 ref。
- **URI 段不动**：改名只动代码符号，`template://session/` 持久化段保留（含 reflow 生产数据）。
- **向后兼容**：3 个新字段都可选；无声明时回落现有行为（default template 不受影响）。

## 6. 开放讨论点（给 Allen）

1. **`agents`**：复用 `members`（+ 可选 `recipe_ref`），还是独立 `agents:[recipe_ref]` 字段？（我倾向复用 members——已有，避免重复。）
2. **`public_face`**：提升到 template 顶层，还是保持读 socialware def？（提升=app 自洽声明；保持=少改动。我倾向提升——app 应自带公开面声明。）
3. **改名时机**：PR-4 现在做，还是等阶段1 字段全稳（PR-1/2/3 合完）再做？（我倾向最后——改名是纯机械收尾。）
4. **`views` 是否 defer**：#1118 未定稿，PR-3 是否推到官网上线后？
