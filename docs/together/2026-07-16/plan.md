# Dev-together — 2026-07-16 团队 plan（开工 prompt 引用此文件）

**本周目标：agent 开发自举（dev-loop 自举）** —— 让平台能被用来开发 agent、企业用户能自助开 workspace 跑 dev-loop。今日各条 track 都服务这个目标。**注意：不要在中间分支上深挖过多**（手段服务目标，别把支撑线做成 headline）。

每条 track 写明 **目标 / 今日任务 / 验收标准 / 相关 PR**。开工时在你的 prompt 里引用本文件对应段落。

---

## gaga — agent 开发自举（Git provider dev-loop / provisioning）
- **目标**：把"企业/开发者能在平台上自助开 workspace 并跑 agent dev-loop"的 provisioning 打通（凭证隔离 + Git provider）。
- **今日**：继续 #1423 **Plan A**——安全前置（Secret Store / SSH parser / Cap / plugin 盘点 + sentinel 复现同 UID 凭证暴露 + SSH broker GO/NO-GO）+ **W29 最短路径原型**（公共仓库匿名 checkout + GitHub Git Data API 建 commit/branch/PR）。
- **验收**：Plan A 输出明确 transport 决策 + 接口；不碰 canary/生产凭证/merge；SSH 隔离证不出就诚实标 blocked、不用临时私钥。
- **PR**：#1423（Draft，设计 review 与 Plan A 并行）。

## zyli — CI 完善（第一优先级）→ UI 完善（与 ruihua）
- **目标**：CI 是 dev-loop 的地基，先扎实；再和 ruihua 过 UI 并开始开发。
- **今日**：**① CI 完善（P1）**——续 #1415（前端 tsc+vitest 已进 gate）的后续：Playwright/E2E smoke + 独立前端 CI workflow / 针对 CI 配置本身的回归测试。若接前端 Tier-1 Playwright handoff（`docs/superpowers/handoffs/2026-07-15-frontend-tier1-playwright-e2e-zyli-handoff.md`）：仅前端、跑 ubuntu gate、**fixture 从后端契约投影生成 + 漂移门**（杜绝 mock-drift）。**② UI（P2）**——和 ruihua 一起过 UI 完善问题清单，开始开发。
- **验收**：CI 项目落地且绿（新增回归门存在、演示一次它能红）；UI 问题清单达成一致、有优先级。

## ruihua — 企业自助 workspace（产品化）+ UI（与 zyli）
- **目标**：把"企业自助开 workspace"从功能排查推进到**产品化可交付**。
- **今日**：**①**（PR 落地后）拿到那条"效率统计 + 企业自助开 workspace 功能排查"PR，**从产品角度完善计划、明确验收标准**，作为下段规划。**②** 和 zyli 一起过 UI 完善问题、定优先级。
- **验收**：workspace 自助开的产品计划有**明确、可验收的验收标准**（用户旅程 + 每步成功判据）；UI 问题清单对齐。
- **PR**：那条 workspace PR（还在 commit，落地后填号）。

## zhaomaota — 收口 #1425 产品缺口（1）+ 分诊 #1134（2）
- **目标**：Hello 官网是用户入口，把昨天合的 #1425 打磨到产品可用，并清掉陈旧 PR。
- **今日**：
  - **① 收口 #1425 缺口**：Hello 回执现在是**委派时刻快照**（用户看不到回流）→ 改成**活刷新，或明确引导去 World Kanban 看活板**；补**跨-workspace 接收拒绝**测试（invariant #13）；在**真实部署栈**上验回流（disposable 栈起不来接收方的活 kanban tab）。参考 `docs/notes/2026-07-15-kanban-reflux-deploy-verify.md`。
  - **② 分诊 #1134**（2 周前的 hello PR：concierge + publish-as-template + 公开只读 + 官网导航 + world durable listings）：和 #1425 比，被覆盖了还是有独有内容？**rebase 抽独有部分重开，或关闭**。
- **验收**：① 回执不再误导用户（活刷新或明确跳转）+ 跨-workspace 拒绝有测试 + 真实栈上录到回流；② #1134 有明确处置（重开干净 PR 或关）。
- **PR**：#1425（已合）、#1134（待分诊）。

## jjkysy — #1374/#1376 去重收口 → 干净协作白板 PR
- **目标**：#1425（已合 main）已覆盖 mount/share/cap；把 #1374 的独有部分干净化。
- **今日**：① 从 main（含 #1425）起干净分支；② 把 #1374 里**独有的「认领式协作白板改版」**（去 gh + 普通用户全链 + 协作白板 UX）抽出、和 #1425 已有的分享/挂载/cap **去重**，重开一个**干净 PR**；③ 关闭 #1374 和 #1376。
- **验收**：新 PR 不含 #1425 已有的 mount/share/cap 代码、只留协作白板独有改动、gate 绿；#1374/#1376 已关。

## Allen — 部署 + cap-signing（稍后讨论）
- 部署（beta/stable 用新 seed 晋级）你们来。cap-signing 严格化实现稍后与 Claude 讨论再定投入。

## Claude（协调）
- 盯 ruihua workspace PR 落地 → 纳入她 track + 转达。跟进 jjkysy 去重、zhaomaota 收口。cap-signing 已完成 spec+plan（`feat/cap-strict-capstore`），**按你指示暂缓实现**。团队清障 + 验收合并。
