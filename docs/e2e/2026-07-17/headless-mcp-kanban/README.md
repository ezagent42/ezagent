# 任务 A e2e：cc-headless kanban-assistant 真 UI 加节点

> Handoff: `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §3 DoD-1
> Branch: `fix/1323-headless-mcp-to-main` · Date: 2026-07-17

## 栈（独立，不碰共享 dev/prod）

- 本机（WSL2）无 docker、远端 disposable(10044) 不可达 → 本地独立栈：
  - `PORT=10053`、独立 DB `ezagent_taska_e2e`、独立 `EZAGENT_HOME=/tmp/ezagent-taska-home`
  - `EZAGENT_SIGNING_SEED_V1` + `EZAGENT_PAT_PEPPER_V1`（throwaway，per-run）
  - 分布式节点 `--name ezagent_runtime@127.0.0.1` + `$EZAGENT_HOME/default/runtime/cookie`
    （kanban-cli.sh 的 dist dispatch 需要）
- world SPA：`pnpm install && pnpm build`（fresh worktree 无 node_modules；dev vite
  watcher 起不来时 SPA 卡 "Loading world"）

## 环境适配（记录，非产品修改）

1. **dev 环境 manifest 晚扫描关着**：`config/config.exs:29`
   `socialware_manifest_boot_scan: config_env() in [:prod]` → 本地 dev 起服后
   `socialware:kanban` 不进目录。用正规 lane 单发跑一次：
   `mix run --no-start -e 'Application.put_env(...boot_scan, true); ...ensure_all_started(:ezagent_web); ManifestSeed.scan_all!()'`
2. **seed 版 `kanban-cli.sh` 硬编码部署机路径**（`/home/yaosh/.ezagent/.../cookie` + `mise exec`）：
   在 agent config_dir 的本地副本改为 `$EZAGENT_HOME` 派生 + 直接 `elixir`
   （SocialwareSeed/SkillSeed 语义本就"respect operator edits"；仓库文件未动 ——
   **kanban lane 债，报给 jjkysy**）。

## 实施期 live 发现并修复

- **sidecar cwd crash-loop**（commit `b088c79de`）：headless 从不调 McpConfigWriter
  （PTY 的 cwd 是它写 cwd 级 .mcp.json 的副作用），fresh host 上
  `Cannot chdir to '~/.ezagent/<role>'` 无限重启。sidecar 现在自己 `mkdir_p` cwd。

## 步骤截图

| # | 文件 | 内容 |
|---|---|---|
| 1 | 01-admin-login.png | admin 登录 |
| 2 | 02-first-session-created.png | 首会话向导 |
| 3 | 03-world-sessions.png | world 会话列表 |
| 4 | 04-kanban-install-wizard.png | kanban socialware 安装向导（两个 cc-headless role slot） |
| 5 | 05-kanban-session-open.png | taska-kanban 会话（3 成员：admin + assistant + dev-together） |
| 6 | 06-board-before.png | 看板 tab（未建板） |
| 7 | 07-board-created.png | `taska-board` 运行时建板（BoardProvision lane） |
| 8 | 08-mention-sent.png | @kanban-assistant 给板加个节点：登录表单 |
| 9 | 09-*.png | （待补）assistant 回复 + 板上见节点 |

## 链路活体证据（read-only /proc 取证）

kanban-assistant 的 SDK worker 进程 env（token 已脱敏）：

```
EZAGENT_CC_SDK_CONFIG_DIR=/tmp/ezagent-taska-home/default/cc-headless-agents/system/eadddd8c-…
EZAGENT_CC_SDK_ENV={"EZAGENT_USER_TOKEN":"<redacted>"}          ← Slice 2 CLI 身份线
EZAGENT_CC_SDK_PLUGINS=[{"path":"…/eadddd8c-…","type":"local"}] ← #1434 skill 包
```

config home：`.credentials.json`（#1309 host-login adopt ✓）+ `skills/kanban-assistant` +
`.claude-plugin/plugin.json`；**无 `.mcp.json`**（headless 不物化 esr-bridge —— 见 return
的 open decision：`Channel.verify_transport_class` 拒 `:in_process_sync` 的 WS join）。
