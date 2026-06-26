# docs/e2e/auto — agent-browser E2E 自动化 runner

把 `docs/e2e/` 各场景的「自动化运行(agent-browser runbook)」节**落实成可一键无人值守跑**的脚本。
2026-06-26 实地跑通,**PASS=11 / FAIL=0**(含真实 DeepSeek 往返)。

## 跑

```bash
# 前提:server 起着(world.localhost:10042 健康)、PATH 里有 agent-browser、PG 可达
bash docs/e2e/auto/run.sh

# 额外验 07 curl(需 DeepSeek key,绝不入库——只经 env 注入)
DEEPSEEK_API_KEY=sk-... bash docs/e2e/auto/run.sh
```

退出码:全过=0,有 FAIL=1(CI 可直接用)。

## 覆盖(可完全自动化的场景)

| 场景 | 断言 |
|---|---|
| 0 preflight | server health 200 |
| 01 登录 | 跳 `/sessions` + 主面板渲染 |
| 02 建 agent | `e2e-native`(native flavor)出现在列表 |
| 03 建 session+成员 | `e2e-auto`(模板 `default`)+ `e2e-native`/`py_default` 加入即 online |
| 04 py 往返 | `@py_default` **逐字回显**唯一 `ping-<RUNID>` |
| 05 cc 回归守卫 | `@claude-bot` 15s **不回**(已知 cc bug,修复后此断言会翻→提示真修了) |
| 09 autocomplete | 键入 `@` 候选**只列本 session 成员** |
| 07 curl/DeepSeek | (需 key)`@e2e-curl` 真实回 `H₂O` |

## 设计要点

- **幂等**:实体用固定 `e2e-` 名,已存在则跳过创建;消息 payload 带 `RUN_ID`(`date +%H%M%S`)唯一,断言不受历史消息干扰 → **可重复跑**。
- **所有 world UI 交互坑封装在 `lib.sh`**(规范见 [`../guide.md` §8](../guide.md)):native-setter 填 React 字段、`requestSubmit` 提交 React 岛 form、`@mention` 走**真实键盘 autocomplete**(不能 native-setter 硬塞)、结果看 `#world-root[data-last-dispatch]`、邀请用完整 URI、session 模板须 `default`。
- **断言谓词**:`assert_url` / `assert_visible` / `assert_text` / `assert_dispatch` / `assert_agent_reply` / `assert_no_agent_reply` / `member_online`。
- **证据**:运行时截 `evidence/scenario-NN/sNN-auto-run-<RUNID>.png`(时间戳命名,不入库;CI 可归档为 artifact)。

## 确定性建议

为可重复的确定性结果,最好对**新 seed 的 DB** 跑(`mix ecto.reset` + `mix run scripts/world_e2e_seed.exs`)。当前脚本对既有状态做了 skip-if-exists 容错,但干净 seed 最稳。

## 未覆盖(及原因,见 [`../notes/2026-06-26-product-gaps.md`](../notes/2026-06-26-product-gaps.md) 与各 scenario)

- **06 codex**:步骤可自动,但 OpenAI **SSE 流经本地代理不稳**(环境/网络)→ 暂不纳入。
- **08 门控**:需 session 内 2 个能回的 agent 对照(py_default + e2e-curl 可组);未纳入默认 run,可扩。
- **10/11 feishu**:外部 channel。入站可用 **`POST /api/feishu/webhook`** 合成注入(未鉴权,见 scenario-11);出站的飞书侧需飞书 Bot API,带外。
- **12 审计**:CLI/DB 查询(非 agent-browser),应单独脚本化查 `invocations`。
