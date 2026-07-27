# 2026-W31 周目标（7/27 – 8/2）

> 主题：把两个延期已久的目标**跑通** —— **开发自举** + **企业自助**。
> 一句话诊断：两个目标**都不缺能力，缺的是集成 + 一个绿的可部署 main**。

设定：林懿伦（PO），2026-07-27。本文件是本周 SSOT，随进度更新。

---

## 🚨 共同前置阻塞：main 全套(mac)系统性红（#189）

两个目标都卡在这一条 —— **main 一天不绿，"部署的产品"就演示不了**。当前状态：

| 成因 | 状态 |
|---|---|
| 编排工具面 env-leak（orchestrator tool-surface） | ✅ 已修（#1577 fix#1，已合） |
| 模板 flavor-store clobber（#1570 回归，**分布式**） | ❌ **未解** —— #1577 曾尝试"延后 pre-store"被 #1578 revert（破坏了"instantiate 期间 flavor 可读"契约）；正解=杀掉插件 adopt 前的覆盖写 + 所有权可观测的删除 + URI 复用清理。**当前由 kimi 修（fix/189-201-adopt-clobber）** |
| SocialwareP10CodexGateTest（cap-signing Path A 在隔离 e2e harness 未物化 signer 授权） | ❌ **未解** —— 需实证 trace |
| 其余（DBConnection.OwnershipError sandbox flake、home_migration fixture 耦合、A/E/F 测试层次缺陷） | ◑ 分派中 |

**先决动作**：修红 → main 绿 → 才能部署。

---

## 目标一：开发自举

**验收标准**：**成功部署**，并在部署完成后**通过 ezagent 的 Feishu 绑定（= channel-server-mcp）通知开发者"已部署"**。
即：平台被用来开发平台自己（cc-openclaw + dev-together 循环）→ 部署成功 → "已部署"通知经 **channel-server-mcp / Feishu 绑定** 回流给开发者。**自举闭环通过 ezagent 的 Feishu 绑定收口。**

**现状**
- 外部 harness（cc-openclaw + dev-together）**每天已在造平台**（近期 PR 都带 return doc + codex review）。
- 部署管道（beta/stable，`ezagent-deploy`）存在。
- channel-server-mcp / Feishu 绑定**已运行**（本对话即经此通道）—— 这就是"ezagent 内的通知面"，无需另造产品内编排面。

**缺口 → 本周步骤**
1. 修 main 红（见上）→ 可部署。
2. 跑一次成功部署（beta 或 stable）。
3. 把**部署完成事件 → channel-server-mcp / Feishu 绑定的"已部署"通知**接通（若尚未自动化）。
4. 验收：一次部署 + 开发者在 Feishu 绑定侧收到"已部署"通知，录证。

**Owner**：cc 协调；部署 = `ezagent-deploy`。

---

## 目标二：企业自助跑通

**验收标准**（含成员添加 + socialware 发布）：一个**全新企业账号**自助完成
**注册 → 建 workspace → 开/配 agent → agent 在 session 里回话 → 添加成员 → 发布 socialware**，
**全程无人工 admin 介入**，一条 Playwright E2E 录进 CI 为证。

**现状**（管道大头已合，#1440，7/17）
- ✅ 自注册 → 自动建 founder-owned workspace → **真签名 founder caps**（不再 stub、不再找 admin 要 member-cap）→ 登录 → KB。

**缺口 → 本周步骤**（按依赖排序）
1. 修 main 红 → 可部署。
2. **#1470 冷建 provisioning deadline（main 上三处全无）** —— 冷建 >5s 撞 5s dispatch 默认 → 孤儿宿主/幽灵会话；压在 #185 冷启动上。需新小 PR（三处走现成 `maybe_put_deadline_ms` 管道）。
3. **G4-AC3**：provider key 校验 + agent 回话证明（存了 key ≠ 能回话）。
4. **G5**：key 失效/缺失的用户可行动面（接现有 `credential_precondition`/`credential_status`）。
5. **成员添加 e2e**：invite → membership（G2-AC7；与 #192/#166 membership=cap-as-truth 相关）。
6. **socialware 发布 e2e**（#183 中 G-items）。
7. **G10**：完整 register→…→**发布** 的 Playwright E2E，录进 CI。

**"跑通"边界**：本周含 **回话 + 成员添加 + socialware 发布**（PO 定，覆盖 socialware 发布与多成员）。

**Owner**：cc 协调；前端/self-service = zyli/ruihua 相关线。

---

## 账单裁决（对账结论，2026-07-27）

- **#1469**（delete_user atomic revocation）：**建议作废关闭** —— 已被 **#1503（=统一撤销程序 "#195"，7/23 合）+ Phase D** 完整取代（main 上 `Users.delete` = 硬删 + `Authority.regenesis` 换代 + `RevocationFence`，四条验收全满足）。唯一未覆盖项 = outbox 死信化（撤销层面已由换代堵死，纯 reconcile 卫生项）。**待 PO 确认关闭。**
- **#1470**（jjkysy，已自闭）：`unmount_all_for_target` 半边已被 cap-epoch 撤销原语取代（合理自闭）；但 **provisioning-deadline 半边 main 上三处全无**，需一个新小 PR（并入目标二步骤 2 / #185）。

---

## 里程碑跟踪（随进度勾选）

- [ ] main 红清零（flavor-clobber #201 + SocialwareP10 + 残余）
- [ ] #1470 provisioning-deadline 新 PR 合入
- [ ] 目标一：一次成功部署 + Feishu 绑定"已部署"通知
- [ ] 目标二：全新企业 E2E（注册→workspace→回话→加成员→发布 socialware）录进 CI
- [ ] #1469 作废关闭（PO 确认后）
