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

## ruihua — 企业自助开通 workspace（产品化）+ UI（与 zyli）
- **目标**：把 **#1427** 的"自助开通 workspace 缺口清单"从工程排查推进到**产品化、可交付、可验收**的下段规划。
- **今日**：
  - **① 接手 #1427**（`docs/plans/2026-07-16-workspace-self-service-gaps.md`）——里面已有 P0 硬闸门（G1 注册开关无 UI / G2 邀请码仅 CLI / G4 founder 无权自配 agent API key / G5 缺 key 失败态不可行动）、P1 可发现/可恢复、P2 业务闭环。**从产品角度完善**：把每条缺口写成**用户旅程 + 每步明确验收标准（成功判据）**，排出交付优先级与阶段。
    - 注意 **G4 依赖 agent 授权模型收口**（= cap-signing 那条线），产品计划里把它标为**有依赖项**、给出"依赖未就绪时的降级/占位"方案。
    - #1427 里的**工程效率分析**（`engineering-efficiency-analysis.md`，session 工时下界）作为**规划的产能参考**（读数纪律：下界、agent 墙钟≠人力、禁止个人绩效用途）。
  - **② 和 zyli 一起过 UI 完善问题清单**、定优先级，开始开发。
- **验收**：自助开通 workspace 的产品计划有**逐条、可验收的验收标准**（每条缺口 = 用户旅程 + 成功判据 + 优先级/阶段 + 依赖标注）；UI 问题清单与 zyli 对齐、有优先级。
- **PR**：#1427（工程效率分析 + 自助开通 workspace 缺口清单）。

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

## Allen — 部署 + 统筹 + dev-together 模板统一
- 部署：beta/stable 用新 seed（`EZAGENT_SIGNING_SEED_V1`）人工晋级；确认 canary 已载昨日全量。
- 统筹各条 track、清障、验收合并；cap-signing 严格化实现稍后再定投入（spec+plan 已在 `feat/cap-strict-capstore`）。
- **dev-together HTML 模板统一**：plan 与 review 用同一套模板/CSS（即 2026-07-15 `review.html` 的风格——蓝色 h1 下边线 + 蓝左边线 h2 + `.kpi`/`.big`/`.risk`/表格），并把 dev-together skill 的 review/plan 生成步骤固化引用同一模板，避免再出现风格不一致。
