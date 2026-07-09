# homesite 飞轮 · 能力缺口清单（Step 2）

> **一句话**：把 `product/4` 的 F 层逐条对**当前平台现状**（`origin/main @ 2026-07-08`，勘察 + `ezagent-socialware` skill + `08` harvest 核实）→ 判 ✅已落地 / 🔧需补充 / 🌱愿景，按**闭环阻断度**排序。**结论：飞轮的承重缺口收敛成一件事 —— gallery（活货架/发现/发布/回流），且它已有设计 spec、未实现；而 fork 已经做好了。**
>
> **现状源**：勘察对 `origin/main @ dd43c4b`（2026-07-08，本地 main 陈旧、已用 origin/main 行号）· `ezagent-socialware` skill（原语模型）· legacy `08 §2/§3`（builder 侧靶心 + 路 B 三步）。**具体 file:line 已尽量给出，最终由研发核实。**
> **喂给**：Step 3 handoff（仿 `docs/scenarios/homesite-handoff.md` 的 W/H 拆分）。

---

## §1 头条：承重缺口只剩 gallery，fork 已就位

```
飞轮承重命题（model §0）= gallery 活货架 + fork 回流真闭合
   ├─ fork（S2/S3）        ✅ 已就位 —— session.fork_config 全链路已接，用户点「复制配置，建新会话」即成 owner
   └─ gallery（B5/S0b/S5） 🔧 承重缺口 —— 发现/发布/回流货架「NOT-FOUND」，但已有设计 spec 未实现
```

- **✅ 意外之喜：fork 不是缺口。** scenario 39 / 任务 W1 实际**已实现**（scenario 文档 🚧 标注已陈旧）：`Conversation.tsx:713` 「复制配置，建新会话」按钮 → `main.tsx:393 session.fork_config` → `conversation_actions.ex:92` → `session_fork_action.ex:30`（moduledoc 原文"website journey segment 5"，"caller becomes the new session's owner"）→ `config_fork.ex:93`；受真 CapBAC `:create_session` 门控，非编排器专属。**需求腿高潮（fork→拥有）今天就能演。**
- **🔧 承重缺口 = gallery。** 发现/浏览/发布已发布产品的**货架**在 shipped 代码里 **NOT-FOUND**（勘察 Q1）：`/socialware/*` 路由全是**单 session 深链**（`router.ex:159/186`），无 listing。gallery/market 只以**设计 spec 存在、未建**：`docs/superpowers/specs/2026-07-03-socialware-manifest-design.md:14`（`Marketplace | app-center (discover/publish/install) | —`）、`2026-07-04-socialware-registry-and-distribution-plan.md:388`、`docs/futures/todo.md:565`（marketplace registry Kind `marketplace://<name>` = future TODO）。

> **一句话洞察**：飞轮转不起来的**唯一硬阻断 = 没有活货架**。`S0 从外部落进一个可浏览的产品`、`B5 发布进货架`、`S5 回流被下一个 seller 发现` —— 三个 ★ 全压在这一个未建的 gallery 上。**好消息：它不是从零想，已有两份设计 spec（manifest + registry-and-distribution）可直接接。**

## §2 缺口清单（F 节点 × 现状 × 归属）

状态：✅已落地 · 🔧需补充 · 🌱愿景。证据 = `origin/main @ 2026-07-08` file:line。

| F 节点 | 功能点 | 状态 | 现状证据（file:line） | 缺什么 | arc/stage |
|---|---|---|---|---|---|
| **F-B5 / F-S0b / F-S5** | **gallery 活货架：发现/发布/回流** ★承重 | 🔧 | 无 listing 面（`router.ex:159/186` 单 session 深链）；设计 spec `2026-07-03-socialware-manifest-design.md:14` + `futures/todo.md:565`（未建） | **整个发现/发布/回流货架** —— 飞轮唯一硬阻断 | B5·S0b·S5 |
| **F-S2/S3** | fork → 新 session owner ★ | ✅ | `Conversation.tsx:713`→`session_fork_action.ex:30`→`config_fork.ex:93`；owner + `:create_session` 门控 | — **已就位**（scenario 39 文档 🚧 已陈旧） | S2/S3 |
| **F-S0a** | `public_view`+`AnonUser` 匿名落地某产品 | ✅ | `/socialware/chat`（`router.ex:186`）+ anon 生命周期（skill §gotcha5） | — | S0 |
| **F-B3b** | `anon→login takeover` 认领 | ✅ | `AnonTakeover`（#68） | — | B3·S3 |
| **F-S1'（substrate）** | 加入**同一** session 当成员 | ✅ | `SessionsTable onJoin`→`conversation_actions.ex:887 self_join`→`Membership.provision_join_authority:909` | — 底座在 | S1' |
| **F-S1'（affordance）** | **分享按钮：产出分享链接** | 🔧 | scenario `38:4` "share affordance not yet built / placeholder" | 只缺**发链接的按钮**（join 底座已在，H4/W4） | S1' |
| **F-S1b（world 侧）** | 深链 page→world session 视图 | ✅ | `routes.ex:283-295 parse_session_uri_param`；多处 push_patch `/sessions?session=` | — world 侧在 | S1 |
| **F-S1b（page 侧）** | 「查看当前 session」按钮 + 红点计数 | 🔧 | 红点/计数推送**NOT-FOUND**（无 code）；page 是静态 mock | badge 计数（W3）+ page 按钮（H2/H3），37 🚧 | S1 |
| **F-S1a** | 营销页 composer 写入官网 session | 🔧 | scenario `37:4` "backend dialog wiring NOT connected / blank placeholder"；营销页 = 静态 mock（真站在未合分支） | 营销页 composer→session 写入（H5），**属 T4 官网轨** | S1 |
| **F-B4 / F-S4** | 用 world+hello 搓/改 socialware（一站式工作台） | 🔧 | 路 B 原语在（`08 §3`：public_view 模板→起活会话→编排器 10 工具）；一站式 UX 未成 | "一个下午搓出来"的**一站式工作台**（原语齐、UX 缺） | B4·S4 |
| **F-B2** | world/hello 真站试玩入口 | 🔧 | demo 在；真站入口在未合分支 `feat/website-hello-*` | 真站入口（T4 官网轨） | B2 |
| **F-B3a** | driver-license 真站建 builder 身份档案 | 🔧 | 仅 mock（`docs/website-demo/driver-license.html`）；`turn_driver.ex:111` 只是注释 | 真站身份档案（营销活动，低阻断） | B3 |

## §3 优先级（按闭环阻断度）

```
P0 承重·飞轮唯一硬阻断（不建则飞轮不转）
  ① gallery 活货架：发现 + 发布 + 回流   [F-B5/F-S0b/F-S5]  ← 已有设计 spec，未实现
P1 小切口·底座已在只缺临门（性价比高）
  ② 分享链接按钮                          [F-S1' affordance] （join 底座 ✅，只缺发链接 UI，W4/H4）
P2 机制·36–39 集群已拆 handoff（链路待接，部分属 T4 官网轨）
  ③ 营销页 composer 写入 + 红点计数        [F-S1a/b]  （37 🚧；world 深链侧 ✅；page 侧属 T4）
P3 供给腿 UX·原语齐缺一站式
  ④ 一站式搓 socialware 工作台             [F-B4/F-S4] （路 B 原语 ✅，UX 缺）
P4 营销/身份·低阻断
  ⑤ driver-license 真站建档                [F-B3a]
  ⑥ world/hello 真站试玩入口               [F-B2]（T4 官网轨）
```

> **一句话洞察**：缺口清单比 `product/4` 预告的**小了一圈** —— 因为 **fork（曾以为的需求腿高潮缺口）已经做好了**。真正卡飞轮的只有 **P0 gallery 一件**；P1 分享只差一个按钮；P2/P3/P4 要么属 T4 官网轨、要么是 UX/营销打磨。**把研发火力集中在 gallery，飞轮就能转。**

## §4 从 legacy AARRR harvest（承 README §0）

Step 2 一并做的 harvest —— 哪些 legacy 素材吸进飞轮、挂哪：

| legacy 素材 | harvest 进飞轮 | 挂点 |
|---|---|---|
| **`08 §2` 靶心 persona**（agency 李复制 / 高风险专家 周把关 / 无工程 SME / 教培） | **= seller 侧 persona**（value-first 业务主，**非 builder**，model §1.1）—— 有自己业务、看到价值才 fork 续 build；按行业气质分渠道变体 | P 层 seller 腿 · S0 渠道气质变体 |
| 赵/钱/孙（跨境电商终端，00 已作废） | seller/end-user 侧参考 | seller 腿受众参考 |
| **builder persona = 技术创作者** | **legacy 里没有** —— 从 **hire 文档的 vibe coder/OPC** harvest（tool-first 创作者，产品源头） | P 层 builder 腿 · gallery 发布者画像 |
| **`08 §3` 路 B 三步**（public_view 模板→起活会话→发链接） | = builder arc **B4/B5 原语路径**（止于"发链接"，缺 gallery） | F-B4/F-B5 现状锚 |
| **`W-成果生产工作流`**（GitHub→成果卡 pipeline） | 给**团队 build-in-public 进度模块**（progress/world.cup）用，**不是**用户产品 gallery | community/retention 子层 |
| **`R-修改原则`**（公式化北极星 / 闭环乘子 / 复用记账） | 方法论直接复用到飞轮 P/F 层（如 P-3 北极星公式化、F 层复用记账） | 方法论 |
| **0→1 基建卡**（站点骨架 / demo 容器 / OG 底座 / 内容管线） | 飞轮同样需要（尤其 demo 容器 → S1 试用、OG → S5 回流分享） | 横切基建 |
| 需求雷达 / 投票 / 成就（build-in-public） | 降为飞轮 community 子层（progress 模块保留），不再是核心定位 | 子层 |

> **关键 harvest 校正（2026-07-08，权威见 model §1.1）**：`08 §2` 靶心（agency/专家/SME/教培）**全是 seller**（value-first 业务主），**不是 builder**。builder = **技术创作者**（tool-first，vibe coder/OPC），legacy 里没有、从 **hire 文档** harvest。Step 1b：builder arc scenario 主角用 hire 的 OPC；**seller arc scenario 用 `08 §2` 的 李复制/周把关，且按行业气质出多套渠道落地变体**（model §1.2 · harvest legacy persona-变体机制）。

## §5 → Step 3 handoff 预告

缺口按承接方归类（仿 `homesite-handoff.md` 的 W=zyli world / H=zhaomato 前端；gallery 可能需新承接方）：

- **P0 gallery**（①）：**最大项，且已有设计 spec**（`2026-07-03-socialware-manifest-design.md` + `2026-07-04-registry-and-distribution-plan.md`）—— handoff 时**先对齐这两份 spec 的落地状态**，不重新设计。承接方待定（可能 world + domain_socialware + 新 discovery 面）。
- **P1 分享链接**（②）：小切口，H4（前端按钮）+ W4（world 出链接），join 底座已在。
- **P2 营销页集成**（③）：36–39 集群已拆好 W2/W3/H2/H3/H5，**部分属 T4 官网轨**（真站 homesite 在未合分支）—— handoff 时注明与 T4 的边界。
- **P3/P4**（④⑤⑥）：UX / 营销打磨，优先级低，可后置。

## 追溯自检

- **状态诚实**：✅ = fork（`session_fork_action.ex`）、anon 落地/认领、join 底座、world 深链侧；🔧 = gallery、分享按钮、营销页集成、一站式工作台、driver-license；🌱 = 无纯愿景项（gallery 回流的跨用户发现随 gallery 一起，归 🔧）。
- **与 `product/4` 的差异**：F-S2/S3 从 🔧 **升级为 ✅**（fork 已实现）—— 本清单以勘察现状为准，修正 `product/4` 的预判。
- **承重收敛**：飞轮 P0 唯一硬阻断 = gallery，且有设计 spec 可接。**通过。**
