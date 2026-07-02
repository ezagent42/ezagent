# Handoff: app package = 变胖的 SessionTemplate（对齐 + retarget）

> **Date:** 2026-07-02 · **From:** Allen (lead) via Claude · **To:** gaga (T7 #1120) + jjkysy (#1125 四篇)
> **Target 分支:** `integration/app-package`（已建，off main `aa1a02d9`）
> **背景:** 昨天 socialware/app 收口讨论 → 今天 Allen + Claude 定调，需你俩对齐 + 切 PR target。

---

## 0. 一句话结论（讨论已定，别 re-litigate）

**不新建 "app package" 顶层概念。app = 一个"变胖的 SessionTemplate"** —— 给 SessionTemplate 加上 `agents / public_face / uses / views` 字段（引用式，不内联），让它从"瘪的 default"升级成"完整产品定义"，最后机械改名为 `App`。

这翻转了两份文档的共同前提（你俩都假设 app package 是 SessionTemplate **之上**的新概念）——但**本质无分歧**：「SessionTemplate 变胖后改名 app」≡「建 app 后取消 SessionTemplate（因为没必要了）」，同一个终点。选前者是因为工程上**先扩后改名**更稳。

---

## 1. 为什么是"变胖 SessionTemplate"而不是"新概念"

代码事实（核过 main `aa1a02d9`）：
- SessionTemplate 现 schema = `prompt_templates + legends + routing + installs + members`。
- world UI `session_template_names(_), do: ["default"]` —— **硬编码只有 default**。
- 现存非 default 模板（hello / advisor operator / e2e）**全是被 socialware/recipe/routing 内容撑出来的**。

→ **剥掉 socialware/recipe/routing，SessionTemplate 永远只有 default**（Allen 的 YAGNI 观察）。让一个 template 区别于另一个的，**恰恰就是那些内容**——它现在瘪，是因为变化维度被抽到独立 registry（`config://recipe`、`config://socialware`）掏空了。

结论：SessionTemplate 的"变化维度"本就该是 app 的定义。app 只是它面向产品的叫法，底层就是 SessionTemplate。

---

## 2. 5 个 open questions 的定论

| Q | 问题 | 定论 |
|---|------|------|
| **Q1** | 可寻址性：新 `config://app/` scheme 还是复用？ | **复用 `template://<ws>/session/<名>`**，不新开 scheme（app 就是 SessionTemplate，一个寻址够） |
| **Q2** | 与 SessionTemplate 关系：超集还是引用？ | **引用**（app 引用分开寻址的 ConfigObject / recipe / definition，不内联） |
| **Q3** | 嵌套真嵌套还是扁平？ | **扁平**（install 多个 definition 到一个 session；真嵌套 YAGNI，defer） |
| **Q4** | 与 #1118 views 关系？ | **对齐** —— app 的 `views` 就是 #1118 dual-surface（json-render vs LiveView）的声明入口 |
| **Q5** | 谁合并成最终 spec？ | **Allen 归口**（gaga T7 术语/接口 + jjkysy 产品流程/形态 合成一份） |

---

## 3. 两阶段路线

### 阶段 1 · 扩字段（先做，本质工作）
给 SessionTemplate 加（**引用式，符合 role-as-data**）：
- `agents: [recipe ref]` —— 注意 `agent_slots` 在 PR-8 已移除（schema 注释 line 181/198），要以 **ref** 形式加回（不是旧的内联 slots）。
- `public_face: CapBAC policy` —— 匿名/公开面能做什么。
- `uses: [plugin]` —— 引用哪些能力 plugin。
- `views: {embedded, public}` —— 对齐 #1118。
- （`installs / routing / prompt_templates` 已有，不动。）

产出：SPEC（Allen 归口）+ 分 PR（每个字段可独立）。**这是 app 概念的全部实质。**

### 阶段 2 · 机械改名（后做，纯改壳）
- 代码符号 `SessionTemplate` module → `App`（32 文件 / 165 处，纯机械）。
- **URI 段 `template://session/` 保留不动**（零数据迁移）—— 它是持久化的（kind_snapshots.uri + ConfigStore key，含 reflow 过来的生产数据），改它会失配所有存量快照。且 `template://session/` 语义仍对：app 的运行实例确实是 session。
- GLOSSARY 记 decision："app = 加载完整声明的 SessionTemplate；SessionTemplate 名称退役为历史符号。"

---

## 4. 给 gaga + jjkysy 的行动项

### 切 target 分支
- **gaga #1120**：把 base 从 `main` 改到 **`integration/app-package`**。你的三载体模型（definition data / runtime substrate / installer flow）**仍成立**——只是"上位单元"从"新 app package"改成"变胖的 SessionTemplate"。数据外化那刀（AutoService package.yaml/kb/persona）不受影响，照常。
- **jjkysy**：你的 #1125 四篇文档结论要**改一处前提**——"app package 是新顶层概念" → "app = 变胖+改名的 SessionTemplate"。#1116/#1115 已 merge 进 main（基座第一批），不受影响。你后续的 kanban 迁移 PR 切 base 到 `integration/app-package`。

### 对齐点（合 spec 前先同意）
1. 三载体模型（gaga）与"变胖 SessionTemplate"（本 handoff）**不冲突**——载体是"内容怎么分层存"，变胖 SessionTemplate 是"谁引用它们"。两者组合：SessionTemplate（变胖后=app）的 `agents/uses/views/public_face` 字段就是"引用各载体的定义数据"。
2. gaga 的通用 `Socialware.Installer` = 阶段 1 之后的"装配契约"落地——app（变胖 SessionTemplate）声明装什么，Installer 负责可重复装 + 验证。
3. conformance CI gate（gaga T7C）= 校验一个"变胖 SessionTemplate"字段合规 + 能装能跑能发布。

### Q5 spec 合并
Allen 归口。gaga 出术语/接口章节，jjkysy 出产品流程/形态章节，Allen 合成一份最终 SPEC（进 GLOSSARY Decision Log）。

---

## 5. 边界 / 不变式（别破）

- **引用不内联**（role-as-data）：agents/uses 都是 ref，内容留在各自 ConfigObject。
- **URI 段不动**：`template://session/` 保留，改名只动代码符号。
- **本周官网上线不等这个**：官网用现状扁平拼上线（#1118 §5.2），这套抽象是上线后拿官网+kanban 当 conformance example 验证。
- **#1116/#1115 已 merge**，是基座第一批，本路线不回退它们。

---

## 6. 关联

| 项 | 状态 |
|---|---|
| `integration/app-package` 分支 | ✅ 已建（off main aa1a02d9）|
| #1116 materialize 基座 | ✅ merged main |
| #1115 recipe-ownership 决策 | ✅ merged main |
| #1125 app/socialware 四篇 | ✅ merged main（前提待改：见 §4）|
| #1120 gaga T7 | 待切 target + 对齐 |
| #1118 五面收敛 | views 对齐锚点 |
