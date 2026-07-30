# A5 — 匿名分享（link_anon）接线（**v3**，撤回 v2 的「去 Mount」立论）

- **status**: proposed — design-first。**v3 撤回 v2（同日早些时候）的核心立论**：v2 宣称「方向是删 Mount」并把 A4 从依赖里移除 —— **经独立取证,该立论不成立**（§0）。v3 回到 Allen 已批准的形状,并补上 v1/v2 都没识别到的**真正阻塞点**（§5）。
- **task**: A5（Group A / URI-share 收尾件）
- **base**: origin/main `4fcb10671`
- **依赖**: A1（已合）· **A4 primitive**（provision 专属 session + 铸指向 R 的 cap；今天叫 `Mount.provision/mount`,A4 计划改名 Provision/Share）· **Allen residual 乙 的闭合**（§5,硬阻塞）

---

## 0. v2 立论为何被撤回（逐条实证）

v2 §0 写:「kanban #1474 的 thesis = Mount + MountRow 整删 → 这与 infra 方向相反、要被删 → A5 不用 Mount」。三处错:

1. **拿未合并、零 review 的 draft 当权威**。`gh pr view 1474`:`state=OPEN, isDraft=true, comments=0, reviews=0`。它删 Mount 全部 + 把 `board_provision` 从 domain 下沉进 plugin,净 -2014 行 —— 这是**分支的单方主张**,不是既定方向。
2. **与 Allen 2026-07-29 的明文批准冲突**。PR #1594 评论（allenwoods, 2026-07-29T05:56）:「**2. 匿名分享设计 — 批准 ✅** 每个被匿名分享的资源 = 专属公开 session（**仅 mount 该资源** + `web_anon_access`,链接指向它）,天然隔离…… owner/GC/workspace 细节在 **A4 完成后的 `link_anon` 接线 PR** 中定案。」—— 被批准的就是本设计,形状是「mount 该资源」。**main 上已合并的代码注释同款**:`share_setting.ex:30-31` 与 `:82-83`「provision a DEDICATED per-resource public session …, **mount the target into it via A4 Mount**, and mark it `web_anon_access`」。
3. **Allen 把 Mount/MountRow 明确列为复用底座**（PR #1587,allenwoods 亲开,非 draft）:「Reuse base is bigger than framed: `mint_cap/4` … **+ `Mount`/`MountRow` with the person-scope axis `mount_for_person/5` already constitute a URI-agnostic "grant a cap toward a URI + durable record" primitive. The gaps are peripheral glue.**」→ URI-share primitive 是**在 Mount 之上泛化**,不是把它判死。

**同时要说清楚 v2 也不是全错的那半**:
- **cap-as-truth 是人类决策**（#1587「(甲) Unify on cap-as-truth / person-cap. Holding a cap ≡ having the access」),且 **#1611 已合**（删 `reconcile_session_mounts` 等,`mount.ex:26-34` moduledoc 现写「重启存活 = cap-as-truth；`MountRow` 保留为记账/反查用途,**不再是重发来源**」)。
- **删 MountRow 表确实在计划里**,但形态是**改名 + 删表**、不是删模块 —— 已合入 main 的团队计划原文（`docs/together/2026-07-28/returns/share-a4-1-reconcile-trap.md:35-36`）:「**XY 结论（与用户对齐）**:session→board **不是** cap 给不了的轴、**不需要**单独真理源……用 **caps_toward(A2-1)**」+「**Mount→Provision/Share 改名 + 删 MountRow 表**」。
- **Allen 对 #1474 的态度**:「**#1474 — your call.** Recommended order: **complete the URI-share primitive first → rebase #1474 onto it → merge**」,并说它「already correctly scoped … no re-scope needed」。→ 终局 Mount 被 primitive 吸收是合理的,但**次序是 primitive 先立**;A5 作为 Group-A 件,应当**建在 primitive 上**,而不是以"Mount 要死"为由绕开它。

**⇒ v3 立场**:A5 用 A4 primitive（今天 = `Mount.provision/mount`,A4 后 = Provision/Share + 无 MountRow 真相源）。**不再声称"删 Mount"是方向。**

## 1. 定位（A1 两层的匿名档）

| 档 | 谁能进 | 拿到什么 |
|---|---|---|
| `link_login` | 登录用户持链接 | 具名 person 授权（A1 已做:`ShareSetting` 开关 + `ShareClaim`,读闸活现算 `Share.shared_to?/2`,**不铸 cap**） |
| `link_anon` | 任何人（匿名） | **view-only 渲染**（本设计） |

## 2. 机制现状（origin/main 实证,含 v2 的关键误解纠正）

- **`Mount` 就是 `mint_cap` 的包装**:`CompositionCaps.mint_cap/4` 全 repo **生产调用点只有 2 处,都在 Mount 内部**（`mount.ex:74`、`mount.ex:107`）。→ v2 说的「锚 `mint_cap` 取代 Mount」在机制上**几乎是同一件事**,差别只在**要不要那条 durable 记账行**。这个差别正是 A4「删表」要处理的,不构成"绕开 A4"的理由。
- **匿名 view 授权确实不经 Mount**（v2 这半句对,已实证）:`Installation.anon_view_caps/1`（`installation.ex:315-328`）铸的是 `cap(:session, <view_module>, <action>, **S**, ws)` —— **instance 是 session,不是 R**;闸 = `SessionView.authorize_view/3`（`session_view.ex`,`caller_holds_render_cap?/3`）。
- **但读 R 的数据这一步今天没有任何 cap 检查**:`Ezagent.Kind.read/3`（`apps/ezagent_actor/lib/ezagent/kind.ex:676`）签名无 caller、实现无 authz;kanban 的 `boards_for/1` 是**按 workspace 枚举、字典序取首个**,无 caller 无 cap 过滤。
- **`MountRow` 今天提供的唯一不可替代物 = session→target 绑定索引**（`MountRow.list_for_session/1`）—— 即「S_R 里到底该渲染哪个 R」。A4 的计划是把这条改成**从 cap 派生**（`Cap.Visibility.caps_toward/2`,A2-1 已合、目前零生产消费者）。

## 3. link_anon 流程（建在 A4 primitive 上）

**A. owner 开启** `ShareSetting.enable(R, owner, …, visibility: :link_anon)`（现 `:anon_share_not_yet_supported` fail-closed）:
1. 验 owner ≡ R 当前 data_owner（A1 `assert_current_owner`）。
2. **幂等 provision 专属公开 session `S_R`**（deterministic per-resource key → 幂等）。owner = R 的 data_owner（决策 1）。
3. **install `web_anon_access: true` 的通用 `AnonShareView` definition 进 S_R** → `Installation.anon_view_caps(S_R)` 才会给 anon render cap。
4. **把 R 挂进 S_R** = **A4 primitive**:铸一把**只读**的、指向 R 的 cap（`mint_cap` 唯一 chokepoint,granter = R 的 data_owner）+ 建立 S_R→R 绑定。今天 = `Mount.mount/6`（它内部就是 §2 的 `mint_cap` + MountRow）;A4 改名/删表后 = Provision/Share + 绑定从 `caps_toward` 派生。**A5 只用其稳定语义,不依赖 MountRow 作真相源。**
5. `ShareSetting` 记 `visibility=link_anon` + `anon_session_uri=S_R`,返 `share_url`。

**B. 匿名访客**:`AnonIngress` → `AnonAdmission.admit_anonymous_participant(S_R)` → anon born with `join_cap` + `anon_view_caps(S_R)` → `authorize_view(AnonShareView, anon, S_R)` 过 → 渲染 **只含 R**（← **这一步今天不成立,见 §5**）。

**C. owner 撤销** `disable(R)`:`Cap.revoke_all_to/2`（generation bump,cap-as-truth 主路） + 退休 S_R + `AnonUser.GC` reap。

## 4. 与 cap-as-truth 的关系（正确表述）

撤销/重启存活**已经是** cap-as-truth（#1611 已合,`mount.ex:26-34`）。A5 不需要为此绕开 A4;A5 要做的是**别把 MountRow 当第二真相源**（读绑定尽量走 `caps_toward`,与 A4 计划一致）。

## 5. **真正的阻塞点（v1/v2 都漏了,Allen 已点名）**

**渲染路没有 caller,因此第 3-4 步铸出的读 cap 没有任何 gate 会检查它。**

- 契约是 arity-1:`@callback external_render(session_uri :: URI.t())`（`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex:84`),注册表**只认 arity-1**:`session_view_registry.ex:136-137` `function_exported?(view_module, :external_render, 1)`。
- 消费方 `KanbanRender.boards_for/1` 因此只能按 workspace 扫、取首个 —— 对 A5 要求的「每资源专属 session、只看到 R」**结构性不够**。
- **Allen 在 #1587 (乙) 里点名的就是这条**:「close the two REAL residuals: **`KanbanRender.boards_for/1`（`kanban_render.ex:113`, a render path with no caller / no cap-filter）** and the `:members` roster」（后者 = A4-2）。
- **现成的正确形状已经存在**:`apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex:99` 的 caller-aware `external_render/2` —— 经 `SessionReads.external_surface(caller, session_uri)`,**fail-closed（无读权 → nil）**。把它升格进 callback 契约 + 注册表即可。

**⇒ 不闭合这条,A5 的 mint 就是 cap-as-decoration。** A5 必须**要么自己闭合它,要么显式依赖它先落**（推荐后者:它是 Allen 名单上的独立 residual,且是跨 UI domain 的契约变更）。

## 6. DoD

- `enable(link_anon)`:provision S_R + install AnonShareView + 经 A4 primitive 铸只读 cap + 记 `anon_session_uri`,返 share_url。
- **caller-aware 渲染**（§5）:`external_render` 穿 caller + 按 caps 定位 R;**回归:S_R 只渲染 R,同 workspace 的其它资源一个都不出现**（这条今天必红,是 A5 的真验收）。
- 匿名访客 e2e:经 AnonIngress 只读看到 R;anon 永远拿不到 operate cap。
- 撤销 e2e:`disable`/R 删 → `revoke_all_to` + S_R teardown + anon reap;撤销后旧链接立即失效。
- **不把 MountRow 当真相源**（读绑定走 caps 派生;若 A4 删表未落,至少不新增依赖它的读路径）。
- 闸 + per_tenant 全绿。

## 7. 交 Allen 的开放问题

1. **§5 的 caller-aware 渲染契约变更**:A5 内做,还是拆成独立前置件（推荐,它是 residual 乙 的正身）?
2. S_R owner = R 的 data_owner（推荐）vs 系统 principal;workspace = `workspace_of(R)`。
3. `AnonShareView` 的 view 集:behavior 静态声明可匿名 view（推荐）vs enable 时参数化。
4. 次序与 #1474:Allen 的建议是「primitive 先立 → #1474 rebase 上去 → 合」。A5 是否等 A4 改名/删表落地后再实现,以免写在旧名上?

## 8. 与 v2 的差异（供 review 对照）

| 项 | v2（已撤回） | v3 |
|---|---|---|
| Mount | 「方向是删」,从依赖移除 | **建在 A4 primitive 上**;Allen 已批准的形状 |
| mint_cap | 「取代 Mount」 | **它就是 Mount 内部那一步**,不构成绕开理由 |
| MountRow | 「第二真相源,不用」 | 不当真相源（对）,但绑定要有替代（`caps_toward`,A4 计划） |
| 真正阻塞 | 未识别（只列为"待实证细节"） | **§5 渲染路无 caller = 硬阻塞**,Allen 已点名 |
