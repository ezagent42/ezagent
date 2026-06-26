# handoff · 2026-06-26 · agent 详情面对真实 agent 失效(FP5 S5)

> **来源**:zyli 的 FP5 world UI 巡检(`docs/together/2026-06-26/notes/zyli-fp5-ui-inspection.md` §S5)。
> **性质**:核心侧(runtime 激活预算 + behavior 覆盖),按 contributing **P0 需先与 lead 对齐设计**,
> 不在 FP5 自行修。本 handoff 把根因钉死、给可复现步骤,交给 agent-runtime 负责人(allenwoods?)对齐后实施。
> **建议 owner**:agent runtime / `domain.agent` 配置面(与 `allenwoods-agent-runtime-consolidation` 同域)。

## 一句话

点进任一 agent 的 **Config / Caps 详情子面**,页面转圈约 20s 后抛**裸 Elixir error tuple**,
读不出配置/caps。两种 flavor 两种坏法,根因都在后端 dispatch 链。

## 现象(证据)

| 子面 | agent(flavor) | 抛出的错误 | 证据截图 |
|---|---|---|---|
| `/identities/agents/<uri>/config` | claude-bot(cc) | `:activate_timeout` | `evidence/fp5-ui-audit/05-agent-config.png`、`05b-agent-config-cc-retest.png`(复测仍复现) |
| `/identities/agents/<uri>/config` | py_default(py) | `{:unknown_action, :read_cascade}` | `evidence/fp5-ui-audit/06-agent-config-py.png` |
| `/identities/agents/<uri>/caps` | claude-bot(cc) | `:activate_timeout`(下方 caps 表空) | `evidence/fp5-ui-audit/07-agent-caps.png` |

> 裸 tuple 直接展示给操作员(无友好文案)。**复测确认持续复现**,非偶发。

## 根因(已钉死代码链)

世界侧 config 面读取走:
`world/identity_data.ex:191` → `Ezagent.Agent.Config.read_cascade(agent_uri, caller, caps)`
→ `domain_agent/lib/ezagent/agent/config.ex:38` 经 **`config_evolve.read_cascade`** action 经 `Invocation`
**dispatch 到 live agent**(需该 agent 实例 ready)。

两个独立失败模式:

1. **cc 冷激活超 ReadyGate 预算 → `:activate_timeout`**
   - dispatch 落在 cc agent `activate`/post-init 窗口,`Ezagent.ReadyGate.await(uri, 5_000)`
     (`ezagent_core/lib/ezagent/invocation.ex:181`)等满 5s 仍 not-ready → 返回
     `{:error, :activate_timeout}`(`invocation.ex:186`)。
   - cc agent 冷启要 spawn PTY / orchestrator,**冷态 >5s 很常见** → 首次点 config/caps 必中。
   - **同族**:`docs/guide/world-e2e-seed.md` §3「⛔ Known blocker」记的 `create_session` 5s
     dispatch 超时 + snapshot race,是同一 5s 预算族的另一面。

2. **py agent 不识别 `config_evolve.read_cascade` → `{:unknown_action, :read_cascade}`**
   - py 的 behavior set(per-instance 加载)**没有 `config_evolve` behavior / `read_cascade` action**。
   - config 面假设所有 flavor 都支持 `read_cascade`,但 py 不支持 → action 解析直接 unknown。

## 实测:这是后端问题(已绕开 web/React 直证)

直接 `:erpc` 连进运行中的 runtime 节点(`ezagent_runtime@127.0.0.1`)调
`Ezagent.Agent.Config.read_cascade/3`,**完全绕开 Phoenix/LiveView/React**,两个 flavor 都复现
UI 里一模一样的错误:

| 纯后端直调 | 返回 | 关键 |
|---|---|---|
| `read_cascade("entity://system/agent/py_default", admin, wildcard_caps)` | `{:error, {:unknown_action, :read_cascade}}` | 瞬时 —— py behavior set 无此 action |
| `read_cascade("entity://system/agent/claude-bot", admin, wildcard_caps)` | `{:error, :activate_timeout}` | **耗时 5003ms** —— 卡满 `ReadyGate.await(uri, 5_000)` 预算 |

→ `:activate_timeout` 是 `Invocation` 返回的 Elixir 原子,React 造不出;前端只是显示服务端
`identity_data.ex:209` 用 `inspect(reason)` 拼好的 `"配置读取失败：…"`。**5003ms 这个数字直接坐实
cc 根因 = 5 秒激活预算**。

## 待 lead 对齐的设计问题(P0)

1. **激活预算**:5s ReadyGate 对 cc 冷启是否过短?方案空间 ——
   - (a) 调大 cc 的 await 预算 / 给 PTY-类 flavor 单独预算;
   - (b) read 类 dispatch 不强制 await live,改读 **snapshot/last-known config**(config 是 set-effect
     写的状态,理论上可从快照读,不必唤醒 agent);
   - (c) lazy-activate + 前端轮询(配 UI 侧 spinner+retry)。
   - **倾向 (b)**:读配置不该唤醒一个重 PTY agent;但需 lead 确认 read_cascade 的快照可读性。
2. **behavior 覆盖**:`config_evolve.read_cascade` 是否应是**所有 Entity.Agent 的通用能力**(host 级),
   而非 per-flavor?py 缺它说明 config 读取没统一到 host。与 `allenwoods` A 块(Entity.Agent 统一
   解析 config+behaviors)直接相关 —— 可能并入该任务。
3. 上述两点修好前,**config/caps 面对真实 agent 基本不可用**,属产品完整度阻塞(目标①)。

## 我(zyli)能在 FP5 自行做的 UI 侧缓解(不需对齐,可并行)

- **S5-a 友好错误文案**:把 `:activate_timeout` / `{:unknown_action, :read_cascade}` 这类裸 tuple
  转成人话(「agent 正在启动，请稍候重试」/「该 flavor 暂不支持读取此配置」)。
- **S5-b 激活态 + 重试**:lazy-activate + spinner + 超时后「重试」按钮,替掉一次性 5s 失败终态。
- 这两项只改 world 前端错误渲染,**不碰 dispatch/激活预算**(那是本 handoff 的核心活)。
  ⚠️ 注意 config 面在 `Identities.tsx`,当前被 `feat/agent-console-crud` 占用(world-coordination §5),
  做前需与该 effort 协调编辑窗口。

## 复现(agent-browser runbook)

```bash
# 前置:world dev server 起(PG dev 库),admin 登录(admin@ezagent.chat / worlddev)
B="agent-browser --session repro"
$B open "http://world.localhost:10042/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fclaude-bot/config"
$B wait --load networkidle; sleep 20
$B snapshot -i           # 看到红框 :activate_timeout
# py 对照:
$B open "http://world.localhost:10042/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2Fpy_default/config"
$B wait --load networkidle; sleep 20
$B snapshot -i           # 看到红框 {:unknown_action, :read_cascade}
```

## DoD(实施侧)

- [ ] lead 对齐激活预算 + behavior 覆盖方向(上 §「待对齐」3 问)。
- [ ] cc:点 config/caps 不再 `:activate_timeout`(冷态也能读出配置/caps)。
- [ ] py:config 面能读出(或明确该 flavor 无此能力,UI 友好提示而非 unknown tuple)。
- [ ] 复现 runbook 跑绿(两 flavor 均不抛裸 tuple)。
- [ ] (并行)zyli 的 UI 友好文案 + 重试落地,与核心修配套。

## 参考

- FP5 巡检清单:`docs/together/2026-06-26/notes/zyli-fp5-ui-inspection.md`(§S5 + 优先级表 + 待对齐节)
- 代码:`ezagent_core/lib/ezagent/invocation.ex:170-191`、`ezagent_domain_agent/lib/ezagent/agent/config.ex:31-75`、
  `ezagent_plugin_world/lib/ezagent/world/identity_data.ex:185-195`
- 同族 blocker:`docs/guide/world-e2e-seed.md` §3
- 关联任务:`docs/together/2026-06-25/handoffs/allenwoods-A-config-unification.md`(Entity.Agent 统一 config+behaviors)
