# CS-team demo — 接手文档 (handoff, 2026-06-03)

> 上一段 session 把 CS-team 客服 demo 从"做不出 + 错误结论"推到"**核心 live demo 跑通**"。
> 本文件让下一个 session 30 秒进入状态。配套读:`docs/notes/2026-06-02-cs-team-demo-script.md`(脚本/PRD + 完整 gap §3)、PR **#538**、memory `project-headless-cc-agent-auth-token`。

## TL;DR — 现在在哪

- **分支**：`docs/cs-team-demo-script`；**PR #538**（已开、已订正、含 Demo GIF）。
- **已交付**：脚本/PRD(rev 4) + 后端彩排测试(全绿) + **1 处 core 修复**(`mcp_server.ex` `as_struct_content/1`) + 核心 demo `.webm`/GIF。
- **核心 demo 跑通**：operator 对话 → 编排器 12s 真回复 → 真调 `list_templates` → 一句话 `add_managed_member` **spawn 出真客服坐席**。
- **下一步(G-worker)**：customer→AI 回答还没通——worker 收到 `chat.receive` 但不回复(worker 侧 PTY/channel 生命周期那一层)。

## 真根因 + 修复(最重要,别再走弯路)

**live demo 卡死的总闸 = 认证,不是 claude 版本**(我先前误判"版本删 flag",已 `strings` + 手动 `/login` 证伪)。

- macOS 把 Keychain 访问绑在**发起进程身份**上 → ESR 用 PtyServer/erlexec spawn 的 `claude` **读不到**交互 `claude login` 写进 Keychain 的 token → headless claude 未认证 → `--dangerously-load-development-channels` 被 ignored → `Channels are not currently available` → agent 收 `chat.receive` 但永不回复。
- **修法(已验证)**：`claude setup-token` 生成绕开 Keychain 的长效 OAuth token(`sk-ant-oat01-…`,走 Max 订阅、非 API 计费)→ 作为 **`CLAUDE_CODE_OAUTH_TOKEN`** 注入 ESR server 环境 → spawn 的 claude 子进程继承 → 认证通过 → demo 跑通。
- 另一道(已修)：sandbox 缺 onboarding 状态会卡首次运行主题屏 → sandbox `.claude.json` 写 `hasCompletedOnboarding:true` 等(纯 config)。`~/.ezagent/cc-orchestrator/.claude/.claude.json` 已是登录+onboarded 态。

## 环境状态

- **dev server**：用 **fresh `csdemo` profile** 跑（`EZAGENT_PROFILE=csdemo`，DB 在 `~/.ezagent/csdemo/db/`）。**你的 `default` profile 数据没动**（default 的真 agent 快照 stale-不兼容 current main，故另起干净 profile）。
- **上一段结束时 server 还在后台跑**（带 `CLAUDE_CODE_OAUTH_TOKEN` env）。重启请见下。
- **admin 登录**：`entity://user/system/admin` / `8bdemo`（**用完整 URI，裸 `admin` 登录会失败**）。
- **token 是 ephemeral**：上一段放在 job tmp(`$CLAUDE_JOB_DIR/tmp/.oat`，随 job 清理)。**下一段要重新拿**：让 operator(Damon) 跑 `CLAUDE_CONFIG_DIR=~/.ezagent/cc-orchestrator/.claude claude setup-token`、把 `sk-ant-oat01-…` 给你;或复用还在跑的 server。

### 重启 csdemo server(带 token)
```bash
pkill -f "mix phx.server"; sleep 2; pkill -9 -f "beam.smp.*phx"
pkill -f "ezagent_mcp_bridge.py"; pkill -f "claude.*server:esr-bridge"   # 清 orphan
CLAUDE_CODE_OAUTH_TOKEN="<the sk-ant-oat01 token>" EZAGENT_PROFILE=csdemo mix phx.server
# 触发编排器：登录访问 /sessions 会 ensure_main_session 起编排器;
# 日志里 grep "Listening for channel messages" 出现即 channel 通。
```

## 怎么驱动(Playwright)

可复用脚本已固化在 `docs/notes/evidence/cs-demo-playwright/`：`lv-login.js`(登录+截图)、`lv-chat.js`(发消息+轮询回复)、`lv-record.js`(录 .webm)、**`lv-record-caption.js`(录**带字幕**版：旁白/视角标签/gap 字幕烧进视频)**、`lv-newsession.js`、`lv-terminal.js`。

**demo 资产(已落库,持久路径)**：`docs/notes/evidence/2026-06-02-cs-demo-orchestrator-live.{webm,gif,png}`(带字幕)。PR #538 的 Demo GIF 指它们(SHA-pin)。

**字幕做法(`lv-record-caption.js`)**：往页面注入两个 `position:fixed` overlay(顶部视角标签 + 底部旁白字幕条),**务必 `pointer-events:none`**(否则盖住 Send 按钮、消息发不出),底部留 padding 别遮聊天输入框。GIF 用系统 ffmpeg。

**踩过的坑（务必照做）**：
- `NODE_PATH=/Users/daiming/.npm/_npx/<hash>/node_modules`（playwright 在 npx cache;`find ~/.npm/_npx -name playwright -type d` 找）。
- 登录用**完整 URI** `entity://user/system/admin`（裸 `admin` 失败）。
- 提交登录用 `page.click(submit, {noWaitAfter:true})` + `waitForURL(!/login)`——post-login 是 LiveView(长连 WS),`networkidle` 永不 settle、会 hang。
- 给编排器/worker 发消息**必须 @mention**（`@entity://agent/system/cc_orchestrator-main …`），否则不路由、agent 收不到。
- GIF 用**系统 ffmpeg**(`/opt/homebrew/bin/ffmpeg`),playwright 自带的 ffmpeg 是精简版、没 palettegen。

## G-worker — 下一步(把 customer→AI 跑通)

**现象**：`add_managed_member` spawn 出 worker(如 `cc_vip_presale-…`),worker 的 channel 也 `Listening`,客户 @mention 它 → 后端 `chat.receive` delivered,但 worker **零回复**;restart 后 worker 的 claude PTY 不自动重起、`listening events` 只有编排器那一条。

**已知**：token 对 worker 同样适用(worker 继承同一 env token、auth OK)。欠的是 worker 侧的 (a) onboarding seed(worker 用 per-agent config 目录,不是编排器那个已配好的)、(b) PTY 重起 / channel listening 生命周期。

**建议切入**：
1. 看 worker 的 per-agent config 目录在哪、有没有 `hasCompletedOnboarding`(对比编排器 sandbox)。
2. 看 worker spawn 后 claude PTY 是否真起来、channel 是否 `Listening`(grep worker 的 os_pid 的 PtyServer stderr)。
3. 若 worker 卡 onboarding/channel,把同样的 seed + token 路套上去。
4. 通了就用 `lv-record.js` 加一段"客户问 → AI 答"录完整流程,补进 PR #538 的 Demo。
5. 作为紧接的下一个小 PR(G-worker)。

**视频后续(Allen review 反馈)**：当前 demo 只有 operator↔编排器一侧、已加字幕(顶部"OPERATOR 视角"+底部旁白/gap 字幕)。Allen 想要**左右分屏(客服界面 | operator界面)**——这要 G-worker 通了才能拍:两个浏览器 context(operator 一个、customer 一个,各登录不同 user),各自录 .webm,再用 `ffmpeg hstack` 左右拼;或同屏两个 LiveView。gap 也继续用字幕标(沿用 `lv-record-caption.js` 的 overlay 做法)。

## 给 Allen 的待决策（已在 PR #538 正文）
① 把 token 认证做进 cc seed/部署文档(headless agent 不能靠 Keychain,有利弊表);② demo gap 群归 #533 + `domain.agent`;③ G-worker 下一个小 PR。
