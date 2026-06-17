# ezagent_plugin_loom

Loom socialware vertical — **多 agent 编排 + AI page-builder**。访客对话驱动：编排器拆解意图、
并发派给主题 worker、聚合出 scene-card，同时实时生成一张页面；页面经 operator 审核后 customer
可见；可发布 / fork；发布页自带 Stitch 辅助 AI、AiSpot 卡片、意图推荐。

绿地新建于 socialware 基座，**零改 ezagent/socialware 逻辑**（迁移分析见 `docs/loom/2026-06-16-*`，
预留接入清单见 `docs/loom/2026-06-17-loom-vertical-pending-integration.md`）。

## 架构

- **运行时 session** = domain-owned 统一 `Ezagent.Entity.Session` Kind + socialware `:kind_base`
  subset（`socialware_behaviors/0` = {Session, Turn, Surface, Publisher}）。loom 不自建 Kind。
- **编排** = `OrchestratorServer`（per-session GenServer，订阅 `esr:session:<uri>:events`）：
  customer 消息 → `decompose → 并发 themed worker → compose`（真实 LLM）→ dispatch
  `turn.open/compose/settle` → operator gate → customer feed。务实版（编排逻辑内并发 LLM）；
  真实 agent Kind fan-out 待架构决策（见预留清单项 3）。
- **LLM** = `EzagentPluginLoom.LLM`，flavor 开关：`curl`（默认，HTTP anthropic 端点，便宜）/
  `cc`（本地 claude 二进制，跟随登录态）。`ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` 或本地 claude。
- **transport** = `EzagentPluginLoom.WebPlug`（`forward "/loom"`），customer 经 HTTP 交互。

## HTTP 端点（`/loom` 前缀）

| 方法 路径 | 功能 |
|---|---|
| POST `/c/:ws/:sid/messages` | customer 发消息（→ 自动编排） |
| GET `/c/:ws/:sid/feed` | 读 visibility-gated feed（messages + page + user_schema_ops） |
| POST/GET `/c/:ws/:sid/stitch` `/aispot` | preview 辅助 AI（stitch 支持 `mode=deep` 4-role fan-out）/ ✨ 卡片 |
| POST `/intent` | session-less 意图推荐选品 |
| POST/GET `/c/:ws/:sid/materials*` ·GET `/m/:dtoken` | 素材上传/列表/受控服务 |
| POST/GET `/c/:ws/:sid/knowledge` | 知识库（grounding） |
| POST/GET `/c/:ws/:sid/team` | meta agent 改 worker roster / 查看 |
| POST `/c/:ws/:sid/user-schema` | per-visitor 页面增强 op |
| POST `/c/:ws/:sid/tool` `/fetch` | page-SDK 白名单工具 RPC / fetch 代理 |
| POST `/c/:ws/:sid/fork` | 从发布物 fork 新 session |
| GET `/c/:ws/:sid/dashboard` | operator 运营摘要数据 |
| GET `/app/:ws/:sid` ·`/dashboard/:ws/:sid` | customer SPA 壳 / operator Dashboard UI 壳 |

## Quickstart

```elixir
# 1. 建 loom session（自动起编排进程）
{:ok, [session_uri], _} = EzagentPluginLoom.Template.LoomSession.instantiate(
  "loom-demo",
  %{"class" => "session.loom", "session_name" => "demo",
    "operator_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())},
  Ezagent.URI.workspace("myws"))

# 2. 签 customer token，浏览器开 /loom/app/myws/demo?token=<token>
token = Ezagent.Socialware.CustomerAuth.issue_token(session_uri, Ezagent.URI.workspace("myws"))
```
customer 在 SPA 发消息 → 编排器（需 `ANTHROPIC_*` env 或本地 claude）→ operator 审批后页面可见。

## Testing

```bash
mix test apps/ezagent_plugin_loom/test                 # 单元/集成（默认排除 :live）
ANTHROPIC_BASE_URL=… ANTHROPIC_API_KEY=… \
  mix test --include live apps/ezagent_plugin_loom/test # 含真实 LLM 的 live 测试
```

## 功能状态

✅ 完整 + 验证：脚手架、SW-USE/DEV/UPD E2E、多 agent 编排、customer 入站闭环、素材库、知识库、
Stitch（含 4 sub-worker）、AiSpot、intent、fork、user_schema、meta agent、telemetry、Dashboard、
page-SDK tool/fetch、前端 SPA（customer + operator，**已真实浏览器交互 E2E 验证**：发消息→真实 LLM
编排→页面渲染，`mix loom.serve` + agent-browser）。

🔶 预留（待外部资源 / 架构决策，见 `docs/loom/2026-06-17-loom-vertical-pending-integration.md`）：
飞书真实投递（凭证 + main facade）、真实 agent Kind 化（Allen 架构决策）、cc-flavor PTY 常驻
（依赖前者、价值低）。
