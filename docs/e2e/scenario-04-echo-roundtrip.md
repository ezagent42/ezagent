# 场景 04(执行记录):echo agent 往返

| 字段 | 值 |
|---|---|
| **状态** | ⚠️ PASS-with-gaps(echo 往返通过;路由 divergence + DLQ 待审计) |
| **对应设计场景** | [scenarios/08-4agent-comprehensive](../scenarios/08-4agent-comprehensive/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~16:21 |
| **环境** | 分支 `feat/product-gaps-f9-f12` · commit `913e2ba0` · server `http://world.localhost:10042` |
| **前置 scenario** | scenario-03 ✅(session `zyli-test-1` + `zyli-echo-1` 在线) |

## 前置条件(当次实际)

- session `session://system/default/zyli-test-1`,成员 `zyli-echo-1`(在线)+ admin
- **ROUTING = 0 条规则**(关键变量,见下方发现)

> 2026-07-02 当前 World UI 备注:在 `work/world-ui-user-surface-main-0702` 上重跑 mention roundtrip 时,`py_default` UI/DOM 显示 online,但 receive 失败 `reason=:not_alive`,未产生回显。新的执行记录见 [`world-scenario-04-agent-roundtrip.md`](./world-scenario-04-agent-roundtrip.md)。

## 角色

- **调用方**:admin · **目标**:`entity://system/agent/zyli-echo-1`

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 输入框发 `hello echo`(**无 @mention**) | 消息上屏(Admin 16:20:44),但 **echo 无回复** —— 因 ROUTING=0,无规则路由该消息到成员 | [s04-step1-echo-roundtrip-zyli](./evidence/scenario-04/s04-step1-echo-roundtrip-zyli.png) | ⚠️ 见发现 |
| 2 | 发 `@zyli-echo-1 hello`(**有 @mention**) | 消息上屏(Admin 16:20:54);**echo 回包** `echo: @zyli-echo-1 hello`(zyli-echo-1 16:20:54)—— @mention 直接寻址,绕过路由规则,echo 原样回显 | (同上截图) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| echo agent 收到并 echo 回 | @mention 路径:收到并原样回显 `echo: @zyli-echo-1 hello` | ✅ |
| LV chat 显示去/回消息 | 3 条全部上屏(2 admin + 1 echo) | ✅ |
| (设计 09 假设)默认 `always → $session_members` 规则使**无 @** 消息也送达 | ❌ 实测 ROUTING=0,**无默认 always 规则**,无 @ 消息不送达 | ❌ **divergence** |

## 发现(重要)

1. **echo 往返本身 PASS** —— agent 收到 + 回包 + 内容正确(echo 原样回显),send **未被吞**(老 `no_such_actor`/send-swallow blocker 未复现)。
2. **路由 divergence**:新建 session **没有**设计场景 09 假设的默认 `always → $session_members` 规则(ROUTING=0)。后果:**只有 @mention 能把消息送达 agent**,普通消息无人接。
   - 这其实**提前演示了 scenario-08(mention-gated routing)**:无规则时 = mention-only。
   - **待澄清**:默认是否本就该无 always 规则(产品决策变更),还是 seed/创建流程漏建默认规则?→ 标记交 Allen,勿在执行层下结论。
3. **不变式待查**:第1条无 @、无路由的消息 —— 是进了 DLQ(unroutable + telemetry,符合"没人接收要有人知道"),还是静默丢弃?UI 层看不出,**留 scenario-12 查 `invocations`/DLQ 表**。

## 遗留 / bug
- 见上"发现 2/3":路由默认规则 divergence + 无路由消息的 DLQ 归宿待审计核对。非阻塞,echo 往返主目标已达成。

## 证据清单
- `evidence/scenario-04/s04-step1-echo-roundtrip-zyli.png` — zyli 视角:两条发送 + echo 回显 + ROUTING=0
- `evidence/scenario-04/s04-step2-echo-confirmed.png` — observer 服务端 transcript 对照(3 条持久化:`hello echo` / `@zyli-echo-1 hello` / `echo: @zyli-echo-1 hello`;ROUTING=0;DOM 无 unroutable/DLQ 痕迹,UI 层无法判 DLQ 归宿)

## 交叉引用
- 设计场景:`docs/scenarios/08-4agent-comprehensive`

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**2026-06-26 agent-browser 实地跑通**。聊天 mention 必须用真实键盘 autocomplete(§8.2),不能 native-setter 硬塞。回显 agent = seeded py_default(逐字)。 -->

> **flavor drift + 实地修正**:人肉记录用 echo flavor(`echo:` 前缀);当前 main 退役 echo→py,`echo.py` **逐字回显(无前缀)**。**实地核实**:零配置新建的 `native`/`np`/`hello_builder` **不回显**;会回显的是 seeded **`py_default`**(py+echo.py)。故往返用 `py_default`(scenario-03 已加为成员)。payload 用可区分标记(`ping-43`)。**关键**:@mention 必须真实键盘走 autocomplete,native-setter 设 textarea 会让 mention 失效 → 发成普通文本 → 无人回(已踩坑)。

**前置(自动化)**:scenario-03 已自动跑(session `e2e-test-1`);**额外把 seeded `py_default` 加为成员**(`entity://system/agent/py_default`,逐字回显的 agent)。停在该 session 会话页。
**入口 URL**:`http://world.localhost:10042/sessions?session=<encodeURIComponent("session://system/default/e2e-test-1")>`
**关键变量**:`ROUTING=0`(无显式路由规则)—— 决定 step1 行为。

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | 真键入无 @ + Enter | `keyboard type` 进 `textarea[aria-label="Message"]` | `hello-noroute` | 用户气泡上屏;**且 1.5s 后无新 agent 气泡** `count [data-sender-kind=agent][data-mine=false] = 0`(ROUTING=0,无 @ 不送达) | `s04-step1-no-mention-no-reply-auto.png` |
| 2 | 真键入 `@py` 触发并过滤候选 | `click textarea` → `keyboard type '@py'` | `@py` | `visible ul[role="listbox"]` 且仅含 `@py_default`(**实地✅**) | — |
| 3 | click 候选(真实点击插 mention) | `click 'ul[role="listbox"] button'` | — | textarea 变 `@py_default `(**实地✅**) | — |
| 4 | 真键入 payload + 发送 | `keyboard type ' ping-43'` → `press Enter` | ` ping-43` | py_default 回包 `visible [data-sender-kind=agent][data-mine=false]` + `text~ [data-sender-kind=agent][data-mine=false] "ping-43"`(**逐字回显,实地✅** 回包 `@py_default  ping-43`) | `s04-step4-py-reply-auto.png` ✅ |

**断言映射**:
- 「agent 收到并回」→ step4 agent 气泡含 `ping-43`(py 逐字回显;**非** `echo:` 前缀)。**2026-06-26 实地坐实**。
- 「LV chat 显示去/回消息」→ step1 用户气泡 + step4 agent 气泡均上屏。
- 「(设计 09)默认 always 规则使无 @ 也送达」→ **step1 断言「无 agent 气泡」即坐实 divergence**(实测 ROUTING=0 无 always 规则,与设计 09 不一致)。**这是把人肉记录里的 divergence 发现转成机器可回归的守卫**:若将来补了默认规则,step1 断言会翻(需同步更新)。
- 「无路由消息的 DLQ 归宿」→ 非 UI 断言,留 scenario-12 审计。

**清理**:无(消息进 transcript,随 session 删除一并清理)。
