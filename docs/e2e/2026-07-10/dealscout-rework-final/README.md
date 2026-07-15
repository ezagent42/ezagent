# dealscout rework 终版收口 e2e — 全链路真浏览器证据（2026-07-10）

**取代** `docs/e2e/2026-07-10/dealscout-rework/`（同日早前 22 件，拍于 #1294/#1311
合入 main **之前**：含"create 5s 超时红条如实标注"与"orchestrator 未验真脑"两处
旧现实）。本套以 rebase 后分支（= main e3677b7ff 基底，含 **#1294 create_session
修复 + #1311 cc-headless 凭证继承修复**）为准、一次连贯跑完（server beam PID
98943 全程同栈，收尾精确 kill）。

```
发布(deploy-seed 车道) → 安装(向导×DealScout，requires 递归带 Orchestrator，无红条建成)
      → orchestrator 真脑重测(#1311 后新现实：@ 一下真回话 ✓)
      → @discover 真键盘 mention → py sandbox 真爬 HN → 回复自带 __dealscout_update__
      → routing rule 2 真命中(routing_traces)
      → crawl_now/search 真 dispatch → 线索入会话 + :crawler slice
      → 「线索」view(registry tab + internal render 真数据)
      → 自动发布腿(crawl 后零干预 committed settlement) → 匿名零 cookie 公开页 → 自动重建
```

## 流程与证据索引

| # | 步骤 | 证据 | 结论 |
|---|---|---|---|
| 00 | 环境：步骤0 重验（crawler 93/93 绿 + 两 scan exit 0）+ ecto.reset + seeds + world_e2e_seed → phx.server（beam PID 98943）→ `_health` 200 | `00-env-and-health.txt` | ✓ |
| 01 | world 登录（admin@ezagent.chat / $ADMIN_PW，见 docs/guide/world-e2e-seed.md） | `01a` `01b` | ✓ |
| 02 | **发布**：deploy-seed 拷贝（manifest byte-identical 实测）+ erpc 在 server 节点跑 `ManifestSeed.scan_dir!` → `result: :published`；DB pointer `socialware:dealscout` | `02-publish-deploy-lane.txt` `dealscout_publish_e2e.exs` | ✓ |
| 03 | **安装**：向导「应用」选 *DealScout*（manifest 描述原文 + discover/page 两 role 槽可见）→ 创建 `session://system/socialware-install-dealscout/dealscout-final-0710`：**无红条建成**（DB duration_us=4420953 ≈4.42s < 5s 预算，#1294 后现实）；**4 成员全绿在线**（discover/page/**orchestrator——requires 递归安装实证** + Admin）；已装 Socialware=2；rule 2 装入与 YAML 逐字一致 | `03a`-`03c` 截图 + `03d-install-db-notes.txt` | ✓ |
| 04 | **orchestrator 真脑重测（gap⑪ 复测，#1311 后）**：① 普通话不 @ → 60s+ 无回话（routing_traces `no_match`，rule 1 receivers 语义，非故障——如实拍）；② 真键盘 @orchestrator → **~65s 真回话**，内容准确复述 dealscout 角色分工/信号语义/路由硬锁（legend protocol 喂进上下文生效） | `04a`-`04d` 截图 + `04e-orchestrator-brain-notes.txt` | **✓ 真脑通** |
| 05 | **@discover 真触发**：真键盘 autocomplete → **3s** py sandbox 真爬 HN Algolia 回 5 条当日真实线索 + `__dealscout_update__` 信号 | `05a` `05b` 截图 | ✓ |
| 06 | **routing + crawl 数据面**：带信号回复命中 rule 2 → page（routing_traces id=6）；admin `crawler.crawl_now`/`crawler.search` 真 dispatch（CapBAC token 身份）各注入 20 条真线索入会话 + `:crawler` slice（erpc 探针 20→40 条留存） | `06a` 截图 + `06b-crawl-dispatch-slice-routing.txt` `dealscout_dispatch.exs` | ✓（#1201 ② 注记见 06b ③） |
| 07 | **「线索」view**：view-switcher 出现「线索」tab（`SessionViewRegistry` 声明→world 通用消费）；点击 dispatch ok、tab 高亮，主区未切换渲染（Conversation.tsx 无非 chat 渲染腿——kanban 同一既有缺口）→ internal render 可达路径：erpc `LeadsView.render/1`（HEEx→HTML 17KB）渲出 20 条真实线索卡片 | `07a` `07b`（.html 为 erpc 渲染原件，Tailwind CDN 仅截图包壳） | ⚠️ PASS-with-gaps（tab/switch/数据真；渲染腿是既有缺口） |
| 08 | **公开页**：crawl_now 后 ~17s 自动落 committed settlement（零干预）→ **匿名零 cookie**（`document.cookie.length==0` 实测）`/socialware/external` 看到 20 条真数据表格页 → search 再爬一轮自动重建 → 新匿名 context 刷出 40 条 | `08a` `08b` 截图 + `08c-auto-publish-notes.txt` | ✓ |

## 结论（分层口径，照 kanban-rework-final 拍板样板）

| 层 | 结论 | 测法注明 |
|---|---|---|
| 发布（deploy-seed 车道） | ✓ 真通 | erpc 驱动 server 节点内同一晚扫描车道（dev 关 boot scan 为设计） |
| 安装（向导 + requires 递归） | ✓ 真通，无红条 | 真浏览器向导；#1294 后 4.42s 同步建成，DB duration 佐证 |
| orchestrator 真脑 | **✓ 真通（本套新增结论）** | 真键盘 @，cc flavor 冷启 ~65s 回话；不 @ 无人应答 = rule 1 receivers 语义（如实拍） |
| 发现流（@discover → py 真爬） | ✓ 真通 | 真键盘 mention；sandbox 真连 HN Algolia 公网 |
| routing（rule 2 内容+角色硬锁） | ✓ 真命中 | routing_traces DB 审计 |
| routing → native page 投递 | ✗ 平台缺口 #1201 ②（不修，如实） | AgentBridge deliver dropped 原文在 06b；生产腿 = 直呼 |
| crawl 数据面（dispatch/slice） | ✓ 真通 | CapBAC token 身份 :call dispatch；erpc slice 探针 |
| 「线索」view | ⚠️ 数据/注册/切换真，主区渲染腿缺 | 既有缺口（Conversation.tsx 无非 chat mode 腿），internal render 实证数据面 |
| 页面自动发布腿 | ✓ 真通，零干预 | settlements 时间线（05:45:12 注入 → 05:45:29 committed） |
| 匿名公开页 + 自动重建 | ✓ 真通 | 零 cookie 新 context 两轮实测 20→40 条 |

## 与上一套证据的两处关键差异（本套存在的意义）

1. **create_session 无红条**：旧套如实标注"5s 超时红条 + 后台建成"（#1279 同类）；
   #1294 合入后本套 4.42s 同步建成、UI 零红条——旧 Blocker 1 已消除。
2. **orchestrator 真脑通了**：旧套只验到 requires 递归装出 orchestrator 成员；
   #1311 合入后本套第一次实证 @orchestrator 真回话（gap⑪ @ 路径闭环）。

## 环境注记（均非本分支回归、不在本 PR 修）

1. **不 @ 的普通话无人应答**：rule 1 `always → {$session_users,$mentions}` 对
   sender 不回投 + 无其他 human → receivers 空 → no_match。产品路由策略候选
   议题，非缺陷（04e ①）。
2. **会话内子视图切换主区不渲染**（07 步）：kanban rework README Blocker 同源，
   候选 issue。
3. **会话右栏「高级规则 0」是预期显示**：rule_set 规则不在 per-session matcher
   列表（03d）。
4. **routing → native 成员投递**：#1201 ②（06b ③ 原文）。
5. **dev 下 world 页面偶发 "Loading world" 卡屏/整页重载循环**：本次 kanban 段
   撞到（dealscout 段未撞）——回列表页再点行可绕开；重启 agent-browser 不一定
   即愈（与 07-09 记的"重启即愈"先例不完全一致，环境噪声待观察，不阻塞证据）。

## 零人工中继层（09x 系列，2026-07-10 追加）

用户拍板判据：**@discover 之后不再需要任何人工动作，页面就更新**（"搜集证据然后
发布 page 是 dealscout 的功能，不能转向人工去 @"）。逐轮真浏览器验证（每轮一处
修正，根因表全量在 `09m-zero-relay-roundtable-notes.txt`）：

| # | 步骤 | 证据 | 结论 |
|---|---|---|---|
| 09a-09d | 路由修正 v1（信号→orchestrator + 渲染指令）：装成、@discover 3s 真爬、信号+`查询词:` 行、routing_traces 命中 | 09a-09d 截图 | ✓ 送达层真通 |
| 09e/09g/09h | **orchestrator 三轮原则性拒绝**（r1 注入形态 / r2 拒裸 cookie 机制并点名要正规工具面 / r3 官方 CLI 就绪后仍拒"消息自证授权"）——姿态正确且一致：**消息载权是死路** | 09e 截图 + 09g/09h 原文 | ✗（安全姿态正确）→ 按裁决切专属操作员 |
| 09f | discover 查询词修正后线索全对题（"agent framework"→Mastra/Jido/Swarm/Nous） | 09f 截图 | ✓ |
| 09i/09j | case-2：dealscout-assistant 槽（cc-headless×persona duty）装成 5 成员 | 09i/09j 截图 | ✓ |
| 09k | persona 注入两条死路实证（recipe prompt 不落地 / skill 落盘不加载）→ 找到正道 `config.system_prompt`（cc 插件 producer 死键补全） | 09k 原文 | ✓ 根因收敛 |
| 09o/09p/09q/09n | **最终轮（最远达成点）**：信号自动路由给 assistant → persona duty 主动接受（"per my standing ingest role"）→ REPO_ROOT 定位 → 官方 CLI `mix ezagent session search` 以自身份跑 → **token 验真通过** → CLI 的 `identity.list_caps` 自呼 5s 超时（它自己的 Kind 正被本回合 receive :call 占用）→ 如实报告 injected: 0 | 09o/09p/09q 截图 + 09n 原文 | ⚠️ **部分达成**：授权链+执行意愿+工具面全通，断在平台 CLI 的 busy-Kind reentrancy |

### 分层口径（零人工中继）

| 层 | 结论 | 归属 |
|---|---|---|
| 信号路由（discover→assistant，from_role 硬锁防回环） | ✓ 真通（routing_traces） | 本 PR |
| 可信 duty 注入（recipe config.system_prompt → SDK system prompt） | ✓ 真通（三轮"standing duty"主动执行） | 本 PR（含 cc 插件 3 处死键/编码补全） |
| 官方 CLI 工具面（mix ezagent session crawl_now/search） | ✓ 语法+身份 env+token 验真全通 | 本 PR（behaviors/0 注册，email 先例） |
| CLI caller-caps 解析（identity.list_caps 自呼） | ✗ busy-Kind 超时——cc agent 回合中自用 CLI 必撞 | **平台缺口，待 Allen**（09m §根因归属 2） |
| CapBAC 裁决（role-slot caps 自 scope vs session 宿主动作） | 未触达（上一层挡住）；读码判定大概率 unauthorized | **平台缺口，待 Allen**（09m §根因归属 3） |
| 数据入 slice → 匿名页自动重建 | 本层未被零人工链触达；admin 直呼腿已在 06/08 步实证 ✓ | — |

**照 kanban 先例的口径**：kanban 当时"送达真、脑死于登录"也照实写，#1311 修了
才补闭环——本层同样如实：**授权与执行意愿已实证打通（这是本次要证的产品争议
点：不是"必须人工 @"，而是操作员形态+两个平台 wiring 缺口）**，剩余阻塞是
平台级 reentrancy/caps-scope 决策，不在 socialware 配置层硬凑。

## 复现要点

按 `docs/guide/world-e2e-seed.md`（PG → reset/seed → seed-then-start）；发布照
`02` + `dealscout_publish_e2e.exs`；dispatch 照 `dealscout_dispatch.exs`（token
自铸不入库）；runtime cookie 一律读 `$EZAGENT_HOME/default/runtime/cookie`；
浏览器坑（React 受控 input 用 native setter、mention 必须真键盘 autocomplete +
listbox 真实 click、`world.localhost`）见 `docs/e2e/guide.md` §8.2。
