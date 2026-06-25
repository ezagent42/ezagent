# docs/e2e — 人肉端到端执行记录

> **本目录是什么**:zyli 实际人肉跑端到端时,**逐步操作 + 证据 + 实测判定**的记录层。
> 一条 `scenario-<no>.md` = 一次真实执行的流水账(不是设计文档)。
>
> **跟 `docs/scenarios/` 的关系**:`docs/scenarios/`(35 条)是**设计层** —— "这个场景*应该*怎样、预期是什么、失败模式有哪些"。
> 本目录是**执行层** —— "我*实际*怎么点的、看到了什么、证据在哪、过没过"。
> 每条 e2e scenario 在头部 `cross-ref` 回链到对应的 `docs/scenarios/NN`,**设计与执行分离,不重复抄设计**。
>
> 取证、命名、判定、单次会话怎么跑 —— 全部规范见 [`guide.md`](./guide.md)。
> 新建一条记录时复制 [`scenario-template.md`](./scenario-template.md);范例见 [`scenario-00-example.md`](./scenario-00-example.md)。

---

## 全流程 —— 核心黄金路径(golden path)

一条端到端主线,从登录走到审计,串起 agent 创建、4 种 agent flavor、mention 路由、Feishu 双向通道。
**按编号顺序执行**:前一条是后一条的前置(登录态、agent、session、成员名册、Feishu 绑定逐步累积)。

| # | 记录文件 | 标题 | 对应设计场景 | 验证面 | 状态 |
|---|---|---|---|---|---|
| 01 | [scenario-01-operator-login.md](./scenario-01-operator-login.md) | 操作员登录 world UI | [scenarios/02](../scenarios/02-password-login-admin/) · [scenarios/01](../scenarios/01-magic-link-login/) | world LV | 🟩 PASS |
| 02 | [scenario-02-create-agent.md](./scenario-02-create-agent.md) | 创建 agent | ⚠️ 设计场景缺位(待补) | world LV | 🟩 PASS |
| 03 | [scenario-03-create-session.md](./scenario-03-create-session.md) | 创建 session + 加成员 | [scenarios/09](../scenarios/09-session-create-lv/) | world LV | 🟩 PASS |
| 04 | [scenario-04-echo-roundtrip.md](./scenario-04-echo-roundtrip.md) | echo agent 往返 | [scenarios/08](../scenarios/08-4agent-comprehensive/) | world LV | ⚠️ PASS-gaps |
| 05 | [scenario-05-cc-roundtrip.md](./scenario-05-cc-roundtrip.md) | cc-agent(Claude Code)往返 | [scenarios/05](../scenarios/05-cc-agent-roundtrip/) | world LV + 日志 | 🟥 确认 bug(Allen)— cascade 两层 5s ReadyGate |
| 06 | [scenario-06-codex-roundtrip.md](./scenario-06-codex-roundtrip.md) | codex-agent 往返 | [scenarios/06](../scenarios/06-codex-agent-roundtrip/) | world LV + 日志 | 🟩 PASS |
| 07 | [scenario-07-curl-roundtrip.md](./scenario-07-curl-roundtrip.md) | curl/deepseek agent 往返 | [scenarios/07](../scenarios/07-curl-agent-deepseek/) | world LV | 🟩 PASS |
| 08 | [scenario-08-mention-routing.md](./scenario-08-mention-routing.md) | @mention 门控路由 | [scenarios/10](../scenarios/10-mention-gated-routing/) | world LV | 🟩 PASS |
| 09 | [scenario-09-cross-session-reject.md](./scenario-09-cross-session-reject.md) | 跨 session mention 被拒 | [scenarios/11](../scenarios/11-cross-session-mention-rejected/) | world LV + 日志 | ⚠️ PASS-gaps |
| 10 | [scenario-10-feishu-bind.md](./scenario-10-feishu-bind.md) | 绑定 Feishu chat↔session(出站) | [scenarios/12](../scenarios/12-feishu-bind-outbound/) | Feishu + LV | 🟩 PASS |
| 11 | [scenario-11-feishu-inbound.md](./scenario-11-feishu-inbound.md) | Feishu 入站到达 → 路由 agent | [scenarios/13](../scenarios/13-feishu-inbound-routing/) | Feishu + LV | 🟩 PASS |
| 12 | [scenario-12-dispatch-audit.md](./scenario-12-dispatch-audit.md) | dispatch 审计核对(收口) | [scenarios/28](../scenarios/28-dispatch-audit/) | DB/审计 + 日志 | ⚠️ PASS-finding |

**状态图例**:⬜ pending(未跑)· 🟩 PASS · 🟥 FAIL · 🟨 BLOCKED(被前置/已知 bug 卡住)· ⚠️ PASS-with-gaps。
判定定义见 [`guide.md` §判定标准](./guide.md#判定标准)。

---

## 进度汇总

> 每跑完一条,回填上表状态 + 这里一行结论。初始全 pending。

- **2026-06-25**:开测。环境基线见 scenario-01(3 session 全 external-mirror;干净 agent `claude-bot`/`echo_default`;stale `r2-*`/`r3-*` 等)。
  - 🟩 **01 登录** PASS — observer + zyli 双 agent-browser 取证,落 Sessions 页无异常。
  - 🟩 **02 创建 agent** PASS — zyli 经 Identities→New Agent 建 `zyli-echo-1`(echo);observer 独立确认服务端 8→9,URI `entity://system/agent/zyli-echo-1`。表单字段已记入(补设计场景素材)。
  - 🟩 **03 创建 session + 加成员** PASS — `session://system/default/zyli-test-1` + 成员 zyli-echo-1(在线)+ admin;**老 no_such_actor 快照竞态未复现**(f9-f12 修复生效)。
  - ⚠️ **04 echo 往返** PASS-with-gaps — @mention 路径 echo 收到+原样回显,send 未被吞;**发现**:新 session 无默认 `always→members` 路由规则(ROUTING=0),无 @ 消息不送达(偏离设计 09 假设),提前演示了 mention-gating;无路由消息的 DLQ 归宿待 scenario-12 审计。
  - 🟥 **05 cc 往返** FAIL — **已 rebase 到 main `8b673310` 重测**(初版 "template boot 顺序" 诊断**已更正为错误**:echo 也报同警告却能回)。latest main 上 cc 三个独立代码 bug(报 Allen):① cc-PTY 旧 `claude-bot`:seed 凭据+代理后已认证("Welcome back · Opus 4.8 · Claude Max"),但消息**送达后不转发进 claude PTY** → 不回(PTY 桥接 bug);② cc-PTY 新建:激活 ~10s > `invocation.ex:181` ReadyGate 5s 全局闸门(P22)→ `:activate_timeout`;③ cc-headless 新建:`config-dir resolution failed :none`(`cc-headless-agents` resource ns 未注册 FsResolver)。**非环境/凭据/cwd 问题。** 未私改 core P22 闸门。
  - 🟩 **07 curl 往返** PASS — 新建 `zyli-curl-1`(curl/deepseek)+ 配 api_url + key,@mention → **真实 DeepSeek HTTP 回复**(~3s,observer 确认非 stub)。**坐实 cc bug 是 cc/PTY 专属**:非 PTY 纯 HTTP flavor 端到端正常,路由/代理出网都没问题。
  - 🟩 **08 @mention 门控** PASS — 用 echo + curl 两个工作 agent 对照:`@echo` 只 echo 回、`@curl` 只 curl 回,无越权回复。机制差异:ROUTING=0 下门控来自 **@mention 直接寻址**(非设计 10 假设的路由规则);分发面单播(没收到 vs 收到没回)UI 不可见,留 scenario-12 审计。
  - ⚠️ **09 非成员/跨 session 拒绝** PASS-with-gaps — @ 非成员(echo_default/e2e-test)零应答;关键对照(同 echo flavor 的成员 zyli-echo-1 会回)证明是成员作用域;**加分**:`@`autocomplete 只列本 session 成员、非成员不在候选(双重防护)。**缺口**:UI 看不到"显式拒绝 vs 静默丢弃"(P22 DLQ-on-zero-match)→ 留 scenario-12 审计。
  - 📌 **贯穿线索**:04/08/09 都撞到「UI 不暴露投递/拒绝/DLQ 信号」→ scenario-12(审计收口)是验证 P22「没人接收要有人知道」的关键一环。
  - ⚠️ **12 dispatch 审计** PASS-with-finding — 查 PG `invocations`(`mix run --no-start` 绕过缺 psql)。**回填确认**:mention **单播**(只被 @ 的 agent 有 `agent.receive`)+ 非成员**零投递**(无 receive)在 dispatch 层成立;每个 echo/curl 往返 `send→receive→send` 全 `granted` 可追溯。**关键发现(交 Allen)**:零匹配消息(04 无路由 / 09 @非成员)→ **无 DLQ 表 / 无 reject invocation / 无 telemetry** = "没人接收时没人知道",P22 DLQ-on-zero-match 是设计 no-op 还是缺口待裁决。
  - 🟩 **06 codex 往返** PASS(**纠正了"预判 blocked"**)— zyli `codex login` + 手工 seed CODEX_HOME(auth.json/config.toml)+ 代理后,@mention → **真实 Codex 回复 ~7s**。创建仅 1.8s **无 `:activate_timeout`**、bridge join ok。**强证据:cc bug 是 cc-flavor 专属** —— codex(同为复杂 bridge agent)正常,只有 cc 坏。轻 DX 缺口:codex 无自动 seed 凭据 task(cc 有 seed_cc_sandbox)。
  - 📊 **flavor 矩阵**:echo ✅ / curl ✅ / codex ✅(均快激活,5s 内)/ **cc 🟥 确认 bug**(慢激活 >10s,触发 cascade 两层 5s ReadyGate 超时)。
  - ⭐ **2026-06-25 晚 scenario-05 定案(Allen 确认 bug)**:临时改 `agent_actions.ex`+`workspace.ex` 传 120s deadline 实测 → 失败 duration=10.17s 钉死**内层 `template_spawn:638`/`invocation:181` 的两段 5s ReadyGate 等 worker ready 才是真凶**(外层 UI deadline 是配套)。修复方法已记 scenario-05,临时改动**已还原**(无 tracked .ex 改动),真修在别的分支。**教训:别凭单点实测/一次推理下结论 —— 我先误判 template-boot-顺序、再以为"只是 UI deadline",实测+Allen 才定到双层根因。**
  - 🟩 **10 Feishu 绑定+出站** PASS / 🟩 **11 Feishu 入站+路由** PASS — zyli 上午 F12 工作时已跑通(证据复用)。飞书群 `@r3-echo-pty-1` → 入站(**WSS 长连接,无需公网 webhook**)→ text-grep 解析路由 → echo 回 → 出站流回飞书群;world UI feishu-bing 交叉确认。本轮实测确认 sidecar WSS 已连(日志 889/890/1001)。机制见 f12 note。
  - ✅ **12 条全部跑完**(06 codex / 10·11 Feishu 都从"预判 blocked"翻成实测 PASS — 实测胜过假设)。
  - 工具说明:CDP 挂操作员真实浏览器在本环境太不稳,已改用「zyli 自己浏览器操作 + 截图」+「headless observer 服务端对照」双证据模式。

---

## 目录布局

```
docs/e2e/
├── README.md                  # 本文件:索引 + 黄金路径 + 进度
├── guide.md                   # 测试全流程的流程 + 取证规范 + 判定标准
├── scenario-template.md       # 新记录复制此模板
├── scenario-00-example.md     # 填好的范例(看格式照着学)
├── scenario-01..12-*.md       # 黄金路径 12 条执行记录
└── evidence/                  # 截图/原始输出,按 scenario 分子目录
    ├── README.md              # 命名约定
    └── scenario-NN/           # s NN 的全部证据
```
