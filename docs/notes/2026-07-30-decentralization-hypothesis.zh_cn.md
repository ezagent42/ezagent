# 「中心化 session」是不是复杂 bug 的根源——全面去中心化（Bluesky/git 式）能不能避开这类 bug？

*给 Allen 的研究备忘 —— 全部结论落在 ezagent 真实代码（origin/main @ 81a90855c，2026-07-30）与真实 bug 史（#189、#1627、#201/#1570、#206、#207、#1576、#1577/#1578、read-plane、#192）上。双语版：本文件（中文）+ `decentralization-hypothesis.md`（英文）。*

---

## ① 假设重述（拆成可检验的命题）

Allen 的假设可拆成四条：

1. **（前提）** ezagent 今天本质上已是一个去中心化的 actor model。
2. **（目标）** 存在一个机制上清晰、简单的授权 + 缓存模型——业务逻辑可以繁琐，但应是「简单机制的组合」。
3. **（因果命题）** 我们不断撞上的复杂 bug，根源是引入了一个**中心化的 session**——一个「要求实体状态一致性」的协调点。
4. **（反事实）** 若像 Bluesky 那样彻底去中心化——每个 actor 的信息完全 LOCAL、不提供全局一致性保证；内容在被查看时**复制**到查看者节点；查看者甚至可以在自己节点上修改副本再**推回**源头（git 模型）——这类复杂 bug 就不会出现。

检验方法：先画出系统实际在哪里要求一致性（②）；再给每个真实 bug 的根因分类（③）：
**[A]** 由全局一致性要求 / 中心化 chokepoint 造成；
**[B]** 由「状态复制且无 owner」造成（两份拷贝 / 两个写者、没有对账规则——即**单一所有权太少**，不是中心化太多）；
**[C]** 正交原因（时序/存活性、密钥生命周期、普通逻辑 bug）。
然后诚实评估反事实（④），给出结论（⑤⑥）。

---

## ② 现状地图：哪里真的 actor-local、哪里要求一致、各自守什么不变式

**先说部署现实：** v0 是**单 BEAM + 单 SQLite/PG**（ARCHITECTURE.md §1.1；federation 排在 v0.x+）。所有「全局」数据都在同一节点、同一 DB 里。今天的一致性要求的代价是**一次 DB 读**，不是分布式共识。下面的 bug 没有一个是 CAP 定理的代价——它们全是**同一数据的多份内部拷贝**之间的记账代价。

### 今天已经 actor-local / 去中心化形状的部分（「像 Bluesky」的部分其实已经存在）

| 机制 | 证据 | 什么是 local 的 |
|---|---|---|
| **cap = 签名的 bearer artifact；每个 target Kind 是自己的签名+验签 authority**（per-Kind ed25519，born-signed，严格验签） | `apps/ezagent_core/lib/ezagent/cap/authority.ex`，GLOSSARY #164（PR #1457） | 签发与验证都是 per-entity 的，没有中央 ACL 引擎 |
| **每个实体持有自己的 cap**（holder 侧存储：`users.caps_json` / snapshot `:identity` slice / #189 后统一的 `identity_caps` store，按 URI 键） | `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex` + `entity_caps/store.ex` | principal gate 只从 holder 自己的 durable store 加载，从不信 presented caps（F-1） |
| **实体状态 = 自己的 GenServer slices + 自己的 snapshot 行** | `kind_snapshots`，`{:snapshot, :on_change}` | actor-local 状态，单一写者（actor 自己） |
| **聊天历史 = append-only MessageStore 单一真相源；replay 是派生的**（`in_session_since(session, last_seen)`）——session slice 只存 ephemeral 在线状态 | Decision #91，`message_store.ex` | session 不私藏第二份消息拷贝；rejoin 是 cursor-replay——已经是 mailbox + projection |
| **World UI 刷新 = 最终一致的 push projection**（`SliceChange → WorldLive → refresh_state → world:surface_state → React partial merge`） | ARCHITECTURE.md §2.3.1 | 查看者持有客户端副本，靠增量更新 |
| **外部 feed/surface = 单调版本号的 projection，靠 durable delivery replay 自愈** | `external_feed.ex`，`SessionFeedChannel.push_viewer_snapshot/1` | feed 查看者容忍滞后；单调 `surface_version` 防止锁死撕裂状态 |
| **代码内置 Definition vs 存储 Definition 的分歧策略：content-hash、默认 NO-CLOBBER、分歧大声上报、显式 apply** | `socialware/definition_registry.ex`（Allen 2026-07-10） | 一个 git 形状的双拷贝对账策略——而且它是好用的 |

### 要求一致性的点（守什么不变式、谁必须一致）

| 点 | 要求的不变式 | 谁必须一致 | 性质 |
|---|---|---|---|
| **KindRegistry `put_new`**（URI→pid 唯一，撞 key 即 crash） | *每个 URI 至多一个活 actor* | 所有 spawn 方 | **actor model 的构成性前提**——正是它让 actor-local 状态成立（每个 key 单一写者）。`kind_registry.ex` |
| **authority generation 平面**（`kind_cap_authorities`：per-URI 单活跃行、单调 generation；`Authority.verify_against_current` = 新鲜读；`EntityCaps.verified/2` gen-gate） | *cap 仅在被 target 的「当前」generation 签名时被承认* ——即**撤销立即生效** | 所有验证方 + holder 自己存的 license | **安全驱动。** 签名防伪造/篡改/转移目标；撤销**必须**有这个一致性点（[[cap-signing ≠ revoke-completeness]]） |
| **principal gate**（`Cap.Authorize.principal_current?` → holder 自己的 durable store，gen-gated） | gen 被 bump 的 principal 加载为空 ⇒ 立即失能 | holder store ↔ generation 行 | holder 的本地 license 是**一个授权事实的本地副本**，必须跟得上全局 generation 计数器——这是系统里唯一真正「副本 vs 全局」的接缝 |
| **dispatch step 5.5 cap chokepoint** + **read-plane chokepoints**（`SessionReads` / `InternalReads` / version-first 原子快照） | *不存在未过闸的路径*（写或读）；feed 快照：*报了 version ⇒ 它的消息必可见* | 所有 dispatch / 所有读者 | **安全/产品驱动**；靠反绕过 CI gate 强制 |
| **Session**（`Ezagent.Entity.Session`——「routing context owner」，IRC channel 形状） | (i) 消息的接收者 = *当前*成员，投递时检查（撤销 ⇒ 立即拒收，A2 §14.5）；(ii) turn settlement 恰好一次、按序 | (i) session roster ↔ 成员各自持有的 member-cap（今天两份 → #192）；(ii) 只需 session actor 自己 | (i) 安全驱动；(ii) **免费**——actor mailbox 本身就是串行化器。session 干的其余事（历史、surface、feed）都已是 projection / 最终一致 |
| **Workspace roster + Loader**（workspace 持 `{:member, URI}` children；boot 时 Loader 全量重生） | boot 按依赖序把 fleet 带起来 | boot 序列 | boot 一致性；被毒化时就是那 ~289 个 `no process: Workspace.Supervisor` 级联 |
| **boot 期各 registry**（BehaviorRegistry、TemplateRegistry 撞名即严格报错、RoutingRegistry `put_new`、SchemeRegistry、`ManifestSeed.scan_all!` fail-loud） | 节点的声明集要么完整一致、要么不 boot | 所有 plugin 在 boot 时 | 有意的 fail-loud（「router 不是 req/resp：默认静默 = 默认有 bug」，ARCH §1.2）——但爆炸半径是**整机**（#206） |
| **flavor store**（`AgentFlavorAttributes`，按 agent URI 键的全局行；plugin 在自己的 `instantiate` 里写自己 agent 的 flavor 是 **by design**，Allen 0727） | 每个 agent URI 一行已提交 flavor，且 `instantiate` 期间可读（#1578 契约） | template pre-store 钩子 + 4 个 plugin 写者 | 单行多写者 → 需要「谁赢谁写」的所有权（#201） |
| **跨 actor cap 投递**（`absorb_cap` 进接收者自己的 store） | grant 恰好一次到达 holder 的 store，即使接收者是冷的 | 授予方 → 接收方 actor | 这是**由 actor-local 设计制造出来的**存活性问题（cap 存在 holder 自己那里）；由 `Cap.DeliveryOutbox` 治愈（durable 重试、提交后才算 applied） |

**地图的读法：** 现存的一致性要求分三类——(a) **actor model 的构成性要求**（每 URI 单活 actor）；(b) **安全要求**（撤销立即生效；不存在未过闸的读/写路径）；(c) **boot 一致性**。session 本身**已经是收敛点，不是强一致性的需求方**：历史是 append log + 派生 replay；surface 是单调版本的最终一致 projection；turn 排序是单 actor 的 mailbox 顺序（免费）；它唯一「严格」的事情是投递时的成员资格检查——那是安全抉择，不是架构事故。

---

## ③ 逐 bug 验尸表——语料库全量分类

图例：**[A]** 全局一致性/中心化 chokepoint 造成 · **[B]** 复制无 owner · **[C]** 正交（存活性/时序、密钥生命周期、普通逻辑）。「全去中心化下」= ①(4) 的 Bluesky/git 反事实。

| # | Bug | 根因机制（已核实） | 分类 | 全去中心化下 |
|---|---|---|---|---|
| 1 | **#189 身份平面**（stale-gen self-license；冷加载对账；dual-write） | holder 的 cap 集有**三个家**：`users.caps_json`（User）、snapshot `:identity` slice（其余实体）、新的统一 `EntityCaps.Store`。self-license **搭在 snapshot slice 上**，于是 `:ephemeral` Kind（ExternalMirrorWorker；Session 干脆没有 Identity）重启即丢 license → 9 个 `holder_revoked` 红。cutover（#1615 PR-1 dual-write → 写平面 → #1621 读翻转）的 6+4 轮 codex 全部耗在双拷贝接缝上：shadow write 静默失败会让分歧的 store 行在读侧压过 legacy；冷 `:existed` 重载时 stale snapshot 会覆盖 Store 里已提交的变更（修复：slice 从 Store **替换**，store 读错误直接拒绝 boot）；ephemeral 每次 spawn 重新 mint 造成复活洞（没写 `ever_created` 标记）；tombstone 跟着 snapshot 行一起被删 | **[B] 为主**（数据多个家；identity 放错了家），叠加 **[C]** 密钥/生命周期角落（复活、tombstone 单调性），再叠加**一次性迁移接缝成本**（dual-write、backfill、parity barrier、epoch fence） | **变形成更糟的问题。**「holder 的本地 license 落后于已轮转的 authority」**就是**撤销传播——最终一致系统的经典痛点。彻底 local-first 会把这道接缝复制到**每一个**副本上，而不是一个 store。真正修好它的终态是**更多**的单一所有权：一个统一 store、一个 `identity_status`、snapshot 降级为 best-effort projection |
| 2 | **#1627 pre-epoch boot 变砖**（canary hard-down 崩溃循环） | 回流的生产 DB：admin 的 authority generation 在 mint 之后被轮转过；epoch 从未激活；G-3 只有创建时 mint、没有 boot 再 mint → genesis-admin 启动即派发 `:holder_revoked`，fail-closed 崩溃循环。修复（B1-hybrid，Allen 拍板）：genesis admin **结构性不可杀**（所有 kill 路径拒绝 `admin_uri()`），于是 stale-gen 的 admin *可证明*合法 → pre-epoch 自动 re-mint 是安全的；合法轮转变成手动操作，在 authority 行锁下**原子地**轮转 + re-mint | **[C]**——一个*有意* fail-closed 的闸的根密钥生命周期角落（严格性按设计工作了；缺的是对唯一可证安全场景的受治理自愈路径） | **砖消失，洞回来。**最终一致的撤销永远不会 boot 变砖——因为被撤销的 principal 会继续行动直到传播到位。这个交换正是 §14.5（「撤销 ⇒ 立即拒绝」）拒绝的。另注：去中心化身份系统在根密钥上有同一类 bug（did:plc 的轮转/恢复窗口） |
| 3 | **#201 / #1570 flavor adopt-clobber**（#189 第③因） | 每个 agent URI 一个全局槽位（`AgentFlavorAttributes` ETS），**多个互不协调的写者**：domain 的 pre-store（在 `instantiate` **之前**写）、每个 plugin 在自己 `instantiate` 里的无条件 `put`（curl `curl_agent.ex:356`、native `native_agent.ex:58`、cc/codex…）、还有回滚路径的 **URI 级删除**。第二个 spawn 尝试 adopt 已经活着的 worker 时走的是 `:ok` 路径（`fresh?: false`），domain 把 adopt 转成 error，**输家的回滚删掉了赢家已提交的行**。之前两次失败修复：#1577 推迟 pre-store → **被 #1578 revert**（Template Class 在 `instantiate` **内部**读 flavor——read-your-write 契约，被 `agent_display_name_test` 逮住）；`put_new`/insert-if-absent 被 codex 判 **NEEDS-WORK、否决**（URI 复用时读到陈旧值；error-undo 会删掉先前存在的行）。最终修复（#1604）= **defer-writes + 单一赢家**：删掉投机 pre-store；唯一的 durable flavor 写是 spawn **赢家**的 post-ownership 写（`template_spawn.ex:542`），以 **core 签发的 spawn 收据 `{:started, created?}`**（DynamicSupervisor 原子裁定）为闸，不信 plugin 的 `fresh?`；非 owner 不许删；回滚补偿按 mint 的 **incarnation id** 定位（ABA 安全）；instantiate 期的读**搬离**共享表、改读 template **data map**（`AgentTemplate.to_template_data/2`）——正是这一步让推迟写变得安全 | **[B] 教科书级**——一个槽位、多个写者、非 owner 的破坏性删除、没有「谁可以写」的规则。修复 = 指定单一 owner（「只有 spawn 赢家写」），用 spawn chokepoint 的裁定作为所有权信号 | **不会消失——会变成 merge 冲突。**各写各的副本再推回，只是把同一场碰撞挪到 merge 时刻，还要额外发明 merge 语义。而 git 自己对并发 push 的答案是**只有赢家能推进的串行化 ref**（reject non-fast-forward）——和 `{:started, created?}` 收据「单一仲裁点决定 owner」同一个形状。「git 模型」是这个修复的形状，不是它的替代品 |
| 4 | **#206 stale-home socialware 包**（#1633 修复） | 包存储是一个**文件系统副本**：`$EZAGENT_HOME/<profile>/socialware/<name>/`（canary 里是持久 bind-mount——DB 重置动不到它），由 `Ezagent.Home.SocialwareSeed.seed_one/2` 从 release 的 `priv/socialware_seed/<name>/` 播种。幂等是**目录粒度**的：`unless File.exists?(target), do: File.cp_r!`。kanban 的 `manifest.yaml` 07-08 上线；同包的 `recipes.yaml` 07-16 才加入；canary 的 `kanban/` 目录恰好在两者**之间**被物化 → 此后每次 boot 整目录跳过，`recipes.yaml` 永远到不了。然后 `ManifestSeed.scan_all!/1`（在 `EzagentWeb.Application.start/2` 里调用——最后 boot 的 app）在 `seed_sibling_recipes/1` 撞上 `{:unknown_agent_recipe, "kanban-assistant"}`，**raise 冲出 OTP `start/2` 回调 → 整节点 boot 中止 / 崩溃循环**。修复 #1633：`seed_one/2` 改为**文件级递归对账**——任意深度缺失的文件补拷、已存在的文件绝不碰（保留运维手改契约）；stale home 下次 boot 自愈 | **[B] 根因**（release 源 vs 持久部署副本 = 两份拷贝；对账规则太粗、且部署副本自物化后无人拥有）**+ 语料库里唯一真正的 [A]，作为放大器**：一个节点级 fail-loud 扫描，raise 即整机中止——#1633 明确把这条 policy 留给 Allen 裁决 | **变得更糟而不是更好。**local-first 让「从不重新同步的副本」成为*默认状态*。解药是真正的对账规则（这里是文件级；`DefinitionRegistry` 是 content-hash + no-clobber + 大声分歧）+ **有界**的 fail-loud（隔离坏包、其余照 boot）——即修爆炸半径、保留大声 |
| 5 | **#207 absorb_cap fire-and-forget** | 唯一的 grant 路径（`Ezagent.Identity.Grant` → `Cap.issue/3` → `Identity.absorb_cap/2`）把签名 artifact 投递进 holder 自己的 `:identity` slice，用的是 **VM 内部 fire-and-forget cast、不等就绪**。冷的/未启动的接收者落到 `Ezagent.PendingDelivery`——ETS、有界（100/URI）、**易失**的 buffer：重启即丢、溢出即掉 → cap 永远落不了地；`CapAbsorbAwait.await_exact/3` 5 秒后超时返回 `{:error, {:absorb_not_committed, […]}}`（socialware `turn_survives_restart` / `page_view_external_render` 那批红）。修复（#1409，2026-07-15）：`Cap.DeliveryOutbox`——**第一次 cast 之前先插一行 durable `:pending`**，目标就绪转换时 drain（`ReadyTransition.drain_pending_then_mark_ready/2`），sweeper 退避重试，**只有目标 handler + slice 提交成功后**才标记 applied（at-least-once + 幂等 apply）。残留 #1501（对抗性评审打回重做中）：`EntityCaps.load/1` 的有效视图只读*已持有*的 cap、不合并 *pending* outbox 行——「补 pending absorb + 幂等 + fail-closed」 | **[C] 触发，[B] 深层。**表象是存活性（cast 假设接收者活着），但纯存活性方案（易失 buffer）被证明不够——在途的 cap 需要一个 **durable owner**（outbox 行）+ 一步对账（就绪时 drain；#1501 的 held ∪ pending 合并）。并且诚实说：这类 bug 是**由设计中去中心化的那部分制造的**——cap 存在每个 holder 自己家里，grant 投递才成了分布式可靠性问题 | **成倍增加。**local-first 系统里每一次跨副本更新都需要这套 outbox/cursor/幂等 apply 机器。ezagent 已经把它认真造过一次了——这是 actor 原生的最终一致模式，跟 session 中不中心化无关 |
| 6 | **#1576 world:dispatch + 异步 bootstrap** | 核心 bug：普通配置错误（hello 默认模型 `deepseek-chat` 被端点拒绝）。回归 (a) `world:dispatch`：异步安装 Hello 或服务重启后 dispatch 打到**冷 actor / 冷 PTY sandbox**；修复 = 按需唤活（chat.send 前 `self_join`；开 PTY 前 `Agent.ensure_deliverable/1` + `Pty.Server.snapshot_buffer/1` 回放缓冲）。回归 (b)：LV mount 改成异步（有界 mount + `:load_world_state` Task）后，Task 结果可能与 `handle_params` 的路由选择乱序 → 路由守卫 + 丢弃 stale Task 结果。全程单一 owner（LV 进程拥有 `socket.assigns`；actor 拥有自己的状态） | **[C]**（配置；存活性；单 owner 的 mailbox 时序竞态） | **不变。**冷副本的存活性、异步结果乱序，是 local-first 系统的家常便饭；只会更多，不会消失 |
| 7 | **#1577 → #1578 flavor 契约 revert** | #1577 试图*弱化写时机*（把 flavor pre-store 推迟到 `instantiate` 之后）→ 打破了**「instantiate 期间 flavor 可读」**的 read-your-write 契约（Template Class 在 `instantiate` 里调 `AgentFlavorAttributes.get`；`:none` → `MatchError`）→ #1578 revert | **[B/C]**——写者与同步读者之间的契约；「改成最终一致就好」的直接反证 | **对假设的直接反例。**有些消费者*就是要求* read-your-write；在任何模型里都不能对它们一刀切最终一致。#1604 最后的解法是把这个读搬到别的数据源（template data map），而不是让它容忍最终一致 |
| 8 | **read-plane chokepoint 工作**（#188/#190 家族：PR #1464/#1467/#1466/#1471/#1494 + `feat/read-plane-atomic-snapshot`） | (i) *supervisor read gap*：消息/成员的读散落在 LV loader 的裸 `Repo`/`MessageStore` 调用里、**零授权**——登录的非成员可以 deep-link 读到别人会话；`:read_unfiltered` 行策略来自 caller 自报的 flag。修复：所有面向 principal 的读收口进 `SessionReads`（先授权、fail-closed），反绕过 CI 边界测试，「supervisor 要读就先成为真成员」。(ii) *straddle window*：`ExternalFeed.snapshot/2` 三次非原子读；settlement 提交恰好落在中间 → *有页面没内容*；修复 = 一次原子 **version-first** chokepoint 读（`external_snapshot_reads/3`）：报了 version ⇒ 它的消息必可见；反向情形靠 replay 自愈 | **[A]——但方向反了**：bug 来自 chokepoint 的**缺失**；加中心化才是解药。这个需求（不许未授权读；不许撕裂页面）是产品/安全需求，任何模型下都在 | **Bluesky 的答案是同一个形状。**AppView 就是一个带 cursor、单调序的中心化 read-model；Bluesky 查看者容忍滞后的方式，与 feed 平面现在的做法（单调版本 + replay）一模一样。local-first 也得保留这个 chokepoint，只是每个副本一份 |
| 9 | **#192 成员 roster vs cap-as-truth**（未完；M-6/M-8、#1611 已落，#1620 计划中） | 成员资格的真相住在**两处**、两个 owner、两套写机制：(i) session 的 `:members` roster（chat-slice map，唯一写者是 `add_self`）——**只管投递目标、明确容忍陈旧、不带权限**；(ii) 每个成员**自己** `:identity` store 里的 member-cap（`MemberCap.grant_at_join` → `Grant.issue_cap` → `absorb_cap`）——**行为时授权**（§14.5：撤销 ⇒ 立即拒收）。入会 grant 是 `:async` best-effort，而且是**不得不**如此——在 `handle_join` 内做同步 grant 会**死锁** session 创建（实证 5s GenServer.call 超时，todo.md #161-A2）——所以漂移是结构性的：stale roster 条目（fail CLOSED，没 cap 就不投递）或有 cap 不在 roster（治愈前不是投递目标）。已落地：M-6（`join` 返回 admission 状态而非 roster）、M-8（`reconcile_after_load` 从并集翻成**精确的 cap-holder 投影**——「caps win」，补齐 + 驱逐，codex 抓住的 EXACT `identity_key` 匹配防止一张 `:any` admin cap 把 admin 加进所有 session）、#1611（删掉 MountRow 重发 mint 的陷阱——重启幸存靠的是受赠者自己的 durable 冷读回，不是台账重 mint）。#1620 计划把 `:members` 变成**纯投影**——今天它仍是独立存储、只是被对账 | **[B] 教科书级**——成员资格两个真相源；owner 指定（caps）进行中 | **去中心化的答案已经是计划本身**：选分布式那份拷贝（各自持有的 cap）当 owner，把 roster 降级为投影。注意严格的部分保留：投递时照查 member-cap。还有个有教益的角落：这处一致性的*同步*版本不只是不好——它**死锁**；actor model 自己把设计逼向了 async + fail-closed + 对账，而安全性成立是因为行为时的闸是严格的 |

### 计数（对自己诚实）

- **[A] 作为 bug 成因：9 个里约 0.5 个。**只有 #206 的*爆炸半径*（全局 fail-loud boot 闸）算真正的「中心化伤了我们」——而且它是放大器，不是缺陷本身。另外两个标了 [A] 的（read-plane）是 chokepoint **缺失**导致 bug、补上才治好的反向案例。
- **[B] 复制无 owner：约 5 / 9**（#201 多写者槽位、#192 双成员真相、#206 的 stale 副本、#189 的多家 cap 平面、#1577/#1578，再加 #207 的深层一半——在途 cap 需要 durable owner）——**占绝对主导**。每一个都是对设计自己的 P3（「任何数据只有一个家」）的违反，而不是 P3 的后果。
- **[C] 存活性/时序/生命周期：约 3.5 / 9**（#207 的触发面、#1576、#1627、#189 的复活/tombstone 角落）——actor 管道与密钥生命周期；与模型选择无关。
- **横切事实：**#189 家族的痛有一大半是**过渡成本**——在两套授权平面之间迁移的编排（dual-write、冷加载对账、backfill、parity barrier、epoch fence）。板上自己的结论（2026-07-30）：一次性 cutover 的节奏成立（additive → 写平面 → cutover）；流血的是那段长时间的双平面窗口。
- **session 没有造成其中任何一个。**语料库里不存在「session 要求实体状态一致、这个要求出了事」的 bug。跟 session 沾边的两个是 roster 复制（#192，B 类）和视图装配的存活性（#1576，C 类）。

---

## ④ Bluesky/git 模式的收益与新代价

**先把 Bluesky（AT Protocol）本身说准**——因为假设点名了它：

- 每个用户的数据住在自己 PDS 上的**签名 git 式 repo**（Merkle log）里。Relay 爬取；**AppView 聚合**——而实践中 Bluesky 公司运营着占主导的 relay、AppView 和大多数 PDS。去中心化的**写**层是真的；所有人实际用的**读**层是一个中心化的物化视图——功能上就是 ezagent 的 session / `SessionReads` 平面扮演的角色。
- **repo 里的数据全部公开。**互动（点赞、回复）是记录在**作者自己** repo 里、以 AT-URI + CID 引用目标的记录。**你不能修改别人的记录再推回去**——协议里根本不存在跨 repo 的 merge。Allen 描述的「查看者改自己的副本再推回源头」其实是 *pull-request 工作流*，它恰恰预设了 (a) 源头的写授权 和 (b) merge 语义——正是假设想绕开的两样东西。
- **私有/受权限数据在 atproto 里是未解问题**——按 2026 春季协议路线图，它是持续到 2026 夏的重点工作（Blacksky/Northsky/Habitat 草案）。参照系模型的简单性是靠**没有** capability、没有私有状态、没有 human-in-the-loop 闸门换来的——而这三样正是 ezagent 的产品域。（来源：[AT Protocol 2026 春季路线图](https://atproto.com/blog/2026-spring-roadmap)、[Bluesky federation 架构](https://docs.bsky.app/docs/advanced-guides/federation-architecture)、[OAuth for AT Protocol](https://docs.bsky.app/blog/oauth-atproto)。）

**逐 bug 类看：彻底 local-first + copy-on-view + push-back 会怎样：**

| Bug 类 | 会消失吗？ |
|---|---|
| 撤销/generation 家族（#189 stale license、#1627 变砖） | **不会——它就是最终一致系统的经典痛点，且会被泛化。**「owner 处已撤销、查看者副本仍承认」正是 gen-gate 存在的理由，也正是 §14.5「撤销 ⇒ 立即拒收」验收明令禁止的。要么为撤销保留一个一致性点（= 今天的设计），要么接受撤销滞后（= Allen 已经拒绝过的安全倒退）。变砖 → 无声复活，是两种失效模式的交换，不是 bug 类的消除 |
| 一行两写者（#201） | **不会——变成 merge 冲突。**而业界标准解法就是已经上线的那个：源头一个仲裁点决定 owner、只有赢家写（git 的共享 ref 用 reject non-fast-forward 推进，同一形状）。分歧副本的 merge 是 git 的*冲突*问题；git 模型是容纳它，不是消解它 |
| stale 副本（#206） | **默认更糟。**没有对账规则的 local-first 就是「skip-if-exists」本人。解药是基于内容的对账 + 有界爆炸半径——与中心化与否正交 |
| 跨 actor 投递（#207） | **成倍增加。**每道副本边界都需要 outbox / at-least-once / 幂等 apply。DeliveryOutbox 就是这套机器，已经造好一次 |
| 视图装配 / 存活性（#1576） | **不变或更多**（冷副本、乱序结果是 local-first 的日常天气） |
| 撕裂读（straddle） | **是「容忍」而不是「修复」**——Bluesky 式查看者接受陈旧/残缺视图。ezagent 的 feed 平面已经走了最终一致路线、*且*配了单调版本号防止把撕裂状态锁死。对 turn 已提交的 socialware surface，「有页面没内容」被判为 bug 而非可接受的陈旧——这是产品判断，不是架构事故 |
| 成员资格双真相（#192） | **local-first 的答案就是现有计划**——cap（分布式持有）为真相，roster 为投影 |

**ezagent 已经是去中心化形状的地方——以及痛真正集中的地方：**签名 bearer cap 对 per-entity authority 验证；实体自有 cap store；append-log 历史 + 派生 replay；单调版本的最终一致 projection；Definition 的 content-hash no-clobber 对账；带 resubscribe/catchup 的推送副本（ExternalMirror）。痛集中在**同步/对账接缝**上——压倒性地是旧 snapshot 平面与新 store 平面之间的**迁移**接缝（dual-write、冷加载对账、spawn 竞态里的 adopt-clobber、backfill/parity/epoch）。那是**给数据搬家的过渡成本，不是「数据有 owner」的稳态成本**。#1621 之后的稳态比之前**更简单、更机制化**：一个 store、一个状态枚举、一个读 facade、snapshot 降为投影。

**把 session 重新审一遍——各 socialware 行为到底要它什么：**

| session 职能 | 要求什么 | 严格还是收敛？ |
|---|---|---|
| Chat 扇出 | 投递时刻的当前成员集 | **闸口严格**（安全：撤销 ⇒ 立即拒绝）——但也只是一个 chokepoint 上的一次 cap 检查 |
| Chat 历史 / rejoin | append log + 每成员 cursor replay | 收敛（已经是） |
| Turn 状态机（hold/settle/approve） | settlement 恰好一次、按序 | **串行化，不是全局一致性**——session actor 的 mailbox 免费提供 |
| Surface / feed / SessionView | 已提交状态的投影 | 收敛（已经是；单调版本） |
| Publisher / ExternalMirror | cursor、环形缓冲、catchup | 收敛（已经是） |
| socialware manifest / Definition | 按名查找 + 分歧策略 | 收敛 + 显式 no-clobber 对账（已经是） |

session 是一个 **mailbox + 投影面**——一个收敛点。它仅有的两处严格行为是投递时的成员资格（安全决定）和单 actor 排序（免费）。「session 要求实体状态一致性」这个前提，就现有代码而言，**基本不成立**。

---

## ⑤ 结论

**假设的因果命题（①-3）不被 bug 语料库支持；反事实（①-4）会让最难的两件事变得更难。判定：假设在其因果内核上不成立——但它有两个精化后的读法是对的、且可执行。**

论据：

1. **计数：**9 个 bug 簇里，约 5 个是复制无 owner（[B]），约 3.5 个是存活性/时序/密钥生命周期（[C]），只有 #206 的爆炸半径算真正的「中心化伤人」（[A]）——而另两个 [A] 是反向的：chokepoint **缺失**才出 bug，收口（SessionReads、version-first 原子快照）才治好。
2. **session 不是元凶。**语料库里没有一条是「session 要求跨实体一致性、这个要求坏了事」。session 今天已经是假设希望它成为的样子：actor mailbox + 最终一致投影，只在两处严格（投递时成员资格、turn 排序），而这两处分别是安全需求和免费品。
3. **[B] 类是对去中心化自身纪律的违反，不是对中心化的控诉。**actor model 的健全性 = 每个数据单一写者 + 异步消息。每个 [B] bug 都是一个数据有两个家或两个写者——P3 违规。所有修复都朝**更单一的所有权**走（统一 cap store；「只有 spawn 赢家写」的 flavor 所有权；roster 变 cap 投影；durable outbox 拥有在途 grant）——这同样是 git 模型的实际机制（只有赢家能推进的串行化 ref），不是它的反面。
4. **反事实会把两大经典最终一致痛点**——撤销传播与 merge 语义——**引进产品的安全核心**，而这个产品的验收标准（撤销 ⇒ 立即拒收；输出到外部受众前的人工闸门）明令禁止那种滞后。而且被点名的参照系（Bluesky）没有解决去中心化的私有/受权数据——它靠全公开 + 实践上中心化的读模型绕开了这个问题。
5. **观测到的复杂度有一大半是过渡成本、不是稳态成本**——#189 的双平面窗口（dual-write、冷加载对账、backfill、parity、epoch）。终结它的一次性 cutover（#1621）验证了「additive → 写平面 → cutover」的节奏；对岸的稳态在机制上比出发点更简单。

**假设说对了的部分（精化后的内核）：**
- 当一个数据的*天然的家*就是实体自己时，再在中心留第二份拷贝必然漂移——#192 的 roster 正是如此，cap-as-truth（让「去中心化的那份」当 owner）方向正确、且已在计划中。
- 中心化的 *fail-loud* 点必须有**有界爆炸半径**——#206 一个坏包放倒整机，是值得工程化消除的真实中心化成本（按包隔离）。
- 跨 actor 的状态传递必须**从构造上就是最终一致的**（outbox + 幂等 apply），绝不 fire-and-forget——#207 的修复应当泛化。
- Allen 的目标——*机制简单、业务繁琐但只是简单机制的组合*——是可达的，而且那个机制就是设计文档里已经写着的：**每数据一个 owner（P3）+ 签名 bearer cap 在一个闸口验证 + mailbox + 派生投影**。复杂 bug 来自对这个机制的*偏离*（两个家、两个写者、缺 outbox），外加一次已经基本付清的刻意迁移。

---

## ⑥ 务实建议

**值得继续向 local-first / 单实体所有权方向挪的（做）：**

1. **完成 #192 / #1620：roster = 成员持有 cap 的投影。**holder store 里的 cap 成为成员资格唯一真相；session 的 `:members` 是派生视图。这是语料库里最清晰的「去中心化它」的赢面——它直接删掉一道 [B] 接缝。投递时的 cap 检查保持严格。
2. **把 DeliveryOutbox 模式定为一切跨 actor 状态投递的标准**（grant、revoke；顺带审计其余 fire-and-forget 的跨 store 写）。at-least-once + 提交后 applied + 幂等 apply 是 actor 原生的最终一致契约。板上 #1501 被打回的「补 pending absorb + 幂等 + fail-closed」就是这套纪律的收尾——落地它，别放松它。
3. **给 boot 爆炸半径设界：`ManifestSeed.scan_all!` 按包隔离**——坏包大声失败（telemetry + 可见降级），其余照常 boot。未来任何全局 fail-loud 的 registry 扫描同理。这是 #206 的正当教训（#1633 明确留给你的那个 policy 裁决点）。
4. **给每个文件/home 目录副本一条基于内容的对账规则**（把 `DefinitionRegistry` 的 no-clobber + 大声分歧策略推广到包播种和一切 `$EZAGENT_HOME` 内容）：缺失 → 播种；hash 相同 → 无操作；分歧 → 不覆盖、大声上报、显式 apply。「skip-if-exists」作为策略应被禁用。
5. **cutover 保持一次性。**#189 的教训：双平面窗口是 [B] bug 的繁殖场。additive → 写平面 → 原子 cutover，shadow 期尽可能短、配显式 epoch/fence。（这已是板上自己的结论；把它定为今后一切「数据搬家」的常规。）
6. **federation（v0.x+）来临时**，现有 cap 平面就是正确的地基——签名 bearer artifact + per-entity authority + generation 正是多节点部署需要的原语。届时把撤销设计为**显式带窗口的**（对 issuer 的 generation 检查允许有界陈旧度）——作为自觉的产品决定，而不是事故。

**千万别动的（它们承重，语料库就是证据）：**

7. **generation 闸 / 撤销立即生效**（`verify_against_current`、gen-gated holder 读、F-1「presented caps 永不满足 principal gate」）。这是安全核心；每个「放松它」的方向都会重新打开 codex 反复抓出的复活/滞后洞。
8. **KindRegistry 每 URI 单活 actor + 只许 `put_new` 注册。**它是 actor-local 状态健全性的来源。adopt 语义保持「只有赢家写」：以 core spawn 收据 `{:started, created?}` 为闸、禁止非 owner 删除、按 incarnation 定位回滚（#1604 形状）。
9. **turn settlement 保持单 actor 串行化。**human-in-the-loop 闸门需要有序、恰好一次的 settle 点；actor mailbox 零成本提供。
10. **read-plane chokepoint 及其反绕过 gate**（SessionReads 先授权；version-first 原子 feed 快照）。它们是*解药*本身；而且其最终一致友好的设计（单调版本 + replay 自愈）已经是与 local-first 兼容的正确形状。
11. **「instantiate 期间 flavor 可读」契约**（#1578）——一个常设警示：有些消费者对 read-your-write 的要求是正当的；把任何写改得更「最终」之前，先枚举这类消费者（#1604 的解法是给这个读换数据源，而不是让它容忍最终一致）。

---

*方法注记：架构经 `git show origin/main:` 读取（ARCHITECTURE.md、GLOSSARY.md、`.claude/skills/ezagent-developer/references/design-principles.md`、cap/identity/session/actor 源码）；bug 语料来自 PR 正文/diff（#1570 #1576 #1577 #1578 #1604 #1615 #1621 #1625 #1627 #1633、read-plane #1464-#1494）、dev-together 板与任务文件（`docs/together/tasks/189-*.md`、`followup-bugs-204-205.md`、07-29/07-30 板）以及项目 memory 语料。tracker 号（#188-#207）是板上的 tracker 编号，非 GitHub issue/PR 号。*
