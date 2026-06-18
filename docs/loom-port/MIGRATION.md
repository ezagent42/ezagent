# Loom 作为 socialware vertical — 实现说明

> 配套文档:`SOCIALWARE-VERTICAL.md`(设计 spec + 决策)、`STORAGE.md`(产物怎么存)。
>
> 目标:把 Loom 做成 **socialware substrate 上的一个 vertical** —— 跟 advisor / autoservice 一样,站在统一的 socialware substrate 上(统一 Session + 行为子集 + 成员),而不是自带一套独立的 Kind 栈。

---

## 1. Loom 是什么(前端 / 后端各做什么)

Loom 是跑在 ezagent 上的 **AI 建站 + 多智能体编排**产品,由前端 SPA + 后端 plugin 两半组成。

### 前端(Next.js SPA)

> **源码在另一个独立仓库,不在本仓库。本仓库只保存它的编译产物**(Next.js 静态导出),vendored 在 `apps/ezagent_plugin_loom/priv/static/loom_ui`(basePath `/loom`)。**不要直接改 `loom_ui` 下的文件** —— 会被下次构建覆盖。

负责全部界面与交互:建站工作台(对话生成 / 编辑实时 React 页面,Sandpack 沙箱预览)、发布与版本、发布页消费体验(成品页 + 导购 Stitch + AiSpot ✨ + 弹幕 + 角色门控)、运营页(接线员)、团队 modal、素材上传。通过 **SDK bridge**(`platform` 模块)调后端 `/loom/api/*`,自己不碰数据库。

### 后端(Elixir plugin `ezagent_plugin_loom`)

负责编排、LLM、持久化、给前端的 SDK API。**关键:它现在是一个 socialware vertical** —— 一个 loom session 就是统一的 `Ezagent.Entity.Session`(socialware 行为子集),页面落 `Surface`,消费走 `CustomerFeed`;多智能体团队作为这个 session 的**成员 agent**。

## 2. 架构:socialware vertical(实现)

样板是 advisor vertical(`EzagentPluginAdvisor.Template.AdvisorSession`):**全局一个 session Kind,vertical = Template + 行为子集 + working-copy 配置 + 成员**。

```
建 loom session
 └ Ezagent.PluginLoom.Vertical.ensure_session
     ├ Kind.spawn(Entity.Session, behaviors: socialware_behaviors())   # Session+Turn+Surface+Publisher
     ├ system_set_working_copy(vertical 配置)
     └ Team.ensure_team(session)   # 把团队 join 成 session 成员

团队成员 agent(都是这个 SocialwareSession 的成员):
  loomorch_<sid>          编排器:缓存 loom_source + 把页面落进 Surface(驱动 Turn)
  loombuilder_<sid>       builder:LLM 生成 / 改页源码(唯一出页的)
  loomworker_<sid>_<t>    worker:按主题产内容片段
  loommeta_<sid>          meta:@ 自然语言加 / 删 worker(进 WorkerConfig + 团队 modal)
  loomsalesperson_<sid>+subs   消费侧导购 AI(Stitch)
```

**页面在哪**:builder 生成页 → 发 `page_update` 消息(SPA 从这渲染)→ 编排器接住 → 缓存 `loom_source`(供 builder 下次编辑读)+ 经 `TurnManager` 驱动一个 **Turn**(open→compose→settle)把页面落进 **`Surface`**(substrate 真相)→ settlement → **`CustomerFeed`** 投给消费者。

驱动 Turn/Surface 用**生产级 within-session cap**(`cap(:session, :any, :any, {:within_session, S})`,跟 socialware orchestrator 同款),不是 `system://bootstrap`。

## 3. 用户交互(@ 语义)

| 操作 | 行为 |
|---|---|
| **`@builder ...`** | 走出页的路子:builder 生成 / 改页 → Surface → SPA 渲染 |
| **不 @** | 普通在 session 发言,**不出页**(编排器 mention-gated,只在被 @ 时才动) |
| **`@meta 加/删 worker`** | worker 进 `WorkerConfig`(团队 modal 可见)+ spawn & join 成 session 成员 |
| **`@worker_<theme>`** | 直接派给某 worker |
| **发布页 salesperson** | 访客跟导购 AI 聊(DeepSeek 直连) |
| **发布 → 消费** | publish token → 打开 `/loom/p/<token>` → mint 冻结消费 vertical session → 看页 + 跟导购聊 |

## 4. 怎么接进基座

- 作为独立 OTP plugin 实现 `Ezagent.Plugin` 契约(`behaviors / agent_flavors / after_boot / register_session_views`)+ `forward "/loom"` + `/loom-signup`。
- **session 用统一 `Entity.Session`**(domain_session),不再自造 session Kind。
- 消费侧用 **socialware**(`ezagent_domain_socialware`:`CustomerFeed` / `CustomerAuth` / `Surface`/`Turn` 的 settlement 等);loom deps 现在**含 `ezagent_domain_socialware`**。
- **消费读走 substrate**:`/p/:token/open` 下发一张 `CustomerAuth` token;`GET /api/:ws/:sid/customer-feed?token=` 经 `CustomerFeed.snapshot` 读 **committed Surface 的页面 + 客户可见消息**(visibility-gated,错 token → unauthorized)。即消费侧真相从 loom 老存储 cut 到了 substrate。
- 唯一 web 入口 `EzagentPluginLoom.WebPlug`(`/loom`),既发静态产物又提供 `/api/*` SDK 桥。

## 5. 关键设计取舍

- **出页只走 `@builder`**:builder 是团队里唯一出页的成员。不 @ 的消息只是普通在 session 发言,不触发出页 —— 编排器 mention-gated,只在被 @ 时才驱动。
- **页面真相在 Surface**:builder 出的页经一个 Turn 落进 `Surface`(substrate 真相),消费侧经 `CustomerFeed` 读 committed 版本;loom_ui 编辑器另从 `page_update` 消息渲染。一次出页两条通道同时写。
- **创作与消费分离**:创作侧(operator + 团队)写 Surface;消费侧(访客)只读 `CustomerFeed`,不能改源码,只能在冻结 base 上叠 `user_schema` ops。

## 6. 怎么保证 main 功能不丢

loom 是独立 OTP plugin,不改 main 的 core/domain 逻辑(只加少数声明式钩子 + forward + 视图注册)。摘掉 loom plugin,main 回原状。merge main 后 CapBAC north-star 测试全绿。

## 7. 实施 / 验证

分期(P0→P3,见 `SOCIALWARE-VERTICAL.md`)逐个打通并实测:P0 统一 SocialwareSession;P1 TurnManager 驱动 Turn/Surface;P2 CustomerFeed 消费;F1 把 loom_ui 接到 substrate(create-on-access + @builder 出页);团队作为成员 agent 恢复(@builder/@meta/@worker/salesperson)。ExUnit 5 个 vertical 测试 + 运行期对着 port profile(DeepSeek)实测。

全部外围功能也在 vertical 上逐个 runtime 回归过(port profile):

| 功能 | 验证 |
|---|---|
| 编辑版本 / 回退 | 建多版页 → `edit-versions` 列出各版 → `revert` 到旧版页面回退 |
| 多页 | 加页 → `active-page` 切换 → `page-source` 写入 |
| AiSpot ✨ | 真生成卡片(tag `mode=aispot`) |
| 角色门控 | 配角色 → `my-roles` 翻 `configured` → `role-check` 对匿名 `granted:false` |
| 素材库 | 上传(嵌套路径)→ 列表 → serve(字节一致)→ 删除 |
| 导购 salesperson + mode | 真导购回复;`ai↔human` 切换持久 |
| 发布 / 消费 | publish token → 列表 → `/loom/p/<token>` 消费页 |
| snapshot / fork | snapshot token → 浏览页;fork 出带源码的可编辑会话 |
| save-as-template / spawn | 存模板 → spawn 新会话带源码 → 删模板 |
| 接线员 operator | **全链路**:登录 → 两访客 open 发布页 → `operator-sessions` 见同伴 → `operator-send` 消息飘进对方会话 |
| 弹幕 danmaku | 会话人类消息即飘在预览页的弹幕;样式 `danmakuConfig` 由 builder 可选随页发出 |

> 契约点:`fork` 走 snapshot token(`/p/<snapshot_token>/fork` → `Snapshots.get`),不是 publish token;`danmakuConfig` 是 builder 可选块,无块即默认无自定义弹幕样式。

## 8. 边界与后续

- 前端 SPA 源码在另一个仓库,本仓库只保存编译产物(`priv/static/loom_ui`);改界面要回那个仓库构建再同步。消费读端点(`/customer-feed`)已就绪,前端 re-point 到它即可把消费完全跑在 substrate 上。
- 消费侧身份继续走 substrate:把 token 模型从 loom `TempUser` 迁到 `AnonUser`/`AnonBinding`、并把 `CustomerFeed` 注册成 `ExternalAdapter`(§3.3),是接下来的归一项;带 publish token 的消费读已可用。
- 默认建站让 workers 自动参与(编排器协作流)是一个可选方向;当前刻意保持「不 @ = 纯发言、出页只走 @builder」。
