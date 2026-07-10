# Return（终版）— dealscout 改版收口：全链路证据重做 + orchestrator 真脑通 + kanban 闭环搭车

> **Task:** dealscout 改版 #1301 收口（取代本目录 dealscout-rework.md 的 pending 项）
> **Branch:** `feat/sw-dealscout-rework`（org）· **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-10 · **deadline_status:** on_time · **CI:** 发本 return 前旧 tip full-suite pass；终版 tip 复跑中，绿后方为终态

## 相比首版 return 的增量
1. **证据收口**：删旧套 25 件（#1294/#1311 之前的现实），重做一套连贯 26 件（`docs/e2e/2026-07-10/dealscout-rework-final/`），基于最新 main。
2. **安装无红条**（#1294 后现实）：4.42s 同步建成，requires 递归装出 orchestrator，4 成员全绿。
3. **orchestrator 真脑通（gap⑪ 复测通过，#1311 后第一次）**：真键盘 @ → ~65s 回话，内容准确复述角色分工/信号语义（legend protocol 生效）；不 @ 无回话 = routing 规则语义（`no_match` 如实拍，非故障）。
4. **kanban 真脑闭环搭车证据**（`docs/e2e/2026-07-10/kanban-brain-closure/`，7 件，证的是 main 的 #1311 非本分支）：@assistant 真回话 + `__done__` relay 后 assistant 14s 自主反应 + 负路径零反应 + 新物化 agent 凭证文件铁证。如实边界：assistant 仅回话记账，未发生 kanban.* dispatch（该会话无 board agent）——"自主操作看板数据"仍待后续。

## 最终分层结论（确定句）
发布 ✓ / 安装 ✓（无红条）/ **orchestrator 真脑 ✓** / @discover 真爬 ✓（py 3s 真 HN 数据）/ routing 命中 ✓ / crawl 数据面 ✓（CapBAC 身份注入+slice 回读）/ 自动发布 ✓（零干预 committed）/ **匿名公开页 ✓**（零 cookie 两轮 20→40 条真数据）。
两处如实缺口（均非本分支引入、不修）：routing→native 投递死（#1201②，平台）；「线索」view 主区渲染腿（kanban 同源既有缺口，internal render 已实证数据真）。

## 合并判定
**可合。** ①目标四条全满足（功能不变/真实组合 socialware/真页面真数据/四旅程划分——PR body 有归属表）；②全套 gate 绿 + 旧 tip CI pass、终版 tip 复跑中；③两处缺口均为平台既有、有 issue/归属；④基于含 #1294/#1311 的最新 main，无未决依赖。

## 作废的旧说法
"orchestrator 摆设/会话没人应答"（gap⑪ 已被 #1294+#1311 联合修复，本套实证）；"cc 凭证每日过期"（#1309 定界+#1311 修复）；旧证据目录 dealscout-rework/（已删）。
