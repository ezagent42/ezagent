# Handoff: D3 — render-cap baseline 发放半件(infra,与 D1 同车)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** an independent developer
> **Tracking:** 开工单 v2 终版 infra 清单 #2 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(记录型——D3「方案a tab 恒显」Allen 已拍;此为其 **infra 半件**备案)

## 0. Mission
D3 = kanban tab 恒显,两半:① `BoardView.applies_to?` 恒 true(kanban 文件,归 PR-K);② **`kanban_render` view cap 按 plugin 基线发给全体登录成员**(否则恒显的 tab 被 view-cap gate 拒,空窗)。本 handoff 只管半件 ②:发放点在 domain_session,走 **D1 同一 shared helper 供给点**,不另起 grant 点。

## 1. Required reading
1. Skill `ezagent-developer` + `ezagent-socialware`。
2. `D1-join-replay-helper.md`(同目录)——供给点宿主。
3. `docs/together/2026-07-16/handoffs/allen-decisions.md` §D3。
4. `docs/notes/2026-07-17-xy-review.md` §4 D3 条(D3 先落削掉 D1 view-cap 半边的耦合)。

## 2. Locked decisions
| # | Decision | Value |
|---|----------|-------|
| 1 | 方案 | a:tab 恒显(`applies_to?` 恒 true)+ render cap 全员基线发放 |
| 2 | 发放点 | D1 shared helper(join/install 路),**不新增独立 grant 文件**(I12) |
| 3 | 契约不动 | `authorize_view` T2-2b 契约保持——发 cap 让 gate 过,不是绕 gate |
| 4 | 顺序红线(重解释) | 原「恒 true 与发 cap 同 PR」防"恒 true 先落被 gate 拒"空窗;file 级切分后改为**顺序约束:本半件(infra)先合,PR-K 翻 `applies_to?` 后合**——cap 先发无害(tab 未恒显=现状),空窗方向安全 |

## 3. Architecture primer(现象/原因)
- **现象(㉜/㉟ 深层)**:未装 kanban sw 的会话不见 tab;新成员无 `kanban_render` cap 时 tab 也被拒。
- **原因**:view cap 现在只有两条发放路——installer(`Installation.grant_installer_view_caps/2`,installation.ex:348-385,由 session_creator.ex:725 驱动)与 anon(`anon_view_caps/1`,installation.ex:306-322);登录后加入的普通成员两路皆不覆盖。cap subject 实体:kanban plugin application.ex:151 `{Ezagent.Entity.Session, :kanban_render, Ezagent.ActionSet.KanbanRender}`(manifest views: `kanban_render`)。
- **落点**:发放逻辑住 domain_session(D1 helper 的 view-caps 分支按「plugin 基线 view 清单」枚举);kanban 侧零代码——manifest 已声明 view,plugin 不加 grant 点。

## 4. Design & plan
单 PR(与 D1 同车或紧随):helper 的 member-view-caps 分支实现「plugin 基线 view → 全体登录成员」口径;rule tag 同 `{:rule, :socialware_member_views, member}`。

## 5. Definition of Done
- [ ] 任意登录成员(含 join 后新成员)持 `kanban_render` cap——helper 单测 + join e2e 断言 cap 存在
- [ ] `authorize_view` gate 原样(T2-2b 契约测试零改动)
- [ ] 与 PR-K `applies_to?` 翻转联测:翻转后任意会话见 kanban tab、无钥匙者 tab 内容=空板集合(人本位口径)——agent-browser e2e(此行在 PR-K 侧勾,这里登记为跨 PR parity 项)
- [ ] All gates green(arch.scan/doc.scan/uri_query.scan/check_invariants/format/test/:ezagent_plugin_check)
- [ ] CI green + rebased on `main`

## 6. Discuss-first vs Deferred
**Discuss-first:**「全体登录成员」的边界(访客/observer 是否含)一句话请 Allen 确认。
**Deferred:** 非-kanban plugin 的 view 基线接入(机制通用,首个消费者是 kanban)。
**Never deferred:** 与 PR-K 翻转的顺序约束。

## 7. Conflict-avoidance / 8. Merge model / 9. LOC
与 D1 同分支同 PR(推荐)或紧随;文件面 = D1 helper 模块 + installation.ex;与 PR-K 零交集。增量 ~50-100 LOC。开放问题:发放口径边界(§6)。
