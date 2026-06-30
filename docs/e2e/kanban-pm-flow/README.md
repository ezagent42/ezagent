# kanban pm-coordinator 团队开发流 — e2e 证据（T14 综合证）

> 这套证据证明 kanban 团队开发流的**配置先行多 agent 协作**跑通了：人 ↔ pm-coordinator
> ↔ dev-together 经 session / 看板 / 路由规则形成闭环。**T14 是 post-refactor（recipe 统一入口
> + nav→World + boot-order 修）+ post-socialware 的一轮综合证**，真浏览器（cdp.py headless
> Chrome）+ 真 cc-headless 大脑 + sanctioned CLI，无 force / stub / raw-RPC mutation / impersonate。
> （早期分幕证据 act5/T11/T13 已被 T14 一轮全链取代、精简删除。）

## T14 全链 PROVEN（每步取证）

1. **boot-seed 实证**（`t14-boot-seed-forensics.txt`）— pm/dev recipe 经统一入口 `DefaultRecipeSeed`
   seed 成 `config://system/recipe/*` ConfigObject（非 plugin）；**boot-order 修验证点：cc after_boot
   的 template-seed 成功、server.log `no_spawn_fn=0`**、标准 AgentTemplate ALIVE。
2. **materialize + JOIN** — bind_session 触发 pm + dev 经统一入口 recipe materialize、双双 JOIN
   （pm 490µs / dev 285µs，zero activate timeout）。caps 证 board-scoping（`t14-pm-coordinator-caps.txt`
   pm 的 kanban caps scoped→board；`t14-dev-together-caps.txt` dev self-scoped）。
3. **relay 全链** — 人 @pm → pm（真 claude）判 gate + claim_node + set_status（`t14-pm-capbac-audit.txt`）
   → 派活 → **dev 只产 artifact**（`t14-dev-artifact-n2-positioning.md`，82 行）→ return →
   **relay-back 路由规则自动唤醒 pm**（`t14-relay-back-audit.txt`：audit 窗口 **zero admin→pm sends**，
   pm 唯独靠 `from(dev)+in_session→[pm]` 规则被唤醒，`t14-relay-back-rule.txt` psql + World UI 双证）
   → pm `attach_artifact`（字段完整）+ `set_stage` 推进。
4. **职责模型铁证**（`t14-dev-board-zero.txt`）— dev→board CapBAC dispatch=0，确立 dev 只产物、
   板推进 + github 都 pm 干。

## 取证文件
- `t14-boot-seed-forensics.txt` — recipe ConfigObject + 标准 template + no_spawn_fn=0
- `t14-relay-back-audit.txt` / `t14-relay-back-rule.txt` — relay-back 自动唤醒铁证 + 路由规则
- `t14-dev-board-zero.txt` / `t14-pm-capbac-audit.txt` — CapBAC 职责模型审计
- `t14-pm-coordinator-caps.txt` / `t14-dev-together-caps.txt` — board-scoping caps
- `t14-dev-artifact-n2-positioning.md` — dev 产的真 artifact
- `t14-session-transcript.txt` / `t14-pm-reply.txt` — 会话/大脑往返
- `t14-01..09-*.png` — 每步截图（登录→SPA→session→成员→routing 面板→chat→board UI）

## 坑 + 已知 surface
见 `docs/guide/kanban-development-pitfalls-and-decisions.md`。
