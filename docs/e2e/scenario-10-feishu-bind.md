# 场景 10(执行记录):绑定 Feishu chat↔session(出站)

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/12-feishu-bind-outbound](../scenarios/12-feishu-bind-outbound/scenario.zh_cn.md) |
| **验证面** | Feishu 聊天 + world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 上午(F12 工作时跑,~11:47;**rebase 前的 f9-f12 代码**) |
| **环境** | 分支 `feat/product-gaps-f9-f12`(F9 绑群 UI 当时已交付,现已并入 main)· Feishu **WSS 长连接** sidecar |
| **前置 scenario** | scenario-03(session 概念就绪)+ Feishu sidecar WSS 已连(本轮实测确认行 889/890/1001) |

## 前置条件(当次实际)

- **Feishu sidecar = WSS 长连接**(本轮日志确认:`credentials loaded app_id=cli_aa9ebbe7457…` / `sidecar started` / `event-dispatch is ready` / `WSS connected`)—— **不需要公网 webhook**(纠正:之前误以为入站要公网 URL)
- 飞书群 **"esr-test"**,bot **esr-test-bot**(app_id `cli_aa9ebbe745789bcb`)在群内
- 绑定:飞书群 ↔ `session://system/default/feishu-bing`(经 F9 绑群 UI;world UI 显示该 session,成员 r3-echo-pty-1 + admin)

## 角色

- **调用方**:admin(绑定侧)· session 成员 agent `r3-echo-pty-1`(出站侧)
- **目标**:`Behavior.ExternalMirror :bind` + 出站镜像

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 经 F9 world UI 把飞书群绑到 `session://system/default/feishu-bing` | world UI `feishu-bing` session 存在(MEMBERS=2:r3-echo-pty-1 + admin);飞书群里出现绑定行 `[session://system/default/feishu-bing \| entity://system/user/admin]` | [s10-world-session-feishu-bing](./evidence/scenario-10/s10-world-session-feishu-bing.png) | ✅ |
| 2 | session 内 agent 产出回复(r3-echo-pty-1 的 echo) | **该回复镜像到飞书群** —— 飞书群显示 `[session://system/default/feishu-bing \| entity://system/agent/r3-echo-pty-1] echo: @r3-echo-pty-1 …`(11:47 / 11:48 两条) | [s10-feishu-group-outbound-mirror](./evidence/scenario-10/s10-feishu-group-outbound-mirror.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| `:bind` 持久化绑定 | ✅ feishu-bing 绑定存在(基线即可见,external-mirror) | ✅ |
| Worker 订阅 publisher,session 出站镜像到 Feishu chat | ✅ session 内 echo 回复出现在飞书群,带 `[session\|sender]` 前缀 | ✅ |

## 遗留 / bug
- 非阻塞。机制说明见 `docs/together/2026-06-25/notes/f12-feishu-mention-coordination.md`(F12 终结:能力靠 text-grep + F9 绑群 + 默认路由,无需新 mention 代码)。

## 证据清单
- `evidence/scenario-10/s10-world-session-feishu-bing.png` — world UI feishu-bing session(出站源)
- `evidence/scenario-10/s10-feishu-group-outbound-mirror.png` — 飞书群收到 session 的 echo 回复(出站镜像)

## 交叉引用
- 设计场景:`docs/scenarios/12-feishu-bind-outbound`、`23-external-mirror-resubscribe`

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**混合验证**:world UI 侧(绑定 + 出站镜像)可 agent-browser 自动验;飞书群侧消息**非 ezagent UI、不可用 agent-browser**,标为带外/手工。 -->

**前置(自动化)**:**Feishu sidecar WSS 已连**(日志 `sidecar started`/`WSS connected`,需真实 Feishu app 凭据)+ 飞书群已经 F9 绑群 UI 绑到 `session://system/default/feishu-bing`(成员含一个 echo agent 如 `r3-echo-pty-1`)。**sidecar 未连 → 绑定/出站不成立,属环境未就绪非回归。**
**入口 URL**:`http://world.localhost:10042/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Ffeishu-bing`

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | navigate(feishu-bing session 详情) | — | — | `visible [data-world-component=conversation]` | `s10-step1-feishu-bing-open-auto.png` |
| 2 | assert(绑定 session 存在 + 成员) | `li[data-kind][data-online]` | — | `attr li[data-kind=agent] data-online=true`(echo agent 在线) | (同步1) |
| 3 | fill(在 session 内发消息触发 agent 回复)+ 发送 | `textarea[aria-label="Message"]` → `button[type="submit"]` | `@r3-echo-pty-1 hello` | `text~ [data-sender-kind=agent] "echo:"`(出站源:session 内 echo 回复) | `s10-step3-outbound-source-auto.png` |
| 4 | **带外(手工)**:看飞书群是否收到镜像 | — | — | 飞书群出现 `[session://...feishu-bing \| entity://...r3-echo-pty-1] echo: …` —— **agent-browser 不可验**,手工/截图 | `s10-step4-feishu-mirror-manual.png` |

**断言映射**:
- 「`:bind` 持久化绑定」→ step1/2(feishu-bing session + 成员可见 = 绑定生效)。
- 「session 出站镜像到 Feishu chat」→ step3(world 侧出站源)+ step4(**飞书侧带外确认**,自动化不覆盖)。

**清理**:无(用基线 feishu-bing 绑定)。
