# A5 — 匿名分享(link_anon)接线【设计 v4 · 对抗取证复核后重写】

- **status**: proposed — design-first,待 Allen 过。
- **task**: A5(Group A / URI-share 统一授权收尾件)
- **branch**: `feat/socialware-share-a5-anon-mount`
- **base**: `origin/main` @ `4fcb10671`(本文 file:line 全部按该 ref 现读核对)
- **依赖**: A1(#1594,**已合** merge commit `7462f95e1`)· **A4 primitive**(provision 专属 session + 铸指向 R 的 cap;今天 = `Socialware.Mount`,A4 计划改名 Provision/Share)

> **修订史(诚实记录:两次自我推翻)**
> - **v1**(2026-07-29):基于 `Mount.mount`。方向对,但"匿名怎么看到 R"是想当然。
> - **v2/v3**(2026-07-30 早):主张**去 Mount**、锚 `anon_view_caps`,并把"渲染契约无 caller"定为硬阻塞 → **三条全部撤回**,见 §0。
> - **v4**(本文):恢复 A4 primitive 依赖(与 Allen 已批准形状一致);阻塞点重新定位为**匿名 feed 里没有"外部资源投影"这件东西**(不是没有 caller)。

---

## 0. 被推翻的三条主张(逐条给证据)

**① "方向是删 Mount" —— 撤回。**
- 原依据 = #1474 删 Mount。实证:`gh pr view 1474` → **OPEN / isDraft=true / reviews=0 / comments=0**(最后更新 2026-07-27T06:46Z),且它还把 `board_provision` 从 domain 下沉进 plugin(净 −2014 行)。**未合并、零 review 的单方主张,不构成架构方向。**
- 与人类决策冲突:**allenwoods 2026-07-29T05:56:25Z 在 #1594 明文批准** ——「**2. 匿名分享设计 — 批准 ✅** 每个被匿名分享的资源 = 专属公开 session(**仅 mount 该资源** + `web_anon_access`,链接指向它),天然隔离;与 share-link(person-cap)正交,`allow_anon` 位撤除正确。owner/GC/workspace 细节在 **A4 完成后的 `link_anon` 接线 PR** 中定案。当前 `ShareSetting.link_anon` 档 fail-closed 守卫保留。」
- main 已合代码注释同款:`share_setting.ex:31`(moduledoc)与 `:83`(`enable/5` 内联注释),均写「mount the target into it via **A4 Mount**」。
- allenwoods 在 #1587(他亲开、非 draft、OPEN)第 35-38 行把 Mount 列为**复用底座**:「**Reuse base is bigger than framed:** `mint_cap/4` … + `Mount`/`MountRow` with the person-scope axis `mount_for_person/5` already constitute a URI-agnostic "grant a cap toward a URI + durable record" primitive. **The gaps are peripheral glue.**」
- 机制补充:`CompositionCaps.mint_cap/4`(定义 `composition_caps.ex:140`)**全仓生产调用点只有 2 处,都在 `mount.ex:74` / `:107` 内部** → "改锚 mint_cap 取代 Mount"机制上就是同一件事,差别只有那条记账行。
- **2026-07-29 之后无任何新的人类表态改变此方向**(穷举 PR 评论 / inline review / issue / main commit / `docs/together/2026-07-29|30` 全查过;allenwoods 07-29 后仅 2 条评论:#1614 与 #1606,后者是技术复审 SOUND,反而重申「A4-2 才 wire `grantees_of`」的既定次序)。

**② "硬阻塞 = 渲染契约 `external_render/1` 没有 caller" —— 撤回(归因错)。**
- 实证:`grep -rn "external_render(" apps/*/lib | grep -v "def external_render\|@callback\|@spec"` → **零命中**。`external_render/1`(契约 `session_view.ex:84`;注册表探针 `session_view_registry.ex:136-137`)**在生产上没有任何调用者**。
- 匿名链路**根本不经 `SessionViewRegistry`**,而且**全程有 caller**(§1)。给那个 callback 加 caller,匿名页显示的内容一个字都不会变。

**③ "A5 锚 `anon_view_caps`" —— 撤回。**
- `Installation.anon_view_caps/1`(`installation.ex:315`)铸的 `<view>_render` cap,**唯一检查点**是 `session_view.ex:121 authorize_view/3`(经 `:174 caller_holds_render_cap?`),而它只从 world **登录内页**的 `applicable_views/2` 可达(`conversation_data.ex:163`,在 `RequireEntity` + `LiveAuth` 之后)。
- ⇒ **匿名侧没有任何 gate 会检查这张 cap** —— 它在匿名路径上确实是 cap-as-decoration。A5 的授权**不能**靠它。

## 1. 匿名读路径的真相(本设计的地基)

| 段 | 证据(origin/main) |
|---|---|
| HTML 只发空壳 | `router.ex:179 /socialware/external`、`:206 /socialware/chat`、`:214 /hello/:session_name` |
| **匿名也有真实 caller** | `AnonIngress.resolve_caller/3`(`anon_ingress.ex:32-44`)→ `AnonAdmission.admit_anonymous_participant`(`:87`,铸 `entity://…/user/anon-*` 并 join)→ `ChatFeedAuth.issue_token`(`:98`) |
| WS 带 caller | `external_feed_socket.ex:23-27`:`ChatFeedAuth.verify(token, session_uri)` → `assign(:caller, caller)` |
| 内容 = 授权读 | `SessionFeedChannel` → **`ExternalFeed.snapshot(session_uri, caller)`(`external_feed.ex:51`)** → `SessionReads.external_snapshot_reads(caller, …)` + `external_surface(caller, …)` → `authorize_external_read` fail-closed |
| **返回结构只有四项** | `external_feed.ex:58-64` → `%{messages, page, shell, shell_css}`,全部来自 session **自己**的消息与 `:surface` slice |
| 那条一元路径的真实用途 | world 登录内页只用 `applicable_views/2` + `external_render?/1` 取**元数据**,把 tab 标成 `mode: "external"`,前端画成指回 `/socialware/external` 的 **iframe** → 绕回上面这条 caller-aware 链路 |

## 2. 真正的缺口:匿名 feed 里没有"外部资源投影"

要做到「专属公开 session `S_R` 只显示被分享的资源 R」,今天缺**两件**,都不是 caller:

**(a) 绑定** —— "S_R 该显示哪个 R"。现成绑定 = `MountRow.list_for_session/1`(`mount_row.ex:114-115`),但**没有任何渲染路读它**(全仓唯一消费者 `mount.ex:227`)。A4 计划把这条改成从 cap 派生(`Cap.Visibility.caps_toward/2`,A2-1 #1596 已合,**目前零生产消费者**)。

**(b) 投影** —— 把 R 的只读视图接进匿名 feed 的返回。`ExternalFeed.snapshot/2` 今天只返回 messages/page/shell(§1)。**这是 A5 的主体工作量。**

授权形状照 `world_data.ex` 的 `visible?/2` → `holds_board_cap?/3`(caller 持 instance 精确指向该资源的 cap 才可见,走 `Cap.authorize`)—— 这是 main 上**既成**的"cap 反推可见性"实现,零 Mount 依赖。

## 3. 流程(修正版)

**A. owner 开启** `ShareSetting.enable(R, owner, …, visibility: :link_anon)`(现 fail-closed `:anon_share_not_yet_supported`,`share_setting.ex:85-86`):
1. 验 owner ≡ R 当前 data_owner(A1 `assert_current_owner`)。
2. 幂等 provision 专属公开 session `S_R`(deterministic per-resource key)。
3. **建立 S_R→R 绑定 + 铸只读 cap** = **A4 primitive**(今天 `Mount.mount/6`(`mount.ex:63`)/ `Mount.provision/6`(`:180`),内部即 `mint_cap`;A4 改名/删表后绑定改由 cap 派生)。
4. 标 `web_anon_access`(`Installation.web_anon_access?/1`,`installation.ex:285`)。
5. `ShareSetting` 记 `anon_session_uri = S_R`,返 `share_url`(`/socialware/external?session_uri=S_R` 一族)。

**B. 匿名访客**:现成链路(§1)→ `ExternalFeed.snapshot(S_R, anon_caller)` → **新增的资源投影**按 caller 持有的 cap 出 R 的只读视图。零新匿名身份代码。

**C. 撤销**:`Cap.revoke_all_to(R)`(generation bump)+ ShareSetting 关档 + 退休 S_R + `AnonUser.GC`。

## 4. 本设计要新建的东西(scope,诚实列)

1. **匿名 feed 的资源投影** —— `ExternalFeed.snapshot/2` 返回结构加一段(如 `resources`),**cap-gated**、per-session 绑定驱动。落在 domain_socialware,**主体工作量**。
2. **取数必须包在 cap 门后** —— `Ezagent.Kind.read/3`(`apps/ezagent_actor/lib/ezagent/kind.ex:676`)**无 caller、无 authz**,不可裸调。
3. `ShareSetting.enable(:link_anon)` 接通(拆 fail-closed 守卫)。
4. 前端:匿名壳渲染这一段。

## 5. 与 Mount / A4 的关系

- **用 A4 primitive,不自造、不绕开** —— 与 allenwoods 2026-07-29 批准的形状一致。
- **绑定源**:今天 `MountRow`;A4「改名 + 删表」后从 `caps_toward` 派生。已合入 main 的团队计划 `docs/together/2026-07-28/returns/share-a4-1-reconcile-trap.md:35-36`:「session→board **不是** cap 给不了的轴、**不需要**单独真理源……用 **caps_toward(A2-1)**」+「**Mount→Provision/Share 改名 + 删 MountRow 表**……归后续」。**A5 不把 MountRow 当长期真相源,但也不为此绕开 A4。**
- **撤销早已是 cap-as-truth**:#1611(merge `fb35003cf`)删掉 `reconcile_session_mounts/1`、`reconcile_person_mounts/1` 及两个私有 remint,并摘掉 `activate/2` 里的 hook;`mount.ex:27` 段落标题即「重启存活 = cap-as-truth,不再照表重发」,`:31-34` 写明「`MountRow` 保留为记账/反查用途,**不再是重发来源**」。
- **次序**:allenwoods #1587 第 72-76 行 ——「**#1474 — your call.** Recommended order: complete the URI-share primitive first → **rebase #1474** onto it → merge」。

## 6. DoD

- `enable(link_anon)` → provision S_R + 绑定 + 只读 cap + 记 `anon_session_uri`,返 share_url。
- **匿名访客经 `/socialware/external?session_uri=S_R` 看到 R 的只读内容**(今天必红——投影不存在)。
- **隔离回归**:同 workspace 的其它资源一个都不出现。
- **fail-closed 回归**:未持指向 R 的 cap 的访客看不到 R。
- **撤销回归**:`disable` / 删 R → `revoke_all_to` 后立即看不到。
- anon 永远拿不到 operate cap。
- 闸 + per_tenant 全绿。

## 6b. 开放问题 4 的实证定案(2026-08-03,实现期)

**「读钥匙由谁持有」—— 答案:每个被准入的匿名访客,born-with(不是专属会话)。**

- **会话持钥版先实现、被基建证伪**:`mint_cap` 给会话的钥匙经 absorb outbox 投递时死于
  `{:unknown_action, :absorb_cap}` —— Session Kind 不挂 Identity 存储动作
  (`entity/session.ex` `behaviors/0` 只有 `SelfLicense` 系),**会话今天无法持有 identity 面的 cap**。
- **改走既有匿名先例**:准入时 born-with(与 `Installation.anon_view_caps/1` 完全同模式,
  `AnonUser.anon_share_read_caps/1`),concrete action × concrete instance,结构上不可能万能钥匙。
- **投影以真实访客身份 dispatch**(true provenance),过完整验签 chokepoint;
  未准入的过路 URI 不持钥匙 → 空(per-caller fail-closed)。
- **撤销两层**,镜像 link_login(codex D3):share 行 = 政策开关(一翻全体立暗,行门控投影);
  已 born 的钥匙不动,死于 target 权威轮转(`Cap.Authority.regenesis`)或 anon GC。

## 7. 交 Allen 的开放问题

1. **资源投影落点**:扩 `ExternalFeed.snapshot/2` 返回结构(推荐)vs 新增独立 channel 事件?
2. **绑定源**:先用现成 `MountRow`,还是等 A4 的 `caps_toward` 派生(那样 A5 就要排在 A4 之后)?
3. **S_R owner** = R 的 data_owner(推荐)vs 系统 principal;workspace = `workspace_of(R)`。
4. **可匿名的只读视图由谁声明**:behavior 静态声明(推荐)vs `enable` 时参数化?
