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
