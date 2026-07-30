# hello session + 页面重建指南

> 任何人在全新 DB / 全新部署上重建 hello session 和 v2 网站页面。

## 全新数据库一键重建 Fusion 官网

同事不需要、也不应该拿到原作者的数据库。完成迁移后，在自己的数据库上运行：

```bash
mix ezagent.demo.seed_hello_fusion
```

命令会通过正式 Ezagent API 幂等创建/修复：

- `workspace://system`
- `session://system/hello/fusion`
- `priv/seed_page/body.json` 中的完整 Page
- `priv/seed_page/shell.css` 中的完整样式

然后正常启动服务：

```bash
PORT=10042 mix phx.server
```

访问：

```text
http://localhost:10042/hello/fusion
```

`mix ezagent.demo.seed_hello` 是通用的基础示例种子，写入 `Spec.seed()`，不能用于重建完整
Fusion 官网。完整官网必须使用 `mix ezagent.demo.seed_hello_fusion`。

## 启动时自动重建

```bash
cd /home/ning/ezagent
PORT=10042 HELLO_LLM_BACKEND=claude_code HELLO_DEMO_SEED=1 HELLO_DEMO_WS=system HELLO_DEMO_NAME=fusion mix phx.server
```

启动后 session `session://system/hello/fusion` 自动创建，完整 Fusion 页面(body + shell CSS)自动写入。

## 公开访问

浏览器直接打开(不需要登录):

```
http://localhost:10042/hello/fusion
```

或完整路径:

```
/socialware/chat?session_uri=session://system/hello/fusion
```

## Admin 登录

- 地址: `http://world.localhost:10042/login`
- 账户: 启动日志里搜 `One-time value:` 获取随机密码
- 或在 `.env` 设 `EZAGENT_ADMIN_PASSWORD=你的密码` 固定密码

登录后在 `/sessions` 找到 `hello/main`，输入框告诉 builder 要什么页面。

## 页面数据来源

v2 页面(body + shell CSS)来自 `apps/ezagent_plugin_hello/priv/seed_page/`:

| 文件 | 内容 | 大小 |
|---|---|---|
| `body.json` | 页面 JSON 树(`@json-render` spec) | 19KB |
| `shell.css` | 页面样式(品牌色、排版、组件) | 14KB |

启动时 `seed_page/1` 函数读取这两个文件，通过 `TurnDriver.drive` + `TurnDriver.set_shell` 写进 session 的 Surface。整个过程在 server BEAM 内完成(Surface 状态正确持久化)。

**页面主题:** Ezagent 开源项目官网("组织的 IDE / Organization IDE")，含 nav、hero、产品介绍、团队、世界赛进度等区块。

## Session 结构(2 个声明式 agent + owner)

| role_name | flavor | 职责 |
|---|---|---|
| `front-desk` | hello | chat 路由总机——收消息→判 owner+意图→向 Session dispatch `:rebuild` / `:answer` / `:share` / `:publish` / `:delegate_to_kanban` |
| `llm` | curl | LLM 后端——持有 key(credential cascade)，供 Hello 的生成与问答动作做 HTTP 补全。**credential-optional**——没配 DeepSeek 也能 keyless spawn。本地 dev 用 `claude_code`，休眠 |

session owner 是 `entity://system/user/admin`。匿名访客被自动 mint 只读 AnonUser(48h GC)。

页面生成、只读问答、分享链接、发布模板和 Kanban 委派都是 Session Action；它们没有独立的 agent、recipe 或成员边，因此创建 Hello 不会再为这些职责物化额外 agent。

## 本地 dev 注意事项

- **`HELLO_NO_ORCHESTRATOR=0`**(默认)——本地 dev 跳过 platform cc orchestrator。本地没 Claude Code 二进制，orchestrator 会 activate 超时
- 部署到有 cc 的环境时，设 `HELLO_NO_ORCHESTRATOR=0` 或在 Definition 里加 `requires:["orchestrator"]`
- `config/config.exs` 的 `hello_workspace` 设为你创建 session 的 workspace(本地默认 `"system"`)
