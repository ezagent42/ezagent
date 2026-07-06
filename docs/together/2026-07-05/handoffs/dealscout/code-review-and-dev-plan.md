# Handoff：dealscout —— 现有代码审阅报告 + 开发计划

> **⚠️ 返工修订（2026-07-06 用户拍板，覆盖本文中一切相抵触的旧文；完整 banner 见同目录 spec.md / plan.md 顶部）**
>
> 层级 **plugin → socialware → ezagent**。DealScout 是 **socialware（纯配置组合）**，唯一真 plugin = 爬取后台。职责重划：**dealscout = 后台数据 + 更新信号**（爬取 plugin + 它的 agent 爬完注入新线索后 emit `__dealscout_update__`，`Ezagent.ActionSet.DealScoutCrawl.update_signal/0`，像 kanban 的 `__done__`）；**hello = 显示 + concierge**（hello 的 agent 收信号更新 json-render 页）。**dealscout 不声明任何 view / render**——下文凡出现 `DealScoutRender` / `DealScoutView` / "dealscout 自己的发现流 SessionView / world tab" 的设计**已删除、作废**（原 I-5 显示件归 hello；I-8 / F-4 world-tab 议题随之消失）。DealScout Definition（Stage D 已落地 `apps/ezagent_plugin_dealscout/lib/ezagent_plugin_dealscout/definition_seed.ex`）：`uses: ["hello","dealscout"]`、`views: [Ezagent.ActionSet.HelloRender]`（hello `PageView` 以此认领渲染，零改 hello）、`routing_rules` 用 `text_contains("__dealscout_update__")` → 已声明角色 `"page"`（内容协议 routing 像 kanban relay，零实例 URI）。下文与此抵触处一律按本 banner 为准。


> **Date:** 2026-07-05 · **From:** jjkysy (FP5) · **Base:** upstream/main `90e8ee29`（skill-1 索引基线，file:line 现读核实）
> **一句话:** ezagent socialware 全流程已闭环到 ~8.5 成，dealscout 今天就能在此基础上开跑；本文=① 现有代码审阅（socialware 生命周期完成度）② 引用 0703 产品/issue 的开发计划（今天能做 vs 缺口）。
> **配套:** 产品定位/旅程/视图/功能 = `../../2026-07-03/yao/dealscout/product/1-4`；开发 issue = `.../tech/issues-plan.md`；概念模型 = `.../model.md`；编号骨架 = `.../README.md §3`。
>
> **⚠️ 证据版校正（2026-07-05，后于本 handoff）**：本 handoff Part 2 原把撮合腿定成 **"#1178 admission gate 申请加入 → owner 审核 → 聊聊看"**。**现读代码确认这跟代码冲突**：`#1178` admission gate **只 pend agent、不 pend 人类**（`membership.ex:138` `not Ezagent.URI.type?(member_uri, :user)`，语义是"owner 拉别人的 agent 进会话 → 那 agent 的主人审批"防偷刷凭证），**今天并无"陌生人主动申请入会"入口**，DealScout 用不上。**撮合腿已换轨成 hello 公开面聊天**——组合 hello 拿公开面 + concierge 客服（`hello/router.ex:13-14` 非 owner 永远路由 concierge、访客到不了 builder）、登录用户自助 join+发言（`session_feed_channel.ex:197-228`）、匿名只读硬禁（`:325-330` + `membership.ex:1200-1208`）、founder 全量白板互见+看身份（`external_feed.ex:85-98` / `session_feed_channel.ex:353`）→ owner 主动 invite 深聊（`conversation_actions.ex:683`）。**权威 = 已校正的 `product/*` + `model.md` + `README.md` + superpowers `spec/plan`**；本 handoff Part 2 下文凡提"#1178 申请加入撮合"处以下均已就地改到证据版，保留作历史记录。

---

## Part 1 · 现有代码审阅：socialware 全流程完成度（~8.5 成）

我们在 PR#1148（可寻址完备性审计）提的"提交/发布/发现/安装/组合/使用/再发布"生命周期，经 #1164（manifest track）+ #1173/#1176（registry P0）+ #1178（admission gate）后，**6 段主干全在代码里闭环**，机器集中在 `apps/ezagent_domain_session/lib/ezagent/socialware/`。

| 段 | 状态 | 入口 file:line |
|---|---|---|
| **提交-定版** | ✅ 闭环 | `Definition.new/1` `definition.ex:77` + artifact 身份 `content_hash/1` `:176`；`ManifestResolver.resolve/1` `manifest_resolver.ex:14`；append-only 版本 `DefinitionRegistry.write_definition/2` `definition_registry.ex:229` |
| **发布** | ✅ 闭环 | `ConfigGovernance.Socialware.publish_cr/publish_or_upgrade` `config_governance/socialware.ex:81,116`；PUBLIC admin gate `:197`；owner_policy `definition.ex:412-425`（**#1180：只准 `:installer`，`:fixed` 被拒；`validate_anon_owner` no-op `:432`，旧"anon 必须 fixed owner"已作废**，owner 由 install caller 派生 `:176`）；retract/restore `:156,167` |
| **发现** | ⚠️ 闭环（仅"发现 DEF 去装"）| `DefinitionRegistry.list/1` `definition_registry.ex:255` 跨 workspace + content-hash 寻址 `resolve_installable_revision/3` `:87`。**跨用户"发现已发布实例/产物"缺**（见 Part 2 发现层第③腿）|
| **安装** | ✅ 闭环 | `Installation.install_template_installs/4` `installation.ex:185` + install-by-ref/pin `:473` + freeze-pin `:94/:151`；world `SocialwareInstall.prepare_create_template/5` `socialware_install.ex:48` |
| **组合** | ✅ 闭环 | `uses` `definition.ex:16,43` + behavior 扁平 merge `installation.ex:58-68` + config merge `definition_editor.ex:296` |
| **使用** | ✅ 闭环 | materialize `definition_agents.ex:63`（**#1180：只把 `fill: :agent` 角色槽物化**，grant recipe caps LAST `:122`→`:241`）+ member-cap grant-at-join `membership.ex:85-103` + **#1178 admission gate** `admission_pending?/2 :123`→`record_pending_admission :227`→`approve_admission/3 :326`；anon 只读 `installation.ex:264` |
| **再发布成新 socialware** | ⚠️ 半闭环 | snapshot `definition_editor.ex:131`（可另存新名 `:141`）+ orchestrator `save_template_as` `orchestrator/tools/templates.ex:55`。**只写作者本 ws private 版本；到 PUBLIC catalog 差一步 `publish_or_upgrade` wiring**（现只 hello boot 调） |

**对照 #1148 原标四缺口**：发布真空 ✅ 闭合、element 寻址 ✅ 闭合（content-hash/revision `definition_registry.ex:87`）、发现 ⚠️ 部分（DEF 级闭合、实例级缺）、匿名受限写 ⚠️ 按设计收敛（匿名只读 `session_feed_channel.ex:325-330` + 登录用户自助 join 后经 confirmed member-cap 写 `session_feed_channel.ex:197-228` / `membership.ex:1200-1208`——**非 #1178 申请入会**）。

### 剩余 3 个真缺口（对 dealscout 的影响 + 归属）
1. **声明式打包 socialware**（`manifest.ex:54-56` 拒 `:socialware` seed + `plugin.ex` 无 `definitions/0`）——socialware 只能 imperative/governance seed，打不进可分发插件包。**我们 propose**（注释自称 future enhancement，无平台计划）。**对 dealscout：不阻塞**（dealscout 走代码 seed，跟 hello 一样）。
2. **跨用户实例发现 + 匹配推荐 + 朋友圈图（关系网层）**——DEF 级跨 ws 发现 ≠ 发现别人已发布的实例。**平台方向**（riding #1169/#1173 registry track）。**对 dealscout：这是发现层第③腿**（见 Part 2），记为 discuss-first，dealscout 不阻塞（①②今天能做）。
3. **republish→public 一键 wiring**（机制 `publish_or_upgrade` 已在 `socialware.ex:116`，UI 未接）——**我们 propose（小改，接线即可）**。**对 dealscout：F6 发布公开面用得上**，可顺带补。

**结论**：全流程主干闭环到"dealscout 今天能开跑真撮合小网络"；成规模网络卡关系网层（平台方向）；两个工程小缺口（声明式打包、republish 一键公开）不阻塞 dealscout。

---

## Part 2 · 开发计划（现有代码基础上，引用 0703 产品/issue）

### 产品定位收敛（yujun 交易模型审 + 用户 2026-07-05 定）
**找为主、撮合为亮点、北极星分期**——地基是 AI 千人千面**发现副驾**（找钱的 founder / 找项目的 investor 都是"找机会的人"，对称），撮合是**涌现的亮点**（不吞掉、但不当地基）。详见 Part 3 待整理进 `product/1`。

### 发现层三条腿（解 yujun"没有发现层"红线）
| 腿 | 机制 | 状态 |
|---|---|---|
| **① 主动找** | dealscout 副驾 AI 千人千面爬取+搜索机会 | **今天能做**（I-1 爬取骨架 + 新增搜索/AI 主动发现，见下） |
| **② 公开面聊天撮合** | 组合 hello 拿公开面 + concierge → 登录用户自助 join+发言供线索、匿名只读、founder 看身份后 invite 深聊 | **今天能做**（riding hello 公开面：`session_feed_channel.ex:197-228,325-330`、`router.ex:13-14`、`conversation_actions.ex:683`）|
| **③ 平台跨用户推荐** | ezagent 关系网层（跨用户实例发现+匹配推荐+朋友圈）| **缺口/discuss-first**（riding registry track；dealscout 首个需求方，不阻塞）|

### 撮合机制换轨（证据版：hello 公开面聊天，非 #1178 申请加入）
0703 文档里的"公开面访客登记 + agent 策展发布"（yujun 说的公开广播问题）→ **换成 hello 公开面聊天**（本 handoff 早期误定为 #1178 申请加入，已按证据版校正，见顶部 ⚠️ 横幅）：DealScout **组合 hello 拿公开面 + concierge 客服 agent**（`hello/router.ex:13-14`：非 owner member 永远路由 concierge、访客到不了 builder；`hello_concierge.ex:43` 回帖）→ **登录用户**在公开面**自助 join + 发消息供线索**（`session_feed_channel.ex:197-228`，post @orchestrator → 非 owner 转 concierge），**匿名只读不能写**（两处硬禁 `session_feed_channel.ex:325-330` + `membership.ex:1200-1208`）→ **founder 本人**同 session 全量白板互见（`external_feed.ex:85-98`）、看发言者身份（`session_feed_channel.ex:353`）→ **owner 主动 invite 对上的人进私有 session 深聊**（`conversation_actions.ex:683` `invite_member`，owner 主动拉、不是申请人申请）→ 私密深聊 → 撮合成功记账。**已整理进** `product/2 J`（公开面聊天故事+双向对称）+ `product/3 V`（公开面聊天视图/身份看板/invite 深聊面）+ `product/4 F`（F-9 登录自助 join+发言）+ `model.md`（撮合机制 = hello 公开面聊天）。

### 分步开发（引用 0703 issue，标今天能做 vs 缺口）
| issue（0703 `tech/issues-plan.md`）| 今天能做? | 依据 file:line |
|---|---|---|
| **I-1 爬取 plugin 骨架** | ✅ | 轮询 GenServer 照 `email/inbound.ex:58`、`:httpc` body_format:binary 照 `miro.ex:141`、dispatch 注入 `router.ex:79` |
| **新增：搜索 + AI 主动发现**（找地基的核心）| ✅ | 复用爬取基建 + recipe（搜索用 cc-headless）；主动发现=副驾按 profile 千人千面匹配推送 |
| **I-2 关键词+token 配置** | ✅ | state slice `kb.ex:80-83` + write_creds `github.ex:32-54` |
| ~~**I-3 DealScoutRender+SessionView+信息流**~~ **作废（返工 banner）：显示归 hello，dealscout 无自有 view/render** | — | 爬取信号 `__dealscout_update__` → Definition routing → hello 页面 agent 更新页 |
| **I-4 3+1 recipe + Definition** | ✅ | roles/0 + materialize `definition_agents.ex:63`；flavor 可 per-agent 声明（#1180 role-slot agent 槽 flavor `definition.ex:282-286`）|
| **I-6 发布公开面** | ✅（+顺带补 republish 一键公开）| visibility_policy web_anon_access + `anon_view_caps` `installation.ex:264` |
| **换 I-10/I-11：公开面聊天撮合**（原访客登记 / 早期误定的 #1178 申请加入）| ✅ riding hello 公开面 | 组合 hello + concierge `router.ex:13-14` / `hello_concierge.ex:43`；登录自助 join+post `session_feed_channel.ex:197-228`；匿名只读 `:325-330`；founder invite 深聊 `conversation_actions.ex:683` |
| **I-5 artifact→upload seam** | ⚠️ 需协调 | agent-facing upload 入口是 core seam |
| **I-7 world tab 接线** | ⚠️ 需协调 | world tab Phase 3 `conversation_actions.ex:369` |
| **发现层第③腿（平台推荐）** | ❌ discuss-first | 关系网层，riding registry track |

### 最小可发布切片（今天能落）
**I-1 爬取骨架 → 搜索/AI 发现 → I-2 配置 → I-3 视图 → I-4 recipe+Definition → I-6 发布公开面 → I-10/I-11 公开面聊天撮合（hello 公开面：登录自助 join+发言 → concierge / founder invite 深聊）**——跑通"千人千面发现（找）+ 公开面聊天撮合（登录进来发言、founder invite 深聊）"的真闭环小网络。I-5/I-7 需协调、第③腿 discuss-first，不卡主干。

---

## Part 3 · 待办（整理进 0703 产品文档）
本 handoff 定的改进模型（找为主+撮合亮点+**撮合腿=hello 公开面聊天**〈证据版校正，非 #1178 申请加入〉+发现三条腿+北极星分期）已回落进 `2026-07-03/yao/dealscout/` 的 P/J/V/F/model/README + 重画 mindmap（52 节点严格单亲、图文一致）。✅ 已完成。

## Part 4 · yujun 复审结论（2026-07-05）：半过 —— 用户模型过关、交易模型未过

用俞军交易模型复审改进后模型，5 红线判定：

| 红线 | 判定 |
|---|---|
| 定位倒置 | ✅ **化解**——发现地基（天天兑现）+ 撮合亮点（涌现），顺序对了；撮合起不来产品也不死 |
| ① 没发现层 | 🟡 **部分**——发现"机会/信息"扎实（①主动找）；发现"对手方"仍靠产品外分享，真平台发现层=第③腿（缺口）。但撮合降级为亮点，红线杀伤力降级 |
| ② 供给身份/spam | ✅ **挡 spam 化解**（公开面匿名只读硬禁 `session_feed_channel.ex:325-330`、非 owner 永远路由 concierge 不触 builder `router.ex:13-14`、founder 看身份后才 invite 深聊 `conversation_actions.ex:683`+AI 预筛）+ 🟡 深度身份不核验（靠深聊渐进披露兜，当前 stake 够用） |
| ③ 需求不敢公开+保密 | ✅ **强化解**（最干净）——撮合全私密、无公开广播、选择性披露，命中损失厌恶 |
| ④ 北极星量非质 | 🟡 **方向化解**（分期+只算通过+不刷申请量），但**指标硬度仍软**："审核通过≠撮合成功"、owner 自报"标记成功"可刷 |
| ⑤ **无利润模型** | ❌ **仍缺，致命**——高边际成本（全网爬取+每用户 cc-headless 千人千面推理）+ 零收入 = **企业这条边永久负净值，会断**。三属性"有利润"不满足，交易模型不可持续 |

**总判**：**用户模型 ✅ 过关**（用户=找机会的人、两类对称、发现/撮合腿清晰、编号严格单亲闭合、保密/定位硬红线化解）；**交易模型 ❌ 未过**（企业边永久负净值，利从何来空白）。一句话：**对用户是好产品，作为生意还不成立**。

**待补清单（优先级序）**：
1. **【红线⑤·最高优先，用户决策】利润模型从零补**——利从何来（撮合抽佣？投资人订阅 deal flow？增值材料？羊毛出在猪身上哪头是猪）+ 高边际成本谁买单（cc-headless 推理）+ 边际结构决定的经营模式（高边际→不能无限免费千人千面，可能分层/限量）。**不补则前面所有红线化解白搭**。
2. **【红线①】第③腿（平台跨用户推荐）是撮合网络长大的唯一开关**——增长叙事要明确"没它撮合网络起不来"，别让"①②今天能做"掩盖"网络效应今天起不来"。
3. **【红线④】撮合北极星换硬质量代理**——用可观测的双方持续互动/双向确认/下游 email thread 动起来，区分"admission 通过数"vs"撮合成功数"，前者别当质量指标。
4. **【发现腿差异化】正面回答"vs 通用 AI 搜索凭什么"**——千人千面+登录源接入偏薄；把护城河做厚（专有源/融资图谱/跨会话记忆）或锁定"完美新用户"。
5. **【红线③残留】** founder 公开页的融资信号成本——考虑"不公开页也能被牵线"（回到第③腿）或页可匿名/只对撮合可见。
6. **【红线②高 stake 预案】** 撮合往真投资走时预留平台级身份/资质核验挂点。

**战略风险（给 Allen）**：重定位修对了顺序，但暴露战略错配——**今天能建的地基（AI 搜索）护城河最薄+还烧钱；有护城河的（撮合网络效应）全推到远期/缺口**。近期=低壁垒+净烧，壁垒=永远的远期。不是红线，但要正视。
