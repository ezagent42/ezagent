# 场景 07(执行记录):curl/deepseek agent 往返

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | [scenarios/07-curl-agent-deepseek](../scenarios/07-curl-agent-deepseek/scenario.zh_cn.md) |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~17:15 |
| **环境** | 分支 `feat/product-gaps-f9-f12`(已 rebase = main `8b673310`)· server `http://world.localhost:10042`(带 `HTTPS_PROXY=7890`) |
| **前置 scenario** | scenario-03 ✅(session `zyli-test-1`) |

## 前置条件(当次实际)

- 新建 curl agent `entity://system/agent/zyli-curl-1`(flavor=curl,无需 cwd)
- 经 `configure` 配 `api_url=https://api.deepseek.com/chat/completions`(provider=deepseek,model=deepseek-chat 默认)
- 在 agent "API Keys" 区填入 deepseek API key(zyli 提供)
- server 带代理 → 可达 `api.deepseek.com`

## 角色

- **调用方**:admin · **目标**:`entity://system/agent/zyli-curl-1`(curl flavor → DeepSeek)

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 建 curl agent + 配 api_url + 加 key + Invite 进 session | 成员名册 MEMBERS=4(claude-bot/zyli-curl-1/zyli-echo-1/admin),zyli-curl-1 绿点在线 | [s07-step1-curl-deepseek-reply-zyli](./evidence/scenario-07/s07-step1-curl-deepseek-reply-zyli.png) | ✅ |
| 2 | 发 `@zyli-curl-1 你好,你是谁`(17:15:06) | zyli-curl-1 **回真实 DeepSeek 回复**(17:15:09,~3s):"你好!我是 **DeepSeek**,由深度求索公司创造的 AI 助手……" | (同上截图) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| curl flavor 调 deepseek 并回包 | ✅ 真实 DeepSeek HTTP 回复,@mention 路径 ~3s | ✅ |
| LV 渲染对话 | ✅ 去/回两条上屏 | ✅ |

## 发现 / 意义

- **curl flavor 端到端通过** —— 创建→`configure`→API key→@mention→HTTP 调 DeepSeek→回复渲染,全链路正常。
- **进一步隔离 cc 的故障**:非 PTY、非 cc 的 flavor(curl,纯 HTTP)工作完全正常,@mention 路由 + 代理 HTTPS 出网都没问题 → 坐实 scenario-05 的 cc bug 是 **cc/PTY/SDK 专属**,不是通用的 agent-reply / 路由 / 网络问题。
- LLM 内容侧:DeepSeek 把 `@zyli-curl-1` 理解成了用户名(回复里说"这似乎是一个特定的用户名"),属正常 LLM 内容,不影响往返判定。

## 遗留 / bug
- 无阻塞。curl `invocations`(`chat.send` + 出站 HTTP)留待 scenario-12 审计核对。

## 证据清单
- `evidence/scenario-07/s07-step1-curl-deepseek-reply-zyli.png` — zyli 视角:@zyli-curl-1 + DeepSeek 回复 + 4 成员
- `evidence/scenario-07/s07-step2-curl-confirmed.png` — observer 服务端对照:zyli-curl-1 `data-online=true`,transcript 持久化,DeepSeek 回复确认为真实 provider(非 echo/stub);旁证 4 条 @claude-bot 全无回复(与 scenario-05 cc bug 一致)

## 交叉引用
- 设计场景:`docs/scenarios/07-curl-agent-deepseek`

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**2026-06-26 agent-browser 实地跑通:真实 DeepSeek 回复**。curl 是纯 HTTP flavor,无 PTY/bridge,最适合做 agent-reply 自动回归基线。 -->

**前置(自动化)**:scenario-03 已跑(session `e2e-test-1`)。**配凭据配方(2026-06-26 实地)**:
> ① 建 curl agent **零配置**(flavor=curl,name=`e2e-curl`,直接提交即建成,跳详情页)。
> ② **`api_url`/`model` 走默认即可**——curl_agent.ex 默认 `api_url=https://api.deepseek.com/chat/completions` + `model=deepseek-chat`(源码核实),用 DeepSeek 无需改。
> ③ **只需配 `api_key`**:它在独立 `:api_keys` slice,走 **api-keys 页**(非 Config 通用字段)`/identities/agents/<enc>/api-keys`(comp=`agent_api_keys`):provider input 填 `deepseek`、password input 填 key、点 `Save key`。
> ④ **key 绝不入库**:runbook/截图用占位 `<DEEPSEEK_API_KEY>`;实跑时由操作者注入(本次已实测真 key,未写入任何文件)。
> key/url 未就绪 → 不回 → reply 断言 FAIL 属环境未就绪,非回归。

**入口 URL**:`http://world.localhost:10042/sessions?session=<encodeURIComponent("session://system/default/e2e-test-1")>`

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | 建 curl(native-setter+requestSubmit) | `/identities/agents/new` form | flavor=`curl` / name=`e2e-curl` | `url~ /identities/agents/entity%3A`(建成跳详情,**实地✅**) | — |
| 2 | 配 api_key | `/identities/agents/<enc>/api-keys` | provider=`deepseek` / key=`<DEEPSEEK_API_KEY>` | `attr #world-root data-last-dispatch=ok`(**实地✅**) | — |
| 3 | navigate session + Invite(完整URI) | `/sessions?session=<enc>` → `#world-invite-input` | `entity://system/agent/e2e-curl` | `attr li[data-kind=agent] data-online=true`(**实地✅**) | — |
| 4 | 真键盘 @ + 提问 + 发送 | `keyboard type '@e2e-c'`→`click 'ul[role=listbox] button'`→`keyboard type ' 用一个词回答:水的化学式是什么'`→`press Enter` | — | `visible [data-mine=true]` | — |
| 5 | wait ≤12s 等 DeepSeek 回复 | `[data-sender-kind=agent][data-mine=false]` | — | agent 气泡含确定性答案(**实地✅** e2e-curl 回 **`H₂O`**,真实 LLM 非 stub/echo) | `s07-step4-curl-reply-auto.png` ✅ |

**断言映射**:
- 「curl flavor 调 deepseek 并回包」→ step5 reply 气泡含正确答案 `H₂O`(真实 DeepSeek HTTP,~数秒)。**2026-06-26 实地坐实**。
- 「LV 渲染对话」→ step4 + step5 双向上屏。
- **回归基线价值**:curl 是纯 HTTP,稳定可复现;选确定性问答(化学式/算术)让 reply 可机器断言。

**清理**:删除自建 `e2e-curl`(及其 api_key);或重置 DB 重 seed。
