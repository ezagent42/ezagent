# 新建 session 超时 + orchestrator 哑掉 —— 根因、契约破坏点、后续方向

> 作者：gaga（黄佳佳）· 2026-07-09
> 基线：`main @ 63877f425`（已 rebase 复核，见 §9）
> 分支：`fix/create-session-no-orchestrator-dep` · 本 PR 只含文档，不含代码改动

---

## 0. TL;DR

canary 上「新建 session 5 秒超时」和「@orchestrator 永不回话」**不是一个 bug，是两个**。它们在 `#1223` 被焊到了一起。

| | bug | 引入提交 | 直接后果 |
|---|---|---|---|
| **链 A** | 创建 session 的事务里 eager spawn cc orchestrator | `#1140` → `#1180` → **`#1223`** | 创建路径上出现跨事务 `:call`，撞破 5s 预算 |
| **链 B** | `Sandbox.activate/2` 在 config_dir 物化之前拉起 PTY | **`#1096`** | claude 无凭证启动 → bridge 永不 join → ReadyGate 永远 `:not_ready` |

- 只有链 B 时（06-30 ~ 07-07）：orchestrator 变哑，但创建不超时（那时 orchestrator 走按需供给）。
- `#1223` 把 orchestrator 从按需车道搬进创建车道 → 链 B 的"永远 `:not_ready`"被拖进 `workspace.create_session` 的 5s 预算 → **超时**。
- 两天后（07-09）canary 报障。

**并且**：链 A 破坏的那条「create session 的事务不应被 create agent 的事务阻塞」的原则，**不是新提议 —— 它是 `#912` 建立的既有契约**，写在 `session_creator.ex` 的 moduledoc 里，还配了一个名叫 `session_create_orchestrator_decouple_test.exs` 的守护测试。`#1223` 把那个测试的断言**反转**了。

---

## 1. 观测到的症状

1. `hello` / `default` 两个模版新建 session 均 ~5.3s 超时，用户可见「创建会话失败」。
   错误签名：`{:create_session_exit, {:timeout, {GenServer, :call, [pid, ...workspace.create_session..., 5000]}}}`
2. 已存在会话里 @orchestrator 无应答（38s 观察窗口内无回复）。
3. `#1252` 发消息回显 18–25ms、`#1257/#1263` 冷启动列表 —— 均正常。

---

## 2. 契约：`#912` 建立了什么

`036ce5401` **#912**（2026-06-23，*"[codex] Decouple session create from orchestrator readiness"*）在 `session_creator.ex:19-39` 写下：

> Rev6 **decouples session creation from orchestrator startup**:
> 1. resolve URI → 2. spawn Session Kind → 3. bind workspace → 4. 记录 template declaration + 装 prompts/legends/rules → 5. **只 join owner**，返回。
>
> **Declared role members are provisioned on first route. Session creation never waits for a transport bridge and never rolls the session back because a role member failed to start.**

这与 Allen 2026-07-09 15:33 说的完全同义：

> 原则是 let-it-crash and fail-fast，通过解耦两边来避免阻塞，**create session 的事务（包括 UI）不应该被 create agent 的事务阻塞**。

### 2.1 按需供给车道是建好并接进路由的

```
Session 路由 {:role, name}
  └─ RoleResolver.resolve/5                 role_resolver.ex:10
       └─ RouteProvisioner.resolve_role/4   route_provisioner.ex:10
            ├─ 活成员里有该 role facet？  → 直接用
            └─ 没有 → 从 member_declarations 取声明
                 └─ TemplateTeam.provision_declared_member/4   template_team.ex:56
```

### 2.2 守护测试

`apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs`

```elixir
test "create_session returns immediately usable session meta without eager orchestrator" do
  assert wait_until(fn ->
    Session.session_member_uris(session_uri)
    |> Enum.map(&URI.to_string/1)
    |> Kernel.==([owner])            # 创建后唯一成员是 owner
  end)
end
```

---

## 3. 契约在哪里被破坏（取证）

| 提交 | 日期 | 作者 | 干了什么 |
|---|---|---|---|
| `e263785f9` **#1140** | 07-03 | Allen Woods (+Opus 4.8) | **破坏规则**：新建 `DefinitionAgents`，在创建路径上 spawn cc agent |
| `bf7db1818` **#1180** | 07-05 | Allen Woods (+codex) | **封死退路**：按需车道对 `fill: :agent` 硬拒绝 |
| `df43253b2` **#1223** | 07-07 | Allen Woods (+claude-agent) | **把 orchestrator 接上创建车道**，并**反转守护测试** |

### 3.1 `#1140` 的 commit message 自陈

> New DefinitionAgents consumer: per declared `%{recipe, role_name}`, resolve recipe by workspace, **spawn a per-session cc agent**, JOIN it as a member …, then GrantRecipeCaps lands the recipe's `requested_caps` LAST. … **Wired into `TemplateTeam.materialize_template_team` (runs on create + repair).**

`materialize_template_team/4` 在 rev6 里本来就在创建路径上，但它只做 moduledoc 第 4 步允许的事（装 prompts / legends / rules）。#1140 把 **spawn + join + grant** 塞进了这个已有的调用点。

### 3.2 `#1180` 用一个 error atom 给回归签名

```elixir
# template_team.ex:72-76
:agent  -> {:error, {:agent_role_slot_materialized_at_session_create, role_name, session_uri}}
"agent" -> {:error, {:agent_role_slot_materialized_at_session_create, role_name, session_uri}}
```

`RouteProvisioner` 再把这个 error **静默吞成 `nil`**（`route_provisioner.ex:44-46` 的 `else -> _ -> nil`）。

### 3.3 `#1223` —— 决定性的一刀

**(a) orchestrator 的声明形态被改变**

```elixir
# #1223 之前 —— legacy member declaration，命中 provision_declared_member 的 `_ ->`
#              fallthrough → ensure_legacy_member_present → 第一次路由时供给
members: [%{role_name: "orchestrator",
            source_template_uri: template://system/agent/cc-orchestrator,
            in_session_template: true}]
installs: ["chat"]

# #1223 之后 —— fill: :agent 角色槽，撞上 #1180 的硬拒绝，
#              改由 DefinitionAgents 在 create 时 eager spawn
members: []
installs: ["chat", "orchestrator"]
```

**(b) 守护测试被反转**

在一个名字叫 `..._decouple_test.exs` 的文件里：

```elixir
- test "create_session returns immediately usable session meta without eager orchestrator" do
-   assert wait_until(fn ->
-     Session.session_member_uris(session_uri) |> Enum.map(&URI.to_string/1) |> Kernel.==([owner])
-   end)
+ test "create_session materializes the default orchestrator Definition" do
+   assert wait_until(fn ->
+     owner in member_uris and match?(%URI{}, member_role_uri(session_uri, "orchestrator"))
+   end)
```

测试从未变红 —— 因为它被重写成了新行为的镜子。

> **契约只存在于一段 moduledoc 和一个测试的断言里，没有 CI gate 兜底。** 三个 PR 都是 agent 协作产出，没有一个读过 `session_creator.ex:19-39` 那 20 行。#1223 甚至改写了那个以 "decouple" 命名的文件而没有停下来。

---

## 4. 链 B：PTY 在 config_dir 物化之前启动（`#1096`）

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

### 4.1 机制

`72ae93a38` **#1096**（06-30，*"fix(autoservice): initialize cc sandbox at create time"*）把 `template_class` + `respawn_template_data` 加进 Agent Kind 的 init args。这两个字段一落进 `Sandbox` 的持久 state，`should_ensure_subprocess?/2`（`sandbox.ex:606`）在 **fresh create** 上就为真 —— `Sandbox.activate/2` 于是走了**本该只给冷重启用的自愈分支**去拉 PTY，而那条分支的前置假设是 config_dir 早已存在。

### 4.2 因果链

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
① grant :call 阻塞满 20s activate budget        ② @orchestrator 永久不回话
   （外层 create_session 5s 预算先炸 → ~5.3s）
```

`start_pty` 把 `{:error, {:already_started, pid}}` 吞成 `{:ok, pid}`（`spawn.ex:497`）—— 这是这套双重启动**从来没人报错**的原因。

---

## 5. 两条链合流的时间线

```
06-23  #912   契约建立 + 守护测试
06-30  #1096  链 B：activate 在 config_dir 物化前拉 PTY          ← orchestrator 开始变哑
07-03  #1140  链 A：创建路径开始 spawn agent（规则被破）
07-05  #1180  链 A：按需车道对 :agent 关闭
07-07  #1223  链 A：orchestrator 接上创建车道 + 守护测试被反转   ← 两条链焊接
07-08  #1259  Allen 在耦合内部给 py 打补丁（provisioning 挪进 activate）
07-09  canary 报障：新建 session 5s 超时 + @orchestrator 哑
```

**#1096 让 orchestrator 变哑；#1223 让"变哑"变成"创建超时"。**

---

## 6. Allen 转来的 handoff 诊断 —— 逐条核对

| 断言 | 核验 | 位置 |
|---|:--:|---|
| `:call` 打到未就绪 Kind 会阻塞在 `ReadyGate.await`，不是 fail-fast | ✅ | `invocation.ex:210-227` |
| activate budget 默认 20s | ✅ | `invocation.ex:48` |
| `imperative_invocation` 硬编码 `mode: :call` | ✅ | `grant.ex:277-287` |
| 两个授权点都打向 agent URI 本身 | ✅ | `grant_recipe_caps.ex:228`；调用点 `definition_agents.ex:174` / `:202` |
| cc 是 transport-gated、py 不是 | ✅ | `spawn.ex:437` |

**诊断全部属实。** 它精确找到了第一个撞破 5s 预算的同步点。

补充两条（均已验证）：

- `grant_cap_via_router/4` 的 `reply_mode: :async` **已经存在**（`grant.ex:121`）。
- `PendingDelivery` 确实 FIFO（`buffer` 用 `current ++ [entry]`，`flush` 按到达序）。

---

## 7. 当前的矛盾点

### 7.1 原则在前，handoff 在后，但 handoff 没有执行原则

时序：

```
15:33  Allen →「原则是 let-it-crash and fail-fast，通过解耦两边来避免阻塞，
                create session 的事务不应该被 create agent 的事务阻塞」
  ↓
稍后    Allen 转 handoff →「用它这版…… gaga 按这版走」
                方案：grant 的 :call 改 :cast
```

| Allen 的原则 | handoff 实际做的 |
|---|---|
| create session 的事务 **不应该被** create agent 的事务阻塞 | 两个事务**仍是同一个**；只把其中一个 dispatch 从 `:call` 换成 `:cast` |
| let-it-crash | grant 失败不再崩、不再回滚，改成 buffer 进 PendingDelivery |
| fail-fast | `:cast` 是 buffer-and-hope；原来的 `:call` 反而会响 |

`:call → :cast` 消除的是**阻塞**，不是**耦合**。

handoff 自己的坑② 就是耦合仍在的证据：

> 「现行授权是 checked（失败→回滚创建），改 :cast 后 drain 时失败必须 log/telemetry，不能静默吞。」

真正解耦之后，"授权失败要不要回滚创建"这个问题**根本不存在** —— 授权不属于创建 session 的事务。

### 7.2 `:cast` 会造出「进了会话但没有 caps 的成员」

现状是 checked 的：授权失败 → `materialize_one` 返回 error → `finalize_fresh_session` 回滚整个 session（`grant_recipe_caps.ex:228-231` 的 `{:halt, {:error, {:grant_failed, ...}}}`）。

改 `:cast` 后顺序变成：

```
spawn agent  →  session.join（成员已在会话里）  →  cast 授权（不等结果）
```

若 drain 时授权失败 —— 或压根不 drain（transport 永不 join → `mark_failed`，见 §8.1）—— 结果是：

> **一个已经 join 进会话、能被路由到、但没有 recipe caps 的 agent。**

它的每次工具调用都会在 CapBAC 被拒。**成员存在性与授权状态被拆成了两个可以各自失败的事务。** Allen 的原则恰恰要求把它们放进**同一个**事务（agent 自己的那个），从而天然原子。

### 7.3 handoff agent 漏掉的两个文件

`session_creator.ex:19-39`（契约）与 `template_team.ex:72-76`（被封的按需车道）。读过这两处的 agent 不会提议 `:cast`，会提议**把 `:agent` 分支打开**。

> **结论：按 handoff 的诊断走，不按它的修法走。** 若 Allen 的意思确实是"就按 `:cast` 合"，需要他明确否掉 15:33 那条原则 —— 两者不能同时成立。

---

## 8. 附带发现（均已核实，独立于上述结论）

### 8.1 `mark_failed` 不 drain PendingDelivery —— `:cast` 方案的静默丢消息洞

| 事实 | 位置 |
|---|---|
| `mark_failed/1` 只翻 ReadyGate，**不 drain PendingDelivery** | `ready_transition.ex:48-51` |
| 全仓只有 `drain_pending_then_mark_ready` 会 flush | `ready_transition.ex:33` |
| `TransportReadiness.await_join` 超时直接 `mark_failed` | `transport_readiness.ex:168` |
| 此后的新 cast 会拿到 `{:error, :failed}`（这条是响的） | `invocation.ex:190` |

```
T0  grant cast   ──▶ PendingDelivery
T1  用户消息      ──▶ PendingDelivery
         …… transport 永远不 join ……
t+30s  mark_failed  ⇒ buffer 烂在 ETS：不投递、不进 DLQ、不打日志
```

等于**把看得见的 5.3s 超时换成看不见的丢消息** —— 撞不变式 #9 与 Decision #67。`#1259` 刚给 `:buffer_full` 接上 DLQ sink，**never-drained 这条从来没接过**。

在 let-it-crash 模型下这条**更**必要，不是更不必要。

### 8.2 三处静默吞咽（fail-fast 原则的直接推论）

- `start_pty` 吞 `{:error, {:already_started, pid}}` → `{:ok, pid}`（`spawn.ex:497`）
- `RouteProvisioner` 的 `else -> _ -> nil`（`route_provisioner.ex:44-46`）
- `Sandbox.activate` 的 `do_ensure_subprocess_alive` 失败仅 log

### 8.3 陈旧注释

`template_spawn.ex:657` 仍写着「`:call` 在这个窗口会 fail-fast（硬不变式 #3）」—— 已被 spec C-A 的 wait-then-serve 推翻，会误导读代码的人。

### 8.4 ⚠️ main 上刚合入的 hello workaround（`#1277`，07-08）

```elixir
# app.ex:118-125 —— 注释原话
# the orchestrator activate times out — skip the requires so the session creates without it.
defp hello_requires do
  if System.get_env("HELLO_NO_ORCHESTRATOR", "1") == "0", do: ["orchestrator"], else: []
end
```

那句 *"the orchestrator activate times out"* 是对 §4 的独立第三方印证。但它埋了三个坑：

**(a) hello 的 `requires` 现在有两个打架的真值源**

| 来源 | `requires` | 何时生效 |
|---|---|---|
| `app.ex hello_requires/0` | `[]`（默认） | 走 `seed_hello_definition` 代码路径 |
| `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml:7-8` | `[orchestrator]` | 走 manifest boot scan |

同一批提交把 `config/config.exs:33` 的 `socialware_manifest_boot_scan` 从 `[:dev, :prod]` 收窄成 `[:prod]`。`Home.SocialwareSeed` 把每个已加载 OTP app 的 `priv/socialware_seed/<name>/` 拷进 deployment home，`ManifestSeed.scan_all!` 再在 prod 扫描导入。于是：

```
dev   : boot scan OFF → 走代码路径 → hello 无 orchestrator   ← 本地"修好了"
prod  : boot scan ON  → 走 manifest → hello 有 orchestrator   ← canary 照样炸
```

**这正是本项目栽过的坑**（见 `orchestrator_prestore_readiness_test` 的 moduledoc：*"the deterministic suite masked it"*）。→ **需在 canary 实测确认最终生效的 Definition。**

**(b) 环境变量语义是反的，且文档写错**

`docs/guide/hello-rebuild-guide.md:62-63` 说 `HELLO_NO_ORCHESTRATOR=0`「(默认)……跳过 orchestrator」。代码默认是 `"1"`，且 `=0` 表示**启用**。第 62 行既与代码相反，也与第 63 行自相矛盾。变量名本身是双重否定。

**(c) `default` 模版完全未被覆盖**

`application.ex:631` 仍是 `installs: ["chat", "orchestrator"]`。LV 新建会话表单默认就是它。**创建 `default` session 依旧必炸。**

---

## 9. rebase 复核

`main` 已从 `96af00d4d` 前进到 `63877f425`。已 rebase，并逐文件核对：

```
$ git diff --stat 96af00d4d..origin/main -- \
    invocation.ex sandbox.ex pending_delivery.ex ready_transition.ex \
    slice_access.ex home_runtime.ex grant.ex transport_readiness.ex \
    definition_agents.ex cc_agent/spawn.ex
(空)
```

**本分析依赖的 10 个文件在新 main 上一行都没动**，§6 表中所有行号在 `63877f425` 上逐一复核仍然精确。

> 我与 handoff 之间的分歧**不是主线版本差造成的**。唯一的主线变化是 §8.4 的 hello workaround —— 它不改变根因，但会改变复现条件。

---

## 10. 后续方向

### 10.1 修复分层

| 层 | 内容 | 修好什么 | 撤销/对应 |
|---|---|---|---|
| **A. 恢复契约** | 从 `materialize_template_team/4` 撤掉 `DefinitionAgents.materialize_definition_agents`；打开 `provision_declared_member/4` 的 `:agent` 分支，把 `materialize_one` 的 spawn→join→grant→MCP-register 搬进按需车道；`hello/app.ex` 里显式调 `materialize_template_team` 处同步改 | create_session 事务里不再有任何 agent 事务。**一刀消灭**创建路径上的 grant `:call`、cp_r、PTY | 撤销 `#1140` 接线 + `#1180` 封堵 + `#1223` 形态变更 |
| **B. agent 事务自己不能重** | `instantiate` 只 spawn Kind 即返回；物化 + role bootstrap + 重校验 grant + 拉 PTY 全在 agent 自己进程/受监督 Task，**且保证 marker 落地后才 `Pty.start`** | 否则 A 只是把 5s 从 Workspace Kind 搬到 Session Kind；且 orchestrator 依然到不了 `:ready` | 修 `#1096` |
| **B'. grant 移进 agent 自己的创建事务** | recipe caps 由 Agent 在自己的 `create/1` 里授予，而非外部 `:call` 打进来 | 跨事务 `:call` 根本不存在，`:cast` 不再需要，§7.2 的「无 caps 成员」不可能发生 | 取代 handoff 的 `:cast` |
| **C. fail-fast 收口** | `mark_failed` flush→DLQ + telemetry；§8.2 三处静默吞咽改 fail-loud；**不引入** durable `last_error` / DEGRADED 降级态 | 崩得响，不静默 | 按 Allen 原则修正我早先方案 |

**A 与 B 正交，必须都做。**
只做 A：创建秒回、发消息卡 5s、orchestrator 永远哑。
只做 B：创建变快（~1s），但 session 事务仍会因一个 role member 起不来而回滚 —— 依然违反契约。

### 10.2 failing-first 测试

1. **A**：恢复 `session_create_orchestrator_decouple_test.exs` 的 `#912` 原始断言（"创建后唯一成员是 owner"）—— 这条测试直接就是 A 的 failing-first。
2. **B**：fresh instantiate 时 `Pty.start` 必须发生在 config_dir marker 落地之后。确定性、与 `Mix.env()` 无关（`require_transport_join` 在 test 被跳过，但顺序断言不依赖它）。
3. **C**：`mark_failed` 后 buffer 必须清空并出现在 DLQ + telemetry。

### 10.3 建议新增的 CI gate

契约目前只存在于 moduledoc 和一个测试断言里，被 agent 反转了都没人发现。建议加不变式 gate：

> **`create_session` 返回后，`Session.session_member_uris/1` 只能包含 owner。**

放进 `mix ezagent.check_invariants`，下次再有人（或 agent）把 spawn 塞进创建路径，CI 会红。

### 10.4 需要 Allen 拍板的两点

1. **按需供给发生在 Session Kind 的 handler 内部**（`RouteProvisioner.resolve_role/4` 跑在 Session 的 action handler 里，`Process.put` 攒 effects）。即便 B 让它只剩 `Kind.spawn` + `join`（cc 因 transport-gated，`do_await_ready` 仍会烧满 `spawn_await_ready_ms` 500ms），这仍是"session 的事务里嵌了一小段 agent 的事务"。
   **这算不算"解耦"的完成态？** 还是 `resolve_role` 找不到活成员时应只 buffer 到声明里的 planned URI，由独立的受监督 materializer 去 spawn，Session Kind 一步都不等？—— 这决定 B 的边界。
2. **§7 的矛盾如何裁决**：确认「按 handoff 的诊断走、不按其修法走」，还是明确否掉 15:33 的原则。

### 10.5 PR 归属建议

- **A + C** ：需要 Allen 先答 10.4.1（边界）。
- **B**：可独立开工，与 A 无文件冲突（`cc_agent/spawn.ex` vs `definition_agents.ex` / `template_team.ex`）。
- **§8.4 hello workaround 收敛**：单独开 PR，不要塞进热修。
- 注意 07-09 群里 `@陈瑞华 @张宁 你们的 PR 可以走一个 review 直接合并进去` —— 若那些 PR 触及 `definition_agents.ex` / `template_team.ex` / `session_creator.ex`，A 会撞车，需先确认。

---

## 附录：复现方法

`:dbg` 探针，trace 三个函数并在每个事件触发时快照 config_dir 的 `dir?/marker?/creds?`：

```elixir
:dbg.tpl(Ezagent.Domain.Pty, :start, 2, [])
:dbg.tpl(Ezagent.Credential.HomeRuntime, :create_agent_config_dir, 4, [])
:dbg.tpl(Ezagent.PluginCc.Template.SpawnPlan, :build_pty_params, 4, [])
```

然后跑一次 `CcAgent.instantiate("cc.agent", tmpl, workspace_uri)`。

`tmpl` 必须显式携带 `"allocated_config_dir"`（prod 由 `Kind.Template.provision_and_instantiate/4` 注入；缺了它 `resolve_config_home` 走不到 realized 分支，观测不到真实路径）。除 Postgres 外无任何外部依赖。
