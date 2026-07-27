#1436 可以 merge 了 — 07-27

✅ 已解阻：
- #1532（跨 BEAM cap → `:missing_cap`）已验证关闭：issue 原根因在 main 上早已不存在（07-18 durable key 表 + 07-21 验签现读 DB），当时实际撞到的是 G-3 self-license gate + 存量数据。fresh DB + 三处种子侧修复后全链跑通。
- G5 E2E 实证：web 发送 `:missing_cap` = 0 → @提及激活 agent → `no_api_key` → Layer 1 错误卡片「Agent 未配置凭证 + 影响 + 前往修复」渲染成功。截图在 `scripts/g5-screenshots/`。
- 分支已 rebase 到 current main（#1543 合入后），零冲突；种子 + Playwright 已适配现行 cap/origin API，一条命令可复现（return 里有）。

请 lead：评审 + flip 合入 #1436（draft 保持中）。内容为纯 docs/种子/E2E 脚本，无平台代码改动。
注：刚推的 CI 里 frontend gate 失败是 setup-node 下载超时（基础设施 flake），push 后已触发重跑。

详细 return：`docs/together/2026-07-27/returns/ruihua-g5-e2e-1532-closed.md`
