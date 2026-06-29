# Migration-rehearsal Phase-1 — 初步草案（reflow.sh vs SPEC 差异 + 集成方案）

**状态**：草案，待 Allen 过 → 写 codex handoff。  ·  **关联**：SPEC #1082、task #148。

## 1. 当前部署调度（核实自 `.github/workflows/deploy.yml`）

| 通道 | 触发 | 机制 |
|---|---|---|
| **nightly** | **每日 cron 19:00 UTC = 03:00 CST** | `deploy.sh nightly`（build main HEAD 当晚 SHA）|
| **beta** | **push 到 `beta` 分支** | `deploy.sh beta`（re-tag nightly 制品）+ `smoke.sh beta` |
| **stable** | **push 到 `release` 分支** | `deploy.sh stable`（re-tag）+ GitHub Environment 人工审批门 |

**修正你的记忆**：不是"每 PR→nightly"。实际是 **nightly=每日 cron 自动**（不是每 PR；PR 只跑 ci.yml 门禁、不部署）；beta=push beta 分支（手动晋级）；stable=push release 分支 + 人工审批。**三通道都不由 PR 触发部署**（codex 高#7 明确禁了 pull_request 触发，防 fork PR 在 Mac runner 跑）。

> 若你想要"每 PR 合 main 后自动滚 nightly"，那是另一处改动（现在是每日 cron 滚一次 main HEAD，不是每次合并）。本 Phase-1 先不动这个。

## 2. reflow.sh vs SPEC §2 差异

**reflow.sh 已做的（= SPEC §2 的大部分）**：
- ✅ 单向 stable→beta/nightly（拒绝 stable 作 target）。
- ✅ 保护目标环境 credentials（13 张 cred 表 data-only dump + agent-FS 凭据子树 → 回流后盖回；**prod 真实凭据永不落低环境** = SPEC 的 scrub 核心）。
- ✅ 回流 DB（stable 全量 → DROP+重建 target schema → 灌入）+ agent-FS。
- ✅ 起目标 ezagent → `Release.migrate()`（**= 对 prod 数据测迁移**）。
- ✅ 健康检查（30×5s 等 healthy，否则暂停 exit 4）。
- ✅ replica role 绕 FK 盖回 cred（精细，避免波及非凭据表）。

**reflow.sh 缺的（SPEC §2 要补的）**：
- ❌ **迁移后的 6 门验证**：reflow 只验"容器 healthy"——但 healthy ≠ 迁移正确。SPEC §2 要验：① 迁移无 error；② 行数守恒（关键表 before/after count）；③ 关键 ConfigObject/kind_snapshots 可解码（term_to_binary 没坏）；④ recipe/socialware-def schema 仍合法；⑤ 无孤儿/FK 断裂；⑥ home-volume 依赖的迁移（若有）。→ 需新增 `verify-rehearsal.sh`。
- ❌ **复用 backup.sh**：reflow 自己 pg_dump，没先存一份 backup。SPEC 建议演练前先 `backup.sh` 留存（回滚锚点）。
- ❌ **每日自动调度**：reflow 是手动脚本，没接 deploy.yml/cron。
- ❌ **失败阻断晋级**：reflow 失败现在只是 exit 非 0，没有"阻断 beta/stable 晋级"的联动。
- ⚠️ **scrub 范围**：SPEC codex 审出 reflow 的 cred 表名单可能漏 `users.password_hash`（在 users 表、非独立 cred 表）+ `messages.body`（聊天 PII）——演练到低环境若有真人数据需确认。reflow 保的是"凭据表"，PII（消息正文）没 scrub。

## 3. 你定的方向

- **演练目标**：beta **和** nightly 都演练（不只 beta）。
- **每日演练**：每次 nightly/beta 上线都跑（无论有无 schema 变动）。
- **失败阻断晋级**：演练失败 → 阻止该通道晋级。
- **部署方式**：deploy.yml 调度 self-hosted CI。

## 4. 集成方案草案

**流程（接进 deploy.yml）**：
```
nightly（每日 cron）:
  1. deploy.sh nightly        # build main HEAD + 起 nightly
  2. backup.sh nightly        # 演练前留存（回滚锚点）
  3. reflow.sh nightly        # stable 数据回流 nightly + 跑迁移
  4. verify-rehearsal.sh nightly  # 6 门验证 ← 新增
  5. 失败 → 标记 nightly 演练 FAIL、阻断后续 beta 晋级（gate）

beta（push beta 分支）:
  1. deploy.sh beta + smoke.sh beta
  2. backup.sh beta → reflow.sh beta → verify-rehearsal.sh beta
  3. 失败 → 阻断 stable 晋级
```

**关键设计点**：
- **"阻断晋级"怎么实现**：演练在**目标通道自己的部署后**跑（nightly 部署后演练 nightly、beta 部署后演练 beta）。但 reflow **会用 stable 数据覆盖该通道**——所以演练**破坏性**（覆盖了刚部署的 nightly 数据）。**这是个张力**：演练要"对 prod 数据测迁移"就得覆盖目标环境数据，但那样目标环境就不是"干净的新部署"了。
  - **选项 A**：演练在**独立的一次性 DB**（不覆盖在跑的 nightly/beta），只为测迁移、测完丢弃。**推荐**——演练不污染在跑环境。
  - **选项 B**：演练直接覆盖 nightly/beta（reflow 现状）——nightly/beta 变成"带 stable 数据"，适合也想"在 prod 数据上手验 UI"，但 nightly/beta 就不是 fresh 实验环境了。
  - → **需要你定 A/B**（这是最大设计点）。
- **失败阻断**：deploy.yml 里 verify 步 exit 非 0 → job fail → 该通道这次部署标红；beta/stable 晋级前检查"上游通道最近一次演练是否绿"。
- **scrub**：演练到低环境若含真人 PII（messages.body），加 SPEC codex 建议的 scrub（mask 或 exclude-table-data）。当前数据量小、tailnet-only，风险低，但要明确。

## 5. 待 Allen 拍的点（写 handoff 前）

1. **演练覆盖 in-place（reflow 现状，覆盖 nightly/beta）vs 独立一次性 DB（不污染在跑环境）**？← 最大设计点。我倾向独立一次性 DB（演练纯为测迁移、不破坏在跑的 nightly/beta），但若你也想"在 prod 数据上手验 UI"则 in-place。
2. **scrub PII**（messages.body 等）：现在加 mask，还是 tailnet 信任先不加？
3. 每日 nightly 演练 + beta 演练都接 deploy.yml；stable 不演练（它是 source）——对吗？
4. "失败阻断晋级"的粒度：阻断"下一通道晋级"（nightly 演练 fail → 不许 push beta）还是只告警？你说阻断——确认硬阻断。

## 6. 实现清单（handoff 内容预览）

- 新增 `docker/verify-rehearsal.sh`（6 门验证）。
- 硬化/复用：reflow.sh 演练前调 backup.sh；（若选独立 DB）reflow 加 `--ephemeral` 模式用临时 DB。
- deploy.yml：nightly/beta 部署后加 backup→reflow→verify 步；晋级 gate 检查上游演练状态。
- 文档：docs/guide/migration-rehearsal.md（操作员怎么看演练结果、失败怎么办）。
- 不重造 pg_dump（复用 backup.sh）。
