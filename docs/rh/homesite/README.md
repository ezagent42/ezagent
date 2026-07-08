# homesite（官网飞轮）—— 入口文档 + 权威编号源

> **一句话**：homesite = **把两条业务闭环（builder 供给 · seller 需求）拼成一个转得起来的官网飞轮**。builder 从 tech site 进来 → 用 world+hello 搓出 socialware → 发布进 gallery（供给）；seller 从 Instagram 直接落在某个 builder 的 gallery 产品里 → 试用 → **fork** → 改成自己的 → 完成自己的价值闭环 → 产物回流 gallery，成为下一个 seller 的落点（需求→再供给）。**gallery 是两条 arc 唯一的物理交汇点**，seller 的 fork 产物回流让它成为**飞轮**而不是两条死 funnel。目标 = **让这两条闭环真转起来并持续优化**；此前做的一切（hire 树洞 / driver-license / DealScout / intro·progress·team / world·hello 试玩 / **已有 scenario 集群 36–39**）都是**为这个目标服务的战术，各归其位**。
>
> **Date**: 2026-07-08 · **作者**: Claude（与 ruihua）· **性质**: PM/designer 的官网闭环梳理（**不落地实现**；缺口经 §4 步骤转 together handoff 交研发）。深度到 **feature 层**，`已落地/愿景/需补充` 标注沿用 hire 文档边界判断、**具体 file:line 由研发核实**。
>
> **本文档是策略层，不是 click-level 真相**：click-level 旅程（页面 mockup + 按钮级动作 + E2E 断言）的权威家 = **`docs/scenarios/NN-<slug>/`**（团队既有格式）。seller arc 大半已由 **36–39** 覆盖（见 §1.1）；缺的半边（builder arc + gallery + 回流）的新 scenario（40+）在 Step 1 确认后开。**本层只做"为什么/哪些 stage/缺什么"，把 click-level 指向 scenarios，不重写它们。**
>
> **文档地图**：本文 = 入口 + 飞轮图 + 资产归位表 + 编号骨架 + 方法步骤 · `model.md` = 飞轮概念模型 · `product/1` = P 定位→北极星 · `product/2` = J 旅程 index（**映射到 scenarios 36–39 + 待开 40+**） · `product/3` = V 视图 · `product/4` = F 功能（标状态，交叉引用 `homesite-handoff` 的 W/H 任务 + 新缺口） · `gaps.md` = 缺口清单。
>
> **参照**：`docs/rh/hire`（同款 P/J/V/F 骨架）。**homesite 是 hire / DealScout 的上层容器**：它们是 seller arc S1 的两个产品实例（`model.md §5`）。**与已有 `docs/scenarios/homesite-journey.md`（36–39）的关系见 §1.1** —— 那份是 seller arc 的 session 机制底座，本层在其上加"供需两面 + builder arc + gallery 飞轮"的商业框架。

---

## 0. 演进声明（2026-07-08）—— homesite 从「需求雷达」演进为「用户产品飞轮」

> **必读。本节界定"哪份是当前框架、哪份是 legacy 参考"，否则同一文件夹里两套框架会打架。**

homesite 原为 **AARRR 五棒需求雷达 / build-in-public 展示站**（`value-chains/` + `docs/`，#1029，ruihua authored）：站的核心是"展示**我们团队**的成果（=已合并 PR）+ 路线图投票 + 收意向信号，本站不收钱"。**2026-07-08 演进**：站的核心变为 **用户造 / 发布 / fork 自己产品的双边飞轮**（builder 供给 × seller 需求，见 §1）。

**当前顶层框架 = 本 README + `model.md` + `product/`（飞轮）。** AARRR 框架**降为 legacy 参考**：

- **legacy 位置（保留不删、不回填历史）**：`value-chains/`（00 战略定位 + 01–05 定位拆分 + V 总表 + W 工作流）、`docs/`（P-personas · M-文案 · R-原则 · T · 08）、`demo/`（原型/组件）。
- **纪律**：不编辑这些 legacy 文件的正文（`never-modify-prior-docs`）；它们记录的是**演进前**的方向，读时按"历史/可 harvest 素材"看，不当当前框架。

**为什么演进≠推翻**：飞轮补的是 AARRR **完全没有的供给侧**（用户发布自己的产品）；而 AARRR 的受众 / 漏斗机制 / 方法论**大多落在飞轮的 seller 侧与横切层，可 harvest**：

| 从 legacy AARRR | 带进飞轮怎么用 | 状态 |
|---|---|---|
| personas 赵钱孙李周 | **全部 = seller 侧**（value-first 业务主，`08 §2` 靶心全在此侧）；**builder（技术创作者）从 hire 文档 vibe coder/OPC harvest，非 legacy 现成**（判别式 model §1.1） | 全转 seller；builder 取自 hire |
| AARRR 五棒漏斗 | 不再是站顶层；降为**每条 arc 内部**的获客→激活→留存→转化→裂变机制参考 | 降维复用 |
| R-修改原则（公式化北极星 / 闭环乘子 / 复用记账） | 方法论直接复用到飞轮 P/F 层 | 直接复用 |
| 0→1 基础设施卡（站点骨架 / demo 容器 / GitHub 内容管线 / OG 底座） | 飞轮同样需要，可复用 | 直接复用 |
| 需求雷达 / 投票 / 成就（build-in-public） | 作为飞轮的 community / retention 层保留，不再是核心定位 | 保留为子层 |

> **harvest 落地时机**：具体把哪些 legacy 卡 / persona 吸进飞轮 P/J/V/F，在 **Step 2（gap 分析）** 一并做——那时对现状 + legacy 一起核实，避免现在凭空搬运。

---

## 1. 飞轮（两条 arc + gallery 交换点）

```
   ┌──────────────── BUILDER ARC · 供给（tech site 来 · 线性）────────────────┐
   B0 抵达      tech site → 落 intro（理念）
   B1 认同      读理念 · 看进度(world.cup) · 看团队(team) —— 信任建立
   B2 体验      试玩 world + hello（产品本身）
   B3 建身份    driver-license → 在官网建 builder 身份档案（+ achievement 延伸）
   B4 构建      用 world+hello 搓出自己的 socialware
   B5 发布 ★    产品进 gallery —— builder 闭环兑现「我的东西对外了」
   └────────────────────────────────┬─────────────────────────────────────────┘
                                    ▼   gallery 陈列「活的 · 可试用 · 可 fork」产品
   ═══════════════════════════ GALLERY 交换点 ═══════════════════════════
                                    ▲
   ┌──────────────── SELLER ARC · 需求（Instagram 来 · 深落地 + fork 回环）──────┐
   S0 抵达 ★    Instagram → 直接落在某 builder 的 gallery 产品           [≈ 36 浏览*]
   S1 试用      匿名用这个产品拿到价值(对话)  ← hire/DealScout=此段实例    [= 37 对话]
   S1' 加入     别人分享 → 进同一 session 当成员(end-user，不 fork)        [= 38 同session]
   S2/S3 fork   复制这个产品 → 改成自己的 + 认领 owner                     [= 39 复制→新session★]
   S4 兑现      自己的产品跑起来 / 对自己的客户开放 —— seller 闭环兑现     [✗ 新]
   S5 回流 ★    我的 fork 产物回到 gallery == 下一个 seller 的 S0 落点     [✗ 新]
   └──────────────────────────────────────────────────────────────────────────┘
```

> **一句话洞察**：三个 ★（`B5 发布` · `S0 落点` · `S5 回流`）是**同一个点** —— gallery。gallery 不是截图墙，是**活的 public_view 产品货架**（当场试用、可 fork）。飞轮转不转、就看这个点厚不厚：`S5 回流 → 成为新 B5` 是把两条 arc 焊成环的那一焊，也是现状最薄、Step 2 缺口最可能扎堆的地方（`model.md §0`）。

### 1.1 与已有 scenario 集群 36–39 的关系（seller arc 的机制底座）

`docs/scenarios/homesite-journey.md`（2026-07-02，你 + Claude）已把一条 homesite 旅程拆成 36–39，框在 **session 机制**上。它**几乎就是 seller arc S0–S3 的 click-level 实现**：

| 已有 scenario | 覆盖 | 对应飞轮 stage |
|---|---|---|
| **36** homesite-browse | 匿名浏览 + 写入门控→登录 | S0（*但 36 是"营销站浏览"，未含"从 gallery 落进某产品"，S0 需补 gallery 落点*） |
| **37** homesite-dialog-world-sync | 官网对话 == 在 world 官网 session 说话 + 红点 | S1 试用 |
| **38** share-deploy-same-session | 分享 → 同一 session 群聊（成员/end-user） | S1' 加入 |
| **39** redeploy-publish-fork-session | 复制配置 → 新 session（owner/租户）**= fork** | S2/S3 fork★ |

> **本层不重写 36–39**。它们是 seller arc 的机制底座（尤其 **39 = fork 已经在**）。本层做两件它们没做的事：① 加**供需两面的商业框架**（36–39 是单访客的 session 机制，无 builder/seller 二分）；② 补飞轮缺的半边 —— **builder arc（B0–B5）+ gallery 活货架 + S4 兑现 + S5 回流**，这些现状**无 scenario**（[✗ 新]），是新 scenario 40+ 的来源。

## 2. 资产归位表（每个旧资产 → 唯一 stage 归宿）

| 已有资产 | 归到 | 作用 | 现状 / scenario |
|---|---|---|---|
| intro（理念） | B0 / B1 | builder 入口理解 | 够用 |
| progress · world.cup | B1 | 信任：看研发进度 / 押注路线图 | 够用 |
| team office | B1 | 信任：看真实团队 | 够用 |
| driver-license | B3 | builder 建身份档案的营销钩子 | 够用（营销活动） |
| achievement-center | B3 延伸 | 身份之上的成就 / 激励 | 够用 |
| **world + hello 试玩** | **B2 + S3** | 既是 builder 体验、又是 seller 定制工具 | 够用 |
| **hire 树洞 case** | **S1 实例** | seller 落在「招 hire」型 socialware 上试用 | 已有 J 树（`docs/rh/hire`） |
| **DealScout** | **S1 实例** | seller 落在「撮合」型 socialware 上试用 | 已有骨架 |
| **scenario 36–39** | **S0–S3 机制底座** | seller arc 的 click-level 实现 | 🚧 design spec（见 §1.1） |
| **cases → gallery** | **交换点（B5↔S0↔S5）** | 飞轮承重点 | ⚠ 最薄 + 无 scenario，见 §1 洞察 |

> **归位纪律**：一个资产**只挂一个 stage**（唯一归宿），避免"到处都有一点"的漂移。同一工具在两条 arc 都用（如 world+hello）时，写明"两处用"、但价值时刻各自独立记在各 arc。

## 3. 编号骨架（traceability index）—— 权威编号源

- **前缀**：`P` 定位→北极星 · `J` 旅程 · `V` 视图 · `F` 功能。**arc 用字母嵌进序号**：`B` = builder 供给 arc，`S` = seller 需求 arc（例 `J-B3`、`F-S2`）。
- **唯一上游 `↑`**：每节点恰一个父、只指上一层（J↑P-3、V↑J、F↑V）。构成从"飞轮转起来"根到功能点的推导树。
- **两条 arc 是颜色不是分层**：🟦 builder 供给 arc / 🟨 seller 需求 arc 标在节点上；父子结构仍是严格单亲树。

### 3.1 P · 定位 → 北极星（`product/1`）

- **P-1.1** 根（无上游）：**让两条业务闭环拼成的官网飞轮真转起来、并持续优化**。边界：只做"把两条 arc 各段体验做通 + 焊上 gallery 交换点"；不做雇佣 / 支付清结算 / 内容审核平台化。
- **P-2.1** ↑P-1.1 🟦 **builder 供给腿**；**P-2.2** ↑P-1.1 🟨 **seller 需求腿**。
- **P-3.1** ↑P-2.1 🟦 **供给北极星**（近期）：发布进 gallery 的 socialware 数 / builder 抵达→发布转化率&时间。
- **P-3.2** ↑P-2.2 🟨 **需求北极星**（远期·质量加权）：fork 并**兑现**的 seller 数 + **回流**产物数（S5，飞轮闭合硬代理）。

### 3.2 J · 旅程骨架（`product/2` = J-index → scenarios）

🟦 **builder arc（↑P-3.1）**：J-B0 抵达 · J-B1 认同 · J-B2 体验 · J-B3 建身份 · J-B4 构建 · J-B5 发布 ★ —— **全段 [✗ 无 scenario]，待开 40+**
🟨 **seller arc（↑P-3.2）**：J-S0 抵达 ★[≈36] · J-S1 试用[=37] · J-S1' 加入[=38] · J-S2/S3 fork[=39★] · J-S4 兑现[✗] · J-S5 回流 ★[✗]

> `product/2-旅程.md` 是 **J-index**：把每个 J 节点映射到已有 scenario（36–39）或标为待开（40+）。**click-level 内容不在 homesite/ 写**，在 `docs/scenarios/`。

### 3.3 V · 视图（`product/3`）· F · 功能（`product/4`）

V-B*/V-S* ↑ 对应 J；F-B*/F-S* ↑ 对应 V，逐条标 **已落地 / 愿景 / 需补充**，并交叉引用 `homesite-handoff.md` 的 W1–W4 / H1–H5（seller arc 机制任务）。F 层的"需补充"即 Step 2 `gaps.md` 来源。

---

## 4. 方法与步骤（plan-of-record）

> 本节是本轮工作的权威步骤记录（合 kanban-first / 不另开 specs 文件的偏好）。方法 = **飞轮做脊柱（A）+ 复用 hire 的 P/J/V/F 可追溯树（B）+ 站在已有 36–39 之上不重写（never-modify-prior-docs）**。**本轮只出文档，不做 demo**（demo 是后续独立一轮）。

| Step | 做什么 | 产出 | 状态 |
|---|---|---|---|
| **0** ✅ | 定飞轮脊柱 + 资产归位 + 织进 36–39 | `README.md` + `model.md` | 完成 |
| **1a** ← 现在 | **策略层**：两条 arc 的 P/J/V/F 树，引用 36–39 作 seller 已有实现、标缺的半边 | `product/1-4` | 进行中 |
| **1b** 待确认后 | **新 scenario**：为 builder arc + gallery + S4/S5 回流写 click-level scenario（40+），补齐 36–39 集群 | `docs/scenarios/40+-*/scenario.md`(+zh_cn) | 待开 |
| **2** | 读当前最新平台功能，F 层逐条对现状 → 缺口清单，按 arc×stage 归类、按**闭环阻断度**排序 | `gaps.md` | 待开 |
| **3** | 参考同事 handoff 写法，把 gaps 转成 handoff（对齐 `homesite-handoff.md` 格式） | `docs/together/<date>/handoffs/…` | 待开 |
| **4** 后续轮 | 依 scenario 做 demo 页面（designer 主导；本轮不做） | demo HTML | 未排 |

**追溯自检（每 Step 收尾跑）**：每个 F 逐级 `↑` 回到 P-1.1（飞轮根）无断链；每节点恰一个 `↑`、只指上一层；两条 arc 是颜色属性、不参与父子结构。
