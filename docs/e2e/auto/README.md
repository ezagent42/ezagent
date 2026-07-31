# docs/e2e/auto — agent-browser E2E 自动化 runner

把 `docs/e2e/` 各场景的「自动化运行(agent-browser runbook)」节**落实成可一键无人值守跑**的脚本。
2026-06-26 实地跑通,**PASS=15 / FAIL=0**(含真实 DeepSeek 往返 + 合成 feishu 入站完整链 + dispatch 审计)。

## 跑

```bash
# 前提:server 起着(world.localhost:10042 健康)、PATH 里有 agent-browser、PG 可达
bash docs/e2e/auto/run.sh

# 全量(07 curl 需 DeepSeek key,绝不入库——只经 env 注入)
DEEPSEEK_API_KEY=sk-... bash docs/e2e/auto/run.sh

# 11 feishu 入站完整路由 + 12 审计 需:pip install pg8000 --break-system-packages
#   + PG env(POSTGRES_*;未设时 run.sh 自动从监听 server 进程的 /proc 取)+ python3.12
```

退出码:全过=0,有 FAIL=1(CI 可直接用)。

## 覆盖(可完全自动化的场景)

| 场景 | 断言 | 备注 |
|---|---|---|
| 0 preflight | server health 200 | |
| 01 登录 | 跳 `/sessions` + 主面板渲染 | |
| 02 建 agent | `e2e-native`(native flavor)出现在列表 | |
| 03 建 session+成员 | `e2e-auto`(模板 `default`)+ `e2e-native`/`py_default` 加入即 online | |
| 04 py 往返 | `@py_default` **逐字回显**唯一 `ping-<RUNID>` | |
| 05 cc 回归守卫 | `@claude-bot` 15s **不回**(已知 cc bug,修复后此断言会翻→提示真修了) | |
| 07 curl/DeepSeek | `@e2e-curl` 真实回 `H₂O` | 需 `DEEPSEEK_API_KEY` |
| 08 @mention 门控 | `@py_default` 仅 py 回、该轮新增 agent 气泡=1(curl 未越权) | 需 key(要 2 个 replier) |
| 09 autocomplete | 键入 `@` 候选**只列本 session 成员** | |
| 11 feishu 入站 | webhook challenge 回显 + **合成事件经路由 → py_default 在会话回显** | 需 pg8000(建绑定);见下 |
| 12 dispatch 审计 | invocations 有 granted agent.receive 轨迹 + P22 DLQ 现状 | CLI/PG,需 pg8000 |

### 11 feishu 入站怎么做到全自动(关键)

**已按 #204 变更:** 公网未鉴权路由 `POST /api/feishu/webhook`(可伪造 `open_id` 冒充)已删除,故此步不再经 HTTP 合成注入 → 现为 SKIP。生产入站改走已鉴权的 WS 长连(`WsClient` → `InboundDispatcher`),本 harness 无 rpc/容器句柄,无法免真飞书在应用内合成注入。入站链(decode→路由→回复)的覆盖改由单测保证:`inbound_dispatcher_test.exs`(共享入站链)+ `webhook_plug_test.exs`(保留但已 unmount 的 plug 逻辑)。`feishu_setup.py`(直插两条绑定:假 `open_id`→admin 过 SenderResolver、假 `chat_id`→session 过 InboundChatLookup)保留,供将来经 WS/rpc 注入复用。

### 12 审计是 CLI 不是 browser

`audit.py`(pg8000 直查 `invocations`/`dlq`):核对前面 UI 往返在 dispatch 层 granted 可追溯,并报告 P22 DLQ-on-zero-match 现状。注意 `inserted_at` 存 UTC、`now()` 带本地 tz,查询用 `now() at time zone 'UTC'` 比较。

## 设计要点

- **幂等**:实体用固定 `e2e-` 名,已存在则跳过创建;消息 payload 带 `RUN_ID`(`date +%H%M%S`)唯一,断言不受历史消息干扰 → **可重复跑**。
- **所有 world UI 交互坑封装在 `lib.sh`**(规范见 [`../guide.md` §8](../guide.md)):native-setter 填 React 字段、`requestSubmit` 提交 React 岛 form、`@mention` 走**真实键盘 autocomplete**(不能 native-setter 硬塞)、结果看 `#world-root[data-last-dispatch]`、邀请用完整 URI、session 模板须 `default`。
- **断言谓词**:`assert_url` / `assert_visible` / `assert_text` / `assert_dispatch` / `assert_agent_reply` / `assert_no_agent_reply` / `member_online`。
- **证据**:运行时截 `evidence/scenario-NN/sNN-auto-run-<RUNID>.png`(时间戳命名,不入库;CI 可归档为 artifact)。

## 确定性建议

为可重复的确定性结果,最好对**新 seed 的 DB** 跑(`mix ecto.reset` + `mix run scripts/world_e2e_seed.exs`)。当前脚本对既有状态做了 skip-if-exists 容错,但干净 seed 最稳。

## 仍未覆盖(及原因,见 [`../notes/2026-06-26-product-gaps.md`](../notes/2026-06-26-product-gaps.md) 与各 scenario)

只剩 2 条,均**本质性/环境性**受限,非脚本能解:

- **06 codex**:步骤可自动且 bridge 能连上跑 turn,但 OpenAI **SSE 流经本地代理 Reconnecting 5/5 → 空回复**(环境/网络稳定性)。代理通道稳定后照 07 的模式即可纳入。
- **10 feishu 出站**:world-UI 侧(bind + 出站镜像)可自动验;但"消息**真到了飞书群**"要读真群 = 需**飞书 Bot API**,带外,非 agent-browser 能断言。

> 11 入站已用合成 webhook 注入解决(见上);08/12 已纳入。
