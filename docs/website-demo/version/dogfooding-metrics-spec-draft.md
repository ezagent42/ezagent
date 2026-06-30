# dogfooding 效率度量 — 口径 + before/after 基线（DRAFT v0）

> **状态:** 🚧 DRAFT — ruihua 内部草案，**未提 Allen**。我们自己敲定后再 promote 到 `docs/together/<date>/returns/` 提交 lead。
> **用途:** 官网 roadmap v1 的 **P1★ dogfooding 效率成果展示**的数据源口径。
> **原则:** 真实可度量 > 好看的数字；宁可少而硬，不要多而软。

---

## 1. 一句话目标

证明「团队用 ezagent（agent 编排 / dev-together 工作流）做开发，比不用时更高效」——用**可复算、可证伪**的口径，不是拍脑袋的百分比。

## 2. 度量对象（unit of analysis）

- **主单位:** per **dev-day**（每人每工作日），归一化以消除"人多了所以产出多"。
- **次单位:** per **task-class**（handoff 任务类）——同类任务的周期时间对比。
- **时间窗:** 以**周**为粒度聚合（dev-together 本就按周/天组织）。

## 3. 候选指标（每个:定义 / 数据源 / 方向 / 风险）

| 指标 | 定义 | 数据源（已有，低成本） | 方向 | 风险 |
|---|---|---|---|---|
| **交付吞吐** | 合并 PR 数 / dev-day | git log + `gh pr` | ↑ | 别用 LOC/commit（奖励灌水） |
| **周期时间** | handoff→return→merge 时长中位数 | returns 的 `returned_at`/`deadline` + PR 时间戳 | ↓ | 任务大小不均→用中位数 + 分 task-class |
| **一次过率** | return 时 CI 首次即绿 + DoD 全 met 的比例 | returns 的 DoD reconciliation + CI | ↑ | 需 return 契约被遵守 |
| **返工率** | 标 not-met/deferred 的 DoD 行占比；merge 后 7 天内的 fix PR 数 | returns + git | ↓ | 区分"新需求"vs"返工" |
| **能力扩张** | 单人可独立闭环的 task-class 数（全栈/部署覆盖） | team.md 开发效能档 | ↑ | 定性为主，做佐证不做主数 |
| **单位成本**（可选） | agent token 成本 / 交付任务 | agent 运行记录 | ↓ | 数据是否可得待确认 |

> 主推 **交付吞吐 + 周期时间 + 一次过率**三个硬指标；其余做佐证。

## 4. before/after 基线方案（核心，三选一）

| 方案 | 定义 | 优点 | 缺点 / confounder |
|---|---|---|---|
| **A 历史窗对比**（推荐起步） | "before" = 团队重度使用 ezagent/agent **之前**的某干净周；"after" = 当前 W27+ | 数据现成（git/dev-together 历史） | 混入招人、流程改进、模型升级等变量——**必须显式列出并标注"未剔除"** |
| **B 任务内 A/B** | 同一 task-class，一部分 with-ezagent、一部分 without，对比周期 | 因果最干净 | 要刻意留对照组，有成本；样本小 |
| **C 案例叙事** | "用 ezagent 在 N 天内交付了 X"（具体功能 + 真实工时） | 最诚实、对外最可信 | 不是百分比，弱量化 |

**推荐组合:** **A 给方向性数字（带 confounder 免责声明）+ C 给 1–2 个硬案例**。**A/B（方案 B）若某条 track 能自然形成对照，顺手采。** **basleine 周一旦选定就冻结**，不许事后挑对自己有利的窗。

## 5. 诚实护栏（对外展示前必过）

- ❌ 不用 LOC / commit 数 / 工时自报这类易灌水或不可复算的数。
- ✅ 每个对外数字必须标 **n（样本）+ 时间窗 + 数据源**，且**可被第三人用同口径复算**。
- ⚠️ A 方案的百分比必须**附 confounder 列表**（"该提升未剔除 X/Y/Z 影响"）。
- 🚫 基线弱时**降级为案例叙事（C）**，不硬凑百分比。"宁可说'我们 3 天搭好了官网框架'，不说'效率+300%'。"

## 6. 落地成本

目标**零新负担**:所有主指标从 **dev-together 现有 artifacts（plans/returns/stats）+ git/gh** 脚本化算出，不要求 dev 额外填表。仅需 lead 确认**口径 + 冻结 baseline 周**。

## 7. 待 Allen 拍板的开放问题（promote 时一起问）

1. baseline "before" 选哪一周？（需要一个 ezagent/agent 重度使用前的干净窗）
2. 主指标三选（吞吐/周期/一次过率）是否认可？要不要加/减？
3. 是否愿意为 1–2 条 track 留 A/B 对照？
4. 单位成本（token）数据是否可得、是否要纳入？
5. 谁来跑度量脚本、多久出一次（建议并入 dev-together `review` 周节奏）？

---

> **下一步:** ruihua + （可拉 lead 之外的人）先把 §3/§4 敲定 → promote 到 `returns/` → 提 Allen。
