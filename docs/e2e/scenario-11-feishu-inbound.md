# 场景 11(执行记录):Feishu 入站到达 → 路由到 agent

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/13-feishu-inbound-routing](../scenarios/13-feishu-inbound-routing/scenario.zh_cn.md) |
| **验证面** | Feishu 聊天 + world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 上午(F12 工作时跑,11:47 / 11:48;rebase 前 f9-f12 代码) |
| **环境** | 分支 `feat/product-gaps-f9-f12`(现已并入 main)· Feishu **WSS 长连接** sidecar |
| **前置 scenario** | scenario-10 ✅(feishu-bing 绑定 + 出站)+ 成员 r3-echo-pty-1(echo) |

## 前置条件(当次实际)

- feishu-bing 绑定存在;绑定 session 成员 `r3-echo-pty-1`(echo)
- **入站走 WSS 长连接**(sidecar 主动连飞书 Open API)—— **纠正:不需要公网 webhook URL**(设计 stub 旧假设)
- 入站 @ 用 **text-grep**(操作员在飞书打字面 `@r3-echo-pty-1`;agent 在飞书无原生身份,见 F12 note)

## 角色

- **调用方**:在飞书群发消息的 Feishu 用户(zyli/李震宇)
- **目标**:text-grep 解析出的 agent `r3-echo-pty-1`
- **外部系统**:Feishu Open API → **WSS** → sidecar → ezagent

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 在飞书群 "esr-test" 发 `@r3-echo-pty-1 你是谁,请回复`(11:47) | 消息经 WSS 入站到达 ezagent | [s11-feishu-group-inbound-at-agent](./evidence/scenario-11/s11-feishu-group-inbound-at-agent.png) | ✅ |
| 2 | ezagent 把入站消息落到绑定 session `feishu-bing` | **world UI feishu-bing 显示该入站消息** `@r3-echo-pty-1 你是谁,请回复`(11:47:06) | [s11-world-session-received](./evidence/scenario-11/s11-world-session-received.png) | ✅ |
| 3 | text-grep 解析 @r3-echo-pty-1 → 路由到该 agent → echo 处理 | r3-echo-pty-1 回 `echo: @r3-echo-pty-1 你是谁,请回复`(world UI + 飞书群均见) | (上两图) | ✅ |
| 4 | 回复经出站流回飞书群 | **飞书群收到** `[session://system/default/feishu-bing \| entity://system/agent/r3-echo-pty-1] echo: …` | s11-feishu-group-inbound-at-agent | ✅ |
| 5 | 再发一条 `@r3-echo-pty-1 你可以干什么`(11:48) | 同样完整往返(入站→路由→echo→出站回飞书) | (同图) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| 入站到达绑定 session(chat→session 解析) | ✅ 飞书消息出现在 world UI feishu-bing | ✅ |
| mention 解析 → 路由到 agent | ✅ text-grep `@r3-echo-pty-1` → 该 echo agent 收到并回 | ✅ |
| Feishu 用户在 chat 看到 agent 回复 | ✅ echo 回复带 `[session\|sender]` 前缀流回飞书群 | ✅ |
| `inbound_chat_lookup`/`feishu_user_bindings`/`ctx.caller`=feishu-resolved | ⏳ DB 层未在本轮单独核(world UI + 飞书群双向已证往返);留审计补 | ⏳ |

## 发现 / 机制(重要)

- **Feishu @ agent 能力靠 text-grep,不靠新代码**(F12 终结论):Allen 2026-05-17 的字面 `@<agent名>` 匹配 + F9 绑群 UI + 默认路由 `{:always}→[$session_users,$mentions]`。详见 `docs/together/2026-06-25/notes/f12-feishu-mention-coordination.md`。
- **入站不需要公网 webhook**:WSS 长连接(sidecar 主动连飞书)—— 纠正设计 stub 的旧假设。
- 双向闭环完整:飞书发 → 入站 → 路由 echo → 出站回飞书,world UI 交叉确认同一对话。

## 遗留 / bug
- ⏳ DB 层(`inbound_chat_lookup`/`feishu_user_bindings`/`ctx.caller`)未单独核 —— 可在 scenario-12 类审计补(本轮往返已由飞书+world UI 双向证据确立)。

## 证据清单
- `evidence/scenario-11/s11-feishu-group-inbound-at-agent.png` — 飞书群:zyli @agent + echo 回复流回
- `evidence/scenario-11/s11-world-session-received.png` — world UI feishu-bing:入站消息 + echo 回复

## 交叉引用
- 设计场景:`docs/scenarios/13-feishu-inbound-routing`、`32-feishu-mention-orchestrator-dispatch`
