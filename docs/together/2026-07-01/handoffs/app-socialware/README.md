# README — app / socialware 收口系列（4 篇导航）

> **Date:** 2026-07-01 · **From:** jjkysy (FP5) · **To:** Allen (lead) + 独立 dev（human + cc/codex）
> **Base:** 干净 upstream/main @ 62820c38（含 A#1117 World UI-surface substrate，已 merge）
> **Status:** research/design handoff（clarify-first）—— 本系列只产 **spec 输入 + build slices**，**不改代码**，供 Allen 拍方向。

---

## 0. 这一系列在收口什么

收口的**不是 socialware**，是 **ezagent「一个 app」整套系统开发**——即定义"一个 app package 是什么"及其**开发 / 安装 / 运行 / 发布 / 部署**生命周期。**socialware 只是一个 app 的「公开对外交付面」（public delivery facet），不是上位 app 单元。**

背景问题一句话：ezagent 口头有一堆"app"（kanban、hello、autoservice、官网、world…），但**代码里没有一个统一叫 "app" / "AppPackage" 的东西**（`grep AppPackage apps/` = 空）。它们分别是 plugin、seed 脚本、或 `SessionTemplate.installs` + socialware definition 拼出来的。本系列先把"平台怎么被用 → 现有概念代码实情 → 应有概念关系 → 实现路径"讲透，作为 gaga T7（socialware/app 标准 #1120）的产品侧输入 spec。

---

## 0.5 先建立清晰分层：一张公司比喻表（读 4 篇前先看这个）

这些概念**看起来都像**（SessionTemplate / plugin / socialware / recipe / agent contract 好像都是"某种 app 的声明"），是因为**"部门（app package）"这个容器概念是空的**。先用公司比喻把它们分开：

| 概念 | 公司比喻 | 管多大范围 | 形态 |
|---|---|---|---|
| **plugin** | 工具（工具箱里的钻、锯） | 一种能力 | 代码（OTP app）|
| **recipe** | 一个员工的**岗位说明书** | 一个 agent | 配置数据 |
| **agent contract（AgentManifest）** | 这个员工**领了哪些工具** | 一个 agent | 清单数据 |
| **SessionTemplate** | 一个**会议室的布置模板** | 一个会话 | 模板数据 |
| **app package（待建 ❌）** | 一个**部门/项目**（用哪些工具+配哪些员工+在哪个会议室+对外开不开窗口+员工怎么接力） | 一个产品 | **没有** |
| **socialware** | 部门**对外接待的窗口** | app 的一个侧面 | app 的一个 facet |

**为什么它们看起来像**：你想指"一个完整的 app（部门）"时，代码里没有这个词，只能抓最接近的替身——有时抓 SessionTemplate（会议室模板）、有时抓 socialware（对外窗口）、有时抓 plugin（hello/kanban），所以它们都"像 app"。**它们各自只是"一个部门"的一个零件，被轮流拿来顶替整个部门。** 建出"部门"容器后，各零件各归其位、不再互相像。

**更深一层**：缺容器只是表面——这套"声明"模式在中间层被复制了 5 次、落地不一致、装配又无统一契约，这三个结构性根因才是"看起来都像"的真正原因（复制 5 次的事实表见文档 2 §④问题4，三根因分析见文档 3 §5.3）。

---

## 1. 4 篇导航（建议顺序 1 → 2 → 3 → 4）

这 4 篇是**并行写的、各自读代码**，然后统一校正到本 README §2 的验证基准。逐篇一句话 + 先读哪篇：

| 篇 | 文件 | 一句话 | 什么时候读 |
|---|---|---|---|
| **1** | `1-platform-usage-flow.md` | **平台使用全流程**：一个用户怎么用 ezagent 开发/安装/发布/使用一个 app（7 步 × 两例子：kanban 扁平 / 官网嵌套），每步"谁参与·想干嘛·现状有没有·举例"。 | **先读这篇**建立产品直觉——它是下游 spec 的产品输入。 |
| **2** | `2-current-concepts-and-problems.md` | **现有概念的代码实情**：plugin / socialware / `SessionTemplate.installs` 在代码里到底是什么、边界在哪、乱在哪，全落到 `file:line`。 | 读完 1 再读——把"流程里的现状"落到确切代码事实。 |
| **3** | `3-target-relationships-and-gaps.md` | **应有的概念关系 + 差距**：从原语（Kind/Behavior/URI/dispatch/CapBAC）到中间概念层到产品概念的三层地图，缺口只在最顶层 app package。 | 读完 2 再读——它夹在"现状"和"实现"中间，画全三层。 |
| **4** | `4-implementation-path.md` | **实现路径**：从现状建到 app package 的 7 步（每步碰哪些文件 + core/基础设施/改造/都不属于分类）+ 6 处冗余结构收口清单 + DoD + open questions。 | 最后读——落到"怎么分步砌上去"。 |

**读法**：1 讲"要什么"，2 讲"现在有什么"，3 讲"该长什么样、差多少"，4 讲"怎么建"。四篇合起来 = 一份从产品到实现的完整前置。

---

## 2. §验证基准（读这 4 篇前必看）

**这 4 篇全部读干净 upstream/main `62820c38`（A#1117 已 merge 进 main）**，所有 file:line 对该 commit 核实。62820c38 相对旧基线只多了 A#1117（改 `plugin.ex`）+ #1121（website），故绝大多数引用行号不变；`plugin.ex` 的 callback 声明行号对 `62820c38` 重核过。

几条纯 canonical 代码事实（4 篇已校正到位）：

- kanban 动作数 = **24**；board slice key = **`:tree`**（board 挂通用 `Entity.Agent` 的 `:tree` slice，`shared.ex:142/149`），**不是** `:kanban`。
- **ExternalFeed 是独立模块** `external_feed.ex` / `external_feed_adapter.ex`（不是 `public_view.ex` 里的某行）。
- `public_view.ex` moduledoc 引言在 **line 3**；`installs` 在 `session_template.ex:53`；kanban `def roles` 在 `application.ex:71`（recipe def 在 `:95`）。
- **world 是 plugin**（声明 behaviors）；**web / cli 不是 plugin**（无 `use Ezagent.Plugin`）。
- pm/dev recipe 的归属见 **C#1115** 决策（在途）——属 app 配方治理、非本系列基座主题，本系列不展开。

---

## 3. §Locked decisions（讨论已定，别 re-litigate）

| # | Decision | 值 |
|---|----------|-----|
| 1 | `socialware` = 一个 app 的**公开/对外交付面（delivery facet）**，不是上位 app 单元 | 匿名/客户/成员的 gated read projection；P5 后 `domain_socialware` 不拥有 session Kind |
| 2 | 上位"可安装 app 单元"**代码里无统一名** | 现 = `SessionTemplate.installs` + socialware definition 散拼（`grep AppPackage` = 空） |
| 3 | 上位单元拟命名 **app package**（gaga T7 出 terminology） | `socialware` 降为其一个 facet |
| 4 | recipe-ownership 见 **C#1115**（在途）：产品配方归产品 plugin、不进平台层 | 属 app 配方治理、**非本系列基座主题**，本系列不展开分层论述 |

---

## 4. §Definition of Done（本系列的闭集）

本系列是 clarify-first 研究前置，DoD = 产出下游 build 需要的东西（**不建代码**）：

- [ ] **app package manifest spec 一页**（`uses / agents / data / views / public_face / lifecycle` 字段 + 可寻址性）—— 证明：Allen + jjkysy grill 过，进 `GLOSSARY.md` Decision Log（Allen 落笔）。
- [ ] **build slices 拆分**（篇 4 的 7 步各拆成 PR-sized，标 core / 基础设施 / 改造 / 都不属于）。
- [ ] **两个 conformance 目标锁定**：**kanban（现有，扁平）** + **官网（嵌套，建在 #1118 §5.2）** 必须过同一 app package gate。
- [ ] **术语对齐 #1120（gaga T7）**：app package（上位）vs socialware facet（公开面），`Socialware.*` = legacy app-install substrate。

---

## 5. §给 Allen 的 open questions（拍板，别先建）

1. **可寻址性** —— app package 新开 `config://<ws>/app/<名>` scheme，还是复用 `socialware/<名>` 泛化？（动 core 契约 + `uri.ex`，必须 Allen 定；决定篇 4 步 2 走法。）
2. **与 SessionTemplate 的关系** —— app package **是** SessionTemplate 的超集，还是**引用** SessionTemplate？（现 `installs` 只装 definition；决定篇 4 步 1 manifest 与现有模型的边界。）
3. **嵌套是真嵌套还是扁平** —— 官网含 hello+kanban+github，是 app package 的 `uses:[其它 app package]`（真嵌套），还是 install 多个 definition 到一个 session（扁平组合）？（决定 composition 模型 + 步 7 compose。）
4. **与 #1118 views 的关系** —— app package 的 `views` 声明是否就是 #1118 "dual-surface（json-render vs LiveView）"的落地口？（决定步 4 收敛终点。）
5. **与 gaga T7 的分工** —— gaga 出 T7A terminology/接口，本系列出产品流程/形态，谁合并成最终 spec？（决定 spec 归口，避免两头各写。）

---

## 6. §关联 PR

| PR | 是什么 | 与本系列关系 |
|---|---|---|
| **A #1117** | World UI-surface **substrate**（拆分后） | **✅ 已 merge 进 main `62820c38`**；基座建设第一批之一 |
| **B #1116** | generic per-session role-agent materialization **substrate**（拆分后） | 在途；落基座材料化下游 |
| **C #1115** | recipe-ownership 决策（Locked decision #4） | 在途；产品配方归产品 plugin，属 app 配方治理 |
| **#1118** | Allen T1 五面收敛闸（Website / Hello / World UI / Agent Console / Socialware） | 例 B（官网）建在其 §5.2；open question 4 与其 views 对齐 |
| **#1120** | gaga socialware/app 标准提案（T7A-E） | 本系列 = 它的产品侧输入 spec；术语对齐它 |
| ~~#1110~~ | ~~拆分前总线~~ | 拆分前总线，已被拆分后 A/B/C 取代，**不引用** |

---

> **给 Allen 的一句话**：这 4 篇按 1→2→3→4 读——底层原语（dispatch / CapBAC / session 沙盒 / public_view / installs-as-list）已支撑"ezagent 当 app 平台"的大部分，缺的是**上层 app package 抽象 + 生命周期接口 + CI gate**。**验证基准见 §2：全部读干净 main `62820c38`（A#1117 已 merge）。** 另外两点：**缺 app package 是表面，根子是中间层声明概念增殖 + 映射不一致 + 装配无契约三个结构性问题**（详见文档 3 §5.3）；且**本周官网上线用现状拼、不等这个抽象**（详见文档 4 §0.5 时间线分层）。
