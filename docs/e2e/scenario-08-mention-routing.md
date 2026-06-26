# 场景 08(执行记录):@mention 门控路由

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/10-mention-gated-routing](../scenarios/10-mention-gated-routing/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~17:21 |
| **环境** | 分支 `feat/product-gaps-f9-f12`(= main `8b673310`)· server `http://world.localhost:10042` |
| **前置 scenario** | scenario-03 + 两个工作 agent 成员(zyli-echo-1 + zyli-curl-1) |

## 前置条件(当次实际)

- session `zyli-test-1`,成员 4:zyli-echo-1(echo)、zyli-curl-1(curl)、claude-bot(cc,坏)、admin
- **ROUTING=0(无显式规则)** —— 本场即在"无路由规则、靠 @mention 直接寻址"下验门控(见下方与设计场景的差异说明)

## 角色

- **调用方**:admin · **目标**:被 @ 的特定 agent(只有它该收到)

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 发 `@zyli-echo-1 请回复1`(17:21:21) | **只有 zyli-echo-1** 回 `echo: @zyli-echo-1 请回复1`(17:21:21);zyli-curl-1 / claude-bot **无回复** | [s08-step1-mention-gating-zyli](./evidence/scenario-08/s08-step1-mention-gating-zyli.png) | ✅ |
| 2 | 发 `@zyli-curl-1 请回复2`(17:21:35) | **只有 zyli-curl-1** 回 `2`(DeepSeek,17:21:36);zyli-echo-1 / claude-bot **无回复** | (同上截图) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| 只有被 @ 成员收到 dispatch / 回复 | ✅ 每条精确路由到被 @ 的那个,另一 agent 沉默 | ✅ |
| 未被 @ 成员无越权**回复** | ✅ 未被 @ 的 echo/curl 互不串台,无越权回复 | ✅ |
| 未被 @ 成员无 dispatch(分发面单播) | ⚠️ UI 只暴露 `data-msg-id`,无 per-recipient delivered marker → "没收到 vs 收到没回" UI 层无法区分 | ⏳ 留 scenario-12 审计 |

## 发现 / 与设计场景的差异

- **门控生效**:@mention 精确选中收件人,未被 @ 的成员不收不回。**两个不同 flavor(echo / curl)互为对照**,排除"碰巧只有一个能回"的混淆。
- **机制差异(承接 scenario-04)**:设计场景 10 假设通过**路由规则**实现 mention-gating;这里 ROUTING=0(**无规则**),门控来自 **@mention 直接寻址**(无规则 = 默认只送被 @ 者)。即本场验证的是"无规则下的 mention-only"路径,而非"显式 mention 规则"路径。显式规则路径(scenarios/22 routing-crud + 添加 `{:mention}` 规则)未在本轮验证 —— 留待补。

## 遗留 / bug
- 非阻塞。建议补一条"显式添加 mention 路由规则"的验证(对照无规则的默认门控)。claude-bot 仍无回复(scenario-05 cc bug,与本场无关)。

## 证据清单
- `evidence/scenario-08/s08-step1-mention-gating-zyli.png` — zyli 视角:两条 @ 各自只回对应 agent
- `evidence/scenario-08/s08-step2-mention-confirmed.png` — observer 服务端对照:① 仅 echo 回、② 仅 curl 回,无越权;per-recipient delivered marker UI 不可见(留 scenario-12)

## 交叉引用
- 设计场景:`docs/scenarios/10-mention-gated-routing`、`22-routing-crud`

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。门控核心断言:发 @A,只有 A 回、B 沉默。需 session 内 ≥2 个能工作的 agent 做对照。 -->

> **flavor drift**:人肉记录用 echo flavor(回包 `echo: ` 前缀);当前 main 退役 echo → py(逐字回显,见 scenario-02/04)。runbook 跟随当前 main:py agent 逐字回显。

**前置(自动化)**:scenario-03/04 已自动跑;session `e2e-test-1` 内有**两个能工作的 agent 成员**做对照。
- 免凭据变体(**推荐自动化默认**):加两个 py agent(`e2e-py` + `e2e-py-2`),纯靠 py 逐字回显对照验门控(不依赖外网/凭据)。
- 跨 flavor 变体(对齐人肉记录的 echo/curl 对照):`e2e-py`(py)+ `e2e-curl`(curl/deepseek)。**curl 需先配 api_url+key,否则不回 → 断言 FAIL 属环境未就绪非门控失效**。
**入口 URL**:`http://world.localhost:10042/sessions?session=<encodeURIComponent("session://system/default/e2e-test-1")>`
**关键变量**:`ROUTING=0` —— 门控来自 @mention 直接寻址(无规则 = 默认只送被 @ 者),非显式 mention 规则。

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | @ 第一个 agent + submit | `textarea[aria-label="Message"]`(`@`→listbox→点 `@e2e-py`,补文本)+ `form.submit()` | `@e2e-py gate-a` | 只有 py 回:`text~ [data-sender-kind=agent][data-mine=false] "gate-a"`(逐字)且**该轮 agent 气泡仅 1 个新增**(py-2/curl 未回) | `s08-step1-gate-first-auto.png` |
| 2 | @ 第二个 agent + submit | `textarea[aria-label="Message"]`(`@`→listbox→点 `@e2e-py-2` 或 `@e2e-curl`)+ `form.submit()` | `@e2e-py-2 gate-b` | 只有第二个 agent 回(py-2 逐字回 `gate-b` / curl 回 DeepSeek 文本);第一个 py **本轮未新增气泡** | `s08-step2-gate-second-auto.png` |

**断言映射**:
- 「只有被 @ 成员收到 dispatch / 回复」→ step1/step2 各自「仅被 @ 者新增气泡」(用可区分标记 `gate-a`/`gate-b` 定位)。
- 「未被 @ 成员无越权回复」→ step1 py-2/curl 沉默、step2 py 沉默(气泡计数不变)。
- 「未被 @ 成员无 dispatch(分发面单播)」→ UI 只暴露 `data-msg-id` 无 per-recipient delivered marker → **UI 层不可断言**,留 scenario-12 审计(查 `invocations` 无对应 `agent.receive`)。

**清理**:无(随 session 删除清理);若建了 `e2e-py-2`/`e2e-curl` 一并删。
