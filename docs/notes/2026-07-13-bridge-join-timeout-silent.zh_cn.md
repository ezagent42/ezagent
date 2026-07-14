# bridge join 超时了,但没有任何人被告知

**状态:** 待处理。独立 bug,独立 PR。**极可能是本周「@orchestrator 不回话」的一条独立根因。**

**归属:** `ezagent_domain_agent`(`TransportReadiness`),**不是** `ezagent_domain_pty`。

---

## 症状

一个 agent 的进程**正确启动了**,但它的 esr-bridge **永远 JOIN 不上**(卡在登录提示、卡在
未知对话框、凭证不对……)。这个 agent 从此:

- 永远 `:not_ready`
- 所有发给它的消息进 DLQ
- **没有任何错误浮现给任何人**

它就那么挂着。运维不知道,创建者不知道,UI 上看不出来。

## 这不是启动器的问题(Allen,2026-07-13)

> 「这个按道理不属于 agent 启动器(pty/py 这些)的问题 —— 正确启动后启动器的任务就完成了,
> 而是 bridge join 不上没有退出机制的问题。正确的做法应该是 bridge 在尝试连接一段时间后
> 超时,触发 bridge 报错,再由创建者检查后处理。」

**这个判断是对的,而且它纠正了我的一个分层错误。**

我原本想让 PTY 熔断器去抓这个僵尸 —— 把 `healthy_after_ms` 对齐到 bridge 的 30s join
超时,理由是「更短的窗口会在 bridge 还没 JOIN 时就宣布健康」。

那是**把 bridge 的语义偷渡进了 PTY 层**。进程启动器只回答一个问题:**进程起来了吗?**
Agent 能不能用,是 bridge 的事。一个数字试图同时回答两个层的两个问题,结果两个都答不好。

(已修正:`RespawnPolicy.@default_healthy_after_ms` 的理由改写为纯粹的进程稳定性,不再引用
transport-join。值仍是 30s,但**理由对了**,而且从此可以独立于任何 bridge 超时自由调整。)

## 但 Allen 描述的那个机制,代码里缺了一半

他说「bridge 超时 → **触发 bridge 报错** → 创建者检查后处理」。

**前两步存在。第三步不存在。**

| 环节 | 现状 |
|---|---|
| bridge 尝试连接 | ✅ `TransportReadiness.require_transport_join/2`(默认 30s) |
| 超时触发 | ✅ `TransportReadinessListener` 的 `{:transport_join_timeout, …}` → `timeout_generation/2` |
| **报错** | ❌ **`transport_readiness.ex` 里零 telemetry、零 Logger、零通知** |
| 创建者得知 | ❌ **无从得知** |

超时之后只做两件事(`fail_current_generation_locked/3` → `ReadyTransition.mark_failed_locked/1`):

1. 排空 `PendingDelivery`,把积压消息投进 DLQ
2. `ReadyGate.mark_failed/1` —— 把 ReadyGate 翻成 `:failed`

**然后就没有然后了。** 没有 telemetry、没有 Logger、没有通知。而且**没有任何 UI /
notification 消费 `ReadyGate` 的 `:failed` 状态** —— 它只是个内部标志。

这正是 `Ezagent.Agent.CredentialPrecondition` 的 moduledoc 亲口写下的症状:

> "`esr-bridge` never joins, `require_transport_join/1` never resolves, and the agent's
> ReadyGate sits at `:not_ready` forever — the "@orchestrator never replies" symptom,
> **with no error anywhere**."

## 为什么这很要紧

**这跟 #1294 的 `--continue` 根因完全无关**,但它是**同一类漏洞的另一个形态**:

| | #1294(已修) | 本 bug |
|---|---|---|
| 现象 | 子进程 37ms 就死,无限重生 | 子进程活得好好的,但永远连不上 |
| 谁发现 | 日志刷屏(933 次/2h) | **没人发现** |
| 归属 | PTY 启动器 | bridge |

`--continue` 那个至少还**吵**。这个是**彻底静默的** —— 它更危险。

而且:**canary 上 6 个 cc agent 无一有凭证**。凭证缺失 → claude 起来但 bridge 连不上 →
正是这个静默失败的**触发条件**。所以本周「agent 真回话」跑不通,**很可能有一部分就是它**。

## 修法(建议)

`timeout_generation/2` 判定 join 失败后,除了 `mark_failed`,还应该:

1. **`Logger.error`** —— 至少让运维在日志里能搜到
2. **telemetry** —— `[:ezagent, :agent, :transport_join_timeout]`,带 `agent_uri` + 超时值
3. **通知创建者** —— 复用已有的 `Ezagent.Agent.CredentialNotifier` 那条链路(它已经在做
   「auth 失败 → 解析 owner → 通知」),把 bridge join 超时也接进去
4. **UI 可见** —— agent 列表 / 详情页要能显示 `:failed`,而不是让它停在一个看不见的
   `:not_ready`

第 3 条最有价值:`CredentialNotifier` **已经**订阅了 `pty:auth_failed` 并能解析出 agent 的
owner。bridge join 超时应该走同一条路 —— **创建者是那个能修它的人**(这也正是 Allen 对
「谁有权恢复 agent」的答案)。

## 范围

- **本 PR 不做。** 不同 app、不同根因、独立可测、独立取证。
- 需要独立的 canary 实证:让一个 agent 的 bridge 故意连不上,确认超时后**确实**有信号浮现。

---

**相关:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.zh_cn.md` — #1294 的根因(是 `--continue`,不是认证)
- `docs/notes/2026-07-13-agent-creator-pty-authority-gap.zh_cn.md` — 创建者进不了自己 agent 的 PTY(operator 恢复杠杆的前提)
