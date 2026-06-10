# Loom Web 面 — WebPlug 路由全表 + 插件外触碰面

## 接入原则

**plugin → ezagent_web 的唯一合法触碰**是 router.ex 的一行顶层 forward：

```elixir
forward "/loom", EzagentPluginLoom.WebPlug
```

顶层 forward 绕过 `:browser` 管线（无 CSRF），必须排在末尾兜底 `get "/*path"`
之前。所有页面 + API 逻辑都在 `web_plug.ex`（1,298 行）。
唯一例外：`POST /loom-signup`（轻量自助注册）在 `ezagent_web` 的
SessionController —— 因为它要写 Phoenix session（`SessionPrincipal.put`）。

## 路由表（按功能分组，前缀均为 `/loom`）

### 聊天 / 编排
| 路由 | 作用 |
|---|---|
| `POST /api/:ws/:sid/messages` | 访客入站 → dispatch chat.send 进 session |
| `GET  /api/:ws/:sid/history` | 拉历史消息 |
| `GET  /api/:ws/:sid/stream` | **SSE**：session 消息流 + `loom:gen_progress:*` 生成进度 |
| `POST /api/:ws/:sid/stop` | 中断当前生成（`LLM.stop/1`，CC 杀子进程 / DeepSeek no-op） |

### 模板 / 发布
| 路由 | 作用 |
|---|---|
| `POST /api/:ws/:sid/save-as-template` | 存为模板（动态 Class，`session.<name>`） |
| `GET  /api/:ws/templates` | 列已存模板 |
| `POST /api/:ws/templates/:name/spawn` | 从模板起新 session |
| `GET  /api/:ws/published` | 列已发布页 |
| `POST /api/:ws/:sid/publish` | 发布：不可变 Class（`session.pub_<hex>`）+ share snapshot |

### 页面数据 / 助手
| 路由 | 作用 |
|---|---|
| `GET/POST /api/:ws/:sid/user-schema` | 用户增强操作序列（ops） |
| `GET/POST /api/:ws/:sid/stitch` | Stitch 辅助聊天（独立直连 DeepSeek，见 llm-backends.md） |
| `POST /api/:ws/:sid/aispot` | AiSpot 划词追问（同上直连） |
| `GET/POST /api/:ws/:sid/knowledge` | per-session Markdown 知识库 |

### 分享 / fork（两阶段）
| 路由 | 作用 |
|---|---|
| `POST /api/:ws/:sid/snapshot` | 冻结 share snapshot，出 16-hex token |
| `GET  /snapshot/:token` | 被分享者只读查看 |
| `POST /p/:token/open` | fork 第一阶段（占位） |
| `POST /p/:token/fork` | fork 第二阶段（从快照模板实例化新 session） |
| `GET  /whoami` | 当前临时用户身份 |

### page-SDK v2（页面沙箱 → 服务端能力）
| 路由 | 作用 |
|---|---|
| `POST /api/:ws/:sid/upload` | 上传文件，回 resource URI |
| `GET  /api/:ws/:sid/resource?uri=` | 取回资源 |
| `POST /api/:ws/:sid/fetch` | 白名单 HTTP 代理（fetch preset，`fetch_proxy.ex`） |
| `POST /api/:ws/:sid/tool` | 调注册的服务端 tool（`tool_registry.ex`） |

### 兜底
| 路由 | 作用 |
|---|---|
| `GET /*_path` | SPA fallback → vendored Next.js 静态产物 |

## 插件外触碰面（PR #480 全部 11 个非 loom 文件）

| 文件 | 改了什么 |
|---|---|
| `ezagent_web/router.ex` | `forward "/loom"` + `POST /loom-signup` |
| `ezagent_web/controllers/session_controller.ex` | `loom_signup`（**故意跳过邮箱验证**的开放注册，Allen 批准的内部测试取舍） |
| `ezagent_web/mix.exs` | `{:ezagent_plugin_loom, in_umbrella: true}`（all_plugin_apps_wired_to_web 不变式） |
| `ezagent_plugin_liveview/admin/session_editor.ex` | header 加 "Open Loom" 链接（仅 `session://loom/...` 显示） |
| `ezagent_plugin_liveview/admin_live.ex` | ghost-session 过滤（`list_visible_sessions_for`）+ 切回 Chat 时 restream |
| `ezagent_plugin_liveview/workspace_detail_live.ex` | 模板名新标签打开 + saved-class 删除按钮 + 删除 trigger_instantiate |
| `config/config.exs` | `:ezagent_plugin_loom` 的 `tools:` + `fetch_presets:` |
| `config/runtime.exs` | dev/test 加载仓库根 `.env`（已有真实环境变量优先） |
| `ezagent_core/lib/ezagent/runtime.ex` | `EZAGENT_NO_DISTRIBUTION=1` 跳过分布式启动（WSL dev 提速，CLI RPC 失效） |
| `.gitignore` / `.env.example` | `.env` 不进仓库 + 模板 |
