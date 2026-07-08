# homesite 支撑概念模型（飞轮 · 两 arc · gallery 交换 · 供需闭合）

> 承接 `README.md`。homesite 的官网飞轮坐在几个 ezagent 原语上；分清它们，才分得清"供给 vs 需求""fork vs 纳入 vs 连接""哪些今天能转、哪些是愿景"。**深度到概念，file:line 由研发核实。**
>
> **结构**：§0 承重命题（飞轮 vs 两条死 funnel）· §1 核心结构（两 arc + gallery 交换）· §2 两条 arc 的身份跃迁 · §3 五个支撑原语 · §4 边界（不做什么）· §5 与 hire / DealScout 骨架对读（homesite 是上层容器）· §6 交易模型链接（承 hire `model.md §6`）。

---

## 0. 承重命题：是飞轮，不是两条死 funnel（2026-07-08）

> **这一节是整条价值链的承重命题，其余各节都服务于它。**

两条 arc 各自跑通只是**两条 funnel**（builder 发布完就走、seller 兑现完就走）。让它成为**飞轮**的，只有一件事：**seller 的 fork 产物（S5）真回流成下一个 builder 的供给（新 B5）**。这条焊缝断了，网络效应就不存在，homesite 退化成"一个作品展示站 + 一堆各自为战的 socialware"。

- **飞轮闭合 = `S5 回流 → 新 B5`**：seller 兑现自己价值后，其 fork 产物作为一个"活的、可被下一个 seller 试用/再 fork 的产品"回到 gallery。这不是"存了个模板"，是**真被下一个人 S0 落地并 S1 试用**。
- **承重假设（第一证伪点）**：**gallery 必须是"活货架"**——陈列的每个产品都能当场 `public_view` 试用、能一键 fork 成自己的家族。若 gallery 只是截图 / 外链展示墙，S0 落不进产品、S2 fork 不了、S5 无处回流，飞轮三个 ★ 全塌。**这是该被最小代价优先验证的第一假设**，也是 Step 2 缺口分析的 core job。
- **与 hire 承重命题的关系**：hire `model.md §0` 的承重假设是"hire 真承载专家经验"（内容质量）；homesite 的承重假设是"gallery 是活货架 + fork 回流真闭合"（**结构/媒介**）。两者正交：内容再真，货架不活也转不起来；货架再活，内容换皮也留不住人。homesite 层守结构，hire 层守内容。

---

## 1. 核心结构：两条 arc 由 gallery 焊成环

```
┌─ BUILDER ARC · 供给 ─────────────┐        ┌─ SELLER ARC · 需求 ──────────────┐
│ 搓出 socialware → 发布进 gallery  │        │ 落 gallery 产品 → 试用 → fork      │
│ 动作：build + publish            │        │ → 改成自己的 → 兑现                │
│ 身份：访客 → 有产品的供给方       │        │ 动作：try + fork + customize       │
│ 出口：一个活的 public_view 产品   │──┐  ┌──│ 身份：匿名 → 认领 → 有产品的兑现方 │
└──────────────────────────────────┘  │  │  └────────────────────────────────────┘
                                       ▼  ▲
                            ┌─ GALLERY 交换点 ─────────┐
                            │ 活货架：陈列可试用·可fork  │
                            │ B5 入库 = S0 落点 = S5 回流 │
                            └───────────────────────────┘
        供给侧灌产品进货架 ───────────►  ◄─────────── 需求侧从货架取并 fork 回灌
```

> **一句话洞察**：builder 和 seller **共享 gallery 这一层媒介**（像 hire/DealScout 共享树洞），但**动作不同** —— builder 是 `publish`（把产品放上货架），seller 是 `fork`（把货架上的产品复制成自己的）。fork 是 homesite 特有的第三个动词，区别于 hire 的**纳入**、DealScout 的**连接**：fork = **复制一个完整产品形态作为自己的起点**（`save_template_as` 家族）。

### 1.1 builder vs seller = tool-first vs value-first（判别式，2026-07-08 定 · 权威）

两条 arc 的分野**不是"造 vs 用"**（两者都 fork、都 build），而是**入口动机与顺序**：

```
builder = 技术创作者（tool-first）
  优先理解「工具/技术」→ 因为懂 world+hello 而从零 build socialware → publish
  谁：vibe coder / 开发者 / 技术型 founder（= hire 文档的 OPC）—— 产品的源头

seller = 价值优先的业务主（value-first）
  优先理解「价值」→ 有自己的业务，看到同行 / 别的 seller 的产品、被价值打动
  → fork 别人的成果续 build → 兑现 → 回流
  谁：agency（李复制）/ 高风险专家（周把关）/ 中小品牌 / 教培 —— 08 §2 靶心全在此侧
```

- **seller 也 build**：seller 的 build 是**派生的（fork 别人的）、价值触发的**；builder 的是**原生的（从零）、工具触发的**。所以 seller arc 的 S2/S3 fork 天经地义。
- **builder 是产品源头**：没有 builder 先 publish，seller 无从 fork —— 这也是 P-2.1 供给腿=地基（冷启动供给先行）的人格化根据。
- **⚠ harvest 校正**：legacy homesite 的 persona（`08 §2` agency/专家/SME/教培 + 赵钱孙）**全部落 seller 侧**；builder persona（技术创作者）**是新的、从 hire 文档的 vibe coder/OPC harvest**，不是 legacy 里现成的（校正 README §0 与 gaps §4 的旧判断）。

#### 两条正交轴（2×2）—— 第三格 = 职能专员

判别式其实是**两条正交轴**；之前只显式用了 tool/value。补全后有第三个角色浮出来：

```
                        tool-first            value/expertise-first
                     （懂工具而造）          （懂价值/领域而动）
供给（造/发布可组合单元） │  builder            │  职能专员 / 领域专家 ★     │
需求（fork/消费别人的）   │ （技术人 fork·边缘） │  seller                   │
```

- **builder = 供给 × tool-first**；**seller = 需求 × value-first**。
- **职能专员 / 领域专家 = 供给 × expertise-first**（填上空格）：有领域经验 → 打包成**可被 hire 的单元**（未必懂 world+hello，技术 agent 化由平台/别人做）。它**跟 builder 共享"供给"轴、跟 seller 共享"价值优先"轴** —— 这就是"seller+builder 结合体"的精确含义（填 2×2 缺格，非模糊混合）。
- **⚠ 机制 = hire 的「纳入」，不是 homesite 的 fork**；**家在 `docs/rh/hire`**（= hire `model §6` 的 expertise 供给方 / 收租金方）。在 homesite 只挂一个 cross-ref：**seller arc S1（hire 型产品实例）内部的供给侧** + 交易模型投影（本文 §6）。**本轮不在 homesite 展开它的旅程** —— 飞轮承重仍是 gallery（P0），加第三条 arc 会稀释焦点（2026-07-08 决策）。

### 1.2 seller 按行业气质分渠道变体（设计原则，2026-07-08）

seller value-first、且**不同行业气质不同** → 投放到不同渠道的落地链接（S0），要用**各行业自己的表述 + UX** 迎合其气质。这直接 harvest legacy 的 persona-变体机制（`00 §五` / `P-personas`：对话式页 persona = 受众/视角，访客自报身份 → 重构到对应视角）。**一个 gallery 产品，N 个按行业气质定制的渠道落地面**（同一 fork 源，多副气质皮）。

## 2. 两条 arc 的身份跃迁

```
BUILDER：匿名访客 ──driver-license 建档──► 有身份的 builder ──publish──► 有 gallery 产品的供给方
         (B0/B1)                          (B3)                      (B5 ★ 供给兑现)

SELLER： 匿名访客 ──试用──► 匿名 fork 者 ──anon→login takeover──► 有自己产品的兑现方 ──回流──► 供给方
         (S0/S1)          (S2 匿名保护下复制)   (S3 认领身份)        (S4 ★ 需求兑现)   (S5 ★ 变供给)
```

- **builder 的结晶点在 B3（建身份档案）**：靠 driver-license 营销活动，把"路过的技术人"变成"官网上有档案的 builder"——身份在**开始认真 build 之前**就落定（供给侧要长期经营，早认领合理）。
- **seller 的结晶点在 S3（fork 后认领）**：匿名试用、匿名 fork 都在**零登录保护**下（`AnonUser`），身份恰在"我要把这个 fork 做成自己的东西"那刻才认领（`anon→login takeover`）——脆弱的"我要占为己有"发生在匿名保护下，与 hire 旅程 J-5 同一条心理安全线。
- **S5 = seller 身份的二次跃迁**：兑现方 → 供给方。这是飞轮闭合在**身份层**的印证（一个人走完 seller arc，就成了下一轮的 builder）。

## 3. 五个支撑原语

| 原语 | 干什么 | 在 arc 哪一步 | 现状 |
|---|---|---|---|
| **`public_view` + `AnonUser`** | 允许匿名访客零登录进入并试用一个产品 | S0/S1 · gallery 货架 | 已落地（socialware + #68 anon-user） |
| **socialware publish（发布进 gallery）** | 把当前 session 形态作为一个可对外试用的产品上架 | B5（发布） | ⚠ 部分——publish 原语在，**"gallery 活货架"陈列/发现待核实** |
| **`save_template_as`（fork）** | 把一个产品快照成可版本化 / 可 fork 的新 SessionTemplate 家族 | S2（fork）· B4（构建复用） | 已落地 |
| **world + hello（构建/定制工具）** | 消息可靠流转 + 界面即问即生，搓/改一个 socialware | B4 构建 · S3 定制 | 已落地 |
| **`anon→login takeover`** | 匿名足迹在登录时物理改名为确认用户 | B3 建身份 · S3 认领 | 已落地（#68 anon-user epic） |

> **fork ≠ 纳入 ≠ 连接**：fork（homesite）= 复制一个完整产品作起点；纳入（hire）= 招一个成员进你的组；连接（DealScout）= 牵两个独立 party 上线。三个动词对应三层不同价值，写 homesite 任何一格时若冒出"招成员/牵线"，就是动词串了 arc。

## 4. 边界（收进根 P-1.1，不做什么）

- **不做支付 / 清结算 / 分成**：fork 一个 builder 的产品是否付费、供给方怎么分成——是交易模型问题（`§6` 链接 hire 的核算），homesite 只做"体验闭环转起来"，不在本轮设计收费管道。
- **不做内容审核平台化**：gallery 上架产品的质量门 / 合规——承重命题在"活货架 + 回流真闭合"（结构），内容质量门沿用 hire `§0`（另一层），本轮不设审核系统。
- **不把 hire/DealScout 当并列旅程**：它们是 seller arc **S1 的实例**（见 §5），不是与 builder/seller 并列的第三/第四条 arc。
- **gallery 活货架 + fork 回流是承重项、部分待核实**：`save_template_as` fork 已落地，但"gallery 作为可发现·可试用的活货架"与"S5 回流可被下一个 seller 检索到"依赖发布/陈列链路——**Step 2 优先核实这段**，`gaps.md` 大概率落在这里。

---

## 5. 与 hire / DealScout 骨架对读（homesite 是上层容器）

| 层 | homesite（本文档） | hire（旅程实例） | DealScout（旅程实例） |
|---|---|---|---|
| 定位 | 官网飞轮：两条业务闭环转起来 | seller 落在"招 hire"型产品上试用 | seller 落在"撮合"型产品上试用 |
| 在 homesite 的位置 | **容器（全飞轮）** | **S1 实例之一** | **S1 实例之一** |
| 核心动词 | **fork**（复制产品作起点） | 纳入（`add_managed_member`） | 连接（`invite_member`） |
| 共享媒介 | gallery 活货架 | 树洞（hello public_view 对话面） | 同左 |

> **一句话洞察**：hire 树洞、DealScout 撮合是 seller 在 S1 试用的**两种产品品类**——seller 落进哪个 gallery 产品，就走那个产品内部的旅程（hire 的 J 树 / DealScout 的 J2）。homesite 不重写它们，在 sellers 旅程 S1 段**引用**它们作趣味化样例。这正是"一个官网装多条旅程"在**飞轮层**的印证：gallery 装 N 个产品品类，seller arc 是它们共同的外层壳。

### 5.1 与已有 scenario 集群 36–39 的分层（session 机制底座）

除了 hire/DealScout（S1 的产品**品类**），还有一层已存在的资产：`docs/scenarios/homesite-journey.md` 的 **36–39** 是 seller arc **S0–S3 的 session 机制底座**（浏览→登录门控→对话==在world说话→{分享同session / 复制新session}）。**39（复制配置→新 session·owner）就是 fork 原语的 click-level 实现**。分层关系：

```
homesite/（本层·商业框架）  供需两面 · 飞轮 · gallery 交换 · 交易模型投影
        │ 引用（不重写）
        ▼
scenarios 36–39（session 机制）  单访客：浏览→对话→同session/新session
        │ 骑
        ▼
ezagent 原语（§3）  public_view · save_template_as · anon→login …
```

> **飞轮缺的半边在 36–39 里没有**：builder arc（搓+发布）、gallery 活货架、S4 兑现、S5 回流 —— 这些是新 scenario 40+ 的来源（README §1.1）。本层的价值 = 把已有的 seller session 机制**升维成供需飞轮**，并指出焊缝（S5→新B5）与承重点（gallery 活货架）所在。

## 6. 交易模型链接（承 hire `model.md §6`）

homesite 层不新设交易模型，而是把 hire 的双边核算**投影到飞轮**：

- **builder = 供给侧**（hire §6 的"专家/authored 供给"）：把经验固化进一个可 fork 的产品，机会成本近零、一份成多份。
- **seller = 需求侧**（hire §6 的"招方/使用方"）：fork 一个产品作起点，省下从零搓的成本。
- **gallery = 交换所**：hire §6 的"平台撮合精准 + 守质量门"在这里具体化为"活货架的发现/陈列 + fork 回流可观测"。
- **飞轮自我强化 vs 自我瓦解**：越多 builder 发布好产品 → 越多 seller fork 到好起点 → 越多 seller 兑现并回流 → 货架越厚（强化）。唯一自我瓦解开关 = **§0 承重命题破**（gallery 不活 / 回流断）。

> **落到北极星**：P-3.2（需求北极星）里"回流产物数（S5）"就是这条飞轮闭合的硬代理——不数存模板量，数**真被下一个 seller 落地试用**的回流产物，同 hire 北极星"被接入深用不用 owner 自报"的纪律。
