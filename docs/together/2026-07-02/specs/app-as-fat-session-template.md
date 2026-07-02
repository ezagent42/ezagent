# SPEC (v2 · 讨论稿): socialware package → 变胖的 SessionTemplate

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** main `adf5fad5` · **分支:** `integration/app-package`
> **Status:** 讨论稿 v2 —— 已经过 Allen grill 收敛。**先定形态再动代码。**

## 1. 三层模型（Allen 认同）

vscode 类比，三层各自寻址、各自命名：

| 层 | 是什么 | vscode 类比 | 寻址 | 用户可见? |
|---|---|---|---|---|
| **socialware package**（`package.yaml`）| **可发布/上传的打包物**（发布单元）| `.vsix` 扩展包 | 文件/上传物 | 否（发布/开发者层）|
| **SessionTemplate**（变胖后，**保留原名**）| package 装进 workspace 后的 DB 形态 | 已安装的扩展 | `template://session/<ws>/<名>` | 否（建会话时选的"类型"）|
| **session** | 运行实例 = **左栏 Session List item** | 打开的编辑器窗口 | `session://<ws>/<名>` | **是**（具名对话：AutoService/官网）|

**命名定论**：
- **用户面**：左栏永远是**具名对话**（AutoService / 官网 / kanban），IM 体感不破，**不引入 "app" 字眼**。
- **代码符号**：**保留 `SessionTemplate`**（当前一切基于 Template 概念）。不改名 App——app 会误导（发布单元是 socialware、打开的是 session，都不是 template）。
- **发布单元**：**socialware package**（`package.yaml` 正式化）。

## 2. package.yaml ↔ SessionTemplate 是同一 schema 的两种表示

gaga 已合的 AutoService `package.yaml`（#1120）是**文件格式**；SessionTemplate 是**安装后的 Kind 形态**。本轮 = 让 SessionTemplate 能表示 package.yaml 声明的一切。现有 package.yaml 结构：
```yaml
name / persona / kb          # 定义数据（引用）
session: {public_view, web_anon_access}   # ← 开放性
routing: [...]               # 接力规则
roles: {autoservice: {requested_caps}}    # recipe 引用（agent 配置在 agent 内部）
surface: {customer: /socialware/chat}     # ← 具体视图
```

## 3. SessionTemplate 现有 schema 已覆盖的（核过 main `adf5fad5`）

`session_template.ex:34-77` 已带：`members`（agent+role+recreate-from）· `installs`（socialware refs）· `routing_rules` · `prompt_templates` · `legends` · `orchestrator` · 版本 · lineage。

→ **members / routing 复用**（agent 配置回 agent 内部，template 只引用）。

## 4. 真正要加的字段（3 个）

| 字段 | 是什么 | 归属 | 现状 |
|--------|--------|------|------|
| **`openness: :public \| :internal`** | 能否加入非-workspace 用户（匿名/外部）| **session 配置** | 现散在 socialware def 的 `visibility_policy.web_anon_access`（`public_view.ex`）→ 提到 SessionTemplate 顶层 |
| **`views: [view_name]`** | **具体**视图列表（hello / kanban / conversation）——非抽象分类 | socialware 对外面 | 现散在 Surface / @json-render / ExternalFeed；package.yaml 里是 `surface:` |
| **`uses: [plugin_id]`** | 引用哪些能力 plugin（依赖校验）| package 顶层 | 现在 plugin 依赖是隐式的 |

**不加 `agents`**（复用 members）。**不叫 `public_face`**（用 `openness` 枚举）。**不分 `views:{embedded,public}`**（views 是具体视图列表；开放性由 `openness` 单独管，正交）。

## 5. 分 PR

- **PR-1 `openness` 枚举** —— `:public | :internal`，提升 socialware def 的 anon-access 到 SessionTemplate 顶层（向后兼容：无 openness 回落读 def）。invariant test: `:public` template 允许 anon join、`:internal` 拒绝。
- **PR-2 `uses` + 依赖校验** —— materialize 时 `uses` 引用的 plugin 不存在 → fail-closed。invariant test: 声明不存在 plugin → 拒绝。
- **PR-3 `views: [view_name]`** —— 具体视图列表（对齐 package.yaml `surface:` + #1118 具体视图）。可最后做（#1118 相关）。
- **PR-4 package.yaml schema + CI 校验** —— 把 package.yaml 从"松散 yaml"正式化成"有 schema 的 socialware package 定义"（gaga T7B/T7C）；installer 读它 → 写成 SessionTemplate。

依赖：PR-1/2 独立并行 → PR-3（#1118）→ PR-4（package↔template 双向，可与 PR-1/2 并行设计）。

## 6. 不变式

- **引用不内联**（role-as-data）：uses/views/members 都是 ref。
- **不改名**：SessionTemplate 保留；URI 段 `template://session/` 不动。
- **向后兼容**：3 字段全可选，无声明回落现有行为（default template 不受影响）。
- **openness 与 views 正交**：一个管开放性、一个管渲染，不互相分类。

## 7. 剩余开放点

1. `openness` 放 SessionTemplate 顶层 vs `session:` 子 map？（package.yaml 里在 `session:` 下；SessionTemplate 里建议顶层字段，materialize 时映射。）
2. PR-4 的 package.yaml schema 归谁：本轮我们做，还是 gaga T7 主线？（Allen：本轮=给 SessionTemplate 加字段，则 PR-1/2/3 我们做，PR-4 可协同 gaga。）
