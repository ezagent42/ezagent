# dealscout 改版设计（T3：迁移+改版一个任务）

- 日期：2026-07-10 · 分支 `feat/sw-dealscout-rework`（基底 = main 3eaceeabf + 迁移 commits，取代已关的 #1264）
- 输入：用户拍板目标（2026-07-09）+ 四路调研合成简报（workflow wf_9b878eb7，5 agents 实证，全文见 job 归档）
- 先例：kanban 改版 #1298（Demo 溶解/契约锁反转/e2e 五步法）、hello v2（纯配置角色/匿名页链路）

## 0. 目标（用户原话拍板）

功能不变；**真实使用组合 socialware 的能力**（一切编排 = manifest 纯配置，Decision #155/#156）；**真正展现出页面而不是假数据**；**严格 plugin/socialware/部署/终端用户四条旅程划分**（P6）。

## 1. 现状的假点（调研实证，改版就是消它们）

1. 数据源唯一真源 = HN Algolia 首页（fetch.ex:29），"商业/投融资线索"是假语义
2. Poller 周期抓取抓完即丢（poller.ex:45-52 `{:ok,_}->:ok`），对用户不可见；RetentionSweeper 是显式 no-op stub
3. "AI 发现"从未自主跑通：discover 槽 cc-headless 物化必崩（平台 gap⑥），旧 e2e 靠手改 native + operator erpc 代跑
4. 页面重建三处人工干预：手工 mount ALT 件、LLM 无 key 靠 fake generator seam、渲染整套借 hello Generator
5. 会话零响应（owner 说话没人理，gap⑪）
6. 插件里还住着 socialware 专属代码（`EzagentPluginCrawler.Demo`、`dealscout_page_refresh_alt.ex` 业务命名 L1 件）

## 2. 关键决策（用户休息期间的自主默认——显式记录，可被推翻）

| # | 决策点 | 默认 | 理由 |
|---|---|---|---|
| D1 | discover 槽 flavor | cc-headless → **np recipe × py flavor**（纯配置） | 绕开平台 gap⑥（Allen 级），hello builder/responser 已验证此路线；"AI 发现"语义后续可加 curl-llm 槽，非本次 |
| D2 | 页面路线 | **自造 dealscout 结构化 view**（照 kanban BoardView 模具：plugin 侧 cap-only render ActionSet + SessionView，manifest `views:` 声明，world 零改动 #1199 generic 消费） | 一举消掉 LLM key 依赖/fake generator/手工 mount 三个假点；不等 gap⑬ 裁决 |
| D3 | ALT 临时件 | **删除**（D2 落地后无存在理由） | #155 红线明标的豁免件，回切条件成立 |
| D4 | 数据源 | 机制层保持 generic（directed source + token 车道不动）；配置层**诚实化**：真实无 token 源（HN Show/Ask 等）+ 语义标注改为与数据相符（L2 配置层措辞，不再冒充投融资） | "真"优先于"多"：先让真数据端到端流动；接商业源要选型+token+合规=产品决策，列 follow-up |
| D5 | 会话应答 | manifest `requires: [orchestrator]`（照 hello #1230） | 安装时递归带上，解 gap⑪ 的最小正路 |
| D6 | 交互页面 | **非目标**：committed 静态页 + 登录后操作（#1267 是 OPEN proposal，硬前置未拍） | 降级明说，不做假交互 |
| D7 | world tab | **不做**（dealscout 从无 world tab，不依赖未合的 #1298 注册表） | 页面=socialware view + 匿名公开页，够 |
| D8 | ShippedManifest 单槽 override | 不动共享模块；dealscout 测试侧自带薄 helper | 不为一家改公共 API |
| D9 | 短链 /dealscout/:name | 非目标 | /hello/:name 是 hello 专属，泛化是独立议题 |
| D10 | 平台 gap⑥/⑧/⑬ | **全部绕开不修**（Allen 裁决权），在 return 里列清 | grill 纪律：不在 feature PR 顺手修平台 |

## 3. 分段（每段可验收，逐段 commit/验证，PR 勾选推进）

**段1 纪律收编**（kanban 先例①③照做，机械低风险）
溶解 `EzagentPluginCrawler.Demo`（测试直驱 ShippedManifest，改名 dealscout_manifest_test 等）；`__dealscout_update__` 契约锁反转为 manifest 权威（测试从 parse 后 manifest 读 arg == 代码常量）；manifest 头注 13/13→15/15 对齐。验收：grep 插件侧 socialware 专属模块零命中（ALT 留段4 删）、crawler 套件绿、`mix ezagent.socialware.check` 15 断言绿、arch 两 gate 0/0。

**段2 数据真化**（crawler plugin 层，保持 generic）
数据源配置诚实化（D4）；Poller 抓取结果**注入 session**（发现流对用户可见——现有 dispatch 车道，抓完即丢改为丢进会话/slice）；RetentionSweeper 接线或删（无 durable 批次则删空转 GenServer）。验收：会话里能看到真实源真线索；无空转 GenServer；crawler 零业务语义。
（落地对齐：选了更彻底的 b 路——**删掉 Poller 周期腿本身**，发现流完全 agent 驱动（crawl_now/search/@discover），RetentionSweeper 连同无消费者的 pin_batch 一并删除。）

**段3 角色链路真化**（manifest 层）
discover 槽 → np×py（D1）；`requires: [orchestrator]`（D5）；routing 单信号规则保持。验收：装完 owner 说话有应答；discover 无人工 erpc 走通"触发爬取→emit `__dealscout_update__`→routing 命中 page"。

**段4 页面立起来**（view 层，D2）
plugin 侧新增 dealscout render ActionSet（cap-only）+ SessionView（照 kanban BoardView/KanbanRender 模具），结构化渲染真实线索数据；page 角色重建走 Surface `put_version`/approve 版本树；删 ALT（D3）+ fake generator seam。验收：install 后零操作员干预页面自动立起；匿名访客 `/socialware/external`（页面投影的匿名入口；`/socialware/chat` 是聊天面）看到 approved 真数据页面；world 零改动。
（落地对齐：段5 真浏览器 e2e 对本段代码修了两处——①发布读有界重试（注入 burst 期间 get_slice 5s 超时被 fail-safe 折叠成"没有线索"→ 自动腿静默跳过）；②render_tree 词表 page/section→shadcn（外部 SPA 现行 renderer 不认旧 hello page-builder 集，渲成 Unsupported node）。证据与根因：`docs/e2e/2026-07-10/dealscout-rework/06c-auto-publish-and-fixes.txt`。）

**段5 e2e + 收官**（kanban 段4 同款）
真浏览器全流程新证据集（发布→安装→会话发现流→页面重建→匿名查看，每步截图）；删被取代旧证据；活文档对齐；return + PR body 按 P6 写四分归属。

## 4. 非目标

不修平台 gap⑥/⑧/⑬；不做交互页面（#1267）；不做 world tab；不接需 token 的商业源（follow-up 列表）；不改共享 ShippedManifest API；不动 hello。

## 5. 已知环境事实

cc 真脑凭证每日过期仅提醒（#801/#1288/#1294）——本改版 D1 后 discover 不再依赖 cc；manifest boot scan prod-only（e2e 显式驱动）；uri_query.scan 必须进自测清单（kanban 教训）。
