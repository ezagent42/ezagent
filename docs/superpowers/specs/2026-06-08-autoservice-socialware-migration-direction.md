# Direction: AutoService → socialware 迁移(定向 + 选定下一阶段)

> **状态**:方向 spec(rev1,2026-06-08)。三段流程的第一段(**方向** → 计划 → 代码)。
> **目的**:在 ezagent 主干经历大变化(socialware 基座 + #17 cascade + arch-deepening)后,
> 重新校准 "把 AutoService 迁过来" 这件事的现状与方向,并**选定一个可建设的下一阶段**。
> **验证基线**:`origin/main` @ `e6d372ec`;本 spec 所有 "现状" 论断均经仓库核实(见 §1)。
> **不修改 `ARCHITECTURE.md`**(Allen 维护);本 spec 是团队内部方向文档,等 Allen review。

---

## TL;DR(先读这段拿全貌,再下钻细节)

- **背景**:ezagent 主干这周大变(socialware 基座 + #17 credential cascade + arch-deepening 重构),需要重新校准"迁移 AutoService"这件事。
- **方向(不变)**:把 AutoService 的 CS 产品迁过来。**socialware 是 Allen 加的新基座**(domain 层、declare-not-code),**不是新目标**;迁移 = **在 socialware 上重写**,`origin/autoservice` 分支只当**内容/参考**,不基于它(Allen rev8)。
- **现在在哪**:基座(`Turn` / `:surface` / settlement / customer-feed / #17 cascade / 多租户持久层)**已在 `main` 上跑且测绿**;cinnox 产品内容(souls/skills/KB + operator 控制台)**只在 `origin/autoservice`**。
- **下一阶段(本 spec 选定)**:**垂直跑通 E2E** —— 一条 cinnox 流在 socialware 上端到端跑通、能录视频,是调优 / admin / 多租户管理面的**前置门**。
- **头号风险(G1)**:socialware `Turn` 经 `@mention` 把回复委派给 cc-worker → E1b 的 cc-worker chat-reply 生命周期堵点在 E2E 关键路径上。
- **要 Allen 定**:① 方向 OK 否;② G1 归属(main 上是否已解决)。

下文:§1 现状地图 · §2 方向原则 · §3 选定阶段 · §4 开放项处置 · §5 风险 · §7 本轮验证记录。

---

## 1. 现状地图(已核实)

| 线 | 层 / 位置 | 内容 | 相对 main |
|---|---|---|---|
| **main = socialware 基座** | domain 层 `apps/ezagent_domain_socialware` | `Behavior.Turn` + `:turns`、`:surface`(immutable 版本 + approved pointer)、settlement(`turn_id` keyed、`:committed` last)、customer-feed(React + json-render SPA)、`Ezagent.Message.visibility`、#17 config/credential cascade、**多租户持久层**(每表 `workspace_uri NOT NULL` + `[:layer, :workspace_uri, :subject_uri, :key]` 索引) | — |
| **origin/autoservice**(= autoservice-dev) | plugin 层 `apps/ezagent_plugin_autoservice` | cinnox souls/skills/KB(37 文件)、`operator_live.ex`(249 LOC,**LiveView operator 控制台**)、`customer_live.ex`(126 LOC,LiveView)、`customer_session.ex` | **68 落后 / 22 领先**,rev8 标注 **"do NOT base on"** |
| **我们的 data-access 探索** | `explore/agent-data-access-rebased`(已 rebase 到 main) | E1/E2 结论:cc-agent 经外部 MCP 读真数据 ✅、claude honor `tools/list_changed` 运行时长工具 ✅;harness + 终端回放视频证据 | 4 commit on main |

**核实要点**:
- cinnox / autoservice plugin **只在 `origin/autoservice`**,main 上 0 文件。
- socialware **无 cinnox 内容**(基座,非产品)。
- socialware 客户面是 **React SPA**;operator 面**复用核心 `SessionView` LiveView**,无专门控制台。
- 多租户**隔离/存储层已在 main 上做完**(workspace_uri 全表),不是从零建。

## 2. 方向与原则(不变)

1. **终点不变**:把 AutoService 的 CS 产品(cinnox vertical + operator 控制台 + 多租户)迁过来。
2. **socialware = 基座**(Allen rev8):迁移 = **在 socialware 上重写**,`origin/autoservice` 仅当**内容/参考**,**不基于其分支**。
3. **vertical = declare-not-code**:base 已建,vertical 作者只 declare(souls/skills/KB → config object + pointer),不写 core。
4. **E2E target = 隔离的 fresh-seeded disposable stack**(socialware #595),**不碰 shared dev/prod node**。
5. **data-access 探索的结论复用、代码作废**:E1/E2 是 claude 协议层事实,作为后续 vertical 的能力输入保留;structuredContent 补丁已证伪(§4)。

## 3. 选定的下一阶段:垂直跑通 E2E

**目标**:一个 cinnox CS vertical 在 socialware 基座上**端到端跑通,能录视频**。这是调优 / admin / 多租户管理面的**前置门**。

### 3.1 范围(in)
- **内容**:迁**一条最小但真实的 cinnox 流**(候选 `customer-type-clarifier` 或 `general-inquiry-flow`)到 socialware vertical(souls/skills/KB declare)。先证 thesis,全量内容后续。
- **Turn 编排**:customer → bot turn(`:auto`)→ compose(`:customer_visible`)→ settle;**含一次 operator takeover**(claim → `:operator_only` → approve → settle)。
- **UI**:补全 socialware customer React SPA 到能显示该 flow 的 feed;**operator 侧用核心 `SessionView` LiveView**(本阶段**不**新建 operator 控制台)。
- **E2E**:隔离 seeded stack 上跑通 + 录屏。

### 3.2 范围(out,显式 defer)
- 全量 cinnox 内容迁移
- 多租户管理面 + 富 admin/operator 控制台 → **下一阶段**
- 数据接入(E1/E2 外部-MCP 读真数据)→ **下一阶段**;本阶段 vertical 用 fixture/话术即可跑通,**不依赖**真实库存数据
- structuredContent 补丁 + live-claude smoke test → **独立小事**(§4)
- 调优

### 3.3 验收
隔离 stack 上:customer 发问 → bot 经 `Turn` 回复(`:customer_visible`)→ operator 接管改写 → settle → customer feed 显示已批准版本;**全程录屏**。

## 4. 开放项处置(不丢)

- **structuredContent 补丁**:已证伪(在 main 上让 `orchestrator_mcp_e2e` + `scenario_33` 共 6 个测试转红;对照组去掉补丁 0 红)。根因:main 契约 = 单值 tool 结果是**裸 URI 字符串**,内部消费者(`uri_to_string` / `KindSnapshot.get/1` / `URI.new!`)依赖裸串;我们的 `as_struct_content` 一刀切包成 `%{"result" => …}` 砸了它们。**处置:从 rebased 分支剔除。**
- **"live claude 是否仍拒裸串 structuredContent"**:这是 **claude client 侧**行为(repo 内无该错误串、bridge 不校验、tool 无 outputSchema),只有真实 claude 能复现。留作**独立小问题**,需要时用隔离协议 smoke 探针(扩展 E1/E2 harness:两 tool,一裸串一 record,`claude -p --mcp-config` 观察)回答。**本阶段不阻塞。**
- **数据接入(E1/E2)**:作为下阶段输入保留。
- **worker 生命周期(风险 #1)**:E1b 的 cc-worker chat-reply 堵点(deliver timeout / channel-join)。**本阶段第一个要验证**:确认 socialware `Turn` 的 subtask worker 是 native Behavior 还是 cc-agent;若仍走 cc-worker,堵点回归 → 提 Allen。

## 5. 风险

1. **cc-worker chat-reply 生命周期在 E2E 关键路径上(已确认,本轮验证 §7.2)** —— `Turn` 本身是 native 编排,
   但回复生成委派给 session 成员 worker(CS 场景 = cc-agent);E1b 的 deliver-timeout / channel-join 堵点回归风险高,
   **是 vertical 跑通 E2E 的头号技术风险**,计划阶段第一件事就要在隔离 stack 上压这条接缝。
2. **customer React SPA 完成度** —— 是真实现(§7.3)但对完整 CS flow 的覆盖未知;同事反馈 UI 有缺失/bug;
   E2E 录视频前需上手核实并补全。
3. **cinnox 内容 → socialware 的映射未设计** —— souls/skills/KB 如何 declare 成 config object/pointer + skill-package,需在计划阶段定。

## 6. 下一步

本 spec 经 Allen review 方向后,进入第二段(`writing-plans`)对 §3 选定阶段出详细实施计划,再进第三段实施。

## 7. 本轮验证记录(2026-06-08,大胆验证 + 记录 gap)

> 在共享 deps 环境(`deps -> .poc-shared-deps`,与 poc-phase-2 同 `mix.lock`)+ 本地 `_build` 上跑,经隔离分支
> `explore/agent-data-access-rebased`(off `origin/main` @ `e6d372ec`)。

1. **rebase + 补丁处置(已闭环)**:4 个 data-access commit 干净 rebase 到 main(git 自动跟随 `mcp_server.ex` 的
   app-rename)。structuredContent 补丁经对照实验**证伪并剔除**(带补丁 6 红 / 去补丁 0 红,见 §4 + 探索笔记 E1b)。
2. **socialware 基座健康 + worker 形态确认**:`mix test apps/ezagent_domain_socialware/test` → **52 tests, 0 failures**。
   读 `behavior/turn.ex`(499 LOC,`use Ezagent.Lifecycle, state_slice: :turns`):`handle_dispatch` 经
   `dispatch_subtask` 发 `{:dispatch, Cmd.new(self_uri, :send, %{message: …, mentions: [mention]})}` —— **subtask 靠
   chat @mention 委派给被点名的 session 成员**;`handle_compose` 把 worker 经 `deliver` 交回的 `card_ref` 聚合成 chat
   消息 + 可选 page version。**结论**:Turn 状态机用注入 card_ref 的 test double 测绿,**真实 CS 的 leaf 回复仍由
   cc-agent worker 经 chat 投递产生 → E1b 接缝在关键路径上**(→ 风险 #1)。
3. **customer SPA 是真实现**:`assets/js/customer_app.js`(78 LOC)用 Phoenix `Socket` 接 `socialware:customer:<uri>`
   channel + `json_render` + Sandpack 渲染 —— 非 stub;完整 flow 覆盖度待上手核实。
4. **operator 控制台**:socialware 无,复用核心 `SessionView` —— 符合 rev8 设计,defer 到 admin 阶段。
