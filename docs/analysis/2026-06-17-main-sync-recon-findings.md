# Main-sync 侦察发现 + 待 Allen 拍板项

**日期:** 2026-06-17
**作者:** 戴明(代 FatNine 推进)
**前置:** [autoservice ezagent-native assessment](./2026-06-17-autoservice-ezagent-native-assessment.md) · [admin UI re-route plan](./2026-06-17-admin-ui-reroute-implementation-plan.md)
**性质:** 纯文档 / 决策征询。代码改动见分支 `fix/content-and-mechanical`。

---

## TL;DR(给 Allen,30 秒)

为了在 #814(`Ezagent.Identity.Grant`,Decision #154)落地后安全推进 re-route,我做了一次**一次性 scratch main-sync 侦察**(把 `autoservice-dev` 合并 `origin/main`,只为摸地形,不落地)。结论:

- **合并机械层 trivial** —— autoservice-dev 落后 main 仅 18 commit,只有 3 个冲突且全是 "keep-both" 并集,合并后**从零编译全绿**。"强迁代码撞 #814 新签名"的担忧被否掉。
- **测试层:21 baseline 失败 → 26(+5)**,这 +5 全是 main 更严的 guard 抓出的存量债。
- **其中 2 个 plugin 侧的,我已自行修好并 push**(A5 cap-axis、#57 未声明 dep)。
- **剩 3 个需要你拍板**,都落在 core/domain / CI-gated catalog —— 见下方 §3。

---

## 1. 合并机械层

| 项 | 结果 |
|---|---|
| autoservice-dev 落后 main | **18 commit**(merge-base `a39c4e66`) |
| 冲突文件 | **3 个,全 keep-both 并集,零语义冲突** |
| 合并后编译 | **全绿**(18 main commit + #814 + autoservice 174 commit,无硬冲突) |

3 个冲突均为"两边都是新增、取并集":
- `system_principal/catalog.ex` — `turn-adapter`(我们的)+ `socialware-gc`(#51)两个 principal 都留
- `no_admin_caps_fallback_test.exs` — 同上(该断言是 list 比对,非硬编码 count)
- `liveview/mix.exs` — content/cr/autoservice + #57 的 domain_pty/agent_bridge,五个 dep 全留

---

## 2. 测试层:+5 失败,按 owner 分类

| # | guard 失败 | 指向 | owner | 状态 |
|---|---|---|---|---|
| **#8** | Catalog 17 个 principal,SPEC §4.1 期望 16 | `turn-adapter` principal | **Allen**(catalog CI-gated) | ⬇ §3.1 待拍板 |
| **#21** | oversized >1000 模块 measured 3 > cap 2 | 合并树叠加效应 | **Allen / domain** | ⬇ §3.2 待拍板 |
| **#22** | god-function `session_creator` 35 def > cap 30 | 同上 | **Allen / domain** | ⬇ §3.2 待拍板 |
| **#11** | 未声明 umbrella dep(#57):`autoservice → domain_workspace` | `customer_session.ex` + seed task | **我们**(plugin) | ✅ 已修 `2fe6ac9e` |
| **#4** | required_caps action-axis A5:多个 action 复用域 cap atom | `ContentAdmin` | **我们**(content) | ✅ 已修 `2fe6ac9e` |

> 另有 ~21 条 pre-existing baseline 失败(merge 前 autoservice-dev 自身就有),是 assessment 里记录的"强迁/跑步机"存量债,与本次 merge 无关,re-route + 后续清理处理。

---

## 3. 待 Allen 拍板的 3 项

### 3.1 `turn-adapter` 第 17 个 system principal(#8)

autoservice-dev 为 Chat→Session turn lifecycle(open / compose / settle / claim)新增了
`system://turn-adapter`,cap = `Capability.cap(:session, Chat, :any)`。
main 的 SPEC §4.1 hard-codes **16** 个 principal,`NoAdminCapsFallbackTest` 断言
`length(uris) == 16`。合并后 17 → 红。

**需决定:**
- (a) main 接纳 `turn-adapter` 进 §4.1(catalog → 17),或
- (b) 这条 turn lifecycle 改用 #814 `Ezagent.Identity.Grant` 的 `:held_by` / `:rule`
  授予路径实现,从而**不需要常驻 system principal**(更符合 #154 把 `{:system,…}`
  逐步转 `{:rule,…}`/`{:held_by,…}` 的方向)。

### 3.2 oversized-module(3>2)+ god-function `session_creator`(35>30)(#21/#22)

`arch_baseline_manifest.exs` 的阈值在 **main 和 autoservice-dev 上完全一致**
(`oversized_modules_gt_1000: 2`、`def_count_session_creator: 30`),且 **main 自身绿**。
但**合并树**测出 3 / 35 —— 即 autoservice-dev 的代码(疑似强迁留下的 monolith)叠加
main 后越过了 governance 阈值。**不是 stale baseline**(否则我直接 bump 就行)。

**需决定:** bump baseline,还是要求 autoservice 侧拆分?
(re-route 完成后 admin LV 会显著瘦身,可能自然缓解一部分 —— 见 re-route plan。)

---

## 4. 我们已经做的(plugin 侧,无需你介入)

分支 `fix/content-and-mechanical`(off `autoservice-dev`):

| commit | 内容 |
|---|---|
| `b8590a03` | content L0/L1 skill 分层修正 + member panel sandbox |
| `00cf2d96` | re-route Phase 0 batch 1 — 4 个 ContentAdmin 写 action |
| `11958f90` | re-route Phase 0 batch 2 — 5 个 ContentAdmin 写 action |
| `2fe6ac9e` | merge-readiness:A5 cap-axis 全改 action-matched + #57 声明 domain_workspace dep |

**Phase 0 现状:** ContentAdmin dispatch 面铺满 **16 个 action**(覆盖 admin UI 全部写操作),
A5 自查零违反,`--warnings-as-errors` 干净,全 umbrella 验证 0 新失败。
operators(add/toggle/disable)故意未纳入 —— 属 identity-domain,留给未来 IdentityAdmin。

**未做(等你 §3 拍板 + caps 通路确认后):** Phase 1(用 `grant_cap_effect` 给 tenant_admin
授一个 `:any` 通配 content cap)→ Phase 2(UI 59 events 改走 dispatch、删
`can_write? = admin_uri != nil` 安全洞)→ Phase 3(E2E)。
