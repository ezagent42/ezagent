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
