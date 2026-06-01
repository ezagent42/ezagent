# 接手文档:cc-agent 桥 JOIN 老大难 + 真实 e2e 测试(新 PR)

> 2026-06-01。**这是给一个全新 session 的起点**,目标:在 `ezagent` 仓库
> 新开一个 PR,彻底修掉"cc agent 连不上 esr-bridge / 永不 JOIN"的问题,
> 并把项目里**假的 / 会 skip 的桥 e2e 测试改成真实测试**。修好后,回到原
> session(poc/phase-2-customer-service / PR #446)录 demo 视频。

## 一句话问题
在这台工作机(Apple Silicon, macOS 26.5, **claude 2.1.92**)上,**所有 cc
agent 都连不上 esr-bridge**(服务器日志始终 `0 JOINED agent_bridge`),所以
web 客服页永远停在 "connecting…"。

## 范围(已确证,别再重复推导)
1. **不是某个 plugin 引入的** —— 连 `cc_cs_main`(setup.exs 建)、cc_pool
   warmup agent(`cc_fresh/v2/v3/wait`)这些**非 customer-chat 代码**的 agent
   也一个都不 JOIN。是机器/环境级。
2. **断点在"claude → 启 esr-bridge MCP → 连 WS → JOIN"这条链**,而且比启动
   对话框更上游:服务器端**只有浏览器的 `CONNECTED TO Phoenix.LiveView.Socket`,
   从来没有 `CONNECTED TO Ezagent.AgentBridge.Socket`**。也就是说 claude 清完
   对话框后,**根本没把 esr-bridge MCP 启起来 / 它没连上桥**。
3. **env / token / uv 全正常**(已活体验证):agent 的 claude env 里
   `EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/...` 正确,没踩 10042 回退坑;
   `uv` 0.9.26 已装;`.mcp.json` 的 token/URI/URL 都对。
4. **最可能是 claude 2.1.92 的 MCP 初始化行为回归** —— 老 claude 靠"往 PTY
   写 `\r`"触发 MCP init(EagerBridge 干的),新版可能不再这样 / 时机变了。和
   本分支已修的 theme-picker / UTF-8 banner 一样,都是 2.1.92 新版回归。Allen
   大概在旧版 claude 上,所以他 #505 "via tmux + live round-trip" 手动验是通的。
5. **测试真空**:真实的 "claude→JOIN" 链**没有任何自动化测试**覆盖 ——
   `apps/ezagent_plugin_cc/test/.../eager_bridge_test.exs` 纯 mock(直接
   `AgentBridge.Registry.bind(uri, fake_pid)`);`apps/ezagent_domain_chat/test/
   integration/orchestrator_mcp_bridge_test.exs` 是 `@tag :slow` + 没 `uv` 就
   skip,只测 MCP schema。所以谁的 claude 一变就中招而 CI 抓不到。

## 本分支已经修好的(都已 push 到 PR #446,新 PR 别重复)
- `64d5a05d` claude 2.1.92 **theme picker** auto-prompt(repeat 重发)+ **UTF-8
  banner 崩溃** scrub —— `apps/ezagent_domain_pty/.../server.ex`。
- `ad61e050` **URI 规范化回归**(插件 `URI.parse`→`URI.new!`,10 处)+
  **EagerBridge 门回归**(`all_fired?` 忽略 `repeat?: true` 的 prompt,否则
  theme_picker 永久卡死唤醒门)—— `eager_bridge.ex` + customer_chat 插件。
- `1ecb3000` **Mode → `use Ezagent.Lifecycle` 迁移**(takeover dispatch 恢复)。
- 合并 `bd1349f2` 已把 **Allen 的 #505**(`--dangerously-skip-permissions`,
  去掉 bypass 确认弹框)纳入。
- 启动对话框现在已处理:theme / trust / dev-channels / bypass-perms 全覆盖。

**所以失败点已被干净隔离到 "claude 不 init esr-bridge MCP" 这一步,不再被上面
的对话框噪音盖住。**

## 下一步调试(新 session 从这里开始)
核心:**搞清楚 claude 2.1.92 到底有没有、什么时候、用什么方式 init `.mcp.json`
里的 esr-bridge MCP server,以及那个 MCP 子进程(`uv run --script
apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py`)报什么。**

1. **手动复现最小链路**:用 PTY 起一个 claude,完全照 cc agent 的方式:
   `claude --dangerously-skip-permissions --dangerously-load-development-channels
   server:esr-bridge --append-system-prompt-file <soul> --settings <claude-pty-
   settings.json> --mcp-config <.mcp.json>`(确切 argv 见
   `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` 的 `build_claude_cmd`
   / `argv =` 段,约 line 1022-1036;env 见同文件 `base_env`/`build_claude_config_env`)。
   参考已有的 PTY 探针:`/tmp/claude_ob_probe.py` / `claude_drive2.py`(本机上,
   抓 claude 屏幕用)。
2. **关键:抓 esr-bridge MCP 子进程的 stderr**。claude 把它当 MCP server 起,
   它的输出不在 ezagent server 日志里。让 claude 真正到 REPL 后看它有没有
   spawn `uv run ... ezagent_mcp_bridge.py`;若起了,看它的 websockets 连接报
   什么(`ezagent_mcp_bridge.py` 自己写 per-bridge 日志,见脚本头部 `EZAGENT_HOME
   /EZAGENT_PROFILE` 日志方案 → 找 `~/.ezagent/poc-phase2/logs/` 下的 bridge 日志)。
3. **对照老 claude 行为**:`EagerBridge`(`apps/ezagent_plugin_cc/lib/ezagent/
   plugin_cc/eager_bridge.ex`)假设"写 `\r` 触发 MCP init"。验证 2.1.92 是否
   还吃这套;若不吃,要么 claude 2.1.92 自动 init MCP(那问题在别处,比如它
   卡在某个我们没处理的屏)、要么需要换触发方式。
4. **桥端 auth**:`apps/ezagent_domain_agent_bridge`(`Ezagent.AgentBridge.Socket`
   / `TokenStore`)—— 确认若 MCP 真连上来了 token 校验能过(对比最早成功那次的
   日志:有 `CONNECTED TO Ezagent.AgentBridge.Socket` + `JOINED agent_bridge:cc:<uri>`)。

## 这个新 PR 应该交付
1. **让 claude 2.1.92 的 esr-bridge MCP 正确 init 并 JOIN**(具体改点取决于上面
   查到的根因:可能在 cc_agent.ex 的 argv/启动方式、EagerBridge 的触发、或一个
   新的 2.1.92 对话框/行为)。
2. **补一个真实的 e2e 测试**:spawn 真 claude(`@tag :live` / 需 uv + claude
   登录)→ 断言 `JOINED agent_bridge`。替换/补强 `eager_bridge_test.exs` 的
   mock-only 覆盖,让以后 claude 升级导致的 JOIN 回归 CI 能抓到。这是 Allen 也
   会受益的项目级修复。

## 环境 / 跑法速记(工作机)
- **永远** `MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps`,
  **绝不 `mix deps.get`**。
- 起服务(分布式):见
  `poc/phase-2/cc-agent-slow-bind-findings-2026-06-01.md` 附录 / 下面命令。
  起前若 boot 很多 agent:`EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=<shared>
  mix ezagent.customer_chat.gc_ephemeral`(服务停时跑,清积累的 session)。
  **新机/合并后首次**要先 `EZAGENT_PROFILE=poc-phase2 MIX_DEPS_PATH=<shared>
  mix ecto.migrate`(合并加了 agent_lineage 等迁移,dev + test 两个库都要)。
- 触发一个 cc agent:浏览器/playwright 连 `/chat/acme`(光 curl 不行,要
  LiveView socket)。本机有现成录制器
  `scripts/demo/record-scenario.js`(prewarm 会 spawn agent 并等)。
- 关键日志信号:`grep 'JOINED agent_bridge'` 和 `grep 'CONNECTED TO
  Ezagent.AgentBridge.Socket'`(后者出现=MCP 连上桥了)。

```bash
cd /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2
COOKIE=$(cat ~/.ezagent/poc-phase2/runtime/cookie)
EZAGENT_PROFILE=poc-phase2 PORT=10142 \
  EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10142/agent_bridge/websocket \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2@127.0.0.1 \
  MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps \
  env -u USE_LOCAL_OAUTH -u ANTHROPIC_API_KEY -u CLAUDE_CODE_DISABLE_CRON -u USE_STAGING_OAUTH \
  elixir --name "ezagent_runtime_phase2@127.0.0.1" --cookie "$COOKIE" -S mix phx.server
```

## 修好之后(回原 session 录视频)
桥能 JOIN 后,在 `poc/phase-2-customer-service` 分支用 `acme` 租户录三个 demo:
```bash
DEMO_MODE=chat     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo          scripts/demo/record-clean.sh
DEMO_MODE=operator DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-clean.sh
DEMO_MODE=soul     DEMO_TENANT=acme DEMO_OUTDIR=docs/assets/demo-soul     scripts/demo/record-clean.sh
```
(用 acme 不用 cinnox:keep PoC 仓库不含真实租户内容;功能与租户无关。)
