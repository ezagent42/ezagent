# dev-together hand-off 标准 + 标准 return 文件（the standard return artifact）

> 本文 = **按 `dev-together` skill 运行的结果**：给出一份**标准 handoff 文件模板**和一份
> **标准 return 文件模板**，可直接复制套用。它把 skill 的两个 reference 落成可粘贴的骨架并
> 逐字段讲清：
> - `.claude/skills/dev-together/references/handoff-standard.md`（four-property DoD /
>   discuss-first triggers / defer rules / per-task-branch merge model）
> - `.claude/skills/dev-together/references/handoff-template.md`（copy-paste 骨架）
> - `.claude/skills/dev-together/commands/return.md`（return 的必填 metadata + DoD-reconciliation 块）
>
> **这是 contract，不是建议**：handoff 缺字段 = 任务没 ready；return 缺字段（如无 `returned_at`/
> `deadline_status`，或 DoD 不是逐行 reconcile）→ `push` 会把它标 `blocked`，`close` 不会 merge。

---

## 0. 这套标准为什么这么写（一句话各条）

- **per-task branch + lead-merge**：并行 dev 不撞车，给一个 accountable 集成点（`push`+`close`）。
- **handoff 前对抗式 review**：抓「方向错」（wrong-approach），不只抓缺陷。
- **clarify/research 前相位**：lead 不把一个「DoD 还写不出来」的 build 任务派出去。
- **goal-derived + user-layer + closed-set DoD + machine return gate**：堵死「绿测试、坏产品」
  和「自述 done」。
- **deferral 由 lead 裁定**，绝不是 dev 的「READY TO MERGE」。
- **method-deltas**：让闭环*学习*（教训不再复发）。

---

## 1. Definition of Done — 四属性（four-property DoD，全部必须）

DoD 是让任务「done」的**闭集 checklist**。「Tests pass」**必要但不充分**——作者自选子集、
证明「跑过一次」而非「不会回归」、验错层，都会放过「绿测试、坏产品」。DoD 仅当满足以下四条
才有效：

1. **Goal-derived（从 goal 枚举，非便利子集）**。**迁移/替换**类任务从**真相源**枚举
   （如「frontend catalog == backend catalog」，parity diff == ∅），绝不手挑一组。
2. **Verifiable，且自带 proof（每行写明*怎么证*）**：
   - **UI / frontend** → 一个**穿过真实 surface** 的自动化测试（LiveViewTest mount 路由 /
     agent-browser 脚本驱动），feature 坏就 fail。**agent-browser 截图是人读的伴随物，不是
     proof。**
   - **Agent / chat / session** → **来自真实 channel 的成功 transcript**（agent 真回复，不是
     unit stub）+ 一个自动化回归测试。
   - **Backend / API** → 一次 **E2E run 输出**（请求打到新路径、返回期望 shape）+ 该路径自己的测试。
   - **Cross-layer**（一个 contract + 它的 consumer，如 backend catalog ↔ frontend renderer）
     → **从 contract 枚举的 parity checklist** + 一个**端到端产品 proof**（生成→渲染→眼看），
     不是单层 unit 测试。**cross-layer 任务只做 backend「done」 = 被拒。**
   - **Demo 类**（设计确认）→ **demo merged + 可在 Tailnet 看** + 设计 sign-off。
3. **At the user-facing layer（在用户/operator 真正碰的层）**——不是内部 seam。backend-seam
   测试过、但路由 404 = **不是 done**。
4. **A closed set（闭集）**——dev 可 **defer** 一行（→ lead 裁定，见 §3），但**绝不删**一行。
   Done = **每一行**绿。

- **永远附加**：所有 gate 绿——`arch.scan` / `doc.scan` / `uri_query.scan` /
  `check_invariants` / `format` / `test` / `:ezagent_plugin_check` + **这活自己的
  invariant/回归测试**，**且 CI 在 PR head 绿 + 分支 rebased on `main`**（machine return gate，见 §4）。

> **Litmus**：每行都过时，一个 fresh reviewer 会同意 **goal** 达成、没有重要东西未证——是人
> reviewer 会查的一个*超集*。
>
> **谁写 DoD**：常常**research 之前写不出来**——这类任务由 **clarify/research 前相位产出 DoD**（见 §2）。

---

## 2. Discuss-first triggers → clarify/research 前相位（tiering criterion）

这些 trigger **也是 tiering 准则**。命中**任何一条**，任务**不**直接进 build handoff：lead
先发 **research handoff**（一个 `clarify_first` 任务），它的 deliverable 是 **findings + 提议
的 build 切片 + DoD**；只有它（经正常 `dive`/`return`）落地后，lead 才发 **build handoff**。

触发条件（命中任一即 discuss-first）：
- 方案有**多于一个可行选项且有真实 trade-off**。
- 碰 **CapBAC/authorization**、**core**（multi-app 改动）、或某条**横切不变式**。
- **偏离北极星**（let-it-crash / no-workarounds、plugin isolation、external-integration-is-an-Adapter、no-unowned-caps）。
- 设计**搁在一个未验证的 codebase 假设**上。
- 是 **scope / MVP-line** 决策，或 **scope / feasibility / DoD 还不可知**（任务带真实未知）。

**Fast path**：没 trigger → 已批准设计内的机械活、follow established pattern → 直接 build
（`plan` → build → CI gate → merge）。小/清楚的任务**不**被强行塞进 research 相位——避免流程变 ceremony。

---

## 3. Defer 规则（deferral is the LEAD's call）

- **仅当显式 flag + 带 target（某后续 phase / issue）才可 defer**：后续 phase 宽度
  （token-level streaming、高级编辑器）、非 load-bearing 的打磨、可选优化。
- **deferral 是 LEAD 的判断，不是 dev 的**。defer 任何 DoD 行的 return 设 `deadline_status:
  deferred`，把每条 deferred 列为**给 lead 的 open decision**；「READY TO MERGE」是 lead 在
  `close` 的裁决，**绝不是 dev 在 `return` 的**。
- **永不可 defer**：**load-bearing 设计决策**、**同一 PR 里当下可解的**、**gates/invariants**、
  **需要人的步骤**（flag 出来，别 silently scope past）。

---

## 4. Merge model + machine return gate

- **Merge model**：一个任务想拆多少 PR 都行；**所有 PR merge 进任务自己的分支，绝不进
  `main`**；分支保持 **rebased on `main`**。DoD 满足时，**lead** 把任务分支 merge → `main`
  （经 `close`）。**lead 是唯一通往 `main` 的路。**
- **Machine return gate**：「done」不靠自述。`return` 要求 **CI（`precommit +
  check_invariants`）在 PR head 上绿 + 分支 rebased on `main`**（分支保护结构性强制）。return
  里要放 **CI run URL + status** 和 **rebase-base SHA**——「gates green」当声明**不被接受**。
  lead 的 `close` 因此变成**确认**，而不是第一次真审查。

---

## 5. 标准 HANDOFF 文件模板（copy-paste）

> 存到 `docs/superpowers/handoffs/YYYY-MM-DD-<topic>-handoff.md`（durable spec）或
> `docs/together/<date>/handoffs/<task>.md`（每日操作日志）。填满每节；删某节只有在你能说清
> *为什么它不适用* 时才行。

```markdown
# Handoff: <title>

> **Date:** YYYY-MM-DD · **From:** <author> · **To:** an independent developer (human + cc/codex)
> **Tracking:** <task/issue> · **Base:** `origin/main` @ <sha>
> **Branch:** `<per-task-branch>`
> **Status:** <brainstormed | codex-reviewed | confirmed> — <one line>
> **Type:** <build | clarify_first(research)>   # research handoff 的 DoD = findings + slices + build DoD

## 0. Mission
<一段话：做什么 + 为什么。一个忙碌 dev 需要的那一句。>

## 1. Required reading（写代码前）
1. Skill `ezagent-developer` —— gate 你 PR 的 invariants（always）。
2. <其它项目 skill：ezagent-socialware / ezagent-session-orchestrator / …，按相关性>
3. `docs/guide/world-coordination.md` —— 若碰 `world` 则 REQUIRED。
4. `dev-together` skill —— 这套 workflow + 本标准。
5. <本工作所建之上的设计 spec / research note，按路径>

## 2. Locked decisions（brainstorm 已定，别重新 litigate）
| # | Decision | Value |
|---|----------|-------|
| 1 | … | … |

## 3. Architecture primer（给新上手这块代码的 dev）
<最小心智模型 + 这活所建的确切 modules/seams，带路径。>

## 4. Design（+ review status）& phased plan
<方案；若做过 codex 对抗 review，标 "codex-adversarially-reviewed YYYY-MM-DD"。
然后 Phase 0 / 1 / … 作为 PR 大小的单元。>

## 5. Definition of Done —— 闭集 checklist（四属性，见 §1）
<Goal-derived（迁移类：从真相源枚举，parity == ∅）· verifiable + 自带 proof ·
在 user-facing 层 · 闭集。dev 在 return 逐行 reconcile；可 defer（lead 裁定），绝不删。>
- [ ] <DoD 行 1 —— 其 proof：穿过真实 surface 的自动化测试（LiveViewTest mount 路由 / agent-browser 驱动）；截图是伴随物，不是 proof>
- [ ] <DoD 行 2 —— …>（cross-layer：从 contract 枚举的 parity checklist + 端到端产品 proof，不是单层 unit）
- [ ] 所有 gate 绿：arch.scan, doc.scan, uri_query.scan, check_invariants, format, test, :ezagent_plugin_check
- [ ] 这活自己的 invariant/回归测试
- [ ] **CI（`precommit + check_invariants`）在 PR head 绿 + 分支 rebased on `main`**（machine return gate）

## 6. Discuss-first vs Deferred（都显式）
**Clarify-first?** <若命中 discuss-first trigger，本应先以 RESEARCH handoff 进来（findings + slices + DoD），再来这份 build handoff。>
**Discuss-first（lead 确认前不许 build）:** <命中 discuss-first trigger 的项>
**Deferred（flag + target；LEAD 在 return 裁定，非 dev 自述）:** <后续 phase 范围，带 target phase/issue>
**Never deferred here:** load-bearing 决策、in-PR 可解项、gates、需要人的步骤。

## 7. Conflict-avoidance
<本任务 own 的 surfaces/files。若碰 world：链 world-coordination.md + 往其 in-flight registry 加一行。>

## 8. Merge model
PR merge 进任务分支 `<branch>`（绝不 `main`）；保持 rebased on `main`；DoD 满足时 lead 把
`<branch>` merge → `main`。

## 9. Gates、file/LOC 估算、open questions
<gate 清单；新文件 + 粗略 LOC；给 lead 的问题。>
```

---

## 6. 标准 RETURN 文件模板（copy-paste）—— hand-off 的**标准 return 文件**

> 存到 `docs/together/<date>/returns/<task>.md`。这是 dev 在 `return` 命令产出的 artifact，
> 也是 `push`/`close` 唯一接受的 done 凭据。**三块强制**：①必填 metadata（含 `returned_at`/
> `deadline`/`deadline_status`）②逐行 DoD reconciliation ③method-friction。

```markdown
> **Task:** <id/name>
> **Branch:** `<branch>`
> **PR:** <url-or-number-or-none>
> **Dev:** <human-or-agent>
> **returned_at:** 2026-06-30 07:12 +0800
> **deadline:** 2026-06-30 20:00 +0800
> **deadline_status:** on_time          # on_time | late | deferred | out_of_scope
> **CI:** <run-url> — <green/red>        # machine return gate：必须 green on PR head
> **rebase-base SHA:** <main-sha>        # 分支 rebased onto 这个 main SHA

## 1. What's done
<这次交付了什么——一段话。>

## 2. DoD reconciliation（每个 return 必填，哪怕全 met）
逐行过 handoff 的 DoD。"All met" 本身是一个信号，所以此块**永远必填**：

| # | DoD line（抄自 handoff §5） | status | proof / open decision |
|---|------------------------------|--------|------------------------|
| 1 | <handoff DoD 行> | met | <test 路径 / E2E 输出 / 真 channel transcript / agent-browser 脚本链接> |
| 2 | <行> | deferred | <为什么 + 给 lead 的 open decision（target phase/issue）> |
| 3 | <行> | not-met | <缺什么> |

**Method friction:** <流程里（handoff/DoD/scope）哪块写错了或事前不可知、本该先 clarify —— 或 "none">

## 3. DoD proofs（路径/链接）
- <DoD 行 1 的 proof artifact 路径/URL>
- <…>

## 4. Gate status
- gates: arch.scan ✓ / doc.scan ✓ / uri_query.scan ✓ / check_invariants ✓ / format ✓ / test ✓ / :ezagent_plugin_check ✓
- 本活自己的 invariant/回归测试: <路径> ✓
- CI on PR head: <run-url> green · rebased on `main` @ <sha>

## 5. Deferred follow-ups + open decisions（若有）
<把已完成部分干净 split 到自己的分支（gates 绿）交出去；把每条 deferred 列为给 lead 的 open
decision——绝不自述 "READY TO MERGE"。>

## 6. Merge request
<哪个 branch/PR、rebase/顺序 note、与别的 return 的依赖。>
```

### `deadline_status` 取值

| 值 | 含义 | `push`/`review` 怎么对待 |
|---|---|---|
| `on_time` | deadline 前返回 | 正常进 stack |
| `late` | 有效 work，但 deadline 后返回 | 留在 `returns/`，由 `push` 决定进今日 stack 还是次日 plan，**显式 call out** |
| `deferred` | 有意 split 的 follow-up，带 target issue/plan | lead 裁定；不当已完成计 |
| `out_of_scope` | 不在今日 plan 内 | 保留 artifact，但**不**当 planned work 计 |

---

## 7. demonstrable-DoD 怎么写（最容易写错的一点）

「demonstrable」= **每条 DoD 行都指向一个会因 feature 坏掉而 fail 的东西**，且这东西穿过**用户
真正碰的层**。对照 §1 属性 2 选 proof 类型：

| 改动类型 | ✅ demonstrable proof | ❌ 不算 done |
|---|---|---|
| UI / frontend | LiveViewTest mount 路由 / agent-browser 驱动脚本（坏就 fail） | 只有截图；只测内部组件函数 |
| Agent / chat / session | 真 channel 的成功 transcript（agent 真回复）+ 回归测试 | unit stub「假装回复了」 |
| Backend / API | E2E run 输出（请求打到新路径、返回期望 shape）+ 路径自己的测试 | 只测内部函数、路由其实 404 |
| Cross-layer | 从 contract 枚举的 parity checklist + 端到端产品 proof（生成→渲染→眼看） | 只做 backend「done」（被拒）；只有单层 unit |
| Demo（设计确认） | demo merged + Tailnet 可看 + 设计 sign-off | 本地能跑、没合、没人看 |

**写法**：每行 = `<要达成的事> —— proof: <具体测试/E2E/transcript 链接>`。截图永远是**伴随物
（companion）**，不是 proof。迁移类一定从**真相源枚举**全集（parity diff == ∅），不手挑。

---

## 8. machine return gate（done 不靠自述）

`return` 在结构上有效的硬条件（CI + 分支保护强制，不是礼貌请求）：

1. PR 的 **CI = `precommit + check_invariants`**，**在 PR head 上 green**。
2. 分支 **rebased onto 当前 `main`**。
3. return 文件里**写明 CI run URL + status + rebase-base SHA**——「gates green」当口头声明不被接受。

满足后，lead 的 `close` 是**确认**而非第一次真审查；任一不满足，`push` 标该 return `blocked`，
`close` 拒 merge。divergence（DoD 其实写错了）应在 `return` 的逐行 reconciliation 里**第一时间
暴露**，不是拖到 `close`。

---

## 9. 在 kanban-on 上跑时的差异（一行）

跑在 live 看板上时（`kanban-on-ezagent`），handoff/return 的**标准不变**，只多两点：handoff 的
DoD 含「**live 节点经 dispatch 推进 + artifact 经 `attach_artifact` 挂上**」，return 的 metadata
多带 **board node id + 这次 dispatch 了什么动作**；dev 的 return 经 `session send` 发回会话后，
一条 **sender-locked relay-back 路由规则**（`from(dev) AND in_session(session) → [pm]`）自动把
它路由回 pm-coordinator——**不靠 `@pm` 文本 parse**。细节见
`docs/guide/bootstrap-development-with-kanban.md` §③ 与 `.claude/skills/kanban-on-ezagent/`。
