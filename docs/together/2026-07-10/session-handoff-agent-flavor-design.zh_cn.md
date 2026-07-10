# Session 交接 · agent×flavor 映射与实例生命周期设计

生成时间:2026-07-10 · 交接人:Claude(本 session)· 归属:`gagameow`(黄佳佳)

> **用途**:切换 session 后,读本文件即可接手。含当前状态、待办、关键路径、以及**本轮踩过的坑**(重蹈成本很高)。

---

## 0. 先分清:你名下有两块任务,本 session 只做其中一块

| 块 | 内容 | 归属 |
|---|---|---|
| **✅ 当前这块(本 session)** | **续 #1256 设计** —— agent×flavor 映射与底层实例生命周期,产出 decision record | **接手本 session 请只做这块** |
| ❌ 另一块 | **Track C**:自创建 socialware 编写/安装失败 + `@mention` 派发 `:unauthorized`(ezagent in ezagent 自举测试) | **由其他 session 处理,不要碰** |
| ❌ 横切 | **Track A**:产品内 agent 必须拿显式 worktree,绝不落 main checkout | 其他 session / 工程纪律 |

---

## 1. 当前状态(一眼看全)

| 项 | 值 |
|---|---|
| **PR** | [#1256](https://github.com/ezagent42/ezagent/pull/1256) · **draft** · title `docs(design): ...(v2.5 · decision record)` |
| **head** | `6b3dd963` · **11 commits** · **1 文件(设计稿)+ 2 辅助文件(handoff + 评审分析)· 零代码** |
| **分支** | `docs/agent-flavor-mapping-lifecycle`(已 rebase 到最新 `origin/main`) |
| **设计稿** | `docs/together/2026-07-08/agent-entity-flavor-mapping-and-lifecycle.zh_cn.md`(**v2.5**,已 commit) |
| **可视化图** | https://claude.ai/code/artifact/8c288393-8edc-4f9d-815c-c6ad0fdc038f (v2.4,待更新到 v2.5) |
| **评审分析/行动计划** | `docs/together/2026-07-09/allen-pr1256-review-analysis-and-plan.zh_cn.md`(已 commit) |

**稿子/图/PR body 当前一致(v2.5)**。

---

## 2. 核心结论(已确立,不要推翻重来)

### 2.1 Framing(v2.5 重写:双域模型)

> **两个正交的域,各有各的权威源。**
>
> | 域 | 权威 | 跨 backend |
> |---|---|---|
> | **D1 · 会话消息** | PG `MessageStore` | ✅ 可 replay |
> | **D2 · 引擎工作集**(tool call/thinking) | **engine 自己** | ❌ 必然清零 |
>
> 边界 = 消息投递。native resume 恢复 D2,PG replay 重建 D1。「flavor = 无状态执行器」**只对 D1 成立**。
> v2.2-v2.4 的 `cache/source-of-truth` 类比不成立(`messages` 表无 tool call,见 §4.0)。

### 2.2 执行模型三轴(v2.4 拆,v2.5 保留)

```
control_lifetime: :daemon | :embedded_live | :oneshot
surface:          :pty | :none
resume_backend:   :engine_handle | :message_store | :none
```

| flavor | control_lifetime | surface | resume_backend |
|---|---|---|---|
| `codex` | `:daemon` | `:pty` | `:engine_handle` |
| `cc` | `:embedded_live` | `:pty` | `:engine_handle` |
| `cc-headless` | `:oneshot` | `:none` | `:engine_handle` |
| `curl` | `:none` | `:none` | `:none` |

`:in_process` → `:embedded_live`; `:none`(cc-headless) → `:oneshot`。

### 2.3 config_dir 四分类(标注归属域)

①② 不属任何域(recipe 投影/凭据)· ③ = **D2 的物理载体**(engine 的 jsonl,engine 是它权威)· ④ = **D2 的句柄**(`EngineSessionHandle` envelope)。

### 2.4 `NativeResume` — Phase 1 全部接口

```elixir
@callback new_session_handle() :: engine_session_handle()
@callback resume_args(handle()) :: [String.t()]

%EngineSessionHandle{
  engine_type: :cc | :codex | :curl,   # provenance:mint 时是哪个引擎
  handle_payload: opaque_adapter_payload,
  cwd: String.t(),                     # provenance:mint 时的 cwd
  version: 1
}
# config_dir 字段已删 —— f(agent_uri) 纯函数,冗余
```

决策在调用点:同 engine + 同 cwd → `:native`,其他 → `:fresh`(Phase 2 后可改成 `:replay`)。**没有** `decide/3`。

---

## 3. 阻塞项状态

| # | 状态 | 内容 |
|---|---|---|
| **B1** | ✅ 关闭 | cc-PTY `--resume` 实测通过,降为两行 argv |
| **B2** | 🟡 future capability(v2.5:重新诊断为信息缺失) | 跨 backend D1 replay。**PG 无 tool call**,不是渲染问题。Phase 2 范围缩小(不需 tool-result folding) |
| **B3** | ⚠️ **需 Allen 再确认(v2.5)** | (c) 批准时 = 共享 live worker;+native resume = 共享持久对话。横向交织从「随重启清零」→「落盘持久」。三选项 (c-1)/(c-2)/(c-3) 回给 Allen(§5.6) |
| **B4** | 🟠 Phase 1 不关闭 | isolation schema 待建模 |
| **B5** | ✅ 已修 | curl 废弃单一 `stateless` 标签 |
| **B6** | 🟠 前置验证(v2.5 新增) | cwd 变化频率未量;handle 路径含 `<cwd-slug>`。命中率是 Phase 1 收益的唯一假设 |
| **并发不变式** | ✅ 已坐实 | `KindRegistry` `keys: :unique` + `put_new/2` 已保证单活跃 worker,零新代码 |

### 分期(Phase 0/1/2/3)

- **Phase 0(前置验证,十分钟)**:量 cwd 变化频率(B6)—— Phase 1 收益的唯一假设
- **Phase 1(NativeResume,non-reuse 路径可立即做)**:`EngineSessionHandle` envelope(key=`agent_uri`) + `new_session_handle/0` + `resume_args/1` + resume 失败 fallback。**⚠️ reuse 路径待 §5.6 Allen 裁决**
- **Phase 2(独立 SPEC)**:`ReplayRestore` = 跨 backend D1 replay = B2 本体。降级为 future capability,范围比 v2.4 以为的小。不阻塞 Phase 1。
- **Phase 3(未来)**:`UnifiedContextRestore` —— 等 Phase 1+2 成型后统一 API。

---

## 4. 立即待办(优先级序)

1. ✅ ~~在 PR #1256 上回 Allen~~ —— 已回; B3 选了 (c)
2. ✅ ~~双 review~~ —— 本 session + Codex 独立 review 完成,共识整合进 v2.4
3. ✅ ~~第三轮 review~~ —— 现读 `message.ex` schema,发现 cache framing 错误,改双域模型(v2.5)
4. 🔴 **B3(c) 语义变化 → 回给 Allen**(§5.6,[PR comment](https://github.com/ezagent42/ezagent/pull/1256#issuecomment-4933310055))—— 唯一需要他表态的事项:**(c-1) 接受 / (c-2) reuse 不做 resume / (c-3) D3 提前**
5. **Phase 0 前置验证** —— 量 cwd 变化频率(B6)
6. **Phase 1 实现(non-reuse 路径)** —— 两行 argv + `EngineSessionHandle` envelope(key=`agent_uri`) + resume 失败 fallback。**可立即开工。**
7. **更新可视化图**到 v2.5(双域模型 + B3(c)语义 + Phase 0)
8. **B2 独立 SPEC**(排期)
9. 登记项:`hello/app.ex:131-136` dead-code drift · `Entity.Agent` 与 `MessageStore` 的 stale moduledoc 应修

---

## 5. 欠 Allen 的回复状态

### ① 他纠正「claude 无 `--resume`」—— ✅ 已回

实测确认他对。B1 关闭。PR comment 已回。

### ② 他反问「共享记忆不也挺好?」—— ⚠️ v2.5 新发现了语义放大,又回了他

Allen 批准 B3(c) 时 = 共享 live worker(进程死即清零)。
+Phase 1 native resume = 共享持久对话(跨重启存活)。
**横向 context 交织从「易失」升级为「持久」,admission gate 拦不住(owner 自己 reuse 不介入)。**
三选项 (c-1)/(c-2)/(c-3) 回给他了,等他选。

### B3 三选一 → ✅ 已选 (c)

---

## 6. 实测复现方法(B1 的证据)

```bash
SB=/tmp/cc-resume-test; rm -rf "$SB"; mkdir -p "$SB"
cp ~/.claude/.credentials.json "$SB/"
export CLAUDE_CONFIG_DIR="$SB"
U=$(uuidgen)

# 1) 首次 spawn(带 ezagent 的完整 argv)
claude --session-id "$U" --dangerously-skip-permissions \
  --dangerously-load-development-channels server:esr-bridge \
  --print "Remember this codeword: pineapple99. Reply with exactly: OK"

# 2) 新进程 resume —— 应答出 pineapple99
claude --resume "$U" --dangerously-skip-permissions \
  --dangerously-load-development-channels server:esr-bridge \
  --print "What was the codeword? Reply with exactly that one word."
```

**结论**:`--resume` 与 `server:esr-bridge` 无冲突。state 物理位置:`$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-uuid>.jsonl`

**仍未验证**:PTY 交互模式(用的 `--print`)· MCP rebind 后 `AgentBridge.Registry` 能否重绑(状态位 13/14)· `--resume` 遇 config_dir 被 wipe(R2)必然失败 → 走 fallback。

---

## 7. ⚠️ 本轮踩过的坑(重蹈成本很高)

### 坑 1:抄 stale moduledoc —— **犯了三次**

| 抄的地方 | 真相 |
|---|---|
| `entity/agent.ex:47` | URI 不是 `entity://agent/<flavor>_<name>`,而是 **`entity://<ws>/agent/<name>`**(`uri.ex:438-441`) |
| `message_store.ex:18-25` | `message_routings` **已移除**,改 copy+ref model(`message_store.ex:80-81`) |
| `app.ex:131-136`(hello roles) | **dead code**;真源是 deploy-seed `manifest.yaml`(`hello.ex:5-24` 权威声明) |

> **教训:「现读代码」不能只读 moduledoc,必须读到实现。** 本项目 moduledoc 大面积滞后。

### 坑 2:下架构结论前没查 CLI help / 没读完对方原文

断言「claude 无 `--resume` ⇒ PTY 不可恢复」——两条都错。**下架构结论前,先跑一次 `--help`,先读完对方的原文。**

### 坑 3:借来词汇但没承担义务

v2.2-v2.4 用 `cache/source-of-truth` framing 整整三个版本,**直到 v2.5 现读 `message.ex` schema 才发现 `messages` 表根本没有 tool call**。`engine_jsonl ⊋ PG` ⇒ **native resume 与 PG replay 重建的不是同一个值,所以"缓存"这个类比不成立。**

> **教训:framing 词汇不是免检的 —— 每个类比都要去 schema 里受审。**

### 坑 4:`gh pr edit` 撞 GraphQL 弃用错误

改用 `gh api repos/<o>/<r>/pulls/<n> -X PATCH -f title=... -F body=@file`。
去 draft 用 `gh pr ready` 是好的;`gh pr ready --undo` 退回 draft。

### 坑 5:commit message 含中文括号/反引号

会把 shell 搞崩 → 写进文件用 `git commit -F <file>`。

### 坑 6:画图比稿子更能暴露分类错误

「③ 是内容 / ④ 是指针」这个实质修正,是画图时被迫把两者并排放进同一张表才发现的 —— 写散文时藏了整整一版。**画图不是投影,是一种约束更强的表达。**

### 坑 7:Codex agent 类型不是协作式的

`codex:codex-rescue` 是 fire-and-forget 转发器,不等待结果。真正的独立 review 需要走 foreground 模式。第二次 review 还撞了 usage limit。

---

## 8. 关键 file:line 速查(18 条 + v2.5 补充)

| 主题 | 位置 |
|---|---|
| Recipe(flavor-agnostic) | `core/recipe.ex:34,47-57` |
| flavor registry(decl 4 字段,**无 isolation**) | `domain_agent/agent_flavor_registry.ex:49` |
| 实例 URI 生成 | `core/uri.ex:438-441`;解析器强制 3 段 `:522` |
| fresh-spawn 全路径 | `domain_agent/entity/agent/template_spawn.ex:241` |
| readiness(bridge join 才 ready) | `domain_agent/agent/transport_readiness.ex:56,88,168` |
| cc PTY argv | `plugin_cc/template/spawn_plan.ex:78-83` |
| cc-headless 的 session id 做法(**Phase 1 照抄它**) | `plugin_cc/template/cc_headless_agent.ex:92,106` |
| cc-headless 的 per-session fallback(D3 先例) | `plugin_cc/cc_headless_bridge_adapter.ex:59` |
| codex app-server(control plane) | `plugin_codex/plugin_codex/app_server.ex:5-9` |
| curl 的 durable conversation slice | `domain_agent/behavior/curl_agent.ex:28-40` |
| MessageStore(copy+ref,无 join 表) | `core/message_store.ex:80-81,123` |
| Message schema(**无 tool call**) | `core/message.ex:84-136` |
| reuse 路径(复用同 agent_uri) | `domain_session/.../definition_agents.ex:179` |
| config_dir 是 agent_uri 纯函数 | `core/sandbox/config_dir.ex:48`;`home_runtime.ex:90` |
| session_discriminator(修串台 bug) | `domain_agent/entity/agent.ex:373,434` |
| role_name 会话内唯一 | `domain_session/behavior/session/members.ex:64-76` |
| 匿名访客 join(不带 role_name) | `domain_socialware/socialware/anon_admission.ex:100-107` |
| `$session_members` 系统默认路由 | `core/routing/resolver.ex:17-25` |
| hello 真源(**不是 app.ex**) | `ezagent_web/priv/socialware_seed/hello/manifest.yaml` |
| **KindRegistry unique-key 不变式(单活跃 worker)** | `core/kind_registry.ex:6,16-22`;`core/application.ex:25` |

---

## 9. 已闭合的历史结论(不用重查)

- **viewer 唯一性 bug 不存在**:匿名访客 join 不占 `role_name` ⇒ 多访客共存;消息走 `$session_members` 兜底到达 agent
- **reuse-join 授权门 = false-positive**(#1269):Part C admission gate 已兜底
- **SkillRegistry P1-P3 已上 main**(#1266)
- **Q3 `cardinality one|many`** / **Q4 curl hook 退化 + completion/tool-loop 正交** 已 ratify
- **并发 lease 不需要** —— `KindRegistry` 的 `keys: :unique` + `put_new/2` + grep gate 已保证单活跃 worker(§4.6)
- **B3 选 (c)** —— 但 v2.5 发现语义被 Phase 1 放大,又回给 Allen 了(§5.6)
