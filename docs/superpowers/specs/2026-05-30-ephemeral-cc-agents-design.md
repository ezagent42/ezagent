# 设计:customer-chat 临时 cc agent 不持久化累积(Approach A)

> 2026-05-30 · scope #1/#2 migration · 状态:已与用户确认,待写实施计划
> 配套:`CLAUDE.local.md`「仍存在的问题」段;follow-up chip「Fix per-conv cc agent accumulation + boot storm」

## 问题

ezagent customer-chat 里,每个客服会话由 `EzagentPluginCustomerChat.Bootstrap.ensure_cc_for_conv/3`
按需创建一个 per-conversation cc 回复 agent(`entity://agent/<ws>/cc_cust_<conv>`)。

`Ezagent.Workspace.create_agent/3` 对 `flavor: "cc"` **无条件**把一条 spawn 模板
`cc.agent.cc_cust_<conv>` 写进 `workspaces.session_templates` 列
(`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:988, 1156-1170`),
且**没有 opt-out 参数**。

server boot 时,`Ezagent.Workspace.Loader.load_all/0` 读 `session_templates` 并把**每一条**
模板都重新实例化 → spawn 每个 cc agent 的 claude PTY
(`apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex:276-318`、
`behavior/workspace.ex:603-607`)。

后果:每个会话都永久留一条注册,boot 时全部一起重启 → 「boot 风暴」。实测累积到 ~10 个
就把 PTY/erlexec spawn 容量打满,导致**新会话**的 `ensure_session`/`ensure_cc_for_conv`
完不成,页面报 "Could not reach the assistant"。这直接卡住 scope #2 的 A/B 对比测试
(A/B 两个变体 = 同 workspace 两个并发 agent)。

根因:**临时的 per-conversation agent 留下了永久的 workspace 模板注册 + 持久快照,boot 时无限复活,没有 GC**。

## 关键约束 / 既有事实(已验证)

- `session_templates` 列已被标记**废弃**(`workspace/store.ex:16-30` moduledoc,"G-12, audit 2026-05-23",计划淘汰)。命名是历史误称,实际是 spawn-模板注册表。
- `Ezagent.Workspace.remove_template(workspace_name, tmpl_name)` 是**公开 API**,后台 LiveView 和一个 mix task 已在用。
- `remove_template` 的语义(`behavior/workspace.ex:437-438`)= `Map.delete(slice.session_templates, name)` + 持久化——**只删注册,不终止正在运行的 Kind**。
- 模板 key 格式 = `"cc.agent." <> agent_name(agent_uri)`,`agent_name` 取 URI 实体段;对 `entity://agent/<ws>/cc_cust_<conv>` 即 `cc.agent.cc_cust_<conv>`。**必须从 create_agent 返回的 `agent_uri` 提取**(含 flavor 前缀 `cc_`),不能用传入的 `agent_name`(`cust_<conv>`)。
- curl/np flavor 已经是**不注册、直接 `SpawnRegistry.spawn`** 的先例;cc flavor 走模板路径(受 invariant 测试 `agent_create_single_path_test.exs` 约束,不可绕过 create_agent 自己 spawn)。
- boot 恢复只走 `session_templates`;`kind_snapshots` 是 Kind 实例化时加载的状态,不是独立的 boot-spawn 触发器 → 删了 `session_templates` 注册即可阻止 boot 重启;残留的 `kind_snapshots` 行是孤儿(无害,清扫 task 顺带清)。

## 范围(本次)

**做:** 只让 `cc_cust_*` 回复 agent 不再持久化累积。
**不做:** per-session orchestrator(由 domain `create_session` 创建,走另一条 session 恢复路径)——维持「PoC 已接受的空转 orchestrator」。若验收发现它独立造成风暴,归入下方 B 提给 Allen。

## 方案 A:插件内 deregister-after-create

### 组件 1 — `bootstrap.ex` 注销临时模板

`ensure_cc_agent/5` 在 `create_agent` 返回 `{:ok, agent_uri}`(含 `{:already_exists, uri}` 归一后)后:

1. 从 `agent_uri` 末段提取实体名(如 `cc_cust_<conv>`)。
2. 构造 `tmpl_name = "cc.agent." <> 实体名`。
3. 调 `Ezagent.Workspace.remove_template(workspace, tmpl_name)`。
4. **best-effort**:失败只 `Logger.warning`,**不**改变 `ensure_cc_agent` 的返回值(对话照常)。

效果:agent 在当前会话正常服务(remove 不杀运行中的 Kind);boot loader 不再重放它。

> 注:create_agent 内部「注册 → 立即 invoke_template_now spawn」是一步;我们在其后注销,只移除 boot 恢复用的「配方」,不影响已 spawn 的运行实例。

### 组件 2 — 一次性清扫 mix task(可复用)

新增 `mix ezagent.customer_chat.gc_ephemeral`(幂等):
- 遍历所有 workspace,从 `session_templates` 删所有 `cc.agent.cc_cust_*` key(保留 `cc_cs_main` 等正式 agent)。
- 清掉孤儿 `kind_snapshots` 行:`cc_cust_*`、`cc_orchestrator-*`、`session://...`。
- 打印删了多少。

用途:清理工作机/换机器上已累积的旧 cruft(本机已手动清过一次)。比手敲 SQL 安全可复用。

> 范围判断:该 task 读写 `workspaces` + `kind_snapshots`,属 domain 数据维护工具,放在 customer-chat 插件的 mix 任务里(它最懂 `cc_cust_*` 命名约定),不动 domain 运行时代码。

### 数据流

```
打开会话 → ChatLive :bootstrap
  → ensure_session(创建 session + orchestrator,本次不动)
  → ensure_cc_for_conv
      → ensure_cc_agent
          → Workspace.create_agent(cc, cust_<conv>, per-conv cwd)   # 注册 + spawn
          → Workspace.remove_template(ws, "cc.agent.cc_cust_<conv>") # 注销注册(新增)
          → EagerBridge.ensure_bound!
          → ensure_agent_in_session
server 重启 → Loader.load_all → session_templates 里已无 cc_cust_* → 不重放 → 无风暴
下次打开同会话 → ensure_cc_for_conv 重新创建(幂等;static-soul 模型,不依赖持久恢复)
```

### 错误处理

- `remove_template` 返回 `{:error, :not_found}`(workspace 不存在)或其它 → `Logger.warning`,继续。对话不受影响(注销失败最坏就是退回到「会累积」的旧行为,不是回复失败)。
- `create_agent` 本身失败 → 维持现有逻辑(返回 `{:error, reason}`,ChatLive 重试/报错),本次不改。

## 测试

- **单元测**(`apps/ezagent_plugin_customer_chat/test/...`):
  - `ensure_cc_for_conv` 跑完后,该 workspace 的 `session_templates` **不含** `cc.agent.cc_cust_*`;
  - 且该 agent 仍在 KindRegistry 中存活(注销没杀运行实例)。
- **mix task 测**:对预置了若干 `cc.agent.cc_cust_*` + 孤儿快照的 workspace 跑 gc,断言清空且 `cc_cs_main` 保留。
- **empirical 验收**(浏览器 + 重启):开 3+ 会话 → 重启 server → boot 只重启 `cc_cs_main`(`pgrep` 计数);重启后新开会话仍正常回复。

## 已知遗留 / 后续

- **orphaned `kind_snapshots`**:运行期注销不清快照(只清扫 task 清)。无害(无 boot-spawn 触发),但行会缓慢增长。彻底解决属下方 B。
- **orchestrator/session 累积**:本次不动。验收时确认是否独立造成风暴;若是,写进 B。

## EMPIRICAL 验收结果(2026-05-30,T4)

- ✅ **deregister 生效**:同一 session 开 3 个会话(gcA/gcB/gcC),3 个 cc_cust agent 全部创建+在 KindRegistry 存活,但 `cinnox.session_templates` **只剩** `cc.agent.cc_cs_main`、**0 个 cc_cust**。
- ✅ **回复未坏**:gcA 正常收到 soul 一致的 AI 回复。
- ✅ **gc `run/0` IO 路径**首次真实运行成功:清掉 5 个累积的旧 `cc.agent.cc_cust_*` + 1 个孤儿 `cc_cust_%` 快照,只留 `cc_cs_main`。
- ⚠️ **boot 风暴未完全消除 —— 发现第二条恢复路径(session 成员恢复)**:重启后 boot **仍 spawn 了 gcA、gcB**(它们完成了 `ensure_agent_in_session` 入会),gcC(未完成 join)未被 spawn。即 `session_templates` 路径已修,但**持久化的 per-conversation session 在 boot 恢复其成员 cc agent + orchestrator**——这条路径**和 session_templates 一样无界增长**(每个完成的会话一条 session)。
  - **结论:plugin-local deregister 是必要但不充分的。** 彻底消除需让 per-conversation **session 本身 ephemeral**(不持久化/不在 boot 恢复其成员)——属 domain,归 **B**(见 Allen note)。
  - 对**当前 scope #2 A/B**(2 个并发 agent)够用:不再是 ~10 个的饱和风暴,新会话可正常开。但长期(多会话)仍会经 session 路径累积。

## B — 提给 Allen 的正式修复(不在本次实施)

在 `Ezagent.Workspace.create_agent/3` 引入 `ephemeral: true`(或 `persist: false`)选项:
- 跳过 `Store.update_templates` 写入;
- boot loader 跳过(或临时 agent 根本不进 `session_templates`)。

理由:这是改 **核心/domain 的 agent-create 契约**,按 repo 文化(CLAUDE.md「不要发明新 Decision … 架构决策走 Allen review」)属架构决策。它正好和 G-12 淘汰 `session_templates`、以及 curl/np 的「直接 spawn 不注册」模式合流——临时 agent 应当走类似的非持久路径。本设计的 A 是其插件层的过渡实现。

产出一份给 Allen 的简短 note(问题 + A 的过渡做法 + B 的建议),不自行实施 B。
