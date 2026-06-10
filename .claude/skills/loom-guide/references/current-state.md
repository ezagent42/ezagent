# Loom 现状权威综述（2026-06-10，对应 feat/loom @ PR #480 rebase 后）

> 本文件是唯一的"现在是什么样"综述。`docs/loom/` 下的设计文档都是历史切片，
> 有效性见 `doc-timeline.md`。

## 1. 一句话

Loom = **每个 session 一支固定 agent 团队**（编排器 + 2 主题 worker + 1 页面
worker + 1 团队管家）+ **一个 vendored Next.js 前端**，访客对话驱动两件事并行：
聊天侧出 scene-card 回复，页面侧实时生成/增强一张 React 页面，页面可发布 →
分享快照 → fork。

## 2. 组件地图

```
apps/ezagent_plugin_loom/
├── lib/ezagent/
│   ├── behavior/          ← 5 个 Behavior（见 agent-roles.md）
│   ├── entity/            ← 5 个 Kind 声明
│   ├── template/          ← 6 个 Template Class（含 loom_session 团队自动装配）
│   ├── web_plug.ex        ← HTTP 入口，26 条路由（见 web-surface.md，1,298 行最大模块）
│   ├── llm.ex             ← LLM 后端分发（claude_code | deepseek，见 llm-backends.md）
│   ├── claude_code.ex / deepseek.ex  ← 两个同签名 chat/2 壳
│   ├── prompts.ex         ← 全部 system prompt + persona（613 行）
│   ├── team.ex            ← ensure_team/1 幂等装配（B path：无 AgentTemplate 记录）
│   ├── span.ex            ← LLM raw 输出 → <span>{json}</span> scene-card 归一化
│   ├── saved_classes.ex   ← "存为模板"：动态生成 Class 级 Template（session.<name>）
│   ├── snapshots.ex       ← share snapshot（≠ Kind snapshot！）
│   ├── stitch_chat.ex     ← Stitch 辅助聊天存储（preview 页右下角）
│   ├── knowledge.ex       ← per-session Markdown 知识库（Stitch/AiSpot grounding）
│   ├── user_schema.ex     ← per-session 用户增强操作序列（ops）
│   ├── temp_user.ex       ← 浏览器临时用户；另有 loom_signup 轻量自助注册（在 ezagent_web）
│   ├── tool.ex / tool_registry.ex / tools/   ← page-SDK v2 的 tool 机制
│   ├── fetch_proxy.ex     ← AI 页面的白名单 HTTP 代理（fetch preset）
│   ├── feishu.ex          ← 直插 BindingRow 的飞书单向镜像
│   └── bootstrap.ex       ← per-visitor 建 session（早期路径，被 LoomSession 模板取代为主路径）
└── priv/static/loom_ui/   ← vendored Next.js static export（源码 github.com/ezagent42/loom）
```

## 3. 一条消息的全链路（编排侧）

1. 浏览器 SPA（`GET /loom/:ws/:sid` 由 WebPlug serve）`POST /loom/api/:ws/:sid/messages`
2. WebPlug 以临时用户身份 dispatch `chat.send` 进 `session://loom/<ws>/<sid>`
3. **默认 mention-gated 路由**（`system_default` 规则：`{:always} → [$session_users, $mentions]`）
   只投给被 @ 的 agent + User 成员 → worker↔worker 串话在结构上不可能
4. 消息 @ 了 `loomorch_<sid>` → `LoomOrchestrator.handle_receive`：
   - `LLM.chat`（decompose prompt）拆出子任务
   - fan-out：每个子任务 `chat.send` 并 @ 对应 `loomworker_<sid>_<theme>`，带 `ref_id`
   - worker 各自 `LLM.chat` 产出片段，带 `ref_id` 回复
   - orchestrator 收齐（或 dead-worker 超时兜底，上界由 `LLM.max_run_ms/1` 推导）
   - `LLM.chat`（compose prompt）组合成 scene-card：`<span>{json}</span>`
   - `chat.send` 回 session
5. 浏览器 `GET /loom/api/:ws/:sid/stream`（SSE）收到全部 session 消息流，渲染卡片
6. 并行页面侧：消息 @ `loomv0_<sid>` 时，v0worker 用 page-gen prompt 出 **JSX 代码块**，
   前端 Sandpack 渲染；streaming 进度经 `loom:gen_progress:<group>` PubSub → SSE

## 4. 消费侧（preview / 分享 / fork）

- **publish**：`POST /api/:ws/:sid/publish` → 创建不可变 Template Class
  （`session.pub_<hex>`）+ 冻结一份 share snapshot（对话 + user_schema ops + 模板引用）
- **分享**：`POST /api/:ws/:sid/snapshot` 出 16-hex token → 被分享者
  `GET /snapshot/:token` 只读查看（含冻结的 Stitch 对话）
- **fork**：`POST /p/:token/fork` 两阶段（先 open 占位再 fork 实例化），从快照模板
  起一个新 session，复制 user_schema ops 与知识库
- **Stitch**：preview 页右下角辅助聊天，**独立直连 DeepSeek-v4-flash**（不走 LLM
  分发器、不进 session 编排），对话持久化、分享时冻结进快照
- **知识库**：编辑者写一段 Markdown，作为 Stitch/AiSpot 回答的 grounding，
  发布随模板带走、fork 复制

## 5. 演化简史（详注见 doc-timeline.md）

| 期 | 标志 | 留下了什么 |
|---|---|---|
| Hello demo（05-27 PRD） | 单 agent req/resp 反例 → 多 agent 编排 demo 立项 | 编排器+worker 的角色划分、飞书镜像 |
| page-builder spec（05-28） | 41 组件 schema-driven 设计 | **大部分被推翻**（前端实际走 vendored ai-ui-builder + JSX 生成，不是 schema 解释器） |
| 前端集成 + SDK bridge（05-29） | `forward "/loom"` 唯一触碰模式、postMessage 桥 | WebPlug、SDK v1 |
| session-rooted 重设计（06-01） | v0worker、page_update span、mention 解析 | 现行编排形态 |
| team-manager + saved classes（06-03 前后） | loommeta、存为模板、cleanup 传播 | saved_classes、ghost-session 过滤 |
| snapshots/Stitch/self-signup（06-05） | 分享快照、fork 两阶段、Stitch、loom_signup | 消费侧全套 |
| v0 streaming + knowledge（06-09/10） | SSE 生成进度、stdin prompt、知识库、LLM 开关 | `llm.ex`、`knowledge.ex` |
| socialware 迁移定调（06-08） | "rewrite directly, do NOT base on loom branch" | `migration-map.md` |
