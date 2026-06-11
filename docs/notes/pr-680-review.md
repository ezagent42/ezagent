# PR #680 评估

> 评估日期: 2026-06-08
> PR: https://github.com/ezagent42/ezagent/pull/680
> 标题: explore(autoservice→socialware): data-access rebase 到 main + 补丁证伪剔除 + 迁移方向 spec

---

## 一、最根本的问题：目标分支应为 `autoservice`，不是 `main`

```
ezagent main = 地基（socialware 基座 + #17 cascade + arch-deepening）
              所有对 core/domain 的修改都应从 autoservice 分支提出

autoservice   = 基于 ezagent 的项目实施分支
               需要 main 的内容 → rebase main 进来（不是往 main 合）
               任何 core/domain 修改需求 → 从 autoservice 提 PR，目标 = autoservice
               任何方案、文档、实施 → 合入 autoservice 分支
```

PR 680 以 `main` 为目标分支。所有 autoservice 的方案、实施、探索——无论是文档还是代码——都应该合入 `autoservice` 分支。需要同步 main 上的地基更新时，通过 `rebase main` 完成。

---

## 二、PR 680 实现了什么？

**没有实施任何东西。** 0 行产品代码。

```
10 files, +654 lines, 0 deletions
0 个 .ex 文件被触碰
0 行 Elixir 代码
0 行 autoservice 插件代码
```

| 文件 | 内容 | 类型 |
|---|---|---|
| `docs/notes/2026-06-03-agent-data-access-exploration.md` (171行) | cc-agent 通过外部 MCP 读数据的探索笔记 | 文档 |
| `docs/notes/evidence/agent-data-access/*.gif/*.webm` | E1/E2 实验录屏 | 素材 |
| `docs/notes/evidence/agent-data-access/inventory_mcp.py` (221行) | **完全不经 ezagent** 的 Python MCP server | 实验 harness |
| `docs/notes/evidence/agent-data-access/term-replay.js` (140行) | 终端回放脚本 | 工具 |
| `docs/superpowers/specs/2026-06-08-autoservice-socialware-migration-direction.md` (101行) | 迁移方向 spec | 方向文档 |

**PR 标题叫 "explore(autoservice→socialware)"，但并没有写 autoservice 代码或 socialware 代码。**

---

## 三、是否基于 ezagent 已有能力最小化修改？

PR 680 对 ezagent 的修改需求 = **0**。

它讨论了三个潜在修改点，但逐一看：

| 需求 | PR 680 的处理 | 是否必要？ |
|---|---|---|
| **structuredContent 补丁** | 自己证明了这个补丁是错的（6红→0红），已剔除 | ❌ 不必要——PR 已自证 |
| **运行中 agent 不重启看到新工具** | E2 实验证明 claude MCP client honor `tools/list_changed`，产品侧用外部 MCP server 自行管理，完全绕开 ezagent 的 `reconfigure` | ❌ 不必须——不需要改 ezagent |
| **G1: cc-worker chat-reply 生命周期** | 指出 deliver-timeout / channel-join 堵点，但只是提需求、未给出修改方案 | 待定——但 PR 没有给出任何具体方案 |

**E1/E2 实验本身完全独立于 ezagent**：
- E1: `claude -p --mcp-config inventory.mcp.json` —— 命令行直接跑，不经 ezagent
- E2: 同上，加了运行时长工具
- E1b: 尝试挂到 ezagent session worker → **失败**（worker 不处理 chat）

E1/E2 证明的是 claude 的 MCP 协议能力（已知事实，ezagent 的 8-tool 模式就是这个原理），不是 ezagent/autoservice 的新能力。E1b 是已知 gap 的复现。

---

## 四、是否基于 autoservice soul/skill/kb 数据架构方案？

**否。** PR 680 完全没有涉及 autoservice 的三层架构设计。

迁移方向 spec §5 风险 3 自己承认：
> cinnox 内容 → socialware 的映射未设计 —— souls/skills/KB 如何 declare 成 config object/pointer + skill-package，需在计划阶段定。

这等于承认了整个 PR 没有基于 soul/skill/kb 架构。

---

## 五、说清楚 customer/operator/admin 的哪部分了吗？

**没有。** 方向 spec 只说"垂直跑通 E2E——一条 cinnox 流"，但完全没有界定这覆盖哪个面的哪些功能。

参照 `docs/notes/socialware-readiness-and-migration-analysis.md` 中完成的覆盖度分析：

| 面 | autoservice 现有功能 | PR 680 是否提及 | 结论 |
|---|---|---|---|
| Customer | `customer_live.ex` (126行) —— 客户聊天 UI | ❌ | 未提及 |
| Customer | `customer_session.ex` (386行) —— 客户 session 供应和双相位代理 | ❌ | 未提及 |
| Customer | fast agent (DeepSeek) + slow agent (cc) 编排 | ❌ | 未提及 |
| Customer | 路由规则 (customer→[fast, slow]) | ❌ | 未提及 |
| Operator | `operator_live.ex` (249行) —— 完整操作员控制台 | ❌ | 提了一句 "operator takeover" 但没有对接方案 |
| Operator | `turn.claim → :awaiting_human → settle` | ✅ 提到 | 只是概念层级，没有实施计划 |
| Admin | Bot 创建器、模板编辑器、Diff 视图、Soul Slot 编辑器、KB Curator | ❌ | 全部未提及 |

方向 spec §3.2 "范围 (out, 显式 defer)" 将 operator 控制台列为 defer：
> operator 侧用核心 SessionView LiveView(本阶段不新建 operator 控制台)

但回避了核心问题：**autoservice 的 operator_live.ex 已经有 249 行完整的操作员控制台，socialware 没有等价物。到底是 port 它、替换它、还是放弃它？PR 没有回答。**

---

## 六、E1/E2 实验跟 autoservice 的关系

| 实验 | 实质 | 跟 ezagent/autoservice 的关系 |
|---|---|---|
| E1 | `claude -p --mcp-config` 命令行直接跑 | **完全无关**——不需要启动 ezagent |
| E2 | 同上，加运行时工具 | **完全无关**——测的是 claude MCP client 行为 |
| E1b | 将外部 MCP 挂到 session worker | **失败**——worker 不处理 chat（已知 gap 复发） |

PR 680 实际证明的：
1. ✅ claude MCP client 能调外部 tool —— 已知（ezagent 8-tool 模式就是这个原理）
2. ✅ claude MCP client honor `tools/list_changed` —— 已知能力
3. ❌ 挂了外部 MCP 的 cc-worker 在 session 里不工作 —— E1b 失败（已知 bug）

**对 autoservice 项目没有新增任何可用能力。**

---

## 七、下一步建议

### 短期（本周）

1. **PR 680 改目标分支为 `autoservice`**。方向讨论文档应合入项目实施分支，而非 main。

2. **补一份具体的范围文档**，明确回答以下问题：
   - 选定迁移的"一条 cinnox 流"具体是哪个？覆盖 customer 面哪个功能？
   - 这条流是否需要 fast+slow 双相位？如果不覆盖，是否意味着 autoservice 双相位模型在 socialware 上被主动放弃？
   - `operator_live.ex` 的 249 行代码如何处理——port 进 socialware 垂直插件、保留为通用 LiveView 组件、还是放弃？
   - soul/skill/kb 如何映射到 socialware 的 config object/pointer + SessionTemplate/AgentTemplate？
   - 具体要实施 customer/operator/admin 的哪个面，按优先级排序

3. **不要继续在"探索/方向"阶段追加新的实验和文档**。当前已经有：
   - autoservice-migration-eval（7 篇子文档，5 月 26 日）
   - autoservice-merge-plan（5 月 26 日）
   - socialware-readiness-and-migration-analysis（今天）
   - PR 680 的方向 spec + 探索笔记（今天）

   方向已经足够清楚了。下一步应该进实施，而非继续讨论方向。

### 中期（本周～下周）

4. **先验证 G1（cc-worker chat-reply 生命周期）**。在隔离 fresh-seeded stack 上压一次 cc-worker 接缝，确认堵点在 `main` 上的实际现状。如果这个堵点确实存在且没有 workaround，整个 vertical E2E 都无法推进——这才是真正的 blocker，优先级高于任何方向文档。

5. **合并 `feat/socialware-config-consume` (PR #607) 到 main**。P6 消费侧（ConfigProjection + CascadeRepoint）未合并是自进化闭环的阻断项。

6. **以 autoservice 分支为基础，rebase main（e6d372ec）**。socialware 基座 + #17 cascade + arch-deepening 已在 main 上，autoservice 落后 68 个 commit。

### PR 680 的处理

```
PR 680 应改为:
- base: main → autoservice
- 保留: migration-direction spec（作为方向讨论的起点，改目标分支后合入 autoservice）
- 可选保留: data-access 探索笔记（记录 E1/E2 发现，作为技术参考）
- 不建议: GIF/webm/Python harness —— 实验素材放在 notes/ 增加仓库体积，不增加实施价值
```
