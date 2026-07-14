# dogfooding 效率度量 — 口径 + before/after 基线（DRAFT v0）

> **状态:** 🚧 DRAFT — ruihua 内部草案，**未提 Allen**。我们自己敲定后再 promote 到 `docs/together/<date>/returns/` 提交 lead。
> **用途:** 官网 roadmap v1 的 **P1★ dogfooding 效率成果展示**的数据源口径。
> **原则:** 真实可度量 > 好看的数字；宁可少而硬，不要多而软。

---

## 0. ICP 与两层定位（grill 已共识）

**第一批用户 = 研发为主** → 信息按研发 ICP 排：**X 主、Y 辅，两层都露出，但永不相加、归因分明。**

| 层 | 讲什么 | 归因给谁 | 网站定位 | 近期形态 |
|---|---|---|---|---|
| **X — 用 ezagent 做研发的效率**（头条） | 团队把研发工作流跑在 **ezagent + dev-together 编排**上，节奏/覆盖/一次过率提升 | **ezagent 的研发体验**（不是裸 Claude） | **头条**——研发 ICP 最吃这一口 | 量化（有历史可做 A 基线）+ 硬案例 |
| **Y — 整个组织跑在 ezagent 上**（背书） | 不止研发：协作/socialware/kanban 等组织工作也路由进 ezagent 自举 | **ezagent 产品本身** | **背书/愿景**——唯一只有你们能讲 | 案例叙事(C) + 现在埋点，量化攒到 G1/G2 |

> **红线**：X 度量的是**经 ezagent/dev-together 编排的工作流**，措辞写"用 ezagent 做研发"，**不得**写成"用 Claude/AI 提效"——否则把模型功劳算给 ezagent，研发一眼看穿。

## 1. 一句话目标

证明「研发团队把工作跑在 ezagent 上更高效」（X，头条）+「连整个组织都自举在 ezagent 上」（Y，背书）——用**可复算、可证伪**的口径，不是拍脑袋的百分比。

## 2. 度量对象（unit of analysis）

- **主单位:** per **dev-day**（每人每工作日），归一化消除"人多→产出多"。
- **次单位:** per **task-class**（handoff 任务类）——同类任务周期对比。
- **时间窗:** 以**周**聚合（dev-together 本就按周/天组织）。
- **纳入边界:** 只计**经 ezagent/dev-together 编排**的工作（off-plan 裸操作不计入 X）。

## 3. 指标

### X 层（主，量化，研发向）
| 指标 | 定义 | 数据源（已有，低成本） | 方向 | 风险 |
|---|---|---|---|---|
| **交付吞吐** | 合并 PR 数 / dev-day | git log + `gh pr` | ↑ | 别用 LOC/commit（奖励灌水） |
| **周期时间** | handoff→return→merge 时长中位数 | returns 的 `returned_at`/`deadline` + PR 时间戳 | ↓ | 任务大小不均→中位数 + 分 task-class |
| **一次过率** | return 时 CI 首次即绿 + DoD 全 met 比例 | returns DoD reconciliation + CI | ↑ | 需 return 契约被遵守 |
| **能力扩张** | 单人可独立闭环的 task-class 数（全栈/部署覆盖） | team.md 开发效能档 | ↑ | 定性为主，做佐证 |

> 主推 **交付吞吐 + 周期时间 + 一次过率**三个硬指标。

### Y 层（辅，近期案例，量化埋点）
- **案例:** "把 X 类组织工作（如 dev-together 自举 / socialware / kanban）跑在 ezagent 上"的真实记录 + 工时/周期。
- **埋点（现在起）:** 经 ezagent 跑的任务数 / 周、覆盖的工作类型数。量化攒到 G1/G2 再对外给百分比。

## 4. before/after 基线方案

| 层 | 推荐基线 | 定义 | confounder / 缺点 |
|---|---|---|---|
| **X** | **A 历史窗 + C 硬案例** | "before" = 团队**重度跑 ezagent/dev-together 编排之前**的某干净周；"after" = 当前 W27+ | 混入招人/流程/模型升级——**必须显式列 confounder 并标"未剔除"**；弱基线时降级为 C |
| **Y** | **C 案例 + 埋点** | 头几个真实组织-工作-跑在-ezagent 的案例叙事 | "after"数据现在才始（G0 今天才建生产 workspace），量化先攒 |

**冻结规则:** baseline 周一旦选定就**冻结**，不许事后挑对自己有利的窗。**A/B（同 task-class 留对照组）若某条 track 能自然形成，顺手采。**

## 5. 诚实护栏（对外展示前必过）

1. **归因分明:** X 归 ezagent 研发体验、Y 归 ezagent 产品；**两层数字永不相加、永不并排成一个总百分比**。
2. **不冒认模型功劳:** X 措辞"用 ezagent 做研发"，禁"用 AI/Claude 提效"。
3. **不灌水:** ❌ LOC / commit 数 / 工时自报；✅ 每个对外数字标 **n + 时间窗 + 数据源**，可被第三人同口径复算。
4. **弱基线→案例:** 没干净 before/after 时降级为案例叙事，不硬凑百分比。"宁可说'我们 3 天搭好官网框架'，不说'效率+300%'。"
5. **A 的百分比必附 confounder 列表**（"未剔除 X/Y/Z 影响"）。

## 6. 落地成本

目标**零新负担**:X 主指标从 dev-together 现有 artifacts（plans/returns/stats）+ git/gh 脚本化算出，不要求 dev 额外填表。Y 埋点 = 在 dev-together `review` 周节奏里顺手记"本周经 ezagent 跑了哪些组织工作"。仅需 lead 确认口径 + 冻结 baseline 周。

## 7. 待 Allen 拍板的开放问题（promote 时一起问）

1. X 的 baseline "before" 选哪一周？（需要 ezagent/dev-together 编排重度使用前的干净窗）
2. X 主指标三选（吞吐/周期/一次过率）是否认可？加/减？
3. "纳入边界 = 只计经 ezagent/dev-together 编排的工作"——这个口径 lead 认不认？
4. 是否愿意为 1–2 条 track 留 A/B 对照？Y 的埋点并入 `review` 周节奏可行吗？
5. 单位成本（token）数据是否可得、是否纳入？谁跑度量脚本、多久一次？

---

> **下一步:** ruihua 内部敲定 §3/§4 → promote 到 `returns/` → 提 Allen。
