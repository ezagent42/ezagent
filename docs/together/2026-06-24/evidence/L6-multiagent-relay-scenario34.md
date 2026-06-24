# L6 — 多 agent 接力 (scenario-34 传话游戏)

**日期:** 2026-06-24

## scenario-34 拓扑
`@传话游戏 → relay-cc →(from relay-cc)→ relay-codex →(from relay-codex)→ relay-curl`(terminal)。
sender-locked:路由只按 `{:from, <prev-member>}` 推进,**no baton / no model-computed routing**——路由表即链路。

## deterministic tier(接力路由逻辑)— ✅ PASS
```
MIX_ENV=test mix test apps/ezagent_core/test/e2e/scenario_34_sender_locked_relay_test.exs
→ 8 tests, 0 failures
```
验证:RuleStore + Routing.Matcher 链、legend(member_set/fold/bound_rule_set)、rule-set `telephone`(单接收者 from-rules)、prompt-template `telephone_hop`({body} 注入)、**no-baton 结构不变式**。这是 scenario-34 的 headline 不变式门。

## live tier(真 cc→codex→curl agents)— 本机环境阻塞
`@tag :live`(默认跳过,需全 agent 环境)。本机无法跑:
- relay-cc + cc orchestrator(搭建用)= cc flavor → **F5**(Sandbox.write_path 激活超时)
- relay-codex = codex flavor → **F7**(需 codex login + TUI 崩溃)
- 仅 relay-curl(curl)可起
→ 3 flavor 中 2 个起不来,live 接力本机不可演;非接力逻辑问题(逻辑已由 deterministic tier 证)。

## 结论
✅ 接力路由逻辑(sender-locked, no-baton)验证通过(8 tests)。live 多 agent 接力受 F5/F7 环境阻塞,待 owner 修 cc/codex spawn 后在全 agent 环境复跑。
