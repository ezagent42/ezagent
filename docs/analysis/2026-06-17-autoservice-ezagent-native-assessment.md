# AutoService → ezagent-native:迁移评估 + 修复规划

> **作者**:FatNine 团队(Claude Code 协作)· **日期**:2026-06-17
> **状态**:评估,待 Allen + 佳哥 review。文末有**按责任分的 review 分工**。
> **TL;DR**:autoservice-dev 现在大面积红,根因不是某个 bug,而是 **admin UI 把老 autoservice 的"LiveView 里直接写文件"范式强行迁移到了新 ezagent 上**,绕过了 dispatch/CapBAC/CLI 路径。我们建议把 admin UI 的写路径 **re-route 到已存在的 `ContentAdmin` dispatch Behavior**(plugin-only,不动 core)。多数红可以我们自己今天就修;少数需要你俩拍板的,文末列清楚了,**没有阻塞我们开工的核心 block**。

---

## 1. 背景:为什么 autoservice-dev 这么多红

两个事实叠加:
1. **ezagent main 在高速演进**(~10 commit/天)。autoservice-dev 目前**落后 main 16 个 commit**,这 16 个正好砸在地基上:`#54` Role×flavor 系统 + cc orchestrator 迁移、`#154` CapBAC "no unowned permissions" + ratchet、`#57` undeclared-umbrella-dep 新不变式、`#58` 修了 uri_canonicalization seam。
2. **autoservice 是从旧 main 上的实现迁移过来的**,迁移时**保留了旧的实现范式**,而不是改用新 ezagent 的原生机制。

第 2 点是病根。

## 2. 核心发现:admin UI 强行迁移了老 fullstack 范式(有数据)

新 ezagent 的写操作应走 **dispatch → Behavior(cap-gated / CLI-reachable / 可审计)**。autoservice 有一个**正确的原生路径**:`ContentAdmin` Behavior(在 `ezagent_plugin_content`),已有 7 个 cap-gated dispatch action(`write_soul_slot` / `write_skill` / `delete_skill` / `upsert_kb` / `delete_kb` / `publish_cr` / `preview_sandbox`),**被测、能用**。

**但 admin UI 几乎完全绕过它**:

| 指标 | 值 |
|---|---|
| `ContentAdmin` 的 dispatch action | **7** |
| admin UI 实际的写操作 `handle_event` | **59** |
| UI 走 dispatch 的次数 | **9** |
| UI 直接 `File.write`/`SkillStore`/`KbStore`/`CrEngine` 的次数 | **85** |
| admin LV 代码量 | **7333 行**(混合 UI + 直接文件操作) |
| `ContentAdmin` Behavior 代码量 | **220 行** |

dispatch 原生路径在最初 7 个操作建好,但 admin UI v2 把后续 ~52 个操作**全用"LiveView 里直接写文件"实现**,没有扩展 ContentAdmin。差距从 7 涨到 59。

## 3. 代价(不是测试洁癖,是真问题)

1. **安全洞**:admin LV mount 是 `can_write? = admin_uri != nil` —— **任何登录用户能改任意租户的 soul/skill/kb**,因为真正的写没过 CapBAC(只有 dispatch 路径才有 cap 检查)。注释写着"CapBAC enforcement happens at the dispatch level",但代码没走 dispatch —— **代码与注释矛盾**。
2. **违反 P13/P14 + LvCliParity guard**:59 个写操作没有 CLI 等价、不走 dispatch —— UI 不再是"transport"而是 fullstack。
3. **无审计**:直接 File.write 没有 dispatch telemetry。
4. **OversizedModules**:7333 行的 LV 撞 god-function / LOC baseline。

## 4. 实测:sync 到最新 main 让 core guard 不减反增(treadmill 实证)

我们在独立 worktree 把 autoservice-dev merge 到最新 main(**只有 3 个加性冲突,sync 本身很便宜**),然后跑全量:

| | sync 前(d3368baf)| **sync 后(+latest main)** | 变化 |
|---|---|---|---|
| **core 架构 guard** | 21 | **25** | ↑ 4 |
| web `AutoServiceAdminE2ETest` | 6 | 6 | 不变(佳哥功能 bug)|
| content SkillLoader/Indexer | 3 | 3 | 不变(佳哥功能 bug)|
| autoservice(干扰,非 bug)| 5 | 5 | 不变 |

**结论**:main 每次演进都新增 guard(`#154` catalog 分类、`#57` undeclared-dep、OversizedModules),强行迁移的代码立刻多撞几条。**在 fullstack 代码上打补丁是个跑步机,追不上 main。** 而真正的功能红(web 6 + content 3)与 main 无关、sync 前后不变 —— **那是佳哥功能自己的 bug**,独立于 guard 拉锯。

> 注:这 25 里有一条是**我们 merge 的产物**——catalog 冲突我保留了 autoservice 的 `turn-adapter` + main 的 `socialware-gc` → 17 个 principal,而两边的不变式各期望 16。这是 **autoservice→main 正式合并时要 reconcile 的 catalog 问题**(两边各加了第 16 个 principal),不是 autoservice-dev 本身的 bug(它单独是 16,通过)。属 Allen 的 catalog。

## 5. 修复方向:re-route 到 ContentAdmin dispatch

| | 做法 | 评价 |
|---|---|---|
| **A. 打补丁** | 在直写代码上修 warnings/URI/手工加 cap/喂 LvCli 映射 | 治标。债留着 + 每 sync main 重撞(§4 实证)|
| **B. Re-route** | ContentAdmin 从 7 扩到覆盖写操作,UI 改 dispatch | **治本**:cap/CLI/审计全免费;LV 瘦下来过 Oversized;未来 sync main 便宜。**E2E 不变** |
| **C. 混合(推荐)** | 纯 sandbox 文件编辑收敛到少数 cap-gated ContentAdmin write action;状态迁移(publish/rollback/refresh agents)必须走 dispatch。不教条地 59→59 个 action | 拿到 B 的正确性,不盲目膨胀 action |

**关键:B/C 是 plugin-only,不动 core/domain。** ContentAdmin 在 `ezagent_plugin_content`,扩它 + UI 改 dispatch 全在 content + liveview 两个 plugin 里,用的是 core 现成的 dispatch/CapBAC API(plugin 本来就该这么用 core)。**所以我们能自己做,不需要 Allen 改 core。**

## 6. Triage:谁做什么(对照 i/ii/iii 框架)

- **ii — 不碰 core/domain,我们直接改**:warnings-as-errors、10 处 stdlib URI→`Ezagent.URI`、`NoChatBehavior` 残留、plugin `mix.exs` wiring(`#57`)、`DocCoverage` 加 `@doc`、member panel test、**content SkillLoader/Indexer 3 红**、**web admin E2E 6 红**、**admin UI re-route(C)** —— 全 plugin。
- **i — 小修,独立 PR 到 main**:目前没有非碰 core 不可的小修(turn-adapter 见 §4 注,是合并期 reconcile,属 Allen)。
- **iii — 标记 + 给你们,非阻塞**:CsOrchestrator 是否随 `#54` 迁移 Role×flavor;baseline bump(走 C 后很多会自然降,剩的留合并期);catalog reconcile。

**没有"必须你们现在拍板、否则我们动不了"的核心 block。**

---

## 7. Review 分工(按责任)

### 🔵 给 Allen(架构 / core / CapBAC 权威)
1. **方向认可**:admin UI 走 dispatch(P13/P14)+ ContentAdmin 扩展为写路径 —— 这符合你的架构原则吗?有没有更好的原生姿势?
2. **CapBAC 接法**:admin 写操作该用哪种 cap 门控(`content:write` bundle? workspace-admin?),以及和 `#154`(no unowned permissions)/`#88`(creator/manager-delegated grant)怎么对齐。
3. **CsOrchestrator vs `#54`**:main 把 cc orchestrator 迁到 Role×flavor 了。我们的 CS 编排(CsOrchestrator Behavior)要不要也走 Role×flavor?**当前它是工作的,不阻塞**,但想听你方向。
4. **catalog reconcile + baseline**:turn-adapter / socialware-gc 双 16(§4 注);Oversized/Duplicate/DocCoverage baseline 在 autoservice→main 时谁来 bump。

### 🟢 给佳哥(autoservice 实现 owner)
1. **re-route 范围认可**:把你 admin UI 的写路径(59 events / 85 直写)收敛到 ~18 个 ContentAdmin dispatch action —— **这是重构你一晚上的后端**,逻辑基本是搬迁不是重写,E2E 不变。你认可这个方向 + 范围吗?有没有你已经考虑过、我们没看到的约束?
2. **功能红归属**:`web AutoServiceAdminE2ETest` 6 红 + `content SkillLoader L0/L1 + SkillIndexer` 3 红 —— 这些是你新功能的自测红。是你还没跑完,还是要我们帮修?
3. **安全洞**:`can_write? = admin_uri != nil` 是临时占位,还是有意?(re-route 后会自动被 CapBAC 取代。)

---

## 8. 我们今天会先做的(不阻塞,等你们 review 期间并行)

1. 这份评估(本 doc PR)。
2. ii 里的 mechanical:warnings / URI / wiring / doc / member panel —— 快、纯 plugin、立刻减红。
3. 调研 web/content 的功能红根因(先定位,修不修等佳哥确认归属)。
4. re-route(C)开一个独立 PR,从最高价值的写操作(soul/skill/kb/publish)开始,逐步收敛。

**这份评估先公开存档;你们有空按上面分工 review 即可。**
