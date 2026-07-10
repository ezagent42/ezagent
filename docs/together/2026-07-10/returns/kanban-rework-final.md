# Return（终版）— kanban 改版收口：全链路证据重做 + #1294 后现实 + 真脑层定界

> **Task:** kanban 改版 #1298 收口（取代 2026-07-09 returns/kanban-rework.md 的 pending 项）
> **Branch:** `feat/sw-kanban-rework`（org）· **Dev:** agent（jjkysy 席位）
> **returned_at:** 2026-07-10 · **deadline_status:** on_time · **CI:** full-suite pass（发本 return 前已确认，新推 docs-only commit 复跑中）

## 相比 07-09 return 的增量
1. **#1294 合入后重验**：安装步骤从"5s 超时如实标注"变为**已修复实证**（无红条 ~1.9s 同步建成，DB invocations 佐证）。
2. **真脑层定界**：cc 401 根因拍死并改写——非"凭证每日过期"，是 **cc-headless flavor 漏 `host_login_dir/0` delegate、#1209 收养链静默 no-op、agent 目录根本无凭证**（宿主凭证有效余量实测 5.2h）。→ **issue #1309**（cc 插件一行修复 + 测试补 cc-headless 面），与本 PR 正交。
3. **证据收口**：删 07-09 三层拼盘 36 件，重做一套连贯全链路证据 26 件（`docs/e2e/2026-07-10/kanban-rework-final/`），README 结论分层确定（用户拍板口径）。

## 最终结论（分层，确定句）
- **看板本体**：真通（被动数据角色，零 mock：动作→持久化→回读全真）。
- **协作 agent 送达层**：真通（真键盘 @ → sidecar 拉起回包）。
- **协作 agent 路由层**：真通（`__done__` 规则命中+双负路径；测法=测试以成员身份注入，README 注明）。
- **协作 agent 大脑层**：未通，被 #1309 挡住（非本 PR 范围；修复后应补一次真脑闭环 e2e）。
- **总结**：kanban 通了 = 看板功能全通 + 协作整条管道全通；agent 自主协作闭环待 #1309。

## 合并判定
**可合。** 依据：①plan 要求"#1298 推进到可合"已满足（四段交付+机器证明）；②CI 绿；③唯一红层根因在 cc 插件（#1309），本 PR 零涉及；④无未决依赖（#1267 两轨确认降级为设计对齐礼貌项，注册表全在 world 插件内部不构成阻塞）。

## 作废的旧说法（勿再引用）
"cc 凭证每日过期"（被 #1309 实证推翻）；"create_session 超时绕开"（已修复）；"#1267 需拍板才能动"（非阻塞）；旧证据目录 `2026-07-09/kanban-rework/`（已删，台账历史引用保留）。
