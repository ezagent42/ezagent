# PR #690 评估

> 评估日期: 2026-06-09
> PR: https://github.com/ezagent42/ezagent/pull/690
> 标题: docs(plan): AutoService→socialware 垂直 E2E Stage 1 实施计划
> 基线: PR #680 review 的后续回应

---

## 一、总体判断

**相比 PR #680 有实质性进步。** 这份计划回答了上一轮 review 提出的核心问题：按 customer/operator/admin 面 + soul/skill/kb 框架组织，有具体的设计决策、文件结构、9 个 task。0 行代码，正确的阶段（计划→评审→实施）。

PR #680 的问题 | PR #690 的回应 | 评估
---|---|---
目标分支是 main | 改为 `autoservice` | ✅ 已修正
没有界定 customer/operator/admin 范围 | 6 个 DD 按面展开 | ✅ 已细化
没有 soul/skill/kb 映射 | DD3/DD4 给出方案 | ✅ 有方案但 DD5-b 偏离 rev8
0 产品代码 | 仍是 0 代码（计划阶段，正确） | ✅ 计划阶段不写代码是对的
没有具体 task 列表 | 9 个 task + 文件级变更清单 | ✅ 足够详细

---

## 二、范围界定评估

### Stage 1 IN 的范围

| 面 | 覆盖内容 | 评估 |
|---|---|---|
| **Customer** | 一条 cinnox 流(`customer-type-clarifier`)，单 cc bot，无 fast+slow | ⚠️ 最薄可行。去掉了 fast+slow 双相位，需要确认这是否可接受 |
| **Customer** | 消息经 Turn(open→compose→settle)→ CustomerFeed → `customer_live` | ✅ 路径正确 |
| **Operator** | takeover: turn.claim → operator_only → edit → settle | ✅ 最小接管，足够证明 visibility 门控 |
| **Operator** | 不 port `operator_live.ex`(249行)，用核心 SessionView | ⚠️ defer 到 admin 阶段。意味着 Stage 1 没有操作员控制台 |
| **Admin** | 完全不覆盖 | ✅ 正确 defer |
| **Soul** | cinnox `customer_soul.md` → ConfigObject → `render_soul` 投影 | ✅ |
| **Skill** | `customer-type-clarifier/SKILL.md` → AgentTemplate working_dir | ✅ |
| **KB** | 不覆盖(defer Stage 2) | ✅ customer-type-clarifier 不需要 KB |

### Stage 1 OUT (deferred)

| 内容 | 归属阶段 | 评估 |
|---|---|---|
| fast+slow 双相位 | Stage 2 | ⚠️ 这是 autoservice 的核心差异化能力（并发 ack + filler loop），去掉后 Stage 1 就是一个"带接管的标准 cc bot 聊天"，与 autoservice 的实际产品形态有差距 |
| KB / general-inquiry-flow | Stage 2 | ✅ 合理 |
| Admin LiveViews(全部) | Admin 阶段 | ✅ 合理 |
| `operator_live.ex` port | Admin 阶段 | ⚠️ 操作员控制台是 autoservice 三大面之一，全部推到 admin 阶段意味着 operator 面在 Stage 1 基本是空的 |
| 多租户管理面 | Admin 阶段 | ✅ 合理 |

---

## 三、六个设计决策逐项评估

### DD1 🔶 — CS Turn Adapter（推荐）

```
用户消息 → routing {:from customer} → session
→ CS turn adapter 截获 → turn.open
→ bot 正常 chat.send 回复 → adapter 截获 → turn.compose → turn.settle
```

**评估: ✅ 方向正确，但缺少关键细节。**

- 优势：bot 不需要学 turn 语义（stay as plain cc chat agent），最小改动
- 未解决的问题：**adapter 如何判断 bot "回复完了"？** cc agent 可能发多条消息（先发 ack 再发正文），也可能超时无回复。adapter 需要"收齐 bot 的本轮消息"的判断逻辑——是等第一条消息就 compose？等 N 秒无新消息？还是有显式的"本轮结束"信号？
- 建议：plan 中补充 adapter 的"回合结束判定"策略

### DD2 — Session Kind

**评估: ✅ 正确。** `SocialwareSession` 替换 bare `Session`。无争议。

### DD3 — soul → ConfigObject

**评估: ⚠️ 方向正确，但需注意归属。**

- soul=ConfigObject，body 带 `"soul_md"` key，session-layer pointer，投影为 `CLAUDE.md`
- 需要修改 `render_soul/1`（在 `ezagent_domain_socialware`）
- **这是对 socialware domain 的修改。** 按分支策略，这个修改需求应从 autoservice 提出，经 Allen review 后合入 main，然后 rebase 进 autoservice。不是直接在 autoservice 分支上改 socialware 代码
- `render_soul/1` 当前是 key:value dump。改为支持 `soul_md` 分支是合理的扩展。但要注意：这不是 autoservice 特有的——任何 vertical 都可能需要直接写 soul markdown。改动应该是 general-purpose 的

**建议**：`render_soul/1` 的 soul_md 分支作为独立的小 PR 合入 main（动因从 autoservice 提出），不在 autoservice 分支上直接改 socialware 代码

### DD4 🔶 — skill/kb 映射

**评估: ✅ 务实。**

- skill → AgentTemplate working_directory（复用 `cinnox_assets.ex` 模式）——合理，skill 文件本来就是 template-time 的，运行时不变
- kb → 外部 MCP server 叠加（E1 已证）——正确，不依赖 socialware config 模型
- soul=ConfigObject vs skill=working-dir-file 这个边界：soul 需要自进化（P6）、需要可审计的版本历史（ConfigObject 天然支持），skill 是静态文件。**这个边界划分是合理的**

### DD5-b 🔶 — 保留 customer_live，只换消息源

**评估: ⚠️ 务实但偏离 rev8，有一个重要的 UX 变更需要明说。**

- 保留 `customer_live.ex` LiveView，只把消息源从 `Chat.session_events_topic` 换成 `CustomerFeed`
- 偏离 socialware spec rev8 的"customer = React SPA"
- **DD5-b 的论证是对的**：CustomerFeed 的门控属性与 LiveView/SPA 正交；无页面的对话式 CS 用不上 json-render
- **但有一个重要的行为变更需要明确**：
  - 当前 `customer_live` 订阅 `Chat.session_events_topic` → **每条消息实时推送**（streaming UX）
  - `CustomerFeed` 订阅 `:customer_delivery` 事件 → **只在 settlement 后推送 message_ids**，LiveView 需要 refetch
  - 这意味着：auto turn 下消息是批量到达（非实时流）；copilot 下客户在 settle 前看不到任何内容
  - **这是正确的 socialware 行为（客户只看 committed 内容），但对现有 `customer_live` UX 是一个变更。** 计划中应该明确说明这个行为变更

**建议**: 在 DD5-b 的说明中补充 "从实时流 → 批量投递" 的行为变更。这本身是正确的（socialware 的核心价值），但需要让 reviewer 知道这不是简单的"换数据源"

### DD6 — Operator 面

**评估: ⚠️ 最薄可行，但实际可交付价值有限。**

- 最小接管：核心 SessionView + 一个 "claim/settle" 控制
- 不 port `operator_live.ex`（249 行）——操作员控制台推到 admin 阶段
- 这意味着 Stage 1 的 operator 体验是"没有会话列表、没有聊天 UI、在 SessionView 上点一个按钮"
- 操作员接管是 autoservice 的 P0 场景，Stage 1 的覆盖过于单薄

**建议**: 考虑在 Stage 1 增加一个最小但可用的 operator 聊天界面（甚至可以复用 `customer_live` 组件），否则录屏 demo 的 operator 部分会很弱

---

## 四、依赖和前提条件检查

| 依赖 | main 上是否存在 | 评估 |
|---|---|---|
| `SocialwareSession` Kind | ✅ | 存在，Chat+Turn+Surface+ConfigUpdate |
| `Behavior.Turn` 完整状态机 | ✅ | 499 行，全部 action 可用 |
| `ConfigStore.write_and_point/1` | ✅ | 行 33 |
| `ConfigStore.resolve/4` | ✅ | 行 132 |
| `ConfigProjection.render_soul/1` | ✅ | 行 218，需要改动（DD3） |
| `ConfigProjection.register/0` | ✅ | 行 59 |
| `CascadeRepoint.repoint_user_layer/3` | ✅ | 行 57 |
| `CustomerAuth.issue_token/3` | ✅ | 行 13 |
| `CustomerAuth.authorize/3` | ✅ | 行 28 |
| `CustomerFeed.snapshot/2` | ✅ | 存在 |
| `CustomerFeed.topic/1` | ✅ | 存在 |
| `Behavior.Turn` 的 compose 接受 chat message card_ref | ⚠️ 需确认 | Task 5 Step 1 应验证 |
| autoservice rebase 到 main | ❌ 未做 | 68 commit 落后，计划标为 Stage 0 前置步骤 |

**结论: 所有关键依赖在 main 上均已存在。** P6 消费侧（CascadeRepoint、ConfigProjection）已在 main。——之前 `socialware-readiness-and-migration-analysis.md` 中标记的"PR #607 未合并"问题已解决。

---

## 五、Task 列表评估

| Task | 内容 | 评估 |
|---|---|---|
| **0** | G1 live 确认（`SCENARIO_34_LIVE=1`） | ✅ 关键门控。G1 如果失败，后续全部停 |
| **1** | `render_soul/1` 增加 soul_md 分支 | ✅ TDD 正确。但代码入 main 的流程需说明 |
| **2** | cinnox soul → ConfigObject 种子 | ✅ |
| **3** | `SocialwareSession` provision | ✅ 替换 `customer_session.ex` 的 Session 创建部分 |
| **4** | skill 种子入 bot working dir | ✅ 复用 `cinnox_assets.ex` |
| **5** 🔶 | CS turn adapter | ⚠️ 依赖 DD1 签字。"bot 回复完成"判断逻辑未定义 |
| **6** 🔶 | operator takeover | ⚠️ 依赖 DD1/DD6 签字 |
| **7** | `customer_live` 换源到 `CustomerFeed` | ⚠️ 行为变更（实时流→批量投递）未说明 |
| **8** | `customer_live` + `CustomerFeed` 集成验证 | ✅ |
| **9** | E2E live runbook + 录屏 | ✅ |

---

## 六、与 `customer_session.ex` + `operator_live.ex` 的关系

计划没有明确说明新的 `socialware_cs.ex` 与现有的 `customer_session.ex` (386行) 和 `operator_live.ex` (249行) 的关系：

| 现有文件 | Stage 1 处理 | 建议 |
|---|---|---|
| `customer_session.ex` (386行) | 部分替换（provision 逻辑移到 `socialware_cs.ex`） | 应明确：是新增文件共存，还是逐步替换。建议共存——`customer_session.ex` 保留原逻辑（fast+slow 双相位仍在工作），`socialware_cs.ex` 是 socialware 路径 |
| `operator_live.ex` (249行) | 完全不碰，defer 到 admin 阶段 | ✅ 但失去了展示操作员接管的机会 |
| `customer_live.ex` (126行) | 修改消息源（Task 7） | ⚠️ 应保留原始订阅路径作为 fallback，或通过配置开关 |

---

## 七、总体评价与建议

### 做对了的

1. ✅ 目标分支改为 `autoservice`
2. ✅ 按 customer/operator/admin + soul/skill/kb 框架组织
3. ✅ 6 个设计决策（DD1-DD6）回答了上一轮 review 的问题
4. ✅ 9 个 task 具体到文件和函数级，TDD 流程
5. ✅ G1 风险 gated by Task 0
6. ✅ DD5-b 的论证（CustomerFeed 门控与 LiveView/SPA 正交）逻辑正确

### 需要补充/修正的

1. **DD1 缺少 "bot 回复完成判定" 逻辑**。CS turn adapter 需要知道 bot 何时结束本轮回复，这个细节应补充
2. **DD3 代码合入路径**。`render_soul/1` 改动应作为独立 PR 合入 main（从 autoservice 提出），流程应写清楚
3. **DD5-b 行为变更未说明**。从 `Chat.session_events_topic` 实时流 → `CustomerFeed` 批量投递，这是一个 UX 变更，应在计划中明确说明
4. **`customer_live` 源码修改策略**。建议保留原始订阅路径作为 fallback（配置开关），避免直接删除现有代码
5. **operator takeover demo 太弱**。Stage 1 不 port `operator_live.ex`，但应有至少一个可录屏的 operator 交互（如复用 `customer_live` 组件挂到 operator 面）

### 下一步建议

```
评审通过后:
1. Stage 0 — autoservice rebase 到 main（我们做，单独 review）
2. Task 0 — G1 live 确认。如果不过，整个计划暂停
3. DD3 的 render_soul 改动 → 独立小 PR 合入 main
4. DD1 补充 "bot 回复完成判定" 逻辑 → 更新计划
5. Task 1-9 按顺序执行，TDD
```

---

## 补充修正（2026-06-09，与同事对齐后）

### 修正 1：autoservice 与 loom 的分工

```
loom        = 客户 Web UI (React SPA, json-render, Sandpack)
autoservice = 纯后端 API 服务 + operator 业务前端 + admin 中台
```

autoservice 里的 LiveView 全是开发/测试工具，非正式前端：
- `customer_live.ex` → 开发用，正式 customer 前端是 loom
- `operator_live.ex` → 客服工作台原型（业务前端），非 admin 中台
- admin LiveViews → 中台管理界面

### 修正 2：DD5-b 不是"偏离 rev8"

rev8 §4.4 明确允许过渡路径：
> Backend E2E can run against a thin LiveView render before the SPA lands (§11)

DD5-b 保留 `customer_live.ex` 做 E2E 验证是标准做法。去掉 🔶 标记，不需要 Allen 决策。

### 修正 3：operator 是业务前端

`operator_live.ex` 属于业务前端（客服工作台产品线），不属于 admin 中台。DD6 在 Stage 1 做最小接管验证是合理的。
