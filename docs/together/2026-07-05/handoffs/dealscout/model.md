# dealscout 支撑概念模型（session 生命周期 + 访问权限 + 数据保留 + 撮合机制）

> **⚠️ 2026-07-06 返工 banner**：DealScoutRender/DealScoutView 已作废——dealscout=后台数据+爬取agent（爬完 emit `__dealscout_update__` 信号），hello=显示（views 引 `HelloRender`）；本文中提及 DealScoutRender/View 之处以此为准。


> 承接用户澄清（2026-07-03 → 2026-07-05 找为主重构 → 2026-07-05 撮合腿证据版校正，核实过代码）。DealScout 从"被开发"到"被使用"，经过 **3 种角色不同的 session**；认证/权限挂在 session 成员身份上、分**配置层 vs 使用层**两层；爬取/搜索数据有**保留策略**；**撮合机制 = hello 公开面聊天——DealScout 组合 hello 拿公开面 + concierge 客服，登录用户在公开面自助 join+发言供线索、匿名只读、founder 看身份后 invite 深聊**（不是 `#1178` 申请加入私有 session——现读代码确认 `#1178` admission gate 是 agent 门、防偷用别人 agent 刷凭证，DealScout 用不上）。编号文档（`README.md` 骨架 + `product/*` + `tech/*`）都坐在本模型上。
>
> **结构**：§1 session 3 角色（作者 / admin 装配组合发布 / 公开共享）· §2 权限两层 + 登录三档 · §3 公开面 concierge 客服（登录发言→concierge、匿名只读）· §4 数据保留 · §5 撮合机制 = hello 公开面聊天 + founder invite 深聊 · §6 发现层三条腿（撮合网络怎么形成）。
>
> **重构记录**：上一版（07-04）§0 画了"数据层弥合点 = 公开共享 session"（需求侧/供给侧两条链在公开面登记处多父交汇），07-05 找为主版把撮合机制改成 `#1178` 申请加入。本版（证据版校正）**弥合概念保留、机制再换**——需求/供给降级为贯穿颜色属性（`README.md §3.9`），tree 严格单亲；撮合机制**从"#1178 申请加入"改成"hello 公开面聊天"**（现读代码：`#1178` 是 agent 门、DealScout 用不上）；"双方交汇"内化进**撮合腿**（一方公开机会页、一方登录进来发言，角色可互换）。旧 §0 弥合点、旧 §5 访客登记/agent 策展公开广播、以及一度的 `#1178` 申请加入玩法**全部退役**。

---

## 1. Session 3 角色（一个 socialware 流经的 session）

DealScout 从"被开发"到"被使用"，经过 **3 种角色不同的 session**（原 4 种里"配置"和"组合再发布"合并为一个 admin session）。分清它们，才分得清"安装 vs 使用""配置权 vs 使用权""哪些今天能做、哪些 in-flight/缺口"。

```
A 作者开发 ──发布──► B admin session（装+配+组合+再发布，一个 session）──发布网页──► 公开共享 session
   (写 plugin 代码)     (install + 配关键词/token + 组合 hello 拿公开面 + republish)      │
                                                                            admin + 匿名 c + 登录 d 都在同一个 session,靠登录/成员身份区分能干啥
```

### 1.1 Session A — 作者 / 开发（author）

- **谁**：原作者（开发者 a/b）。
- **干嘛**：写 dealscout plugin（爬取/搜索 GenServer / `DealScoutRender` / 发现腿 recipe / 可选的私有深聊辅助 recipe 等代码）+ 定义 DealScout 的 `Definition`（纯 config：`uses`/roles（角色槽）/views/routing_rules，只引用代码模块名）。**公开面客服不用自己写**——组合 hello 直接拿到 hello 的 concierge（§3）。ezagent 内外结果一样。
- **代码现状**：✅ 完全可做（独立开发者三条路，dev/热装零改已有代码）。

### 1.2 Session B — admin（安装 + 配置 + 组合 + 再发布，**一个 session**）

- **谁**：拿到已发布 DealScout 的人（成为该实例 admin）。**配置和组合是同一个 session 的事**（用户 2026-07-04：不拆两个）。
- **干嘛**：
  1. **安装（install）**：拉取已发布 DealScout Definition 进 B → B 成"可配置的 DealScout 实例"（`SocialwareInstall.prepare_create_template/4`）。
  2. **配置**：改关键词/源/token/pin、配 profile，让它爬取/搜索生成发现流。
  3. **组合（compose）**：**组合 ≠ `uses`**——`uses` 字段只声明"依赖哪些 plugin（必须已装）"（`manifest_resolver.ex:41` `ensure_plugins_installed`/`plugin_installed?`）；**真正的组合**靠两条：多个 Definition 的 `installs` merge（`definition_editor.ex:63` `config_for_template`）+ 单个 Definition 内 bases/shape/views union（`definition.ex:124` `behaviors/1`）。DealScout 通过 `uses:[:ezagent_plugin_hello]` 声明依赖 hello、再靠 bases/shape/views union 拿到 hello 的公开面 + concierge，就**自带一个公开网页 + 客服**。**网页不是单独的"发布功能"，是 socialware 组合 hello 得到的一部分**（平台基本玩法；对齐 #1169 code-vs-config split）。也能组合别的能力拼成新 socialware。
  4. **再发布（republish）**：走 CR 治理 `ConfigGovernance.Socialware.publish_cr→publish_or_upgrade`（`config_governance/socialware.ex:81,116`，**只有 scope:public 跨 ws 发现才要 admin gate** `socialware.ex:197,228`，web_anon_access 发布者自助），把配好/组合好的 Definition 发布进 catalog；`DefinitionRegistry.list/1` 让别人发现、`SocialwareInstall` 让别人安装。**发布 = 今天仿 hello code-seed**（写 config map + boot 经真 governance publish）；未来 registry P3 从外部 config 源发布（不写 Elixir）。
- **权限**：基础用户 + **配置权限（admin cap）+ 发布权**。
- **代码现状**：✅ 大部分通（#1164 manifest track 落地 install+publish+discover，#1173/#1176 registry P0 加版本化+content-hash 安装）。**仍缺小口**：`installs` merge / bases·shape·views union 的组合展开深度要 F1 验证；纯数据 Definition 打进可分发插件包 manifest 仍不行（`manifest.ex:174-179` 拒 :socialware）——但这是 **Allen 有意让 socialware 走独立 config registry（决策 #1147/#1152），不是待补缺口**，走 imperative/governance seed 是正解。

### 1.3 公开共享 session — 匿名可看已发布的机会页（use，**不安装**）

- **谁**：admin + 匿名 c + 登录用户 d —— **都在同一个已发布的共享 session 里**（用户 2026-07-04 + 代码实证）。
- **关键**：**不是每人新建 session，是一个共享的已发布 session**。匿名走 `AnonAdmission.admit_anonymous_participant(session_uri)` → `join_as_anon` **join 那个已发布 session 本身**（铸只读 anon-User 成员）；external_feed 读授权 = 对这个共享 session 的 `:session` slice 跑 live membership 判定（`external_feed.ex:10-21`，"public viewer 是只读 anon-User 或登录 member"）。**大家通过这个网页看已爬到/搜到的发现流快照**，靠**登录三档**区分能干啥（三档详见 §2）。
- **这个公开面 = 匿名只读 + 登录可写**：匿名只看快照、下载已批准 artifact（都是读）；**登录用户能自助 join + 发言**跟 concierge 客服聊（§3）。**撮合就发生在这个公开面 + founder 主动 invite 的私有 session**——不走"公开面登记 + 公开广播"、也不走 `#1178` 申请加入，走 hello 公开面聊天（§5）。公开机会页的作用是**让别人发现你、登录进来发言、被你 invite 深聊**（`README.md` J-6：组合 hello 公开机会页 → 别人 J-7 登录进来发言 → 你 J-9 invite 深聊）。

### 1.4 这个模型对 dealscout 文档的影响

- **认证/权限挂在 session 成员身份上**，但分两种 session：
  - **admin session（B）成员** = 配置+发布权（install 了 DealScout Definition）。
  - **公开共享 session** = 匿名/登录都能看已发布机会页，靠**登录三档**（匿名只读 / 登录非成员只读 / 成员可写）区分。
- **"安装 vs 使用"**：install → 可配置的 admin 实例；use → join 已发布的共享 session、不 install。
- **组合 hello = 拿公开面 + concierge**：socialware 组合 hello 就自带公开网页 + concierge 客服。**注意口径**：`uses` **不是组合轴**——`uses` 只声明"依赖哪些 plugin（必须已装）"（`manifest_resolver.ex:41` `ensure_plugins_installed`）；真正的"组合"= 多个 Definition 的 `installs` merge（`definition_editor.ex:63`）+ 单个 Definition 内 bases/shape/views union（`definition.ex:124` `behaviors/1`）。网页是 socialware 组合出来的一部分，不是外挂发布功能。
- **dealscout 今天能做**：A 开发 ✅ + B 装配组合发布 ✅ + 匿名只读+下载 ✅ + **撮合腿（hello 公开面聊天：组合 hello+concierge / 登录自助 join+发言 / founder invite 深聊）✅**（riding 已在 main 的机制，见 §5，**不再是缺口**）。
- **等平台/要建**：① `installs` merge / bases·shape·views union 的跨-socialware 组合深度（F1 验）；② registry 跨环境 promote（#1169/#1173 已落 P0，剩 UI wiring）；③ **平台跨用户推荐**（发现层第③腿，缺口/discuss-first，见 §6）。

---

## 2. 配置权限 vs 使用权限（两层）+ 登录三档

认证不是单独一套账号，就是 **ezagent 的 session 成员身份**——成员持有的 cap（materialize 时 grant，`grant_recipe_caps` `definition_agents.ex:127`）就是"能对 DealScout 做什么"的凭证。但**"进哪个 session"决定你是配置者还是使用者**（session 角色详见 §1）：

- **admin session（B）的成员 = 配置+发布权（admin）**：这个 session **install 了 DealScout Definition**（**per-install 独立**——别人装 DealScout 各写一份本地 install SessionTemplate + 独立 write cap，`socialware_install.ex:109-124`），成员持配置 cap，能改关键词/源/token/profile、组合 hello 拿公开面、发布网页、再发布成新 socialware（配置和组合是同一个 session 的事）。**改自己那份配置走 `session.fork_config`**（`conversation_actions.ex:82`）；改公共发布物要 manage 权限。
- **公开共享 session = 匿名/登录都能看已发布机会页**（不是每人新建）：匿名 c / 登录 d / admin **都 join 同一个已发布的 session**（匿名 `AnonAdmission.admit_anonymous_participant(session_uri)`→`join_as_anon`；登录用户自助 join `session_feed_channel.ex:197-228`；external_feed 读授权对这个共享 session 的 `:session` slice 跑 live membership `external_feed.ex:10-21`）。**通过这个网页看发现流 + 登录后发言**，靠**登录三档**区分能干啥。
- 一句话：**install 让你成为可配置的 admin；公开面是一个共享 session，匿名只读、登录可发言、founder 全量白板互见**。**要深聊就靠 founder 在公开面看到身份后主动 invite 进私有 session**（§5），不是在公开面登记、也不是申请加入。

### 2.1 两层动作（靠 CapBAC 区分谁持哪个 cap）

| 层 | 动作 | 谁能做 | 代码依据 |
|---|---|---|---|
| **配置层**（改 DealScout 本身） | 改关键词+描述+profile、加/换信息源、提交 API/token、pin 保留某次爬取 | **只有配置权限的成员**（持 config cap；行级可再用 `Shared.owner_or_admin?` idiom `kanban/connectors.ex:38`） | 配置动作的 cap 在 recipe 的 requested_caps，只 grant 给该角色成员 |
| **使用层**（用 DealScout 的产出） | 成员追问深挖（扩共享 KB）、下载 artifact、**登录后在公开面发言→concierge 客服回帖**、发 email（需登录）、**被 founder invite 进私有 session 深聊（见 §5）** | 成员默认有全部；匿名只读快照 + 下载（读）、**发不了言**；登录用户自助 join+发言；email 需登录；深聊靠 founder 主动 invite | 匿名读=`anon_view_caps` `installation.ex:264`、匿名写硬禁 `session_feed_channel.ex:325-330`；登录发言→concierge（§3）；成员写 cap 来自 recipe；深聊=owner `invite_member`（§5） |

**关键**：配置层永远成员限定（改的是 DealScout 的"定义/配置"）；使用层是"可配的"（发布时决定放开哪些给匿名/他人）。**区别只在"谁能改配置"**，正如用户所说。

### 2.2 登录三档（#1168 落地，公开共享 session 里靠身份分权）

- **匿名（没登录）**：**只读** public 页快照 + 下载已批准 artifact。**发不了言**——web 层 `session_feed_channel.ex:325-330` 对 anon 返回 `not_logged_in`（join 与 post 两处硬禁），配合 `membership.ex:1200-1208`。
- **登录用户**（#1168 落地）：**能读** public 页（原来死"无权限"），并且**能在公开面自助 join + 发消息**（`session_feed_channel.ex:197-228`）——发的消息 @orchestrator → 非 owner 永远路由 concierge 客服回帖（`router.ex:13-14` / `hello_concierge.ex:43`）。登录用户**能聊、能供线索**，成为这个公开面的（受限）成员。
- **founder / owner**：读 + 写 + **全量白板互见**（`external_feed.ex:85-98`）+ **看发言者身份**（`session_feed_channel.ex:353`）+（有配置 cap 的话）配置。founder 想深聊就**主动 invite** 对上的人进私有 session（`conversation_actions.ex:683`）——**深聊靠 owner 主动拉，不是申请人申请**。

### 2.3 发布后：匿名/房外人能做什么

DealScout 定版发布（`visibility_policy.web_anon_access: true`，**发布者自助、不需 admin**——只有 `scope: :public` 跨 workspace 发现才要 admin，`socialware.ex:197,228`；真正上不上公网靠**域名分配（infra 层）**，合规是外部审批、平台不背）后：
- **匿名能**：看已爬到/搜到的发现流快照（view render cap，`anon_view_caps` `installation.ex:264`）✅、下载已批准的 artifact（`/socialware/external/download` `router.ex:166`）✅——**都是读**。
- **匿名不能**：改关键词/源/token（配置层，成员限定）✅ 正确挡住；**发 email**（真·写内容，需登录 CapBAC）；**在公开面发言/发帖**（`session_feed_channel.ex:325-330` 两处硬禁）。
- 房外人想进来交流：**登录 → 在公开面自助 join + 发言供线索 → founder 看到身份 → founder 主动 invite 进私有 session 深聊**（§5），**不是**在公开面登记、也不是申请加入等审核。想拥有完整配置权则**把 DealScout 装进自己的房间**（per-install 独立、自己成为那份实例的成员）——这是"复制一份自己的 DealScout"，跟原房间的 KB 隔离。

---

## 3. 公开面客服 = 组合 hello 的 concierge（登录发言→concierge、匿名只读，非缺口）

**结论**：**公开面的客服**（登录访客发言时回帖的那个）**不是**"匿名受限写"平台缺口、也不用新写 recipe——就是**组合 hello 自带的 concierge 客服**（hello #1168 已在 main）。（私有深聊 session 里的 AI 撮合辅助是另一回事，可选、由 dealscout 自己的深聊辅助 recipe 承担，见 `tech/issues-plan.md` I-13。）三档读写清清楚楚：
- **匿名只读**：看发布那刻定死的快照 KB，**发不了言**（`session_feed_channel.ex:325-330` 硬禁 join 与 post）。
- **登录用户发言 → concierge 客服回帖**：登录后自助 join + 发消息（`session_feed_channel.ex:197-228`），消息 @orchestrator → 因为是非 owner，`router.ex:13-14` 结构性保证**永远路由 concierge**（`hello_concierge.ex:43` 回帖）、到不了改页的 builder、不为访客发 builder LLM 调用。
- **发 email** 是真·写内容、需登录 CapBAC。成员追问不受影响（成员有写 cap，追问扩共享 KB）。

**对 dealscout 的含义**：dealscout **组合 hello 就直接拿到 concierge 客服**（`uses` 声明依赖 hello plugin + bases/shape/views union），**不另起 `dealscout-support` recipe、不依赖 #1146 匿名临时 session 路径**。dealscout 是 hello 公开面聊天机制的**消费方、不另起缺口**。

**完整论证（含全部 file:line —— `router.ex` / `hello_concierge.ex` / `session_feed_channel.ex` / `external_feed.ex`）详见 `spec-vs-code-gaps.md §3b`，这里不复述。**

---

## 4. 数据保留（爬取/搜索数据不无限膨胀）

- **触发**：一次配置 → 定时爬取（F-1 轮询 GenServer）+ 手动爬取 + 主动搜索（F-3）。数据持续流入 KB slice。
- **保留策略**（dealscout 自建，非平台缺口）：**默认保留最近 10 次爬取**（或最近 1 个月，取先到者），保持信息新鲜；**可选 pin 某几次长期保存**（pin 是配置层动作，成员限定）。
- **实现**：一个保留 sweeper（周期 GenServer `Process.send_after`，照 `apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex` + `idempotency/sweeper.ex` 先例），扫 KB slice、丢弃超期且未 pin 的爬取批次。
- **寻址**：每次爬取批次在 KB slice 里有个批次 id（配 pin 标记）；pin 列表也存 slice。

---

## 5. 撮合机制 = hello 公开面聊天 + founder invite 深聊（换掉"#1178 申请加入"）

> **来由**：用户 2026-07-05 找为主重构后，撮合一度定为"#1178 申请加入你的私密 session、owner 审核、私密聊聊看"。**证据版校正（现读代码）**：`#1178` admission gate 是 **agent 门**（防偷用别人 agent 刷凭证、cross-owner mount 一个 session 才落 pending），DealScout 用不上、过度设计。真实玩法 = **hello 公开面聊天**：DealScout 组合 hello 拿公开面 + concierge 客服，登录用户在公开面自助 join+发言供线索，founder 在同一 session 全量白板互见、看身份后**主动 invite** 对上的人进私有 session 深聊。公开面聊天 + owner 主动 invite，就是撮合作为"涌现亮点"该有的形态。

### 5.1 公开面聊天故事（撮合腿的核心流）

用户 **e**（一个投资人 / 线索方 / 或纯想进来）在网上或平台看到用户 **c** 组合 hello 公开的机会页（`README.md` J-6）→ 知道 c 在找什么 → e 想跟 c 建立连接：

1. **匿名只看**：e 没登录时**只能读** c 的公开页快照，发不了言（`session_feed_channel.ex:325-330` 对 anon 返回 `not_logged_in`，join 与 post 两处硬禁；配合 `membership.ex:1200-1208`）。
2. **登录自助 join + 发言供线索**：e 一登录，就能在 c 的公开面**自助 join**（`handle_participatory_join` `session_feed_channel.ex:197-228`）、**发消息**（`handle_participatory_post` → `dispatch_post` 带 `mentions:[orchestrator_uri]`）。因为 e 是**非 owner**，`router.ex:13-14` 结构性保证消息**永远路由 concierge 客服回帖**（`hello_concierge.ex:43`）、e 到不了改页的 builder。e 在公开面附上联系方式 / 商业线索 / 意图，跟 concierge 先聊清来意。
3. **founder 全量白板互见 + 看身份**：c（founder/owner）本人也在同一 session，**全量白板互见**（`external_feed.ex:85-98`，每个 viewer 看所有参与者消息）——e 供的线索、跟 concierge 聊的，c 都实时看得到；且 c 看到 e 的**真实身份**（登录=真实 URI 带用户名，`session_feed_channel.ex:353`）。c 想亲自下场跟 e 聊也行（c 是 owner）。
4. **founder 主动 invite 深聊**：c 判断 e 对上了，就**主动 invite e 进一个私有 session 深聊**（`conversation_actions.ex:683` `invite_member`；`:join` 需 e 是 live member Kind）。**这是 owner 主动拉、不是 e 申请**——公开面负责让人自助进来发言，深聊由 c 挑人 invite。

**一句话**：公开机会页让别人发现你、登录进来实名发言供线索；真正的深聊连接靠**founder 在公开面看到身份后主动 invite 进私有 session**——**看到（公开面发言）→ 挑人（founder 判断）→ 拉进来（invite 深聊）**，owner 全程掌控挑谁深聊。

### 5.2 深聊后玩法（撮合作为涌现亮点长出来）

被 invite 进私有 session 之后：

- **私密深聊**：双方在私有 session 里低成本私聊，看是否匹配。深聊在私有 session、不在公开面白板上。
- **按信任选择性披露**：owner 控制对方看到什么——先给公开面级信息，随信任升级再逐步放开更敏感的资料。深聊私密、逐级披露，解保密顾虑。
- **AI 辅助撮合**：AI 副驾辅助双方对齐意图、补齐材料、判断匹配度。
- **持续关系通道**：这个私有 session 成为 c↔e 的长期私密通道。
- **撮合成功记账**：连接达成后双向记一笔（c 侧记"e 从公开面进来撮成"、e 侧记"从 c 的页进来撮成"），形成可回溯的双向边——喂撮合北极星 P-3.2（`README.md`，**质量加权 = 公开面真实互动/被邀深聊、不刷登录发言量**）。
- **私密关系网涌现**：一个个私密撮合边累积，长出 c 的私密关系网。撮合**不当地基、当发现之上涌现的亮点**（发现腿天天用、撮合腿慢慢长）。

### 5.3 数据落地：公开面（public_view）+ founder 另拉的私有 session

- **撮合腿 = 一个组合 hello 的公开面 session（public_view）+ founder 想深聊时另 invite 的私有 session**。访客在公开面登录后自助成员、实名发言供线索（在公开面白板上）；founder 主动 invite 才把对上的人拉进**另一个私有 session** 深聊（深聊内容不在公开面）。
- **对比旧模型**：07-04 版让访客往"公开共享 session"追加登记、agent 策展公开广播上页（数据天然公开）；07-05 找为主版一度改成"#1178 申请加入 c 的私密 session、落 pending、owner 审核"（agent 门、DealScout 用不上）。**证据版**：公开面负责发现+实名发言（登录可写、匿名只读），深聊靠 founder 主动 invite 进私有 session——**公开发现与私密深聊两个 session 分离**，都 riding 已在 main 的机制。
- **落法锚点**：`README.md` F-8（组合 hello + concierge）/ F-9（登录自助 join+发言）/ F-10（匿名只读硬禁+身份）/ F-11（founder invite 深聊）；对应 I-10..I-13。**撮合不再是缺口**——riding hello 公开面聊天，`router.ex:13-14` / `session_feed_channel.ex:197-228,325-330,353` / `external_feed.ex:85-98` / `conversation_actions.ex:683` 全在 main。

---

## 6. 发现层三条腿（撮合网络怎么形成）

> **来由**：yujun 指出旧模型"没有发现层"（撮合当地基、访客靠公开广播找到彼此，红线）。改进模型把"人怎么找到彼此、网络怎么形成"拆成**三条腿**（`README.md §0` + handoff Part 2）。撮合网络不是靠公开广播，是靠这三条腿把对的人送到对的门口。

| 腿 | 是什么 | 机制 | 状态 |
|---|---|---|---|
| **① 主动找**（发现腿核心） | AI 千人千面**主动发现**（按 profile 推匹配机会）+ **主动搜索**（手动 query 全网/指定源） | dealscout 副驾 recipe（可用 cc-headless）复用爬取/搜索基建 | **今天能做** |
| **② 公开面聊天**（撮合腿） | 别人从你组合 hello 公开的机会页**登录进来自助 join、发言供线索**，founder 看身份后 invite 深聊 | hello 公开面聊天（组合 hello+concierge `router.ex:13-14` → 登录自助 join/post `session_feed_channel.ex:197-228` → 匿名只读 `:325-330` → founder invite `conversation_actions.ex:683`）| **今天能做**（riding，§5）|
| **③ 平台跨用户推荐**（关系网层，缺口） | 平台跨用户**发现别人已发布的实例** + **匹配推荐** + **朋友圈图** | ezagent 关系网层——现在只有 **DEF 级**跨 workspace 发现（`DefinitionRegistry.list/1` `definition_registry.ex:255`，只"发现某类 socialware 去装"），**实例级发现 / 匹配推荐 / 朋友圈图都缺** | **缺口 / discuss-first**，riding registry track（#1169/#1173），dealscout 首个需求方、**不阻塞** |

**三条腿的关系**：①②今天就能拼出一个真撮合小网络（我主动找机会 + 别人从我公开面登录进来发言、我 invite 深聊）；③是把小网络长成大网络的关键——让平台能跨用户把"c 在找的"和"e 已发布的实例"自动撮到一起，而不只是发现"有哪类 socialware 可以装"。第③腿是平台方向，dealscout 是它的**首个真实需求方**，标 discuss-first，但**不卡 dealscout 主干**（①②今天能做）。

**为什么撮合网络能私密地长出来**：靠①把机会送到人眼前、靠②让登录用户在公开面自助发言供线索而 owner 看身份后**主动 invite** 才把对上的人拉进私有 session 深聊（发言者不能自己闯进你的私域，深聊是 owner 主动拉、且在私有 session 里进行）、靠③（将来）让平台智能牵线——**全程没有一处需要"公开广播我在找什么/我有什么"**（公开的只是机会页本身，深聊私密）。这正是从旧"公开面登记+广播"换到 **hello 公开面聊天 + owner 主动 invite 深聊** 换来的结构收益（撮合腿证据版校正后，非 `#1178` 申请加入）。
