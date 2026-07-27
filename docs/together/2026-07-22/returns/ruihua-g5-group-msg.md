G5 E2E 第 2 轮 — 07-22 进度

✅ 完成的：
- 隔离 E2E 环境搭好（`EZAGENT_HOME=/tmp/ezagent_g5_e2e`，独立 DB）
- 种子脚本完善：用户 + agent(无 API key) + session + caps，一个 `mix run` 跑完
- Playwright 自动化脚本能跑通：登录 → 加载 session → 输入消息 → 发送
- Rebase 到最新 main（含 #1451 #1456 全部 G5 代码）
- 修了 `LayoutBootstrap` 的 `already_registered` race

❌ 卡住：
- 消息在 `session.send` 被 `:missing_cap` 拒绝。根因是 `mix run`（种子）和 `mix phx.server` 两个 BEAM 的 key store 不互通，种子发的 cap 签名服务器不认。

求助：跨 BEAM cap 下发的标准做法是什么？或者 G5 错误卡片效果能否用单元测试覆盖，Playwright 截图只证 UI 流程？

详细 return：`docs/together/2026-07-22/returns/ruihua-g5-e2e-round2.md`