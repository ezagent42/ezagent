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

> plan(`docs/together/2026-07-09/plan.md`)把「续 #1256」和「Track C」都写在 gagameow 那一行,但它们是两码事。

---

## 1. 当前状态(一眼看全)

| 项 | 值 |
|---|---|
| **PR** | [#1256](https://github.com/ezagent42/ezagent/pull/1256) · **draft** · title `docs(design): ...(v2.2 · decision record)` |
| **head** | `65489626` · 5 commits · **1 文件 +442/-0 · 零代码** |
| **分支** | `docs/agent-flavor-mapping-lifecycle`(已 rebase 到最新 `origin/main`) |
| **设计稿** | `docs/together/2026-07-08/agent-entity-flavor-mapping-and-lifecycle.zh_cn.md`(**v2.4**,已 commit) |
| **可视化图** | https://claude.ai/code/artifact/8c288393-8edc-4f9d-815c-c6ad0fdc038f (v2.2,同链接可 redeploy) |
| **评审分析/行动计划** | `docs/together/2026-07-09/allen-pr1256-review-analysis-and-plan.zh_cn.md`(**untracked**,工作分解非设计) |

**三者(稿子/图/PR body)当前完全一致,都在 v2.2。**

---

## 2. 核心结论(已确立,不要推翻重来)

### 2.1 Framing —— 这是整个设计的锚

> **引擎的 session = 可弃缓存。PG `MessageStore` = 权威。**
> - **同 backend**:命中缓存 → 走引擎自己的 CLI-native resume(零 token)
> - **跨 backend / 缓存失效**:回源 → 从 PG 重建

Allen 的「flavor = 无状态执行器」由此获得精确含义:**不是"每次都从 PG 喂",而是"引擎的记忆永远只是缓存,丢了能重建"。**

### 2.2 Control plane 分层(PTY 是正交 surface,不是 mode)

```
control_plane: :daemon | :in_process | :none(oneshot)
surface:       :pty | :none                 # 正交
```

| flavor | control_plane | state 实际在哪(实测) |
|---|---|---|
| `codex` / `codex-remote` | `:daemon` | daemon 的 thread + rollout |
| `cc` | `:in_process` | **磁盘 `<uuid>.jsonl`**(`--resume` 可恢复) |
| `cc-headless` | `:none` | **磁盘 `<uuid>.jsonl`**(同机制) |
| `curl` | `:none` | ezagent 的 `:curl_agent` slice |

判别证据:`app_server.ex:5-9`(app-server 是 shared control plane,**刻意与 `Domain.Pty` 分离**)· `Domain.Pty` 引用数 **cc 51 处 vs codex 7 处**。

### 2.3 config_dir 四分类(③是内容,④是指针,**都是缓存**)

① recipe 投影(可复现)· ② 凭据(cascade 可恢复)· ③ 对话内容 `<uuid>.jsonl`(同 engine 可 `--resume`)· ④ handle(指向③的指针)。
**没有一类是"权威"。权威只有 `MessageStore`。**

### 2.4 `ContextRestore` 三层封装契约(§4.3)

```
L1 framework   ContextRestore.decide/3 -> :native | :replay | :fresh
L2 adapter     new_session_handle/0 + resume_args/1
               (+ :replay 分支的 render_context/2 + inject_context/2)
L3 core(已有)  MessageStore.in_session_since/2 · ReadyGate
```

关键:把 config_dir 第④类收编为 framework 管的 **opaque `engine_session_handle`**。**它是 native resume 与 PG replay 的分岔点** —— decide 只需问「engine 变了没」。

---

## 3. 阻塞项状态

| # | 状态 | 内容 |
|---|---|---|
| **B1** | ✅ **实测关闭**(critical→low) | cc-PTY 的 state 在磁盘;`--resume` 与 `server:esr-bridge` 无冲突。实现 = 两行 argv |
| **B2** | 🟡 **降级为 future capability**(v2.4) | 跨 backend replay。同 backend native resume 是高频需求;跨 backend switch 未经验证。Phase 2 独立 SPEC 排期,**不阻塞 Phase 1** |
| **B3** | ✅ **已裁决(c)** | 承认 reuse = 共享 runtime(D2 收紧);另列 D3「共享身份不共享记忆」为未来设计。Part C admission gate 兜底非 owner。**不再阻塞 Step 1** |
| **B4** | 🟠 **Phase 1 不关闭 B4**(v2.4) | `isolation` 未建模;建模轴已找到(`control_lifetime`/`surface`/`resume_backend`)。B4 关闭条件 = `AgentFlavorRegistry` 完整 isolation schema |
| **B5** | ✅ 已修 | curl = stateless transport + **stateful** flavor behavior |

### 分三步走(Phase 1/2/3,v2.4)

- **Phase 1(小,可立即做)**:`NativeResume` —— `engine_session_handle` + `new_session_handle/0` + `resume_args/1`。cc 补两行 argv(`--session-id` / `--resume`),codex 把 `thread_id` 挪进 handle。**收益:B1 关闭、第④类收编、resume 失败有 fallback。不关闭 B4。**
- **Phase 2(独立 SPEC)**:`ReplayRestore` = 跨 backend replay = B2 本体。降级为 future capability,不阻塞 Phase 1。
- **Phase 3(未来)**:`UnifiedContextRestore` —— 等 Phase 1+2 成型后统一 API。

---

## 4. 立即待办(优先级序)

1. ✅ ~~在 PR #1256 上回 Allen~~ —— 已回;B3 选了 (c)
2. ✅ ~~双 review~~ —— 本 session + Codex 独立 review 完成,共识整合进 v2.4
3. **Phase 1 实现** —— `NativeResume`:两行 argv + `EngineSessionHandle` envelope(key=`agent_uri`) + resume 失败 fallback。**可立即开工。**
4. **B2 独立 SPEC**(排期,不在本 PR)—— 降级为 future capability,不阻塞 Phase 1。
5. 登记项:`hello/app.ex:131-136` dead-code drift · `Entity.Agent` 与 `MessageStore` 的 **stale moduledoc 应修**。

---

## 5. 欠 Allen 的两条答复(他回了,我还没正式答)

### ① 他纠正我:「claude 无 `--resume`」是错的 —— **他对,我已实测确认**

- claude CLI **有** `-r, --resume [value]`(带 value 非交互按 session ID 恢复)、`-c, --continue`、`--session-id <uuid>`。
- 我读对的是「**ezagent 的 spawn argv 里没用**」(`spawn_plan.ex:78-83`),错在从中推导出「PTY 物理上喂不进历史」。
- **更糟:他的 RULING 第②层原文早就写了 "CLI-native resume — `claude --continue` in the same config_dir — restores same-backend conversation cache from disk"。我没读完他的原文就去论证。**
- **实测已通过**(见 §6),B1 关闭。

### ② 他反问:「贡献身份的同时共享记忆好像也挺好的吧,为啥要删掉?」—— **未答**

**准备好的答复要点**(需先把两件事分开):

- **纵向记忆共享**(同一 agent 跨 session 保留长期记忆)—— **这是 reuse 的价值,想要**。
- **横向 context 交织**(两个 session 的消息实时混进同一个 context window)—— 这是 `session_discriminator`(`entity/agent.ex:373` 「The bug this closes」)当初修的**串台事故**,而且**可能是隐私问题**(session A 的内容出现在 session B 的回复里)。

当前 reuse 的实现给的是**后者**(同一个 live worker 同时是两个 session 的成员),不是可控的前者。

而且:**如果 Q1 落地(flavor 无状态、每次 run 只喂当前 session 的 context),横向交织自然消失,纵向记忆可以另行实现。** 所以 Allen 的诉求恰恰要靠 Q1 才能安全兑现。

### B3 三选一(等他定)

- **(a)** D2 生成新 runtime URI(退化成 fresh,"reuse"名不副实)
- **(b)** runtime key `{agent_uri, session_uri}`(要改**所有** config_dir/`CODEX_HOME`/sidecar registry 的 key)
- **(c)** 承认 reuse = 共享 runtime,另列 D3「共享身份但不共享记忆」 ← **Allen 倾向这个**

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

**结论**:`--resume` 与 `server:esr-bridge` 无冲突(该 flag **带值**,argv 里零位置参数)。
**state 物理位置**:`$CLAUDE_CONFIG_DIR/projects/<cwd-slug>/<session-uuid>.jsonl`

**仍未验证**:PTY 交互模式(用的 `--print`)· MCP rebind 后 `AgentBridge.Registry` 能否重绑(状态位 13/14)· `--resume` 遇 config_dir 被 wipe(R2)必然失败,需 fallback。

---

## 7. ⚠️ 本轮踩过的坑(重蹈成本很高)

### 坑 1:抄 stale moduledoc —— **犯了三次**

| 抄的地方 | 真相 |
|---|---|
| `entity/agent.ex:47` | URI 不是 `entity://agent/<flavor>_<name>`,而是 **`entity://<ws>/agent/<name>`**(`uri.ex:438-441`) |
| `message_store.ex:18-25` | `message_routings` **已移除**,改 copy+ref model(`message_store.ex:80-81` 代码明写) |
| `app.ex:131-136`(hello roles) | **dead code**;真源是 deploy-seed `manifest.yaml`(`hello.ex:5-24` 权威声明) |

> **教训:「现读代码」不能只读 moduledoc,必须读到实现。** 这个项目里 moduledoc 大面积滞后。

### 坑 2:没查 CLI help / 没读完对方原文就下结论

断言「claude 无 `--resume` ⇒ PTY 不可恢复」——两条都错。**下架构结论前,先跑一次 `--help`,先读完对方的原文。**

### 坑 3:工具层面的两个坑

- **`gh pr edit` 会撞 GitHub Projects-classic 弃用的 GraphQL 报错**(改不动 title/body,但不报错退出)。
  → 改用 `gh api repos/<o>/<r>/pulls/<n> -X PATCH -f title=... -F body=@file`。
  → 去 draft 用 `gh pr ready` 是好的;`gh pr ready --undo` 退回 draft。
- **Bash 里 `rg`/`grep` 的输出偶发字符 mask**(词被替换成 `n`/`ln`),行号可靠但词不可靠。
  → 拿行号后**用 `Read` 工具读原文件**,不要信 grep 输出的词。
- commit message 含中文括号/反引号会把 shell 搞崩 → 写进文件用 `git commit -F <file>`。

### 坑 4:图比稿子更能暴露分类错误

「③ 是内容 / ④ 是指针」这个实质修正,**是画图时被迫把两者并排放进同一张表才发现的**;写散文时藏了整整一版。**画图不是投影,是一种约束更强的表达。**

---

## 8. 关键 file:line 速查

| 主题 | 位置 |
|---|---|
| Recipe(flavor-agnostic) | `core/recipe.ex:34,47-57` |
| flavor registry(decl 4 字段,**无 isolation**) | `domain_agent/agent_flavor_registry.ex:49` |
| 实例 URI 生成 | `core/uri.ex:438-441`;解析器强制 3 段 `:522` |
| fresh-spawn 全路径 | `domain_agent/entity/agent/template_spawn.ex:241`(mint→instantiate→obligations→slice→overlay→flavor attr) |
| readiness(bridge join 才 ready) | `domain_agent/agent/transport_readiness.ex:56,88,168` |
| cc PTY argv | `plugin_cc/template/spawn_plan.ex:78-83` |
| cc-headless 的 session id 做法(**Step 1 照抄它**) | `plugin_cc/template/cc_headless_agent.ex:92,106` |
| codex app-server(control plane) | `plugin_codex/plugin_codex/app_server.ex:5-9` |
| codex PTY resume thread | `plugin_codex/template/codex_agent.ex:276` |
| curl 的 durable conversation slice | `domain_agent/behavior/curl_agent.ex:28-40` |
| MessageStore(copy+ref,无 join 表) | `core/message_store.ex:80-81,123` |
| reuse 路径(复用同 agent_uri) | `domain_session/.../definition_agents.ex:179` |
| config_dir 是 agent_uri 纯函数 | `core/sandbox/config_dir.ex:48`;`home_runtime.ex:90` |
| session_discriminator(修串台 bug) | `domain_agent/entity/agent.ex:373,434` |
| role_name 会话内唯一 | `domain_session/behavior/session/members.ex:64-76` |
| 匿名访客 join(不带 role_name) | `domain_socialware/socialware/anon_admission.ex:100-107` |
| `$session_members` 系统默认路由 | `core/routing/resolver.ex:17-25` |
| hello 真源(**不是 app.ex**) | `ezagent_web/priv/socialware_seed/hello/manifest.yaml`;`domain_session/socialware/demo/hello.ex:5-24` |

---

## 9. 已闭合的历史结论(不用重查)

- **viewer 唯一性 bug 不存在**:匿名访客 join 不占 `role_name` ⇒ 多访客共存;消息走 `$session_members` 兜底到达 agent。`from_role: viewer` 对匿名访客**空转**但不影响交付。
- **reuse-join 授权门 = false-positive**(#1269):Part C admission gate(`handle_join` 的 member-cap seam)已兜底,非 owner/非 manages 的凭据型成员被 PEND。
- **SkillRegistry P1-P3 已上 main**(#1266)。
- **Q3 `cardinality one|many`** / **Q4 curl hook 退化 + completion/tool-loop 正交** 已 ratify。
