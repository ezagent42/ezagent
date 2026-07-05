# Handoff: 官方 socialware 规范 vs 实际代码——不符点与修复办法

> **Date:** 2026-07-03 · **From:** jjkysy (FP5) · **To:** Allen (lead)
> **Base:** upstream/main（已含 #1153 规范 / #1154 Kb-字面清理 / #1150 W0-tenant / #1151 deploy）
> **来由:** 拿官方规范 `docs/guide/socialware-authoring-interim.md`（#1153）逐条对照实际代码，校准我们的 dealscout 文档（`../dev/independent-dev-feasibility.md` / `README.md`，已按 Part 1 改）。本文件是 **Part 2**：规范承诺/现代 shape、但代码还没跟上、**本轮可修复**的点。

---

## 0. 先说结论

规范整体**准确、可信**——6 个查证点里 5 个规范说的与代码完全一致（caps-only-from-recipe、持久化路径、bases/shape 指 plugin ActionSet、CR-governance agent-subject-only、views 住 plugin）。

> **状态更新（2026-07-04，对 `de4f40a5` 现读；2026-07-05 补 #1180）**：原来记的 2 处"规范承诺、代码还旧"里，**修复点二（flavor gap）已被 #1164 闭合**（角色槽 flavor 字段落地 + materialize 读取，见 §2 —— 现在标 CLOSED；**#1180 后承载字段从 `agents` 改名 `roles`**）。**只剩修复点一（autoservice 例子还是旧 shape）仍未修**（`git diff de4f40a5` 证实 #1164 没顺带改它）。发布/发现相关的链路（`DefinitionRegistry.list/1` 发现、`ConfigGovernance.Socialware` CR publish、`SocialwareInstall` 安装）**#1164 都已闭合**——不再是"埋管道零入口"。第 3 处（纯数据 Definition 打进 manifest 包，`manifest.ex` 仍拒 `:socialware` seed_ref）**不是"待补 defer"，是 Allen 有意让 socialware 走独立 config registry（决策 #1147/#1152）**——见 §3 校正口径。**另附撮合面（§3b）：DealScout 撮合面 = 组合 hello 的公开面 + concierge（#1168 已在 main），登录自助 join/发言→concierge、匿名只读、founder invite 深聊——非缺口、dealscout 复用 hello 不另起客服 recipe。**

## 1. 修复点一 · autoservice 官方例子还是旧 shape

> **状态（2026-07-04 核实；2026-07-05 补 #1180）**：**仍未修**。#1164/#1180 都没顺带改它——`package.yaml` 仍是旧 shape（legacy `roles:` 映射 / inline `requested_caps` / `Ezagent.Behavior.Kb` pre-T1 命名）。这是唯一还没修的"规范承诺、代码还旧"点。

**规范自认**（`socialware-authoring-interim.md:70-74`）："shipped 例子还用 OLD shape"。

**代码现状**：`apps/ezagent_domain_session/priv/socialware/autoservice/package.yaml` 是旧 shape——
- legacy `roles:` 是一个 **映射**（`autoservice: {requested_caps: [...]}`），**跟 #1180 后 Definition 的新 `roles:` 字段（角色槽列表）同名但形状完全不同**——别混：新字段每条是 `%{role_name, fill: :agent, recipe, flavor}` 的 role-slot（`definition.ex:34-36`），不带 inline caps。
- inline `requested_caps`（规范禁止：caps 应只在 recipe）
- `Ezagent.Behavior.Kb`（pre-T1 命名，应是 `Ezagent.ActionSet.Kb`）
- `session:`/`surface:` 等安装器字段混在里面

**为什么是问题**：这是**唯一 shipped 的 socialware 例子**，第三方（包括 dealscout）会照它抄——照旧 shape 抄就违反规范三条纪律，且新 `roles:` 角色槽形状（#1180）与 legacy `roles:` 映射撞名，抄错会被 `Definition.new/1` 拒。规范给了现代化后的样子（`:77-97`）但没落到文件。

**修复办法**：
1. `package.yaml` 现代化为 `%Definition{}` shape（**#1180 role-slot 口径**）：`roles: [%{role_name: "autoservice", fill: :agent, recipe: "autoservice-support", flavor: "cc"}]`（角色槽——只声明角色、绝不塞实例 URI）、`views: []`、`routing_rules: [%{match: in_session, receiver: {:role, "autoservice"}}]`（receiver 只能是已声明角色名）、`visibility_policy: %{publish_policy: auto, web_anon_access: true}`、`owner_policy: %{type: :installer}`（**`:fixed` 已被 #1180 拒**）。
2. **caps 下沉**：把 inline `requested_caps` 移进 `autoservice-support` recipe（住 kb/autoservice plugin），例 `requested_caps: [{Ezagent.ActionSet.Kb, :query}]`。
3. **⚠️ 连带改安装器**：`scripts/autoservice_tier1_seed.exs` 读的是 legacy `roles:` 映射——**光改 yaml 会断安装器**，必须同步改它的解析（改成读 #1180 的 `roles:` 角色槽列表）。这条别漏，否则 CI/e2e 红。

## 2. ~~修复点二 · flavor gap~~ → **CLOSED（角色槽 flavor 字段已落地；#1164 落地、#1180 改名 roles）**

> **状态更新（2026-07-04 现读；2026-07-05 补 #1180）**：本节原记的 flavor gap **已被 #1164（socialware manifest track）闭合**，**#1180 又把承载字段从 `agents` 改名 `roles`、退休 `members`**。字段落地 + materialize 读取都在，**per-agent flavor 现在能声明了**。仅"非 cc flavor 是否真 runnable"是运行时另一回事（见下"仍需注意"）。

**#1180 后代码现状**（file:line 对 `bf7db1818`）：
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex:34-36` — agent 角色槽 type 现是 `%{role_name: String.t(), fill: :agent, recipe: String.t(), flavor: String.t()}`，**flavor 字段已加、且是 agent 槽必填**。
- `definition.ex:275-303` — `role_slot/1` 现**读取并要求** agent 槽 flavor 非空（`non_empty_string?(flavor)` `:284-286`；返回 map 含 flavor `:286`）——**不再静默丢弃**。
- `.../session_creator/definition_agents.ex:321-326` — `flavor_of/1` 从角色槽读 flavor（缺省回填 `"cc"`），materialize 一路透传到 `create_agent_from_recipe`。**flavor 全程被读并路由**。

**结论**：dealscout / kanban 都想要的"per-agent flavor 差异"，**声明层今天成立**——Definition.roles 的 agent 槽每条按 `%{role_name, fill: :agent, recipe, flavor}` 写，flavor 会一路传到 materialize。**不再需要 dealscout workaround、不再是硬缺口。**

**仍需注意（非本 gap，运行时另一回事）**：字段落地 ≠ 所有 flavor 都 runnable。今天唯一双 materialize hook 齐全的仍是 `cc`；若声明 `native` / `cc-headless`，能不能真起一个活 agent 取决于那个 flavor 的 materialize hook 是否补齐——这是运行时能力问题，不是"Definition 表达不了 flavor"的缺口。dealscout 可以放心按规范写 `flavor: "cc"`（或将来某个已接线的 flavor），字段这一层已通。

## 3. 声明式打包缺口 = Allen 有意绕过（不是"待补/我们 propose"）

> **口径校正（2026-07-05）**：这里原写成"路线图 defer、未来 W1 补"。**校正**：纯数据 Definition 打不进 plugin 包**不是待补的缺口，是 Allen 的有意架构决策**——**socialware 走独立 config registry**（ConfigStore + governance + discover + install 面），**plugin 包只管代码 + recipe**。两条职责刻意分离，不是"还没做"。

**代码现状**：manifest `seed_refs` 拒 `:socialware`（`plugin_package/manifest.ex:174-178`，seed_ref kind 必须 `:recipe`）、plugin 契约无 `definitions/0` 回调。**这是 Allen 决策 #1147/#1152 的有意选择**：socialware 的发布/发现/安装全走独立 config registry（`ConfigGovernance.Socialware.publish_cr` / `DefinitionRegistry.list` / `Installation.install_template_installs`），而不是塞进 plugin 包的 manifest。

**对 dealscout 的含义**：dealscout 照此走——**代码（爬取/搜索/DealScoutRender/SessionView + 组合 hello 的 concierge）进 plugin，Definition 走 code-seed（仿 hello：写 config map + boot 经真 governance publish）**，不等、也不该等"纯数据 Definition 打进包"这条通道（它按设计就不该存在）。未来 registry P3（#1169/#1173）让 Definition 从外部 config 源发布（不写 Elixir），是同一条独立 config registry 路线的延伸，不是补 plugin 包的缺口。

## 3b. 撮合面 = 组合 hello 的公开面 + concierge（证据版校正，非缺口）

> **校正（2026-07-05）**：早前把 DealScout 的客服追问画成"匿名开临时 session 跟 `dealscout-support` agent 对话、依赖 #1146"。**现读代码校正**：撮合面 = **组合 hello 的公开面 + hello 自己的 concierge**（#1168 已进 main），三档读写清清楚楚，**不是匿名追问、也不另起 dealscout-support recipe**。

**正确模型**（就是 hello 公开面聊天，代码已在 main）：
- **匿名 = 只读快照，不能写**：发布的 DealScout 就像 hello 网页；匿名看快照信息流（`anon_view_caps` `installation.ex` 铸 view render cap）+ 下载 approved artifact（`router.ex:166`），**都是读**。**匿名发不了言**——web 层 `session_feed_channel.ex:325-330` 对 anon 返回 `not_logged_in`（join 与 post 两处硬禁），配合 `membership.ex:1200-1208`。
- **登录用户 = 自助 join + 发消息 → concierge 客服回帖**：登录后在公开面自助 join（`session_feed_channel.ex:197-228` `handle_participatory_join`）、发消息（`handle_participatory_post` → `dispatch_post` 带 `mentions:[orchestrator_uri]`）；因为是非 owner，`router.ex:13-14` 结构性保证**永远路由 concierge**（`hello_concierge.ex:43` 回帖）、到不了改页的 builder、不为访客发 builder LLM 调用。**DealScout 复用 hello 的 concierge，不新写 dealscout-support 客服 recipe。**
- **founder/owner = 全量白板互见 + 看身份 + invite 深聊**：founder 本人在同一 session，`external_feed.ex:85-98` 全量白板互见、`session_feed_channel.ex:353` 看发言者真实身份，想深聊就 `conversation_actions.ex:683` `invite_member` 主动拉进私有 session。
- **发 email = 真·写内容 = 需注册登录（CapBAC 授权范畴）**，非匿名能干。

**dealscout 的立场**：撮合面**不是缺口**——组合 hello 拿公开面 + concierge、登录自助 join/发言、匿名只读、founder invite 深聊，全部 riding 已在 main 的机制（hello #1168 + `session_feed_channel` + `invite_member`）。dealscout 只需在 Definition 里组合 hello（`uses` 声明依赖 + bases/shape/views union），**不另起 `dealscout-support` recipe、不依赖 #1146 的匿名临时 session 路径、不等新平台字段**。

> **concierge 回帖的两个硬前提（现读复核，2026-07-05）**：登录用户发帖收件人是 web 层写死的 `orch_<name>`（`session_feed_channel.ex:373-375`）——它**不是** Definition materialize 出来的随机 UUID（那条根本不经过），而是 hello **命令式按名重挂**的：`ensure_session_orchestrator` 对**任何经 world 路径建的 page session** 都补一个 `orch_<session名>` 成员（`create_role_agent(ws, "orch_#{name}", ...)`，hello `app.ex:136,143`），由 world 建 session 后调（world `conversation_actions.ex:326,342`），跟收件人算法逐字对齐、必命中。所以撮合面自包含可达，**但要满足两条**：(1) DealScout Definition 复制 hello 公开面配置（`shape` 含 `Surface`+`Turn`、`adapters` 含 `external_feed`、带 seed 页 → 成 **page session**，`page_session?` 才不 no-op）；(2) 建/装会话**走 world 路径**（socialware install→`create_session`）。**不走 world 路径或无 Surface/seed 页 → orchestrator 不建 → concierge 不回**（前提没满足，不是死锁；无需任何平台改动）。

---

## 4. 给 Allen 的建议

- **修复点一（autoservice 现代化）** 值得排——它是唯一 shipped 例子，越晚改越多人照旧 shape 抄。**#1164 没顺带改它**（`git diff` 证实），仍是旧 shape。注意连带 `autoservice_tier1_seed.exs`。
- **修复点二（flavor gap）→ 已闭合（#1164 落地、#1180 改名 roles）**：Definition.roles 的 agent 槽 flavor 字段落地（`definition.ex:34-36`）+ `role_slot/1` 读取要求非空（`:282-286`）+ materialize 透传（`definition_agents.ex:321-326`）。dealscout/kanban 现在**声明层能表达 per-agent flavor**，无需再等、无需 workaround。剩下的只是"非 cc flavor 是否 runnable"的运行时能力（材料化 hook），非本 gap。
- **撮合面（§3b，非缺口）**：DealScout 撮合面 = **组合 hello 的公开面 + hello concierge**（#1168 已在 main）——匿名只读（`session_feed_channel.ex:325-330` 硬禁写）、登录自助 join/发言→concierge（`:197-228` + `router.ex:13-14` + `hello_concierge.ex:43`）、founder invite 深聊（`conversation_actions.ex:683`）。dealscout **复用 hello、不另起 `dealscout-support` 客服 recipe、不依赖 #1146 匿名临时 session 路径**。撮合腿从"#1178 申请加入私有 session"证据版校正为"hello 公开面聊天"——`#1178` admission gate 是 agent 门、DealScout 用不上。
- 我们两份 dealscout 文档已按规范校准（flavor 从"硬缺口"改成"forward-declare 写法"、补 caps-only-from-recipe 纪律、views 措辞对齐 extension-pack 心智），可与本文件一起看。
