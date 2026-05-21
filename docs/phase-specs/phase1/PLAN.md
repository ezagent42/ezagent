# Phase 1 — PLAN

> 任务清单。`SPEC.md` 定义"做什么",`VERIFICATION.md` 是验收契约,本文件定义"按什么顺序做"。
> Phase 1 是 2 sub-step(1a / 1b),1a 内部细化成 6 个 PLAN step,每步一次 commit。
> 实施由 `/goal` 驱动,/goal 走 self-motivated skill(详见本 phase 末尾「`/goal` 触发」段)。

## 实施 conventions

- **每个 PLAN step 一次 commit**,commit message 形如 `phase1a step <N>: <subject>`(eg `phase1a step 1: ETS primitives + Capability struct + User stub`)
- **每个 sub-step 末尾打 tag**(`phase1a` / `phase1b`)— 在 VERIFICATION 全绿之后
- **sub-step-gate.sh PreToolUse hook 在 commit/tag 时 fire**,跑 `mix format --check` + `mix test`(Phase 1 期把 `mix ezagent.check_invariants` 也加进 gate)
- **撞墙处理**:any step 的 e2e gate 红 / 不变式违反 → `/goal` 自动暂停;不要绕过、不要 silent 修复绕过条款
- **每个 step 完成前自查**:VERIFICATION.md 列的相关 grep + checkbox。Phase 0 教训:checklist 跑过才能 tag,不是「应该绿」就 tag

## 1a 内部 6 个 PLAN step

### 1a-step 1 · 基础模块(ETS primitives + 数据类型)

**目标**: 5 个 ETS-backed primitive + 1 个数据类型模块 + 1 个 stub Kind 模块,各自独立单测全绿。零业务依赖。

**文件**(在 `apps/ezagent_core/lib/esr/`,部分在 `apps/ezagent_plugin_echo/lib/`):

- `ready_gate.ex`:ETS table `:ezagent_ready_gate`(set),`put/2`(`:ready`/`:not_ready`)、`status/1`、`mark_ready/1`
- `pending_delivery.ex`:ETS table `:ezagent_pending_delivery`(set),value 是 list,bounded 100/URI(overflow → DLQ),`buffer/2` + `flush/1`
- `idempotency.ex`:ETS table `:ezagent_idempotency`(set),bounded LRU 10k,`seen?/1` + `record/1`(`Ezagent.Idempotency.Sweeper` GenServer 周期 prune)
- `kind_registry.ex`:thin wrapper over stdlib `Registry`(borrow 老 `Ezagent.Entity.Registry` pattern,改 URI-keyed),`put_new/2` + `lookup/1` + `list_all/0`
- `behavior_registry.ex`:裸 ETS table `:ezagent_behavior_registry`(set),`register/3({kind, action, behavior_module})` + `lookup/2({kind, action})`
- `capability.ex`:`%Ezagent.Capability{}` struct(5 字段:kind/behavior/instance/granted_by/granted_at)+ `matches?/2`(纯函数,Phase 3d 才被 dispatch 调)+ `revoke/2`(admin-protected 守门,Decision #81)
- **`apps/ezagent_plugin_echo/lib/esr/entity/user.ex`** OR **`apps/ezagent_core/lib/esr/entity/user.ex`**(待 step-1 实施决定):`Ezagent.Entity.User` stub —— `@behaviour Ezagent.Kind`,`type_name/0` `:user`,`behaviors/0` `[]`,`persistence/0` `{:snapshot, :on_change}`,**外加** `admin_uri/0` 返回 `URI.parse("user://admin")` 和 `admin_caps/0` 返回 MapSet of `%Capability{kind: :any, behavior: :any, instance: :any, granted_by: URI.parse("system://bootstrap"), granted_at: <static>}`

**Application 接线**(在 `apps/ezagent_core/lib/ezagent_core/application.ex` 的 children):
- ETS table owners(可以是 `:ets.new` from a single bootstrap Task,或几个小 GenServer 各管一张表 — 实施时决定;**建议**:用 `Ezagent.Core.EtsOwner` 单 GenServer 持所有 ETS table 的 lifecycle,简单)
- `{Registry, keys: :unique, name: Ezagent.KindRegistry}` for stdlib Registry
- `Ezagent.Idempotency.Sweeper` GenServer

**单测**:
- ReadyGate / PendingDelivery / Idempotency / KindRegistry / BehaviorRegistry 各自 ~20-40 行 unit test
- `Ezagent.Capability.matches?/2` 各种 wildcard 组合(`:any` for kind / behavior / instance);`revoke/2` 拒绝 admin all-caps(返回 `{:error, :cannot_revoke_admin}`)
- `Ezagent.Entity.User.admin_caps/0` 返回 MapSet 含 :any/:any/:any 那一条

**commit message**: `phase1a step 1: ETS primitives + Capability + User stub`

---

### 1a-step 2 · Dispatch 主路径

**目标**: `Ezagent.Invocation.dispatch/1` 完整可调用,Echo Kind 还没接入(下 step),但 dispatch 路径已经能 mock 一个 Kind 跑通完整 7-step。

**文件**:
- `uri.ex`:`Ezagent.URI.parse/1`、`Ezagent.URI.SchemeRegistry`(`agent://` / `user://` / `session://` / `resource://` schemes)
- `invocation.ex`:`%Ezagent.Invocation{}` struct(target / mode / args / ctx) + `dispatch/1`(Appendix A 12 步:parse URI → arg validate → idempotency → ReadyGate routing → KindRegistry lookup → GenServer.call/cast → ... → reply)+ `reply/2`(7-case reply 表)
- `interface_validator.ex`:`validate/2(@interface, args)` 递归校验(基础类型 `:string` `:integer` `:boolean` `:atom` `:map` + 组合 `{:list, ty}` `{:tuple, ts}` `{:option, ty}` `%{field => ty}`)
- `behavior.ex`:`@behaviour Ezagent.Behavior` callback 契约(`actions/0`、`state_slice/0`、`init_slice/1`、`invoke/4`)
- `kind.ex`:`@behaviour Ezagent.Kind` callback 契约(`type_name/0`、`behaviors/0`、`persistence/0`、可选 `uri_from_args/1`)
- `kind/server.ex`:**共享** `Ezagent.Kind.Server` GenServer(Y option,不是宏)。`start_link({kind_module, args})`、`init/1`(load_or_init → KindRegistry.put_new → ReadyGate.put :not_ready → subscribe topics → handle_continue :announce_ready)、`handle_continue(:announce_ready, ...)`(ReadyGate.mark_ready + PendingDelivery.flush)、`handle_call({:dispatch, inv}, ...)` + `handle_cast({:dispatch, inv}, ...)` 全部 delegate to `Ezagent.Kind.Runtime.handle_dispatch/3`
- `kind/runtime.ex`:`handle_dispatch(inv, server_state, kind_module)` 实现 Appendix A step 5-10:`BehaviorRegistry.lookup({kind_module, action})` → `authz_check/2` stub(永远 `:ok` + emit `[:ezagent, :authz, :stub_grant]` + `PHASE-3D-STUB: DO NOT REMOVE` 注释)→ slice = state[behavior.state_slice()] → behavior.invoke(...) → put_in state → emit `[:ezagent, :invoke, :stop]` telemetry → return result

**单测**:
- `Ezagent.Invocation.dispatch/1`:用一个 mock Kind(test helper)cover 五种 case(:ready / :not_ready+:cast → buffer / :not_ready+:call → fail-fast / :unknown / cap stub grant)
- `Ezagent.Kind.Server` lifecycle(`init` → `handle_continue` → `handle_call`)用 ExUnit 的 GenServer test
- `Ezagent.InterfaceValidator` 各种 type spec corner case

**commit message**: `phase1a step 2: dispatch + Kind.Server + InterfaceValidator + authz stub`

---

### 1a-step 3 · Audit + DLQ + Persistence 骨架

**目标**: telemetry → audit → SQLite 闭环;DLQ 落库;Snapshot helper 骨架(Phase 1 ephemeral 不调,但接口在位)。

**文件**:
- `telemetry.ex`:event 命名 helper(`Ezagent.Telemetry.invoke_start/2`、`invoke_stop/3`、`authz_denied/2` 等)— 跟老 esr `[:ezagent, area, verb]` convention 对齐
- `audit.ex`:`Ezagent.Audit` 模块,boot 时 `:telemetry.attach("esr-audit", [:ezagent, :invoke, :stop], &handle_event/4, nil)`;handler 内 fan-out 两路:① `Phoenix.PubSub.broadcast(Ezagent.PubSub, "esr:audit:stream", {:audit_event, event})`(给 LV);② `GenServer.cast(Ezagent.Audit.Writer, {:write, event})`(给 SQLite)
- `audit/writer.ex`:GenServer,state 持 batch list,`handle_cast({:write, _})` append + 检查 batch ≥ 500 / mailbox 阻塞;timer 每 100ms 触发 flush via `handle_info(:flush, ...)` → `Ezagent.Repo.insert_all(invocations, batch)`;mailbox > 10k 时切 sync call 做 backpressure
- `dlq.ex`:`Ezagent.DLQ` 模块,`put(reason, payload)` → `Ezagent.Repo.insert(dlq, ...)`;reason 枚举(`:behavior_exception` / `:unroutable` / `:no_actor` / `:idempotency_duplicate_marker`);bounded 10k,oldest evict via Sweeper(借鉴 Idempotency.Sweeper pattern)
- `kind/snapshot.ex`:`Ezagent.Kind.Snapshot.load_or_init(uri, kind_module)` → query `kind_snapshots` table by uri → ok? return state : call `init_state_from_behaviors(kind_module)`;`maybe_save(uri, kind_type, old_state, new_state, persistence)` → 只在 `:on_change` 且 `new_state != old_state` 时 insert/update。**Phase 1 Echo 是 `:ephemeral`,maybe_save 走 no-op 分支;但接口完整,Phase 3 直接用**

**Ecto migrations**:
- `invocations` 表(per ARCHITECTURE §10.2 schema):trace_id / caller / target / action / args(JSON) / result(JSON) / duration_us / authz / exception / inserted_at + 两个 index
- `dlq` 表:reason / payload(JSON) / inserted_at + index on inserted_at
- `kind_snapshots` 表(per §10.1):uri PK / kind_type / state(JSON) / version / updated_at

**Application 接线**:
- `Ezagent.Audit.Writer` GenServer 进 children
- `Ezagent.DLQ.Sweeper` GenServer 进 children
- `Ezagent.Audit.attach/0` 在 `Ezagent.Application.start/2` 调用(挂 telemetry handler)

**单测 + 集成**:
- `Ezagent.Audit.Writer` GenServer 单测:batch flush 触发 + backpressure
- `Ezagent.DLQ.put` 集成测:写后 SQL 查得到
- `Ezagent.Kind.Snapshot.load_or_init` 集成测:有/无 snapshot 两路 + `maybe_save` `:on_change` 不变时不写

**commit message**: `phase1a step 3: Audit + DLQ + Snapshot 骨架 + SQLite migrations`

---

### 1a-step 4 · Echo plugin + Application 接线

**目标**: dispatch 路径在 `mix test` 里跑通 F1 直接 invoke(不经 LiveView,纯 ExUnit)。**PLAN-内部 checkpoint**。

**文件**:
- `apps/ezagent_plugin_echo/`:新 OTP app
  - `mix.exs`:依赖 `ezagent_core`(`in_umbrella: true`)
  - `lib/ezagent_plugin_echo/application.ex`:`Application.start/2` 注册 `Ezagent.Entity.Echo`(KindRegistry 的 type registration)、`Ezagent.Behavior.Echo`(BehaviorRegistry.register({Ezagent.Entity.Echo, :say}, Ezagent.Behavior.Echo))、起一个 `Ezagent.Entity.Echo.Supervisor` 子 DynamicSupervisor;启动时 spawn 一个 `Ezagent.Kind.Server.start_link({Ezagent.Entity.Echo, %{uri: URI.parse("agent://echo")}})` 当 default echo 实例(URI `agent://echo`,常驻)
  - `lib/esr/entity/echo.ex`:`Ezagent.Entity.Echo` Kind callbacks(`type_name :echo` / `behaviors [Ezagent.Behavior.Echo]` / `persistence :ephemeral`)
  - `lib/esr/behavior/echo.ex`:`Ezagent.Behavior.Echo` Behavior(`@interface %{say: %{args: %{msg: :string}, returns: %{echo: :string}, modes: [:call]}}`、`actions [:say]`、`state_slice :echo`、`init_slice _ -> %{count: 0}`、`invoke(:say, slice, %{msg: m}, _ctx) -> {:ok, %{slice | count: slice.count + 1}, %{echo: m}}`)

**Umbrella `apps/` 注册**:确认 `mix.exs` umbrella root 把 `ezagent_plugin_echo` 包括进 children;`config/config.exs` 不需要为 ezagent_plugin_echo 加东西(用 Application.spec :env 发现机制)

**集成测**:F1 in pure ExUnit(`test/integration/f1_direct_invoke_test.exs`):
```elixir
test "F1: dispatch echo invocation, get reply, see audit" do
  invocation = %Ezagent.Invocation{
    target: URI.parse("agent://echo/behavior/echo/say"),
    mode: :call, args: %{msg: "hello"},
    ctx: %{caller: Ezagent.Entity.User.admin_uri(),
           caps: Ezagent.Entity.User.admin_caps(),
           reply: {:caller_inbox, self()}}
  }
  assert {:ok, %{echo: "hello"}} = Ezagent.Invocation.dispatch(invocation)
  # 等 audit batch flush(100ms)
  Process.sleep(150)
  # 查 invocations 表
  rows = Ezagent.Repo.all(from i in "invocations", select: {i.target, i.authz})
  assert Enum.any?(rows, fn {target, authz} -> target =~ "agent://echo" and authz == "stub_grant" end)
end
```

**PLAN-内部 checkpoint**(/goal 在这里 commit 后**短暂自检**):
```bash
mix test test/integration/f1_direct_invoke_test.exs
# 应 1 pass 0 failures
```
绿了才进 step 5。

**commit message**: `phase1a step 4: ezagent_plugin_echo + F1 direct invoke (PLAN-internal checkpoint)`

---

### 1a-step 5 · `ezagent_web_liveview` plugin

**目标**: LiveView `/admin` 真实加载,可以从浏览器触发 dispatch + 看 audit log 实时流。**还没 e2e 浏览器测**(下 step)。

**文件**:
- `apps/ezagent_web_liveview/`:新 OTP app
  - `mix.exs`:依赖 `ezagent_core` + `ezagent_web` + `phoenix_live_view`
  - `lib/ezagent_web_liveview/application.ex`:可能不需要,因为 LV 本身是 ezagent_web router 调用的;但需要 plug into ezagent_web 的 router(`apps/ezagent_web/lib/ezagent_web/router.ex` 加 `live "/admin", EzagentWebLiveview.AdminLive`)
  - `lib/ezagent_web_liveview/admin_live.ex`:`AdminLive` LiveView
    - `mount/3`:`if connected?(socket), do: PubSub.subscribe(Ezagent.PubSub, "esr:audit:stream")`;`socket = stream(socket, :invocations, [], limit: 50)`;`assign(socket, :caller, Ezagent.Entity.User.admin_uri())`
    - `handle_info({:audit_event, event}, socket)`:`stream_insert(socket, :invocations, event, at: 0)`
    - `handle_event("echo_test", _, socket)`:dispatch a Echo say invocation via `Ezagent.Invocation.dispatch/1`,reply 经 audit 流回 LV
    - `handle_event("manual_dispatch", %{"target" => t, "args" => a_json, "mode" => m}, socket)`:parse args JSON,构造 Invocation,dispatch;失败 flash 错误
    - `render/1`:`~H""" ... <Layouts.app flash={@flash}> <div> <h1>Admin</h1> <.button phx-click="echo_test">Echo 测试</.button> <.form ...> ... </.form> <table id="invocations" phx-update="stream"><tbody>... for invocation in @streams.invocations end ...</tbody></table> </div> </Layouts.app> """`

**Router**:在 `apps/ezagent_web/lib/ezagent_web/router.ex` 加:
```elixir
scope "/", EzagentWebLiveview do
  pipe_through :browser
  live "/admin", AdminLive
end
```

**单测**:`EzagentWebLiveview.AdminLiveTest` 用 `Phoenix.LiveViewTest`:
```elixir
test "Echo button triggers dispatch and audit stream updates", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/admin")
  lv |> element("button", "Echo") |> render_click()
  # 等 telemetry → PubSub → LV handle_info
  assert render(lv) =~ "agent://echo"
end
```

**commit message**: `phase1a step 5: ezagent_web_liveview /admin (LiveView with stream + form + Echo button)`

---

### 1a-step 6 · F1 via LiveView 浏览器 verify(sub-step gate)

**目标**: 完整执行 `VERIFICATION.md` 1a-G4 的 6 个 agent-browser steps,全绿后 tag `phase1a`。

**步骤**(/goal 跑):

1. `mix phx.server` 启动(background),等 `/_health` 返回 200
2. 执行 `VERIFICATION.md` 1a-G4 的 step 1-6(agent-browser open / snapshot / click / paste 文本 / screenshot / SQLite SELECT)
3. 把 `/tmp/phase1a-final.png` screenshot 也提交进 git(or 至少在 docs/phase-specs/phase1/artifacts/ 留一份)
4. 跑 `VERIFICATION.md` 1a-G1(结构 + compile + test) + 1a-G2(grep checklist) + 1a-G3(`mix ezagent.check_invariants`)
5. 全绿 → `git commit -m "phase1a step 6: 1a sub-step gate verified" && git tag phase1a`

**注意:`sub-step-gate.sh` PreToolUse hook 在 commit/tag 时会自动 fire,跑 `mix test` + `mix format --check`。Phase 1 期 update hook 加 `mix ezagent.check_invariants` 调用(也作为 step 6 的小子任务)。**

**commit message**: `phase1a step 6: 1a sub-step gate verified + agent-browser F1 screenshot`

---

## 1b 序列(线性)— REV REAL CC (2026-05-15)

> 历史:初版 spec 让我 spawn Python echo bridge + 标 `_v1_prototype`,事实上没接真 claude(memory `feedback_completion_requires_invariant_test`)。Allen 反问"怎么知道成功链接了呢?",roll back tag,重写为真 CC 集成。**架构 reference 是 cc-openclaw,不是老 esr 的 Phoenix Channel WS pattern**。

1. **Python MCP+channel server**:`apps/ezagent_plugin_cc_bridge_v1_prototype/python/esr_mcp_bridge_v1_prototype.py`,~225 LOC。`capabilities.experimental['claude/channel'] = {}` 声明 channel;init 时 POST `/api/cc-bridge/announce`(自动注册);SSE 订阅 `/api/cc-bridge/events`;`notifications/claude/channel` 推消息进 claude;`reply` tool 收 claude 回复 → POST `/api/cc-bridge/reply`
2. **Elixir McpConfigWriter**:`lib/esr/bridge/v1_prototype/mcp_config_writer.ex`,~20 LOC,write/0 + 默认 ESRD url
3. **Elixir Server rewrite**:`lib/esr/bridge/v1_prototype/server.ex` 去掉 Port spawn,改为 connected-state tracker(GenServer state = Map<bridge_id, info>)
4. **Web 侧 announce controller**:`apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex` + router POST `/api/cc-bridge/announce` → Server.register + PubSub broadcast
5. **LV /admin 增量**:订阅 events 改 status 显示(connected list 替代 single "ready" status)
6. **scripts/cc-bridge-attach.sh**:写 mcp.json + `exec script -q /dev/null claude --mcp-config <path>`
7. **集成测**:Python MCP server unit test(stdio in/out) + announce controller unit test(post → server state) + 端到端 mock 测试
8. **agent-browser e2e**:agent 跑 attach 脚本 → 等 claude init → 看 LV connected → screenshot → kill claude → 看 disconnected → re-attach → re-connected
9. **commit + tag**:`git commit -m "phase1b: real CC bridge via cc-openclaw MCP-stdio pattern"` + `git tag phase1b`

**user/agent action note**: v1_prototype 阶段 agent 自己跑 attach 脚本。无 user-only step。Phase 5 由 Ezagent.Behavior.OSProcess 接管。

---

## `/goal` 触发(self-motivated skill)

spec 4 文件全部 sign-off 后,**主 agent**(就是我)走 self-motivated skill 的 3 步:

1. **Define done-condition**:见 `VERIFICATION.md` Phase 1 整体 gate 段
2. **Compose + announce**:把 `/goal` 完整文本 post 到 Feishu(用户先看到再发,announce-before-send 不阻塞但保 legibility)
3. **send-slash submit**:`.claude/skills/self-motivated/scripts/send-slash submit "/goal <text>"`;然后 `send-slash capture` 截一段 ack 给用户

**`/goal` 文本(待最终 brainstorm/subagent 起草后定稿)**:
```
/goal Implement ezagent Phase 1 sub-step 1a then 1b. Approach: TDD per
docs/phase-specs/phase1/PLAN.md (1a internal 6 steps with commits between
them, then 1b). Each sub-step ends with agent-browser F1 verification +
sub-step-gate.sh green. Refs:
docs/phase-specs/phase1/{SPEC,VERIFICATION,PLAN,DECISIONS}.md, ARCHITECTURE.md
§4-§6 + §5.7 + §10.2 + Appendix A, GLOSSARY.md (8 invariants).
Done when: phase1a + phase1b tags both pushed + all VERIFICATION
checkboxes ticked + sub-step-gate green for both + mix test + mix
format --check-formatted all pass + screenshots /tmp/phase1[ab]-final.png exist.
```

实际文本由 subagent 起草(用户要求),主 agent 确认后再发。
