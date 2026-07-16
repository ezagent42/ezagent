# Return: kanban 协作改版 round2(kanban 自包含整包)

> **Task:** kanban-collab-round2(fix-plan v3 的 PR1「本 PR #1374 收尾」+ PR2 发布侧 + 债② 可搬半)
> **Branch:** `feat/kanban-collab-round2`
> **PR:** #1374 线(收尾推送到同一 PR 分支)
> **Dev:** jjkysy + Claude(agent)
> **returned_at:** 2026-07-17 03:30 +0800
> **deadline:** 2026-07-17(当日)
> **deadline_status:** on_time

## 干了什么(16 commits:后端 9 + 前端 6 + 搬迁 1)

围绕 2026-07-16 定稿的修法计划(`docs/notes/2026-07-16-kanban-fix-plan.md` v3),把「kanban 自包含」归属内的全部项落地:

- **行为层**:㉕ drop 重定义为非破坏跟踪标记(标红不删,记理由/历史,授权=认领人或版主);⑲ `kanban.delete_board`(版主校验→retire+清挂载,不直调 terminate);⑳ 建板 assistant 钥匙从硬前置降级为增强(主链=宿主+建板人钥匙)。
- **分层债**:债③ 分享接收业务从 web controller 搬进 plugin `receive_shared_board`(controller 瘦成 verify+调用+redirect),并收敛 receive 链不发 render cap(撞 I12 铁闸,TODO 归 Allen D1/D3);债② 可搬半——`kanban_data`/`kanban_actions` 从 world 搬进 plugin_kanban,world 只留 @pages 注册数据;债① 半步——BoardProvision kanban 默认值上提为调用方必填参。
- **推送环(kanban 半+发布侧)**:㉘/㉒-① 写动作成功广播 `:kanban_changed`,同会话成员画布自刷新。
- **前端(kanban 面整包)**:㉗ 节点面板按规格重做(吸收 ㉓ 去本图配置块、㉖ 名称就地编辑、㉞ 摘「✓已保存」;产物区「添加」+下拉 链接/内容/画图/附件+每产物删钮+「内容」md 大框);㉕ 红框渲染+面板理由;⑲ 导图列表删钮+确认框;㉙ 分享对话框两选项;㉚ 剪贴板回退+真实成败反馈;㉝ world 通用链接 unfurl 注册机制(kanban 首消费者);⑱ kanban 面硬编码浅色 token 化。
- **配置**:⑮ dev 确认信链接域名覆盖为本地。

## DoD 对账(本轮任务单 vs 实际)

| # | DoD 线(fix-plan PR1/PR2 任务单) | status | 证据 |
|---|---|---|---|
| 1 | ㉕ drop 标红(behavior 非破坏标记 + KanbanCanvas 红框 + 理由/历史) | met | commits 1d9243257+9e810572c;e2e `docs/e2e/2026-07-17/r02-drop-red.png`(红框+理由+drop历史,服务端 authz granted) |
| 2 | ⑲ delete_board(动作 + 删板 UI + 确认框) | met | commits 79f0cdd24+50cf5e513;e2e r03/r03b(确认弹窗文本捕获,demo-board 真删,列表消失) |
| 3 | ⑳ assistant 钥匙降级为增强 | met | commit 772b64215;e2e r08(无 assistant 会话建板)——见 README 结论 |
| 4 | 债③ receive 搬 plugin | met | commits 7f32a44a8+ccdce242a;controller 瘦身,receive 路由回归通 |
| 5 | ⑮ dev.exs 确认信域名一行 | met | commit e24b9b0d2 |
| 6 | ㉗ 面板规格重做(含㉓㉖㉞) | met | commit 889e84f9c;e2e r01(无配置块/就地编辑/一排一信息/产物四选项下拉/无已保存) |
| 7 | ㉙ 分享两选项 UI + ㉚ 剪贴板回退 | met | commit 657ec1c5c;e2e r04(两选项框)+r05(分享到会话气泡);㉚ 的 http://<IP> 回退路径未在本轮 e2e 单独验(localhost 是安全上下文),留下轮手测 |
| 8 | ㉘/㉒-① 推送环 kanban 侧(+PR2 发布侧 :kanban_changed) | met(kanban 半) | commit 7120b147f;e2e r09 双浏览器验证——见 README 结论;world 订阅基建半边在 zyli #1443 |
| 9 | ㉝ unfurl 整条(注册机制+气泡+点击跳转) | met(渲染+机制) | commit 6629c1919;e2e r06(粘链接渲成气泡);点击挂载落点修正归分享二期 PR4 |
| 10 | kanban 组件深色 token 化(⑱ kanban 半) | met | commit 20ba01122;e2e r07;Conversation 层归 zyli #1443 |
| 11 | 债② 可搬半(kanban_data/kanban_actions 进 plugin) | met | commit d5655c715;fixtures manifest 重生成 dea46aa5b |
| 12 | 证据/文档收敛(PR 收尾规矩) | met | `docs/e2e/2026-07-17/`(截图+README+AUDIT.md ㉞ 项对照表)+ 本 return |
| 13 | 机器 return gate(CI 绿 + rebase main) | not-met(如实) | 本轮在 worktree 分支上连续推进,未跑 CI/未 rebase 到最新 main;**开放决策给 lead**:收口前补 rebase+CI |

**Method friction:**
- agent-browser 对**原生 window.confirm** 无截图路(CDP 截不到原生框):删板确认弹窗只能以 CLI 捕获文本+删除结果图作证。后续凡「确认框」类 DoD,规格里应写明自定义 modal 还是原生 confirm——原生的 e2e 证据形态不同。
- 分享 modal 依赖 `world:state` 回推,**弹出有秒级延迟**,固定 sleep 后 snapshot 会漏;agent-browser 场景应改「轮询 snapshot 至元素出现」。
- e2e 中途撞上驱动方 API 断流(分类器不可用),只读操作可继续但浏览器操作全阻塞——长 e2e 应把「拍图脚本化成单条 bash」减少中断面。

## 分支 + gate 状态

- 分支:`feat/kanban-collab-round2`(worktree kanban-progress-board),本轮 16 个实现 commit + 本次证据/文档 commit。
- gate:`mise exec -- mix compile` 干净;真 UI e2e 见 `docs/e2e/2026-07-17/README.md`(逐项截图+结论);CI/rebase 未跑(DoD #13,开放给 lead)。

## Merge request

- 请 lead 将 `feat/kanban-collab-round2` 按 #1374 线收口:先 rebase origin/main + CI 全绿,再进 stack。
- 顺序注意:与 zyli #1443(world 前端)在 `Conversation.tsx`(unfurl 消费点)有相邻面,建议本分支先进;gaga #1444 无文件冲突。
- ⏸ 项(D1-D6)与 📋 项(join 补发 PR3/分享二期 PR4)见 `docs/e2e/2026-07-17/AUDIT.md` 汇总,不在本 return 范围。
