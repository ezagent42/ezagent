# 创建 session 超时 + orchestrator 哑掉 —— 根因调查

> 作者：gaga（黄佳佳）· 2026-07-09
> 基线：`main @ 63877f425`（已 rebase 复核，见 §6）
> 分支：`fix/create-session-no-orchestrator-dep`

---

## 0. 一句话

Allen 转来的那版根因（grant `:call` 打在未就绪的 cc agent 上）**逐条核过，全部属实**。但结尾那句"@orchestrator 38s 无回复……和创建延迟是两码事"要更正 —— **它们是同一条因果链的两端**。那个被标为"仍需单独暴露"的 bug 已经用 `:dbg` 探针钉死了：**cc-orchestrator 的 `claude` 进程是在自己的凭证落盘之前 10ms 被启动的**，所以它永远到不了 `:ready`。

因此：**grant 改 `:cast` 是必要的，但单独上线后创建会秒回、orchestrator 会永久性地冷着。**

---

## 1. 对 Allen 那版的核对结果

| 断言 | 核验 | 位置 |
|---|:--:|---|
| `:call` 打到未就绪 Kind 会阻塞在 `ReadyGate.await`，不是 fail-fast | ✅ | `invocation.ex:210-227` |
| activate budget 默认 20s | ✅ | `invocation.ex:48` |
| `imperative_invocation` 硬编码 `mode: :call` | ✅ | `grant.ex:277-287` |
| 两个授权点都打向 agent URI 本身 | ✅ | `grant_recipe_caps.ex:228`；调用点 `definition_agents.ex:174` / `:202` |
| cc 是 transport-gated、py 不是 | ✅ | `spawn.ex:437` |

**两条对方案有利的补充**（均已验证）：

- `grant_cap_via_router/4` 的 `reply_mode: :async` **已经存在**（`grant.ex:121`）—— 不需要新造 API。
- `PendingDelivery` 确实是 FIFO（`buffer` 用 `current ++ [entry]`，`flush` 按到达序）—— "T0 授 cap 排在 T1 用户消息之前"的顺序义务真的成立。

**一条陈旧注释建议顺手清掉**：`template_spawn.ex:657` 仍写着「`:call` 在这个窗口会 fail-fast（硬不变式 #3）」，该行为已被 spec C-A 的 wait-then-serve 推翻，会误导读代码的人。

---

## 2. 新证据：orchestrator 为什么根本到不了 `:ready`

带上 prod 才有的 `allocated_config_dir` 跑 `:dbg` 探针，在每个事件触发的**那一刻**快照 config_dir 状态：

```
t+0.0ms   PID<0.851>  ← Agent Kind 自己 (activate)
            build_pty_params      dir?=true  marker?=false  creds?=false
t+0.2ms   PID<0.851>
            Pty.start             dir?=true  marker?=false  creds?=false   ← claude 起来了，没凭证
t+10.4ms  PID<0.845>  ← 创建路径
            create_agent_config_dir                                        ← 这才开始物化
t+24.2ms  PID<0.845>
            build_pty_params      dir?=true  marker?=true   creds?=true
t+24.3ms  PID<0.845>
            Pty.start             （被 already_started 静默吞掉）
```

### 2.1 怎么来的

`#1096 fix(autoservice): initialize cc sandbox at create time`（`72ae93a38`，6/30）把 `template_class` + `respawn_template_data` 加进了 Agent Kind 的 init args。这两个字段一落进 `Sandbox` 的持久 state，`should_ensure_subprocess?/2`（`sandbox.ex:606`）在 **fresh create** 上就为真 —— 于是 `Sandbox.activate/2` 走了**本该只给冷重启用的自愈分支**去拉 PTY，而那条分支的前置假设是 config_dir 早已存在。

### 2.2 完整因果链

```
#1096 init args (template_class + respawn_template_data)
      │
      ▼
Sandbox.activate/2 : should_ensure_subprocess? = true   ← fresh create 也命中
      │
      ▼
ensure_subprocess_alive → ensure_pty_server → Pty.start
      │                                   ↑
      │              CLAUDE_CONFIG_DIR = 只有 .claude.json 的空目录
      ▼              （无 .credentials.json，无 .ezagent-config-complete）
claude 启动，无凭证
      │
      │  ……10ms 后，创建路径并行地：
      │  create_agent_config_dir → marker 不存在 → stage_and_swap
      │  → atomic_replace → File.rename(target, bak)
      │  ⇒ 把正在运行的 claude 脚下的目录整个换走
      ▼
esr-bridge 永远不 join
      │
      ▼
require_transport_join 永不满足  →  ReadyGate 卡死 :not_ready
      │                                        │
      │                                        └─→ 30s 后 mark_failed
      ▼
① grant :call 阻塞满 20s activate budget        ② 已存在会话 @orchestrator 永久不回话
   （外层 create_session 5s 预算先炸
     → 观测到的 ~5.3s 超时）
```

而 `start_pty` 把 `{:error, {:already_started, pid}}` 吞成 `{:ok, pid}`（`spawn.ex:497`）—— 这就是为什么这一整套双重启动**从来没有人报过错**。

### 2.3 对结论的影响

grant `:call` 确实是第一个撞破 5s 预算的同步点（Allen 那版是对的），但它之所以撞得这么死、而不是等 4-6s 就放行，正是因为 **transport join 压根不会来**。同一个原因也直接解释了已存在会话里 @orchestrator 38 秒无应答。

> **只上 grant `:cast` 就宣布修好，会重演"没先线上复现就宣布"的那个错误** —— canary 上创建秒回，orchestrator 依然哑。这正是 #1259 review 里担心的僵尸成员，只是原因不在 grant 上。

---

## 3. `:cast` 方案上有一个会静默吃消息的洞

| 事实 | 位置 |
|---|---|
| `mark_failed/1` 只翻 ReadyGate，**不 drain PendingDelivery** | `ready_transition.ex:48-51` |
| 全仓只有 `drain_pending_then_mark_ready` 会 flush | `ready_transition.ex:33` |
| `TransportReadiness.await_join` 超时直接 `mark_failed` | `transport_readiness.ex:168` |
| 此后的新 cast 会拿到 `{:error, :failed}`（这条是响的） | `invocation.ex:190` |

按当前部署走一遍 `:cast` 方案：

```
T0  grant cast   ──▶ PendingDelivery
T1  用户消息      ──▶ PendingDelivery
         …… transport 永远不 join ……
t+30s  mark_failed  ⇒ buffer 烂在 ETS：不投递、不进 DLQ、不打日志
```

等于**把一个看得见的 5.3s 超时，换成看不见的丢消息** —— 撞不变式 #9 与 Decision #67。#1259 刚给 `:buffer_full` 接上 DLQ sink，**never-drained 这条从来没接过**。

Allen 的坑② 只堵住了「drain 时失败」，没堵住「永远不 drain」。`mark_failed` 必须对称地 flush→DLQ + telemetry。

---

## 4. 对坑① 的修正，以及一条设计约束

**坑①（test-mode 陷阱）**：`require_transport_join` 在 `Mix.env() == :test` 被跳过，所以朴素 cc 测试不会阻塞。

- 对 **grant 那条**：同意，failing-first 必须人为把成员按在 `:not_ready`。
- 对 **PTY 早产这条：不需要。** 顺序断言（`Pty.start` 不得早于 config-dir marker 落地）是确定性的、与 `Mix.env()` 无关。§2 那个探针可以直接转成回归测试，比 arm 一个没有 joiner 的假 gate 稳得多。

**设计约束（会坑到 PR-2）**：**不能把 `cp_r` 原地挪进 `activate`**。`activate` 跑在 Kind 的 `handle_continue` 里，而创建路径紧接着的 `template_spawn.record_sandbox_state` → `Kind.get_slice` 是 `GenServer.call(pid, …, 5_000)`（`slice_access.ex:66`），会被堵满 5s。物化必须交给受监督的 Task，Kind 本身保持可响应。

---

## 5. ⚠️ 主线上刚合进一个**掩盖症状**的 workaround

`feat/hello-0709`（#1277，昨天合入 main）新增了 `hello_requires/0`：

```elixir
# apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:118-125
# ... the orchestrator activate times out — skip the requires so the session
# creates without it. Set HELLO_NO_ORCHESTRATOR=0 to force-enable.
defp hello_requires do
  if System.get_env("HELLO_NO_ORCHESTRATOR", "1") == "0", do: ["orchestrator"], else: []
end
```

注释里那句 **"the orchestrator activate times out"** 是对 §2 根因的独立第三方印证。但它带来三个问题：

### 5.1 hello 的 `requires` 现在有两个互相打架的真值源

| 来源 | `requires` | 何时生效 |
|---|---|---|
| `app.ex hello_requires/0` | `[]`（默认） | 走 `seed_hello_definition` 代码路径时 |
| `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml:7-8` | `[orchestrator]` | 走 manifest boot scan 时 |

而同一批提交把 `config/config.exs:33` 的 `socialware_manifest_boot_scan` 从 `config_env() in [:dev, :prod]` **收窄成 `[:prod]`**。

`Ezagent.Home.SocialwareSeed` 会把每个已加载 OTP app 的 `priv/socialware_seed/<name>/` 拷进 deployment home，`ManifestSeed.scan_all!` 再在 prod 扫描导入。于是：

```
dev   : boot scan OFF → 走代码路径 → hello 无 orchestrator  ← 本地"修好了"
prod  : boot scan ON  → 走 manifest → hello 有 orchestrator  ← canary 照样炸
```

**这正是本项目栽过的那个坑**（见 `orchestrator_prestore_readiness_test` 的 moduledoc：「deterministic suite masked it」）。
→ **需要在 canary 上实测确认最终生效的 Definition 到底带不带 orchestrator。**

### 5.2 环境变量语义是反的，而且文档写错了

`docs/guide/hello-rebuild-guide.md:62-63`：

> - **`HELLO_NO_ORCHESTRATOR=0`**(默认)——本地 dev 跳过 platform cc orchestrator
> - 部署到有 cc 的环境时，设 `HELLO_NO_ORCHESTRATOR=0` …… 来启用

代码里默认值是 `"1"`，且 `=0` 的含义是**启用** orchestrator。所以：第 62 行既与代码相反，也与第 63 行自相矛盾。变量名本身是双重否定（`NO_ORCHESTRATOR=0` 表示"要 orchestrator"），建议改名或反转。

### 5.3 `default` 模版完全没被覆盖

`application.ex:631` 的 `default` SessionTemplate 仍是 `installs: ["chat", "orchestrator"]`。LV 新建会话表单默认就是它。**所以创建 `default` session 依旧必炸**，与 hello 的 workaround 无关。

---

## 6. rebase 复核（回答"是不是主线不一致造成的出入"）

`main` 已从 `96af00d4d` 前进到 `63877f425`。已 rebase，并逐文件核对：

```
$ git diff --stat 96af00d4d..origin/main -- \
    invocation.ex sandbox.ex pending_delivery.ex ready_transition.ex \
    slice_access.ex home_runtime.ex grant.ex transport_readiness.ex \
    definition_agents.ex cc_agent/spawn.ex
(空)
```

**本次分析所依赖的 10 个文件在新 main 上一行都没动**，§1 表中所有行号在 `63877f425` 上逐一复核仍然精确。

> 结论：我与 Allen 那版之间的"出入"**不是主线版本差造成的**，两份分析互相补充、不冲突。
> 唯一的主线变化是 §5 的 hello workaround —— 它不改变根因，但会改变复现条件。

---

## 7. 建议的落地拆分

| PR | 内容 | 修好什么 | 归属 |
|---|---|---|---|
| **PR-1** | `definition_agents.ex:174` / `:202` 改走 `grant_cap_via_router(…, :async)`；drain 时失败 log + telemetry | 创建立即返回 | Allen 那条线 |
| **PR-2** | cc provisioning 单点收口：`instantiate` 只 spawn Kind 即返回；物化 + role bootstrap + 重校验 grant + 拉 PTY 全部交给 activate 里起的**受监督 Task**，保证 marker 落地后才 `Pty.start`；`start_pty` 的 `already_started` 吞咽改 fail-loud | **orchestrator 真的能暖起来** | gaga |
| **PR-3** | `mark_failed` flush→DLQ + telemetry（可折进 PR-1） | PR-1 的安全前提 | 谁先到谁做 |
| **PR-4** | 收敛 hello `requires` 单一真值源 + 修正 guide 的反向文档；`default` 模版不受 workaround 覆盖，需一并验 | 防止 dev 绿 / canary 红 | 待定 |

PR-1 与 PR-2 无文件冲突，可并行。

### 验收标准（**两条必须同时满足**，缺一不算修好）

1. 带 cc orchestrator 的 `create_session` **< 1s 返回**；
2. 该 orchestrator 在健康路径上**确实翻到 `:ready`**，且首条用户消息 drain 后拿到回复。

第 2 条必须在 canary 上实测，不能只看 CI —— 见 §5.1。

---

## 8. 待 Allen 拍板

1. **`start_pty` 吞 `{:error, {:already_started, pid}}` → `{:ok, pid}`**（`spawn.ex:497`）：修完早产竞态后，正常路径不该再撞上 `already_started`，这个吞咽只剩掩码作用。我倾向改成 fail-loud，但它动的是 cc create chokepoint 的返回契约（codex 反复 review 过），按 grill 约定先问一句。
2. **PR 归属**：默认我接 PR-2 + PR-3，PR-1 留给你那条线。要我三条全接也行。
3. **§5 的 hello workaround** 是否要求作者回滚 / 收敛真值源？我倾向 PR-4 单独开，不要塞进热修。

---

## 附：复现方法

`:dbg` 探针（trace `Pty.start/2`、`HomeRuntime.create_agent_config_dir/4`、`SpawnPlan.build_pty_params/4`，并在每个事件触发时快照 config_dir 的 `dir?/marker?/creds?`），跑一次 `CcAgent.instantiate/3`，`allocated_config_dir` 必须显式传入以模拟 prod（由 `Kind.Template.provision_and_instantiate/4` 注入）。无需 DB 以外的任何外部依赖。
