# 场景 05(执行记录):cc-agent(Claude Code)往返

## 2026-07-02 World UI current retest note

See world-scenario-05-cc-roundtrip.md for the World-specific run.

- Current Invite UI uses the Invite member dropdown, not a full URI text input.
- The retest invited claude-bot agent, verified data-kind=agent and data-online=true, selected @claude-bot through mention autocomplete, and sent @claude-bot cc-ping-world-0702.
- The message was written with mention entity://system/agent/claude-bot and a delivered read marker, but no cc-agent reply appeared, so the World scenario is FAIL.
- The same service log shows the Claude PTY process exited with error unknown option --dangerously-load-development-channels, while the UI still reported the member as online.

| 字段 | 值 |
|---|---|
| **状态** | 🟥 确认 bug(**Allen 已确认**)—— cc PTY 慢激活(>10s)撞上 create_agent cascade 两层 5s ReadyGate(内层 `template_spawn:638`/`invocation:181` 真凶 + 外层 UI 无 deadline)→ `:activate_timeout` 回滚。临时改动已实测定位并**还原**,修复留别的分支。详见「✅✅ 确认 bug + 修复方法」 |
| **对应设计场景** | [scenarios/05-cc-agent-roundtrip](../scenarios/05-cc-agent-roundtrip/scenario.zh_cn.md) |
| **验证面** | world LV + server 日志 |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~16:26 |
| **环境** | 分支 `feat/product-gaps-f9-f12` · commit `913e2ba0` · server `http://world.localhost:10042` |
| **前置 scenario** | scenario-03 ✅(session `zyli-test-1`) |

## 前置条件(当次实际)

- 用基线现成 cc agent **`claude-bot`**(`entity://system/agent/claude-bot`),Invite 进 `zyli-test-1`
- claude 二进制存在(`~/.nvm/.../bin/claude`);PtyServer 子进程已 spawn(os_pid 63993)

## 角色

- **调用方**:admin · **目标**:`entity://system/agent/claude-bot`(cc flavor)

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | Invite `claude-bot` 进 session | 成员加入成功(`session.invite` dispatch);成员名册显示 claude-bot | (zyli 报告) | ✅ |
| 2 | 发 `@claude-bot 你好,请回复一句话` | 消息**送达** claude-bot(日志:`chat.send` mention=[claude-bot] → 存 messages → claude-bot `delivered` read_marker;`session.send` invocation `granted`)**但无回复** | server log 行 6124-6142 | 🟥 |
| 3 | 查 server 日志定位 | 见下方根因 | phx_live.log | 🟥 |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| cc-agent 真实 SDK sidecar 回复 | ❌ 无回复 —— cc Kind 未实例化,消息无人处理 | ❌ |
| LV 渲染富文本对话 | ❌ 仅 admin 发出的消息上屏 | ❌ |

## ✅✅ 确认 bug + 修复方法(2026-06-25 晚 —— Allen 确认 + 临时改动实测定位)

> **状态**:**Allen 已确认这是 bug。** 临时改 `agent_actions.ex` + `workspace.ex` 传 deadline_ms 实测后,**已还原**(两文件回 HEAD,无 tracked 改动)。真正修复在**别的分支**做;本分支只记录方法。

**完整根因(两层超时,实测钉死):**
cc PTY worker 要 **>10s 才 `:ready`**(Claude Code TUI 冷启动 + trust/login 对话框)。create_agent cascade 等 worker ready 有**两层 5s 卡点**:

| 层 | 位置 | 行为 | 实验结论 |
|---|---|---|---|
| **外层** | `agent_actions.ex` 创建 ctx 不含 `deadline_ms` → `invocation.ex:269` `ctx[:deadline_ms] \|\| 5_000` = **5s** | LiveView→Workspace 的 `GenServer.call(_, 5000)` 5s 超时 → **LiveView 直接崩,操作员看不到真错误** | 改:`agent_actions` 传 `deadline_ms: 120_000` + `workspace.create_agent/3` 把它透进 Cmd ctx(原本会丢)。**实测生效**:LiveView 不再 5s 崩、等到了真错误。但**创建仍失败** → 外层是必要非充分。 |
| **内层(真凶)** | `template_spawn.ex:638` `ReadyGate.await(worker_uri, 5_000)`(best-effort,`_=` 忽略)+ 随后 sandbox.write_path dispatch 命中 `invocation.ex:181` `ReadyGate.await(worker_uri, 5_000)` → `:activate_timeout` | 两段 5s ≈ **10s** 等 worker ready;cc worker >10s → 超时 → `{:sandbox_write_path_failed, …, :activate_timeout}` → cascade 回滚 | 实测:加了外层 deadline 后,失败 **duration=10.17s**(`10170018µs`)正好两段 5s → **内层 ReadyGate 才是真凶** |

**修复方法(给别的分支):**
1. **内层(根因)**:把 `template_spawn.ex:638` 等 worker ready 的 `ReadyGate.await(worker_uri, 5_000)` 放宽到能容纳慢 flavor 激活(如 120s;ReadyGate ready 即返回,**不拖慢 echo/curl/codex 快 flavor**)。或让 cc worker 的 `:ready` 不依赖完整 PTY 冷启动。
2. **外层(配套)**:`Workspace.create_agent/3` 透传 `deadline_ms`(现在直接 build `%{mode,caller,caps,reply}` 丢掉了);world UI `agent_actions.ex` 为慢 flavor(cc/codex)传更长 deadline。否则即使内层修了,UI 仍可能在 worker ready 前 5s 崩、吞掉成功/错误。

**关于"同事 API 能用"**:其 cc 大概率激活更快(API-key 认证跳过 OAuth trust/login 对话框,或 cc-headless SDK)→ 落在内层 10s 窗口内 → 成功。**慢路径(cc PTY + OAuth)触发本 bug**,Allen 确认。

---

## (历史)初版"同事反证"分析 —— 已被上方 Allen 确认版取代

> **触发**:zyli 同事用 **API 创建 cc agent、deadline 设 60/120s,无创建失败,正常使用**。这直接反驳了下方「cc 不可用」的结论。深查代码确认 —— **我之前 over-concluded 了,cc 本身能用**。

**真根因(代码钉死):**
- `agent_actions.ex:53-71`(world UI `agents.create`)的 `caller_ctx = %{caller, caps}` **不含 `deadline_ms`** → `invocation.ex:269` `timeout = inv.ctx[:deadline_ms] || 5_000` 取**默认 5s**,且 UI 无法覆盖。
- cc PTY 激活 ~10s(Claude Code TUI 冷启动 + trust 等对话框)> 5s → `:activate_timeout` → 回滚。
- 对照:codex 激活 ~1.8s、echo/curl 更快,都在 5s 内 → 所以**只有 cc 在 UI 创建时中招**。
- **API/CLI 路径不受限**:`protocol_api/reply_waiter.ex` 默认 `@default_deadline_ms 120_000`;`mix ezagent.agent.create` 包 `Workspace.create_agent/3`。同事经此路 120s → cc 创建+回复正常。

**逐条重判:**
| 原"bug" | 更正后 |
|---|---|
| ❌ cc-PTY 新建 `:activate_timeout` | **不是 cc bug** → **world-UI/DX bug**:`agent_actions.ex` 创建未设 `deadline_ms`,默认 5s 对慢 flavor(cc)太短。修法:UI 为 cc/codex 传更长 deadline(如 120s)。cc 经 API 正常。 |
| ⚠️ cc-PTY 旧 `claude-bot` 不回 | **存疑、需重测** → claude-bot 是**开机冷加载的陈旧老 agent**;同事**新建**的 cc 正常回复。我仅凭一个陈旧 agent 就断"cc PTY 转发坏"= over-conclude。**待**:经 API/120s 新建一个 cc agent 验证回复(预期正常)。 |
| ⚠️ cc-headless `config-dir :none` | **单独的 cc-headless 问题,低置信** → 这是**快速失败**(非超时),`config_dir.ex:66` FsResolver 未解析 `cc-headless-agents` ns。与 cc(PTY)无关,需单独查证是否真 bug;同事用的是 cc 非 cc-headless。 |

**净结论**:**cc 可用(API/足够 deadline)**。world UI 创建对慢 flavor 用 5s 默认超时 = 真正该修的 DX bug(`agent_actions.ex` + `invocation.ex:269`)。claude-bot 不回 + cc-headless 错误降级为"待单独验证",不再当作"cc 坏了"。

---

## ⚠️ 以下为已被上方更正的初始(rebase 后)结论 —— 保留备查

## ⭐ 最终结论(2026-06-25,rebase 到 origin/main `8b673310` 后测;**已被上方更正**)

> **诊断更正**:本场景最初把 cc 不回归因为 "cc.agent Template Class boot 顺序未注册" —— **该诊断是错的**。zyli 质疑后核对:① 该 "no Template Class registered" 警告 **echo.agent 也报**(行 86-91),而 echo 能回 → 是 benign 的早期冷加载时序提示,非根因。② 当时跑的是落后 main 7 个 commit 的旧代码;已 rebase 到 main(含 `#980 A1: register template flavor hook`)重测。
>
> rebase + 重测 + 真实根因排查后,cc/cc-headless 在 **latest main** 上有 **三个独立代码层 bug**:

| flavor / 路径 | 失败 | 真实根因 | 证据 |
|---|---|---|---|
| **cc(PTY)** 旧 agent `claude-bot` 回复 | 消息送达(`delivered` marker)**但不回** | **已排除**:沙箱无凭据(已 `seed_cc_sandbox` 修,claude 现 "Welcome back · Opus 4.8 · Claude Max" 认证 OK + server 带 `HTTPS_PROXY`)。**仍不回的真因**:送达后**消息没被转发进 claude PTY**(日志无 PTY stdin/stdout 处理)= cc PTY 型的 inbound-chat→PTY 桥接未生效 | phx_proxy.log:claude-bot delivered 后无 PTY I/O;`sdk_sidecar.ex:26` 回复超时本就 `120_000`(非超时问题) |
| **cc(PTY)** 新建 | `{:cascade_spawn_failed, {:sandbox_write_path_failed, …, :activate_timeout}}` | 激活 ~10s > **`invocation.ex:181` `ReadyGate.await(_, 5_000)` 全局就绪闸门**(P22 可靠性原语,故意 5s);`template_spawn.ex:638/673` 抛 sandbox_write_path_failed | 两次创建 duration ~10s 后 `:activate_timeout` |
| **cc-headless** 新建 | `RuntimeError: config-dir resolution failed for resource://system/cc-headless-agents/zyli-cch-1: :none` | `config_dir.ex:66` 经 FsResolver 解析 `resource://system/cc-headless-agents/<name>` 返回 `:none` —— **`cc-headless-agents` resource 命名空间未注册进 FsResolver**(`cc-agents` 有) | zyli 截图 `cc-handless-create-fail.png` |

**判定**:cc 全系列(PTY + headless)在 latest main 经 world UI 创建/回复流程**均不可用**,三处独立代码 bug。**非环境、非凭据、非 cwd、非我最初的 template-注册误判。** 按 CLAUDE.md grill 文化 → 标 issue 报 Allen / 走 dev-together,不在测试中私改 core(尤其 P22 ReadyGate 全局闸门)。

---

## 根因(server 日志)—— ⚠️ 以下为 rebase 前旧代码的初始(已更正)记录,保留备查

**boot-sequencing bug**:
- 日志行 82-83 / 188-189(早期 boot,共 4 次):`Workspace.Loader: no Template Class registered for "cc.agent" (template "cc.agent.claude-bot") ... skipping`
- `cc.agent` Template Class(`Ezagent.PluginCc.Template.CcAgent`)在 cc 插件 **application.ex 注释明确的 "Phase 2 才发布"**;而 **workspace 冷加载早于 Phase 2** → claude-bot / e2e-test 的 **cc Kind 被跳过、从未实例化**。
- 后果:claude-bot 只有 `snapshot.restored`(状态加载)+ 孤立 PtyServer 子进程,**没有活的 cc Kind 接收/处理 chat dispatch** → 消息送达 `delivered` 但无处理 → 不回。
- 对照:`echo.agent` Template Class 注册及时,`zyli-echo-1`(scenario-04)能实例化并回包 → 证明问题专属 cc(Phase-2 published)flavor 的注册时序。

## 追加验证:新建 cc agent 是否绕过?(zyli 假设)

为区分"代码问题 vs 旧 agent 冷加载",zyli 新建了 cc agent `zyli-cc-1`(project_cwd `/tmp/cc-agent-zyli-cc-1`),勾选/不勾选 PTY 各一次。**两次均创建失败**,失败模式与旧 agent **不同**:

| # | 操作 | 实际观察 | 判定 |
|---|---|---|---|
| A1 | New Agent flavor=cc, name=zyli-cc-1, **with_pty=true** | PtyServer spawn claude(os_pid 82369,行 7748);Claude Code 起、碰 `trust_folder_dialog` 自动答 1(行 7775);但 `workspace.create_agent` 的 `:call` **5000ms 超时**,激活实耗 ~10s → `{:cascade_spawn_failed, {:sandbox_write_path_failed, .../zyli-cc-1, :activate_timeout}}`(行 7779/7927),创建回滚 | 🟥 |
| A2 | 同上 **with_pty=false** | 同样 `Ezagent.Kind.spawn ... not :ready within 500ms`(行 8666)→ 同样 `:sandbox_write_path_failed :activate_timeout`(行 9061),~10.6s,回滚 | 🟥 |

**结论(回答 zyli)**:**是代码问题,不是"旧 agent"的锅**。新建 cc 也失败,但原因不同 —— **cc 激活(Claude Code 冷启动 + trust 对话框 + sandbox 写路径)耗时 ~10s,超过 `workspace.create_agent` 的 5s `:call` dispatch 预算** → `:activate_timeout`。这与 `world-e2e-seed.md §3` 记的 `create_session` 5s 超时同属一类 framework-dispatch-budget blocker。换 cwd / 改环境救不了。

## 遗留 / bug
- 🟥 **cc 双重代码层 blocker(报 Allen):**
  1. **旧 cc agent**:workspace 冷加载 vs cc 插件 Phase-2 template-class 发布的顺序竞态 → claude-bot/e2e-test 开机即被跳过、Kind 不起。
  2. **新建 cc agent**:激活耗时 ~10s 超过 `create_agent` 的 5s `:call` 预算 → `:sandbox_write_path_failed :activate_timeout` → 回滚。
  - 均**非凭据、非网络、非 cwd 问题**。按 CLAUDE.md grill 文化,未在测试中私自 hack 修复。
- 预判:**scenario-06 codex 同类**(codex.agent 也是 plugin-published template,且叠加无 pypi 外网 → 双重 BLOCKED)。
- 候选验证:server 全新重启大概率**复现**(确定性 boot 顺序);真正修复需在代码层调整 workspace 冷加载与 plugin template 发布的先后(Allen)。

## 证据清单
- `evidence/scenario-05/s05-cc-bugs-server-log.txt` — 三个 cc bug 的 server 日志关键行固化(Bug A 送达无回复 + Welcome back 认证 / Bug B `:activate_timeout` / Bug C config-dir :none + benign template skip 对照)
- `evidence/scenario-05/s05-cc-headless-create-fail-zyli.png` — zyli 视角:cc-headless 创建报 `config-dir resolution failed :none`

## 交叉引用
- 设计场景:`docs/scenarios/05-cc-agent-roundtrip`

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**2026-06-26 agent-browser 实地验证:UI 路径下 claude-bot 不回(回归守卫成立)**。注意上方人肉记录的更正结论:cc 经 API/足够 deadline 可用,world-UI 创建/回复路径是真正该修的 DX bug;故本断言是 **UI 路径** 的回归守卫,非"cc 整体坏"。 -->

**前置(自动化)**:scenario-03 已跑(session `e2e-test-1` 存在)。用 seeded cc agent **`claude-bot`** 做被测体。**UI 路径已知问题**:慢激活(~10s)> `invocation.ex` 5s 默认 deadline / ReadyGate(见上方记录),且 claude-bot 是陈旧 agent,送达后不回。
**入口 URL**:`http://world.localhost:10042/sessions?session=<encodeURIComponent("session://system/default/e2e-test-1")>`
> **cc 新建字段约束(2026-06-26 实地,补 UI-create DX bug 证据)**:经 UI 新建 cc(非用 claude-bot)需填 `project_cwd`,否则 `error:cwd_required_for_cc`;cwd 还须是**已存在目录**,否则 `error:{:cwd_not_a_dir, ...}`;补齐后提交 `data-last-dispatch` 回 `idle` 但 agent **未创建**(疑似 activate_timeout 回滚,印证上方"UI 5s deadline 对 cc 太短")。故 runbook 默认用 seeded claude-bot。

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | navigate + 开邀请框 | `/sessions?session=<enc>` → `button[aria-label="Invite a member"]` `.click()` | — | `visible #world-invite-input` | — |
| 2 | fill(**完整URI**)+ requestSubmit | `#world-invite-input` | `entity://system/agent/claude-bot` | `attr li[data-kind=agent] data-online=true`(claude-bot 加入即 online,**实地✅**) | — |
| 3 | 真键盘 @ + autocomplete + 发送 | `keyboard type '@claude'`→`click 'ul[role=listbox] button'`→`keyboard type ' cc-ping-99'`→`press Enter` | `@claude-bot cc-ping-99` | `visible [data-mine=true]`(自己消息上屏,**实地✅**) | — |
| 4 | wait 16–30s 等 cc 回复 | `[data-sender-kind=agent][data-mine=false]` | — | `text~ [data-sender-kind=agent] "cc-ping-99"` —— **2026-06-26 实地 🟥 FAIL**(等 16s claude-bot online 却无 reply 气泡) | `s05-step1-cc-no-reply-auto.png` ✅ |

**断言映射**:
- 「cc-agent 真实 SDK sidecar 回复(UI 路径)」→ step4 reply 气泡断言 → **2026-06-26 实地确认 FAIL**(claude-bot online 却不回);**UI-create/reply DX bug 修复后应 PASS**,此即回归守卫。
- 「LV 渲染富文本对话」→ step3 `data-mine=true` 上屏(发送侧 PASS)+ step4 回复侧(当前 FAIL)。

**清理**:无(用 seeded `claude-bot`,未建新实体)。可从 session 移除该成员还原。
