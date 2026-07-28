# G5 E2E 解阻（#1532 关闭）+ #1436 可合入实证 · ruihua · 2026-07-27

**分支 / PR:** `docs/workspace-self-service-product-plan` → PR #1436（draft）· base `main`
**状态:** 分支已 rebase 到 current main（`7ec3c8bda`，#1543 合入后），零冲突；#1532 已验证关闭。

## 演示了什么

- **#1532（cross-BEAM cap → `:missing_cap`）阻塞解除。** 在 current main + 全新 DB 上跑通 G5 E2E 全链：
  种子（独立 BEAM）签发 cap → 服务器（另一 BEAM）验签 → web 发送 **`:missing_cap` = 0**（07-22 必现）
  → founder @提及 agent → curl agent 激活、无凭证失败 `no_api_key`
  → **G5 Layer 1 错误卡片渲染成功**：「Agent 未配置凭证 / 无法调用 AI 模型，你的消息暂时无法得到回复 / 前往修复 →」。
- 种子脚本 + Playwright 脚本适配现行 main API，可一键复现（见下）。
- 07-22 round-2 return 中 blocked 的 DoD「A/B/C 截图」：Layer 1（A）本轮回合达成；Layer 2/3（B/C）为后续项。

## 怎么看

- 截图证据（本分支内）：
  - `scripts/g5-screenshots/g5-layer1-error-card.png` — 错误卡片渲染（标题 + 影响 + 修复链接）
  - `scripts/g5-screenshots/g5-mention-typed.png` — @提及发送前
- 复现（全程隔离，不碰日常 dev 库）：

  ```bash
  POSTGRES_DB=ezagent_g5_e2e mix ecto.create && POSTGRES_DB=ezagent_g5_e2e mix ecto.migrate
  EZAGENT_HOME=/tmp/ezagent_g5_e2e POSTGRES_DB=ezagent_g5_e2e \
    mix run apps/ezagent_plugin_world/assets/scripts/g5_e2e_seed.exs
  EZAGENT_HOME=/tmp/ezagent_g5_e2e POSTGRES_DB=ezagent_g5_e2e mix phx.server
  G5_AGENT_URI=<种子打印的 agent URI> node scripts/g5-e2e-playwright.js
  ```

  （要点：fresh DB 用 `POSTGRES_DB` 换库——`EZAGENT_HOME` 只隔离 FS 层，不隔离 DB。）

## 技术决策（为什么之前卡、为什么现在通）

1. **issue #1532 原根因已过时。** 「cap key store 是进程内状态、不跨 BEAM」在提交当日（07-23）对 main 即不成立：durable `kind_cap_authorities` 表 07-18 落 main（#1457），验签 07-21 起每次现读 DB active row（#1493 F-1）。同 DB 即互通。
2. **当时真正撞到的**：G-3 self-license gate（07-21）—— G-3 前创建的存量用户行永不补铸 self-license，`EntityCaps.load` 恒为 `[]` → `:missing_cap`。所以 rebase 无用，必须 fresh DB。
3. **fresh DB 后还剩三处种子侧 staleness + 一处真缺口，已全部修复**（`3eae2e811` 系提交，rebase 后 `a322c6b9b`）：
   - DispatchOrigin 纪律：join dispatch 需 `origin: :authenticated_external` + `authenticated_principal`；
   - `Provisioning.create_agent` ctx 需 `authenticated_principal`；
   - **`Cap.issue` 只返回 artifact、不投递到用户 durable cap store** —— e2e-session 的 join/send caps 必须随用户创建载荷落库，否则 web 发送按 store 加载仍判 `:missing_cap`（fresh DB 上最后一处真因）；
   - curl agent **仅对 @提及激活** —— Playwright 发送改为 `@<agent-uri> hello`（裸发 "hello" 到不了 agent），登录改用种子用户（fresh DB 无 admin）。
4. **不做的事**：未动平台侧（未给存量行补铸 self-license）—— 若 lead 认为该兜底，另开 issue 指派即可，不阻塞本线。

## 对应本周目标

- **W31 目标二（企业自助跑通）**：验收要求「注册 → 建 workspace → 开/配 agent → agent 在 session 里回话 → …，一条 Playwright E2E 录进 CI」。本交付正是该旅程「agent 在 session 里回话 + 错误机制」段的实证底座：可复现种子 + 可自动化 Playwright + cap 链全绿。进 CI 是后续步骤（依赖 main 复绿，#189）。

## 关联

- Closes #1532（关闭评论含完整时间线与验证链）
- PR #1436（结果评论已同步）；修复提交 `a322c6b9b`（rebase 后）
- 接续 `docs/together/2026-07-22/returns/ruihua-g5-e2e-round2.md`（当时的 blocked 项）
- 群消息：`docs/together/2026-07-27/returns/ruihua-1436-mergeable-group-msg.md`
