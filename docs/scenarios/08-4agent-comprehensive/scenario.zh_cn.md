# 场景 08：4-agent 综合（user → cc → curl → np → user）

**类别**：2 — Agent 生命周期
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-23（Allen Feishu 规约 + CI 测试通过）

## 前置条件

- 按 `docs/runbook/4-agent-comprehensive-e2e.md`：
  - `uv` 在 PATH（np-agent + cc bridge）
  - `python3` 在 PATH（cc-agent）
  - `claude` CLI 在 PATH（cc-agent）
  - Anthropic API key：`ANTHROPIC_API_KEY=sk-ant-...`
  - DeepSeek API key：`DEEPSEEK_API_KEY=sk-deepseek-...`
- Admin 已登录
- 已创建 3 个 agent 模板：cc-orchestrator、curl-translator、np-math-helper

## 角色

- **调用方**：admin
- **目标**：
  - cc agent `entity://agent/system/cc_orchestrator`
  - curl agent `curl-agent://my-deepseek`（translator）
  - np agent `np://default/math_helper`（numpy/sympy）
- **外部系统**：真 `claude` + DeepSeek + numpy/sympy
- **Behavior**：chat、routing、orchestration

## 步骤

流程演练多 agent 编排：admin 让 cc 计算某事；cc 委托给 np 做数学 + curl 做翻译；最终回复流回。

1. 设置路由规则：
   - `@cc_orchestrator` 被 mention → cc 接收
   - cc 发 `@curl-translator` mention → curl 接收
   - cc 发 `@math_helper` mention → np 接收
   - 其他文本 → 仅 admin
2. 在 `/admin/sessions/<session-uri>` 发：`@cc_orchestrator please compute the square root of 144 then translate "the answer is X" to Mandarin`。
3. cc 的 LLM 理解多步任务；发：
   - `chat.send "@math_helper sqrt(144)"` → np 计算 `12` → 回复
   - cc 收到 `12`；发 `chat.send "@curl-translator translate: the answer is 12"` → curl POST 到 DeepSeek
   - DeepSeek 返回翻译文本
   - cc 收到翻译；发最终回复给 admin
4. Admin 在 session 看到最终翻译。

## 预期结果

- Per-step `invocations` 行追踪编排（admin → cc → np → cc → curl → cc → admin）。
- Mention-gated 路由（场景 10）阻止离题 agent 加入。
- 全部 3 个后端集成（claude、DeepSeek、numpy/sympy）成功。

## 失败模式

- np-agent 数学错误（例如 `sqrt(-1)` 返回复数）：cc 必须处理意外类型 + 给 admin 转译合理错误。
- DeepSeek 不可达：cc 必须抛 "翻译不可用" + 单独完成数学步骤。
- cc LLM 幻觉错 mention（例如 `@unknown-agent`）：mention-failed 通知（PR #406）触发给 admin。

## 交叉引用

- 相关 PR：
  - PR #126 — curl-agent
  - PR #390 — PTY phase 状态机（np + cc）
  - PR #406 — mention-failed 通知
  - PR #422 — mention-gated 路由
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - `docs/superpowers/specs/2026-05-23-domain-python.md` — np-agent 基础
- 测试：
  - `apps/ezagent_plugin_np/test/integration/comprehensive_4agent_e2e_test.exs` — CI 版用 FakeCcAgent + mocked DeepSeek（Bandit Plug）
- 证据 + runbook：
  - `docs/runbook/4-agent-comprehensive-e2e.md`（完整操作员菜谱）

## 备注

- 本场景最接近 "生产真实多 agent 流" — 任何路由、mention 解析或 agent 编排变更的规范回归。
- 按 Allen 2026-05-23，本场景是多 agent 派发的 V1 签收场景。
- CI 版（FakeCcAgent + Bandit Plug for DeepSeek）约 3 秒；操作员 runbook 是真栈 smoke（约 30 秒 wall-time）。
