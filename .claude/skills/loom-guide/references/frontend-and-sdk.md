# Loom 前端 + page-SDK

## 前端源码与 vendored dist

- **源码仓库**：<https://github.com/ezagent42/loom>（ai-ui-builder，Next.js）
- **运行产物**：`apps/ezagent_plugin_loom/priv/static/loom_ui/`
  —— Next.js **static export**，整目录 vendor 进本仓库，由 WebPlug 的
  SPA fallback（`GET /loom/*_path`）serve。
- **vendor 流程**（`docs/loom/FRONTEND_DIST_PLAN.md` Phase 6 固化）：
  前端仓库 `npm run build` → 把 `dist/*`（Next export 产物）整体拷进
  `priv/static/loom_ui/` → 提交（commit 习惯：`chore(loom/ui): rebuild static export (...)`)。
- **改前端 ≠ 改 plugin**：页面行为问题先确认是前端产物还是 WebPlug API；
  vendored 产物是构建结果，**不要手改** `loom_ui/` 里的 JS。
- 页面内 AI 生成的 JSX 由 **Sandpack** 沙箱渲染（生成代码不进 vendored 产物）。

## SDK 形状

权威文档：`docs/loom/SDK.md`（v1 形状）+ `docs/loom/sdk-v2-additions.md`（v2 增量，
含端到端 curl 验证步骤）。桥接设计：`docs/loom/2026-05-29-loom-sdk-bridge.md`。

- **v1**：会话/消息基础能力（sendMessage / history / stream 订阅），sandbox ↔ host
  经 **postMessage** 帧、host（LoomBridge）↔ 服务端经 WebPlug API。
- **v2 增量**（4 个能力，对应 web-surface.md 的 SDK 路由组）：

| SDK 方法 | 服务端 | 说明 |
|---|---|---|
| `uploadFile(file)` | `POST /upload` | 回 resource URI |
| `openResource(uri)` | `GET /resource?uri=` | 取回资源 |
| `fetch(preset, url, opts)` | `POST /fetch` | 白名单代理；preset 在 `config :ezagent_plugin_loom, :fetch_presets`（URL 正则 + 方法 + body/timeout 上限 + 服务端注入 header，secrets 用 `{:env, "VAR"}`） |
| `tool(name, args)` | `POST /tool` | 服务端 tool；boot 时 `ToolRegistry.register_all/0` 注册 `config :ezagent_plugin_loom, :tools` 列表 |

## 加一个新 tool / fetch preset

1. **tool**：写一个实现 `EzagentPluginLoom.Tool` 契约的模块（参照
   `tools/echo.ex` / `tools/now.ex`）→ 加进 `config :ezagent_plugin_loom, :tools`
   → 重启。验证：`POST /loom/api/:ws/:sid/tool`。
2. **fetch preset**：在 `config :ezagent_plugin_loom, :fetch_presets` 加一个 entry
   （`url:` 正则必须收紧到具体域名）→ 重启。

具体步骤和 curl 验证序列照 `sdk-v2-additions.md` 末两节，那里是权威。

## 迁移指向

前端 SPA **重建不直接搬**（P4：React + json-render，扔 SSE 改 gated feed）；
SDK 的 fetch_proxy / tool 机制 📦 移植到 P4 page-runtime。红线：新前端
**不得复用 `/stream` 的 SSE-from-Publisher**（routing-blind，泄漏
`:operator_only`）。详见 `migration-map.md`。
