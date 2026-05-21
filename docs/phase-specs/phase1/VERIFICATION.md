# Phase 1 — VERIFICATION

> **先于 PLAN.md 写**(M1 / Decision #80)。VERIFICATION 是 sub-step + phase 完成的验收契约。
> 配套: `SPEC.md` / `PLAN.md` / `DECISIONS.md`

## 验收原则

1. **验证 SUPERSETS 人类 review**(memory `feedback_goal_human_ergonomic_verification`):
   自动 gate 跑的所有 check 中,**必须包含人类 review 时实际会做的所有事**;gate 可以**比**人类做的更多(grep / SQL / unit test / ...),以便更充分定位和发现问题。**关系是 `人类 review ⊆ gate checks`,不是等式**。
   - ✅ 人会浏览器开页面看 audit table → gate **也**走 `agent-browser open + snapshot + screenshot`(加上更多 grep / SQL / unit test)
   - ❌ gate **只**做 `curl ... | grep` —— 不行;curl 通过不代表人类视角的页面 OK(Phase 0 `/dev/dashboard**` 404 教训)
   - **任何 UI-touching phase 的最终 gate MUST 以 `agent-browser screenshot` 结尾**,供人眼确认页面是活的(不是错误页,不是静态死页)
2. **人 review 步骤要人体工程学**:
   - 任何需要人手动输入的步骤,必须**提供完整 paste-able 文本**(URI / JSON args / 等)。不让人手打 UUID / 长 URI
   - 见各 sub-step gate 的「人 review 行动 — 复制粘贴文本」段

---

## 1a Sub-step Gate

> 1a 完成 = `phase1a` tag 的前置。**全绿才能 tag**。

### 1a-G1 · 结构 + 编译 + 单元测试

- [ ] `apps/ezagent_core/` 含 SPEC §3 列的 18 个 core 模块(`mix.exs` deps 不变,仍无 `:phoenix` 框架)
- [ ] `apps/ezagent_plugin_echo/` 存在,定义 `Ezagent.Entity.Echo` Kind + `Ezagent.Behavior.Echo`
- [ ] `apps/ezagent_web_liveview/` 存在,有 `EzagentWebLiveview.AdminLive` LiveView module
- [ ] `Ezagent.Entity.User`(stub Kind)存在,导出 `admin_uri/0` + `admin_caps/0`
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix test` 全绿(ezagent_core 单元测试 + Phase 0 已有 + 新增 LiveView test)
- [ ] `mix format --check-formatted` 通过

### 1a-G2 · 8 不变式 grep checklist(Phase 1 适用 6 条)

- [ ] **#1 inbound 走 dispatch**: `grep -rn "PubSub.broadcast" apps/ezagent_core apps/ezagent_plugin_echo apps/ezagent_web_liveview --include='*.ex' | grep -v ":events" | grep -v "esr:audit:stream"` 无 inbound 路径残留(audit:stream + :events 这两个 view-fanout 是合法的,§5.7.6)
- [ ] **#2 use Ezagent.Kind 生命周期**: `grep -rn "def init(" apps/ezagent_core apps/ezagent_plugin_echo --include='*.ex' | grep -v "kind/server.ex" | grep -v "_test.exs"` 应为空(plugin Kind 模块不该手写 init,共享 `Ezagent.Kind.Server` 是唯一 init)
- [ ] **#3 :call to not-ready fail-fast**: `Ezagent.Invocation.dispatch/1` 的 case 分支里 `{:not_ready, mode}` when mode in [:call, :call_stream] → `{:error, :not_ready}` 存在,unit test 覆盖
- [ ] **#4 put_new for unique-key**: `Ezagent.KindRegistry.put_new` 是唯一注册路径;无裸 `Registry.register` 在 Kind 注册场景
- [ ] **#6 audit 异步 cast**: `Ezagent.Audit` telemetry handler 内只调 `GenServer.cast` + `PubSub.broadcast`,**不直接写 SQLite**(SQLite 写在 `Ezagent.Audit.Writer.handle_info` 的 batch flush)
- [ ] **#7 零匹配 → DLQ unroutable**: Phase 1 还没 routing,但 dispatch 路径里 `{:error, :no_such_actor}` 须有 telemetry + DLQ 落库

不适用 Phase 1(标 N/A,Phase 2+ 适用):#5 snapshot on slice change(Echo 是 ephemeral)、#8 CC channel stdio(Phase 1 是 bridge 原型,Phase 5 才有正式 channel)

### 1a-G3 · `mix ezagent.check_invariants`

- [ ] Phase 1 期,task 应该 grep 上面 5 条不变式(从 Phase 0 的 no-op skeleton 升级为有实际 grep);exit 0 表示干净,exit 非 0 表示发现违反

### 1a-G4 · agent-browser F1 e2e 测试(强制最终 gate)

> 这是 1a 的**最终验收门**(per memory `feedback_goal_human_ergonomic_verification` + Phase 0 mandatory agent-browser gate)。**不通过不允许 tag `phase1a`**。

**前置:** `mix phx.server` 起来,绑 0.0.0.0:4000;tailnet IP `100.64.0.27` 可达。

**Step 1 · 浏览器打开 /admin**
```bash
agent-browser open http://100.64.0.27:4000/admin
agent-browser snapshot -i
```
- [ ] snapshot 里看到:`heading "Admin"`(或 Ezagent-specific 标题)、`button "Echo 测试"`、manual dispatch form(target / args 输入框)、audit log table(空表头)

**Step 2 · 点 Echo button**
```bash
agent-browser click @e<Echo button ref from step 1 snapshot>
agent-browser snapshot -i
```
- [ ] snapshot 里 audit log table 至少多 1 行:target = `agent://echo/behavior/echo/say`, action 列显示 say, authz 列 `:stub_grant`, result 列含 `echo: "hello"` 或类似

**Step 3 · manual dispatch form(人体工程学 — 复制粘贴文本)**

人 review 行动:把下面三段**逐段复制粘贴**到表单(不要手打):

`target` 框粘贴:
```
agent://echo/behavior/echo/say
```

`args` 框粘贴(JSON):
```json
{"msg": "verification test"}
```

`mode` dropdown 选:`call`

点 "Dispatch" button。

```bash
agent-browser snapshot -i
```
- [ ] audit log table 多 1 行,result 含 `echo: "verification test"`,duration_us > 0

**Step 4 · 重启 BEAM,audit history 不丢(F8 audit-子集预览,不是完整 F8)**

> 本步**不在 F1(文本往返)范围**;它是 F8(重启恢复)的 audit 子集预览,验证 `Ezagent.Audit.Writer` 的 SQLite 持久化在 Phase 1 期已可工作。完整 F8(Workspace state / Kind state snapshot 都恢复)由 Phase 3 验。Phase 1 验完不等于 F8 通过 — 架构师 review P3-4 显式化此边界。


```bash
# 在 server pane(不是 /goal pane)kill phx.server,重启
pkill -f "mix phx.server"; sleep 2; mix phx.server &
# 等 5s,重新打开
agent-browser open http://100.64.0.27:4000/admin
agent-browser snapshot -i
```
- [ ] 重新打开后 audit log table 显示历史 invocations(从 SQLite `invocations` 表读回);至少看到上面 step 2/3 留下的几行

**Step 5 · screenshot 人眼确认**
```bash
agent-browser screenshot /tmp/phase1a-final.png
```
- [ ] screenshot 显示:页面真实渲染(不是错误页 / 不是空白);audit log table 有内容;Echo button 存在;manual dispatch form 存在。**Allen 看 screenshot 一眼确认 OK**

**Step 6 · SQLite 持久化验证**
```sql
SELECT id, caller, target, action, authz, duration_us, inserted_at
FROM invocations
ORDER BY id DESC LIMIT 10;
```
- [ ] 至少 4 行(上面 step 2/3 各 2 行 invocation + reply),`authz = stub_grant`,`duration_us` 都 > 0

---

## 1b Sub-step Gate

> 1b 完成 = `phase1b` tag = phase1 整体完成。

### 1b-G1 · 结构 + 编译

- [ ] `apps/ezagent_plugin_cc_bridge_v1_prototype/` 存在(目录名 + 内部模块名都带 `_v1_prototype` 后缀)
- [ ] `apps/ezagent_plugin_cc_bridge_v1_prototype/python/esr_mcp_bridge_v1_prototype.py`(~225 LOC,MCP stdio + `claude/channel` capability + `reply` tool + SSE subscriber)
- [ ] `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/mcp_config_writer.ex`(写 mcp.json)
- [ ] `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/esr/bridge/v1_prototype/server.ex`(rewrite,只跟踪 connected state)
- [ ] `apps/ezagent_web/lib/ezagent_web/controllers/cc_bridge_announce_controller.ex` + router POST `/api/cc-bridge/announce`
- [ ] `scripts/cc-bridge-attach.sh`(PTY 包装 + 写 mcp.json + exec claude)
- [ ] `EzagentWebLiveview.AdminLive` 增量:CC bridge 状态显示(connected list)
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix test` 全绿

### 1b-G2 · agent-browser real CC verify(强制最终 gate)

**Architecture pattern**: cc-openclaw MCP-stdio(就是这个 chat 用的 openclaw-channel 走的路径)。**不是**老 esr `--dangerously-load-development-channels` Phoenix Channel WebSocket。

**前置:** Ezagent `mix phx.server` 跑,绑 `100.64.0.27:4000`。`claude` binary 在 PATH(`which claude` 有输出)。

**USER ACTIONS / AGENT ACTIONS**:
- v1_prototype 阶段:**agent 自己跑 `bash scripts/cc-bridge-attach.sh`** 后台启动真 claude session
- 真 claude 会 spawn esr_mcp_bridge_v1_prototype.py 作为 MCP+channel server
- bridge 在 MCP `initialize` 阶段自动 POST `/api/cc-bridge/announce`(不靠 claude 触发)
- bridge 同时启 SSE 订阅 `GET /api/cc-bridge/events?bridge_id=<id>`,接收 LV 推送
- bridge 通过 stdout JSON-RPC `notifications/claude/channel` 把消息送进 claude

**Step 1 · 启动 attach 脚本 + 验证 claude 起来**
```bash
bash scripts/cc-bridge-attach.sh > /tmp/cc-bridge.log 2>&1 &
# 等 ~5s 让 claude 初始化 + MCP server spawn + announce 完成
sleep 8
curl -s http://127.0.0.1:4000/admin   # 应该看到 connected bridges
```
- [ ] esrd 端有 announce POST 进来 + LV /admin "CC Bridges" 列表多一个 `bridge-XXXXXXXX` 行

**Step 2 · agent-browser 看 LV /admin 显示 connected**
```bash
agent-browser open http://100.64.0.27:4000/admin
agent-browser snapshot -i
```
- [ ] snapshot 里 "CC Bridges" 区域显示至少 1 个 connected bridge,带 `bridge_id`(真实的 claude session 标识,不是 stub "ready")

**Step 3 · screenshot 人眼确认**
```bash
agent-browser screenshot /tmp/phase1b-final.png
```
- [ ] screenshot 显示真的 connected bridge,**Status: connected** + bridge_id 文本

### 1b-G3 · CC bridge lifecycle

- [ ] kill claude(`pkill -f 'claude.*mcp-config'`),agent-browser snapshot:LV 显示 bridge disconnected(或 last_seen 时间停在 kill 前)
- [ ] 重新跑 attach 脚本:LV 重新显示 connected,bridge_id 可能换(新 session)

---

## Phase 1 整体 Gate(`phase1` 隐式 = `phase1b` tag)

- [ ] 1a + 1b 全部 sub-step gate 绿
- [ ] `git tag phase1a` 和 `git tag phase1b` 都在
- [ ] `sub-step-gate.sh` 在 commit `phase1b` 时实际跑过且通过(`mix test` + `mix format --check` + 8 不变式 grep)
- [ ] `docs/phase-specs/phase1/VERIFICATION.md` 全部 checkbox 打勾(执行记录)
- [ ] `mix ezagent.check_invariants` 输出干净(exit 0)
- [ ] `/tmp/phase1a-final.png` 和 `/tmp/phase1b-final.png` 两个 screenshot 都生成且 Allen 看过

---

## 人 review 关键点(Allen)

- 1a screenshot 真的显示 audit log + Echo button 工作?
- 1b screenshot 真的显示从 LV 发到远程 CC 的 reply 回来?
- 老 esr 借鉴的 6 处 pattern 真用上了(grep `Ezagent.KindRegistry` 类似老 `Ezagent.Entity.Registry` 形态)?
- 老 esr 反例的 6 处真的没复刻(grep 不到 `dedup_keys: MapSet` / `HandlerRouter` / per-actor MapSet 等模式)?
- 8 不变式 5 条 grep 全干净?
- bridge 文件名带 `_v1_prototype` 后缀(Phase 5 替换路径清晰)?

---

## 不变式 grep 完整命令清单(可执行)

```bash
# #1 inbound via dispatch(allowlist: :events suffix + audit:stream 这两个 view-fanout)
grep -rn "PubSub.broadcast" apps/ezagent_core apps/ezagent_plugin_echo apps/ezagent_web_liveview \
  --include='*.ex' | grep -v ":events" | grep -v "esr:audit:stream" \
  && echo "✗ inbound broadcast found" || echo "✓ clean"

# #2 use Ezagent.Kind 生命周期(只有 kind/server.ex 应该有 def init)
grep -rn "^\s*def init(" apps/ezagent_core apps/ezagent_plugin_echo --include='*.ex' \
  | grep -v "kind/server.ex" | grep -v "_test.exs" \
  && echo "✗ stray init found" || echo "✓ clean"

# #3 :call to not-ready fail-fast(检查 dispatch.ex 有对应 case)
grep -E '\{:not_ready, mode\} when mode in \[:call' apps/ezagent_core/lib/esr/invocation.ex \
  && echo "✓ present" || echo "✗ missing"

# #4 put_new for unique-key(KindRegistry 用 put_new)
grep -rn "Registry.register" apps/ezagent_core --include='*.ex' | grep -v put_new | grep -v "_test.exs" \
  && echo "✗ bare Registry.register found" || echo "✓ clean(only via put_new)"

# #6 audit 异步:Ezagent.Audit 内不直接写 SQLite
grep -rn "Ezagent.Repo\|Repo.insert\|exqlite" apps/ezagent_core/lib/esr/audit.ex \
  && echo "✗ audit handler writes SQLite directly" || echo "✓ clean(only cast)"

# #7 零匹配 → DLQ unroutable(dispatch 的 no_such_actor 路径有 DLQ.put + telemetry)
grep -E '(:no_such_actor|:unroutable)' apps/ezagent_core/lib/esr/invocation.ex apps/ezagent_core/lib/esr/dlq.ex \
  | grep -E '(DLQ\.put|telemetry)' \
  && echo "✓ no_such_actor → DLQ + telemetry present" || echo "✗ missing DLQ/telemetry on no_such_actor"
```

(以上 grep 命令也写进 `mix ezagent.check_invariants` 的 1a 完成版,自动化跑)
