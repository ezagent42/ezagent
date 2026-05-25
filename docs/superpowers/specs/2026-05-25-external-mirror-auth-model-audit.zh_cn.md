# ExternalMirror Facade 鉴权模型审计 — 4 个 enforcement gate、信任传递、原子性、集体不变式

**状态:** r1。2026-05-25。
**层级:** 对 `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` 的文档补丁 + `apps/ezagent_core/` 中的小型原语提升 + `apps/ezagent_domain_external_mirror/` 中的 invariant 测试。
**触发:** Allen 2026-05-25 — 观察到 PR #317 (PR-EM-3) 走了 5 轮 `/codex:adversarial-review`、累计 12 个 HIGH/CRIT findings、全部集中在 `Behavior.ExternalMirror` 的 facade 与 action-body 划分上。Allen 2026-05-25 (飞书): "未来 codex 多轮 review 失败的 pattern 我们要 generalize 成 SPEC + invariant test，不能靠 point fix"。
**前置 (均已合并到 `main`):**
- `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` (父 SPEC; §4.2 是本审计要补的欠规格区域)。
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` (PRs #306-#310; Check 1 验证的 cap 形状)。
- PR-EM-3 / PR #317 — 产出本审计的 5 轮 codex 迭代。每个合并的 commit (a9d40af、89904b9、931a0203、4a1637d8、017f5ff2、e3ca119f、4cc0e237) 都承载了对应轮次的 finding + 修复 rationale。
- PR-EM-FINAL 不是前置；本审计可以在它之前或之后落地。
- `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05): 不要 `:warning`+降级、不要默认值、不要白名单、不要 shim。审计结论 MUST 遵守此规则。
- `feedback_completion_requires_invariant_test` (Allen 2026-05-05): 多 PR 阶段 "完成" 的判定，必须有一个架构 invariant 测试在目标未达成时会失败。§6 的 invariant 测试就是本审计的 gate。
- `feedback_north_star_plugin_isolation` (Allen 2026-05-05): 设计模糊点的 tiebreaker 是 "把 plugin 作者挡在 core 之外"。
- 技能 P3 (单一真相源) + P14 (Kind 之间唯一路径是 dispatch) + P22 (可靠性原语住在 core；plugin 作者不能绕过) + P23 (declare-don't-call 的 plugin 契约)。
**对照:** `2026-05-25-external-mirror-auth-model-audit.md` (英文镜像)。

---

## 1. 背景 — 为什么需要这次审计 (meta-finding)

PR #317 实现了父 SPEC §4.2 / §8.2 r6 定义的 `Ezagent.ExternalMirror.bind/4` facade + `Behavior.ExternalMirror.invoke(:bind, ...)` action body。它经历了 **5 轮** `/codex:adversarial-review`。每一轮都浮现 2-3 个新的 HIGH/CRIT findings，**全部集中在同一表面**: facade 与 action-body 的划分、enforcement 顺序、原子性、失败模式。累计 **12 个 finding** 跨 r1-r5。

### 1.1 各轮总结 (从 PR #317 的 commit body 原样抄录)

| 轮次 | 结论 | Findings | 结构性隐含 |
|------|------|----------|-----------|
| r1 | needs-attention | 1 CRIT (projection 行的 key 是 `<adapter>/<target>`，跨 session 撞 key) + 1 HIGH (对 JSON 解码的 opts keys 调用 `String.to_atom`) | "row key 是 session-scoped" — 父 SPEC §7.1 写了 "natural key `(session_uri, adapter_id, target_id)`" 但没定 PK 推导；实现者直接用内存中人类可读的 binding_id |
| r2 | no-ship | 3 HIGH — HIGH-1 启动顺序 (BootReconciler 跳过持久化的 bindings 因为 adapter 后注册) + HIGH-2 读侧 cap 绕过 (`list_bindings/1` + `sessions_for_adapter/1` 跳过 CapBAC) + HIGH-3 启动顺序 (per-adapter cap subject 永不注册) | "adapter 一旦可观察，X 也必须为真" — 没有规格化的事件驱动 install hook；app boot 时的一次性 poll 在 plugin boot 之前跑 |
| r3 | needs-attention | 1 CRIT (`_facade_checks_ok` flag 可被直接 dispatch 伪造) + 2 HIGH (`sessions_for_adapter/2` 只按 workspace 过滤仍泄露; `BindingRow.insert` 在 unique 冲突时 raise 而不是返回 changeset) | "从 facade 到 action body 的信任传递" — 父 SPEC §8.2 说 "facade 注入 `args[:_facade_checks_ok] = true`"，没承认 args 是 caller 可控 |
| r4 | needs-attention | 2 HIGH (BootReconciler 缺重试循环；`spawn_worker_idempotently` 在重试耗尽且无活 worker 时返回 `:ok` — `:warning`+降级反模式) + 1 MED (Check 1 在 facade 中比 Check 3 晚跑，所以缺 session bind cap 的 caller 可以触发 adapter target 枚举 I/O) | "enforcement 顺序" — 父 SPEC §4.2 列了 gate 但没定顺序也没说理由 |
| r5 | needs-attention | 2 HIGH 在 **既有** 代码上 — HIGH-A (AdapterInstall 与 BindingRegistry 的原子性顺序; install 在同一 adapter_id 的两个 registry 都填充前就触发) + HIGH-B (`do_bind` 先 spawn 再 persist; spawn 成功 + persist 失败产生孤儿 worker; blanket `{:error, changeset} → :ok` 映射 silently 丢失真实 DB 失败) | "bind 的原子性契约" — 父 SPEC §8.2 说 "persist + spawn" 但没定顺序、错误分类、补偿 |

### 1.2 Meta-finding

5 轮、12 finding、**一个架构表面**。每个修复单独看都对，但父 SPEC §4.2 在 5 个正交维度上欠规格:

1. **Enforcement 顺序** — 哪些 gate 先于哪些跑，为什么，对 "便宜+吵" 的 caller vs "贵+静" 的 caller 各失败成什么样。
2. **信任传递** — facade 如何用不可伪造的方式告诉 action body "我已验证此调用"。
3. **原子性契约** — persist-first vs spawn-first; 幂等 vs 真实失败; 部分失败的补偿。
4. **启动顺序不变式** — "adapter X 可观察的那一刻，Y 也必须为真" 何时适用、如何不靠 poll 强制。
5. **纵深防御** — 哪些 gate 也在 dispatch §5.5 / §5.6 跑，facade 的预检节省了什么 (I/O、延迟、target 枚举)。

本审计在一个 spec + 一个 invariant 测试中关闭这 5 个维度，使将来对此表面的任何修改触发的 codex 一轮就能命中 r1 级的结构性断言，而不是只发现 r1 的零散 finding。

### 1.3 范例 finding (能代表 pattern 的两个)

**r3 CRIT — `_facade_checks_ok` 伪造 (信任传递):**
> facade 在 Check 2+3 通过后设置 `args[:_facade_checks_ok] = true`。action body 信任那个布尔值 — 但 `args` 在 `Invocation.dispatch/1` 时间点是 caller 可控的，所以任何持 session :bind cap 的 VM 内 caller 都可以直接 dispatch 并设置 flag，跳过 Check 2 与 Check 3。**真实的 authorization bypass。** 修复: 用一个 32 字节的 `:crypto.strong_rand_bytes` nonce 替换 flag，存到 `:protected` ETS 表中，该表只有 FacadeNonceTable GenServer 能写。要伪造，要么猜 256 bit RNG，要么写入 caller 不拥有的表。

**r5 HIGH-B — spawn-before-persist 脑裂 (原子性):**
> `:bind` action body 先 spawn worker，再 `persist_binding_row/2`。如果 `Repo.insert/1` raise，worker 活着但没行也没 slice 变化。还有: `persist_binding_row` 把任意 `{:error, changeset}` 都 blanket 映射为 `:ok` (注释说 "for unique-constraint idempotency")，所以 NOT NULL / FK / 校验错误也都 silently 成了 "成功"，行没建，worker 活着且任何 rehydration 都看不到。修复: 先 persist，区分返回 (`{:ok, :persisted}` / `{:ok, :idempotent_unique_conflict}` / `{:error, {:db_insert_failed, _}}`)，后 spawn，spawn 在 persist 之后失败时补偿删除。

这两个 finding 一起说明问题: 父 SPEC 的 "facade 跑 Check 2+3 然后 dispatch" + "action body persist + spawn" 在抽象层面是对的，但每个具体细节都欠规格。本审计把每个具体细节都钉死。

---

## 2. 四个 enforcement gate (规范顺序)

### 2.1 表

| # | Gate | enforce 在哪 | 成本 | 失败形状 | 触发缺口的 findings |
|---|------|-------------|------|---------|------------------|
| 1 | **Cap 1** — caller 持有 `{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: <session>, workspace_uri: <ws>}` | facade INLINE (`check_session_bind_cap/2`) + Dispatch §5.5 (纵深) | O(caps) MapSet 扫描；亚 µs | `{:error, :unauthorized}` | r4 MED — 原来在 Check 3 之后 → 无 session cap 的 caller 触发 adapter I/O |
| 2 | **Cap 2** — caller 持有 `{kind: :session, behavior: <adapter.cap_subject.behavior_module>, instance: <session>, workspace_uri: <ws>}` | facade Check 2 (`check_adapter_allow_cap/3`) + Dispatch §5.5 (自动推导，因为 adapter 的 per-session allow cap 在 AdapterInstall 时注册为 Session 上的 Behavior) | O(caps) MapSet 扫描；亚 µs | `{:error, :adapter_not_authorized}` | r2 HIGH-3 — 从未注册过，因为 Application.start 在 plugin boot 前跑 |
| 3 | **Workspace 隔离预检** — caller 的 workspace == session 的 workspace | facade `check_workspace_iso/2` (本审计新增) + Dispatch §5.6 (纵深) | O(1) URI 比较 | `{:error, :cross_workspace_denied}` | NEW (Q4 — facade 预检避免在跨 workspace target 上浪费 Check 4 的 adapter I/O) |
| 4 | **`target_ownership_check`** — adapter 侧 I/O 验证 caller 在该 adapter 的外部表面拥有 `target_id` | facade Task 带 5s 超时 (`run_target_ownership_check/3`) | bounded 5s adapter I/O | `{:error, {:target_ownership_denied, reason}}` / `{:error, :target_check_timeout}` / `{:error, {:target_check_crashed, reason}}` | r4 MED 顺序 (必须最后跑); r4 HIGH-1 原本在 dispatch 内部 (死锁) |

### 2.2 为什么这个精确顺序

每个 gate 的位置都承重:

- **Gate 1 第一**，因为它最便宜 (caller caps 的 MapSet 成员关系) 而且最通用 — 缺 session bind cap 的 caller 根本不该进 facade。在这失败把所有下游 gate 都省了。
- **Gate 2 第二**，因为 per-adapter cap 也便宜 (同样的 MapSet 形状) 且**最不通用** (针对单一 adapter)。如果 caller 有 gate 1 没 gate 2，他们对 ExternalMirror 通常授权但对此 adapter 没授权 — 这是个真实的 authorization 区分，应该在我们问 "这个 adapter 同意吗" 之前浮现。
- **Gate 3 第三**，因为 workspace 隔离是结构性的 (caller 的 workspace 在其身份 URI 里；session 的 workspace 在 session URI 里)，O(1) 无 I/O。在这里挡跨 workspace 省了 gate 4 对一个本来就不该合法服务跨 workspace target 的 adapter 的网络往返。
- **Gate 4 最后**，因为它是唯一做 I/O 的 gate (对 Lark / Slack 等的网络调用，bounded 5s)。它也是唯一其结果依赖 ADAPTER 视角而非 BEAM 视角的 gate — 如果 gate 1+2+3 已经说 "不"，我们就不该问 adapter。

**每个顺序关上的泄露向量:** 任何两 gate 互换都引入信息泄露。具体:

- 4-before-3 把 "这个 target 在 adapter 里存在" 泄给跨 workspace caller (r4 MED 几乎重新引入的症状)。
- 4-before-2 把 "这个 target 存在" 泄给没 adapter cap 的 caller (有有效 session cap 但无 adapter cap 即可 target 枚举)。
- 4-before-1 把 "这个 target 存在" 泄给完全没有 ExternalMirror cap 的任意人 (最糟 — r4 MED 实际修的 bug)。
- 3-before-2 信息上无害但对每个被拒调用多花一点 CPU (可忽略)。
- 3-before-1 信息上无害 (workspace 不匹配且无 cap 哪侧先触发都是同一种拒绝)。

**规范顺序 (1, 2, 3, 4) 是保留最小权限信息披露的最低成本顺序。** 本审计把它钉死，使将来对 `Ezagent.ExternalMirror.bind/4` 的修改不能在没有 SPEC 修订的情况下重排 gate。

### 2.3 纵深防御

Gate 1、2、3 也在 `Ezagent.Invocation.dispatch/1` 里跑 (步骤 5.5 / 5.6)。facade 的 inline 预检 **不是** 唯一 enforcement — 它是避免被拒调用到达 dispatch 的优化。`feedback_let_it_crash_no_workarounds` 的不变式适用: 用某种方式绕过 facade 直接 hit `Invocation.dispatch/1` 并带 `?action=external_mirror.bind` 的 caller **仍然** 在 dispatch §5.5 / §5.6 失败 gate 1/2/3，**并且** 在 action body 失败 gate 4，因为 FacadeNonceTable consume 返回 `:error` (没有 claim 过)。4 个 gate 都被 enforce；facade 是按最便宜顺序跑它们的规范入口。

Gate 4 **在 dispatch 侧无纵深防御** — 没有 "在 action body 里重跑 target_ownership_check" 这种等价物，因为 action body 明确 MUST NOT 做 I/O (按父 SPEC §8.2 r6 — Session GenServer 被 slice 变更 + 便宜的 Kind.spawn 框住)。取而代之，gate 4 结构上与 gate "5" 绑定 — FacadeNonceTable。**信任传递** (§3) 在 action body 里替代了重跑 gate 4。

---

## 3. Facade 与 action-body 的边界 + 信任传递

### 3.1 边界契约

| 关注点 | Facade (`Ezagent.ExternalMirror`) | Action body (`Behavior.ExternalMirror.invoke/4`) |
|--------|-----------------------------------|--------------------------------------------------|
| Adapter I/O | YES (只 gate 4; bounded 5s Task) | NO (会阻塞 Session GenServer) |
| Caller-context 读 (caps、workspace) | YES (gates 1、2、3) | YES 通过 dispatch step 5.5 (纵深) |
| DB 写 | YES (AdapterInstall 时 Worker 重新对账) | YES (`insert_binding_row` — 按 §4 先 persist) |
| Slice 变更 | NO (Kind 拥有 slice) | YES (slice 变更的唯一处) |
| `Kind.spawn` for Workers | NO (普通 bind 路径下 facade 不 spawn — 那是 action body 的活；AdapterInstall 是例外，单独在 §5 处理) | YES (`do_spawn_after_persist`) |
| `Invocation.dispatch` 到其他 Kind | NO (会重新进入 caller 进程的 authorization 域) | NO (父 SPEC §8.2 禁止 — adapter 回调也禁止) |

这个划分有一个结构原因: **facade 跑在 caller 进程中；action body 跑在 Session GenServer 中。** 任何 I/O-bound 的事必须在 caller 侧，否则 Session 对该 session 上的所有其他 action (chat send、subscribe call、其他 bind) 都被阻塞超时窗口。任何变更 slice 的事必须在 Session 侧，否则两个 caller 互相覆盖。

### 3.2 信任传递问题

一旦 facade 跑完 gates 1-4，它 dispatch `:bind` 到 Session Kind。action body 需要知道: **"gates 1-4 对此精确 (session, adapter, target, caller) 元组已通过"。**

朴素方案 (PR #317 r2 形状) 是 `args[:_facade_checks_ok] = true`。**这是 r3 CRIT — 真实的 auth bypass。** `args` 在 `Invocation.dispatch/1` 时间点 caller 可控；任何持 session :bind cap (gate 1) 的 VM 内 caller 都可以直接 dispatch 并设置 flag，跳过 gates 2+3+4。他们的 dispatch 过 step 5.5 (gate 1)，他们**完全跳过** facade，action body 信任伪造的 flag，他们 bind 到一个他们不拥有的 target 上一个他们没有 per-adapter cap 的 adapter。

### 3.3 FacadeNonceTable pattern — 规范化

PR #317 (commit `4a1637d8`) 中的修复引入了 `Ezagent.ExternalMirror.FacadeNonceTable`。本审计把它规范化为 facade 与 action body 之间的 **唯一** 信任传递原语。

**性质 (契约):**

1. **`:protected, :named_table` ETS，GenServer 拥有。** 只有 FacadeNonceTable GenServer 能 `:ets.insert/2`。任何 VM 内 caller 能 `:ets.lookup/2` (没关系 — lookup 返回存的元组但 consume 要走 GenServer 实现原子 delete-on-read)。靠直接 ETS 写来伪造要求 elevation 越过 BEAM 的 ETS 访问模型 — 超出应用层 auth 范围 (能写到外部 pid 拥有的 `:protected` 表的进程已经破坏了其他所有安全边界)。

2. **来自 `:crypto.strong_rand_bytes/1` 的 32 字节 nonce。** 256 bit 熵。在单次 bind 窗口内 (~20ms 典型，5s 上限) 猜测不可行。

3. **SPEC-pinned 5 秒 TTL。** 不按部署可配 (按 `feedback_let_it_crash_no_workarounds` — 配置开关本身就是 workaround；需要不同 TTL 的部署在 dispatch 延迟上有结构性问题，应当被 SPEC 修复)。5s 上限是 p99 dispatch 延迟 (~20ms slice 变更 + Kind.spawn) 的 250×，给慢 CI / debug 构建 / 竞争风暴留出余量，同时让被偷 nonce 的利用窗口可忽略。**只允许测试覆盖**: 私有 `claim_nonce/5` ttl 参数 (标 `@doc false`) 让 nonce 过期 invariant 测试能毫秒级跑完; 生产 caller 严禁传它。

4. **绑定到精确元组 `(session_uri, adapter_id, target_id, caller_uri, expires_at)`。** consume 验证四个 URI/term 相等性 + 过期。任何失配 → `:error`。

5. **靠单次 GenServer call 原子 consume。** `consume_nonce/2` 在一个 `handle_call` 内读取 + 验证 + 删除。两个并发 consume 同一 nonce: 恰好一个 `:ok`，另一个 `:error` (call 内 read-then-delete 由 BEAM 单进程串行化保证原子)。

6. **周期扫描** (30s 间隔) 删除过期行使表不能无限增长。扫描用 `:ets.select_delete/2` (每行原子)。

7. **失败形状:** 缺 nonce、过期 nonce、元组失配、replay (第二次 consume) — **四种都拒为 `{:error, :bind_must_go_through_facade}`**。action body 原样传播。caller 对任何伪造尝试都看到同一个 atom — 不泄露具体绊到哪个检查的信息 (探测不同伪造向量的攻击者不应得到提示)。

### 3.4 伪造分析 — 攻击者能与不能

| 攻击 | 需要什么 | 为什么失败 |
|------|---------|----------|
| 猜中合法 nonce | 2^256 次尝试 | 计算上不可行 |
| 直接往 ETS 写伪造 nonce | elevation 到 owner pid 或 `:public` 访问 | 表是 `:protected`；只有 FacadeNonceTable GenServer 能写 |
| Replay 捕获的 nonce | 同 nonce 被消费两次 | 第一次 consume 删除；第二次返回 `:error` |
| 把一个 nonce 重用给不同 target | nonce 绑定到原元组 | consume 验证元组相等；失配返回 `:error` |
| 等过 TTL 再 consume | consume 中的 `expires_at` 检查 | `now > expires_at` 返回 `:error`；扫描也会删 |
| 并发两次 consume 同 nonce | 两个并发进程 | 单 GenServer 串行化；恰一个 `:ok`，另一个 `:error` |
| 拦截 facade-to-dispatch 网络伪造 | 无网络 — facade 在进程内 | 全在 BEAM 内，无线协议可拦 |
| BEAM 内存 dump → 读活 nonce | 跑 BEAM 主机上的 root | 超出应用层 auth 范围 |

唯一已知弱点 — BEAM 主机上的 root — 明确出于范围。威胁模型是 **持部分 cap 的 VM 内 caller**，不是 **主机 root**。这与父 SPEC §4.2 隐含假设的威胁模型一致。

### 3.5 为什么不把 `TrustTransfer` 抽到 core 原语

诱人把 FacadeNonceTable 抬升到 `ezagent_core` 的 `Ezagent.TrustTransfer`。**V1 拒绝:**

- **YAGNI** — ExternalMirror 是当前唯一需要 facade↔action 信任传递的 domain。在第二个消费者出现前抬升会招致错形 API。
- `feedback_north_star_plugin_isolation` — 把它留在 `ezagent_domain_external_mirror` 把 plugin 作者挡在又一个 core 表面之外。如果将来某个 Domain 需要同样的 pattern，**那个** PR 在两个具体消费者塑形 API 后再抬到 core。
- 当前实现就是将来抬升的规格。任何拷贝它的人都有这个 5-finding 资历可参考。

**本审计在 domain 内做了一个薄的泛化:** 数据形状从 session/adapter/target 专属移到通用不透明元组，使 PR-EM-FINAL 之后如果 ExternalMirror 内不同 facade/action 对需要同样 pattern，可以无命名耦合地重用。模块名仍是 `Ezagent.ExternalMirror.FacadeNonceTable` (改名 `TrustTransfer` 会暗示更广 scope，这里还不该取)。

---

## 4. 原子性契约

### 4.1 `:bind` — 先 persist、后 spawn、补偿删除

**规范顺序 (PR #317 commit `4cc0e237`):**

```
do_bind:
  1. insert_binding_row(session_uri, binding)
       → {:ok, :persisted}                            -- 新插入
       | {:ok, :idempotent_unique_conflict}           -- 同元组竞争赢家已插入
       | {:error, {:db_insert_failed, %Changeset{}}}  -- 真实 DB 错误 (NOT NULL / FK / 校验)

  2. 对 :persisted 与 :idempotent_unique_conflict 两种情况:
     spawn_worker_idempotently(session_uri, binding)
       → :ok                                          -- {:ok, _pid} 或 {:already_started, _pid}
       | {:error, :worker_spawn_failed}               -- 重试耗尽

  3. on :ok: 更新 slice 把新 binding 加入，返回成功 map
     on {:error, :worker_spawn_failed} 当 persist 已成功之后:
       补偿删除 (BindingRow.delete_by_natural_key/3)
       传播 :worker_spawn_failed
```

### 4.2 错误分类 — 区分，不要 blanket

r5 之前，`persist_binding_row/2` 匹配 `{:error, %Ecto.Changeset{}}` 然后 blanket 返回 `:ok` "for unique-constraint idempotency"。这 silently 丢失真实失败 (NOT NULL / FK / 校验)。r5 之后，`insert_binding_row/2` 用 `unique_constraint_violation?/1`:

```elixir
defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
  Enum.any?(errors, fn
    {_field, {_msg, opts}} when is_list(opts) ->
      Keyword.get(opts, :constraint) == :unique
    _ -> false
  end)
end
```

它只匹配 error opts 列表中带 `constraint: :unique` 的 changeset。按 `BindingRow.insert/1` 声明，命名 natural-key 索引和默认名 PK 约束都可能触发 — 两者都是幂等情况 (其他 caller 的并发同元组 bind)。任何**其他** changeset 错误是真实失败: **契约是 `{:error, {:db_insert_failed, cs}}` — 原样传播，不要吞。** 调用方 (do_bind 的 `with`) 返回这个给 facade；facade 返回给用户；slice + worker 保持不变。

### 4.3 补偿删除 — 何时、为什么、幂等

如果 `spawn_worker_idempotently` 在 `insert_binding_row` 返回 `:persisted` 或 `:idempotent_unique_conflict` 之**后**返回 `{:error, :worker_spawn_failed}`，projection 表有行但无活 worker。按 P3 (单一真相源) 与父 SPEC §7.1 契约，"`external_mirror_bindings` 中的行" → "PerBindingSupervisor 中的 worker"。有行无 worker 是破坏的不变式。

**补偿:** `BindingRow.delete_by_natural_key(session_uri, adapter_id, target_id)` 删行。这是幂等的 (删缺失行是 no-op)。

**边界 — 并发赢家存活:** 如果我们的 `do_bind` 输掉 spawn 竞争 (其他 caller 的 worker `{:already_started, _}` — 我们不把这看作 `:worker_spawn_failed`；我们看作 `:ok`)，不跑补偿。好。

**边界 — 并发赢家也失败:** 如果我们的 spawn 重试耗尽**且**赢家的 spawn 也耗尽 (同一 `KindRegistry.put_new` 外部 pid 阻塞影响两者)，两 caller 都跑补偿删除。第一次删除移除行；第二次 no-op。最终状态: 无行、无 worker，两 caller 都看到 `:worker_spawn_failed`。正确 — 都没拿到能工作的 binding，projection 表如实反映。

**边界 — 赢家成功，我们耗尽:** 如果这里跑补偿删除，我们会删赢家依赖的行。**不可能发生**: 如果赢家成功，其 `Kind.spawn` 返回 `{:ok, _}`；我们的 `spawn_worker_idempotently` 然后从 registry 看到 `{:already_started, _}` 并返回 `:ok`，**不是** `:worker_spawn_failed`。"赢家成功且我们耗尽" 分支不可能，因为他们共享 registry 作为真相源。

### 4.4 `:unbind` — slice 变更 → DB 删 → Worker 终止

`unbind` 顺序 (action body, 父 SPEC §8.2):

```
do_unbind:
  1. WorkerSpawn.terminate(session_uri, adapter_id, target_id)
  2. BindingRow.delete_by_natural_key(session_uri, adapter_id, target_id)
  3. 更新 slice (从 bindings 列表移除)
  4. 返回成功
```

worker 是 (slice + DB row) 的 **派生视图**。先终止它意味着清理窗口期内不会有 SliceChange 事件触发到一个孤立的订阅者。slice 变更最后意味着 slice 读者 (`list_bindings`) 看到 "binding 存在" 直到 worker 与 row 都消失的那一刻 — 一个短窗口期读者看到的 binding 其 worker 已死，但该窗口由 action body 的串行化框住 (此 action 完成后的下一次 slice 读取看到已清理状态)。

**幂等性:** 对不存在的 binding `unbind` 返回 `{:ok, %{ok: true, unbound: false}}`。三个子操作各自独立幂等 (terminate 缺失 worker、delete 缺失 row、从无的 slice 中移除)。

### 4.5 AdapterInstall 触发 — 必须等两个 registry 都填充

按 r5 HIGH-A finding 与 PR #317 commit `4cc0e237` 的修复:

> `AdapterRegistry.register/1` 之前对新插入无条件触发 `AdapterInstall.install/1`。但 install/1 走持久化的 binding 行并 spawn worker，其 dispatch 路径通过 `BindingRegistry.lookup!/1` 查 binding 模块 — 而 `Plugin.publish_adapters!` 在 adapter 之**后**注册 binding。所以 install 跑时 BindingRegistry 对这个 adapter_id 还空 → spawn 的 worker 会在首次 publish 事件 crash。

修复: 拆为 `maybe_install/1` (从 `AdapterRegistry` 调) 与 `maybe_install_by_adapter_id/1` (从 `BindingRegistry` 调)。各自检查**另一个** registry 是否已有此 `adapter_id` 的条目，再触发 `install/1`。**第二个注册的那方触发 install — 两个 registry 此时都填充了。** 对称所以注册顺序无关。

此 pattern 泛化为 **core 原语**: 见 §5。

---

## 5. `Ezagent.Plugin.publish_after_all_registered/2` — 新 core 原语

### 5.1 模式

"等两个 registry 都对同一 key 有条目后再触发 hook" 的模式 **结构上通用**。ExternalMirror 是第一个消费者；未来的跨 registry 依赖 (如某 plugin 对同一流暴露 routing rule 与 template class，install 要两者都到位) 会从同样的原语受益。

本审计把模式从 `Ezagent.ExternalMirror.AdapterInstall` 抬升到 `apps/ezagent_core/lib/ezagent/plugin.ex` 的 `Ezagent.Plugin`。

### 5.2 API

```elixir
@spec publish_after_all_registered(
        registries :: [{registry_module :: module(), key :: term()}],
        hook_fn :: (-> :ok)
      ) :: :ok

# 范例 (AdapterInstall 消费者):
Ezagent.Plugin.publish_after_all_registered(
  [
    {Ezagent.ExternalMirror.AdapterRegistry, adapter_id},
    {Ezagent.ExternalMirror.BindingRegistry, adapter_id}
  ],
  fn -> Ezagent.ExternalMirror.AdapterInstall.install(adapter_module) end
)
```

### 5.3 契约

1. **`registries`** — 非空的 `{registry_module, key}` 列表。每个 `registry_module` 必须实现两个 callback:
   - `subscribe_register/2 :: (key, ({:ok, value} | :error -> :ok)) -> :ok` — 订阅在 `register/n` (任意 arity) 为 `key` 插入新条目时触发。
   - `lookup/1 :: (key) -> {:ok, value} | :error` — 同步检查 `key` 是否已有条目。
   - 这些 callback 是 `publish_after_all_registered` 调用的契约；registry 模块拥有实现细节。

2. **`hook_fn`** — 零参函数，所有 `registries` 对其 key 都有条目时**触发一次**。幂等: 如果调用时已经全部注册，立即同步触发；如果未，注册一次性 hook，最后一个落下时触发。

3. **跨重新调用幂等:** 同一 `(registries, hook_fn)` 调用两次，`hook_fn` 在 "全部到位" 转换中最多触发一次。当前 ExternalMirror 消费者模式 (maybe_install 触发其 body 幂等的 `install/1`) 优雅处理罕见的二次触发；未来消费者应写幂等的 hook。

4. **热卸载 (V2):** 当 registry 条目被**移除** (如 `__delete__/1`)，原语不触发任何 "uninstall" hook。按父 SPEC §10，热卸载是 V2 scope。

### 5.4 实现 — 最小化，住 `ezagent_core`

实际实现 ~80 LOC:
- `Ezagent.Plugin.RegistrationHooks` GenServer 拥有按 `[{registry_module, key}]` 列表索引的待触发 hook 的 `:protected` ETS。
- 每个想参与的 `*Registry` 模块加一个薄的 `subscribe_register/2` callback，从其成功插入路径调 `RegistrationHooks.notify_subscribers(__MODULE__, key)`。
- `publish_after_all_registered/2` 若所有 registry 有 key 则立即解析；否则插入一个 hook 记录，`:ets` 监视 `notify_subscribers` 触发的 "全部到位" 转换。

### 5.5 ExternalMirror 作为第一个消费者

PR-EM-AUDIT (实现 PR) 把 `Ezagent.ExternalMirror.AdapterInstall.maybe_install*/1` 的 body 替换为对 `Ezagent.Plugin.publish_after_all_registered/2` 的一次调用。两个 registry (`AdapterRegistry`、`BindingRegistry`) 加 `subscribe_register/2` shim。已有测试 (PR #317 r5 加的 2 个 — "register adapter alone → no install; then binding → install fires" 与对称路径) 移到针对新原语跑 — 它们仍通过而无需修改，因为可观察契约不变。

### 5.6 为什么 core 而非 domain

严格说 ExternalMirror 可以把模式留在内部。**抬升到 core 因为:**

- 原语在观察上是关于 "plugin 注册完整性" — 那是 `Ezagent.Plugin` 关注，不是 ExternalMirror 关注。
- 未来写跨 core 的两个 registry 注册扩展代码的 plugin 作者 (如同一流既需 RoutingRegistry 也需 TemplateRegistry) 会有同样需求。现在抬升意味着他们伸手够 `Ezagent.Plugin.publish_after_all_registered/2`，而不是发明 poll 循环或 domain 内部 hook。
- 按 `feedback_north_star_plugin_isolation`: "tiebreaker 是把 plugin 作者挡在 core 之外"。Plugin 作者被挡在 `Ezagent.Plugin.RegistrationHooks` 之外 (它是内部 GenServer)；他们只看到公开的 `publish_after_all_registered/2` API。净: core 表面增加一个公开函数，换取消除一类 "我注册了 X 但 install 没触发" 的 plugin bug。

---

## 6. 集体 invariant 测试 — gate

### 6.1 位置 + 形状

按 `feedback_completion_requires_invariant_test`: 本审计 "完成" 的判定是单一架构目标测试存在且在 PR #317 12 finding 中任何一个 (或结构性相似的新 finding) 被重新引入时会失败。

**位置:** `apps/ezagent_domain_external_mirror/test/invariants/auth_model_invariant_test.exs`

**形状:** 单一测试**文件** (不是单一测试)。14 个场景 (按 §6.2 编号 `1..14`)，每个有:

- `@moduledoc` 头引用其回归保护的 PR #317 codex finding 来源 (如 `# scenario 7 — regression for PR #317 codex r3 CRIT: _facade_checks_ok forgery`)。
- 聚焦的 `test` 块。
- 断言同时证明 (a) 失败形状恰好是规格化的，**且** (b) 没有下游工作发生 (无 adapter I/O、无 DB 行写入、无 worker spawn、无 slice 变更)。

### 6.2 14 个场景

| # | 名称 | 测试 | 回归保护 |
|---|------|------|---------|
| 1 | Cap 1 拒绝 (无 session :bind cap) | 返回 `{:error, :unauthorized}`；mock adapter 的 `target_ownership_check/2` 调用计数 == 0；DB 无行 | PR #317 r4 MED |
| 2 | Cap 2 拒绝 (有 session cap，无 per-adapter cap) | 返回 `{:error, :adapter_not_authorized}`；mock adapter 调用计数 == 0；DB 无行 | PR #317 r2 HIGH-3 |
| 3 | Workspace 隔离拒绝 (facade 预检，gate 3) | 返回 `{:error, :cross_workspace_denied}`；mock adapter 调用计数 == 0；DB 无行 | NEW (Q4 = B) |
| 4 | Workspace 隔离拒绝 (dispatch §5.6，绕 facade) | 直接 `Invocation.dispatch/1` 跨 workspace caller 仍返回 `{:error, :cross_workspace_denied}` | 纵深防御 |
| 5 | `target_ownership_check` 拒绝 | 返回 `{:error, {:target_ownership_denied, :not_a_member}}`；DB 无行；registry 无 worker | 父 SPEC §8.2 r6 (facade-vs-action 划分) |
| 6 | `target_ownership_check` 超时 | Mock adapter sleep > 5s (测试用降低的超时)；返回 `{:error, :target_check_timeout}`；无行；无 worker | 父 SPEC r4 MED |
| 7 | Nonce 伪造 (args 中随机 nonce) | 直接 dispatch 带 `args[:_facade_nonce] = <random 32 bytes>` 返回 `{:error, :bind_must_go_through_facade}`；无行；无 worker；无 slice 变更 | PR #317 r3 CRIT |
| 8 | Nonce replay (同 nonce 消费两次) | 第一次 consume 成功；第二次 consume 从 FacadeNonceTable 返回 `:error` → action body 返回 `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 9 | Nonce 过期 (sleep 过 TTL) | 用很短 TTL claim nonce；sleep 过期；consume 返回 `:error`；action body 返回 `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 10 | Nonce 元组失配 (不同 session/adapter/target) | 为元组 A claim；用元组 B consume → `:error`；action body 返回 `{:error, :bind_must_go_through_facade}` | PR #317 r3 CRIT |
| 11 | DB insert NOT NULL 违反 | 强制 `BindingRow.insert/1` 以非 unique changeset 错误失败；action body 返回 `{:error, {:db_insert_failed, _}}`；**不**是幂等成功；无 worker spawn | PR #317 r5 HIGH-B |
| 12 | Worker spawn 在 row 持久化**之后**失败 | 在 worker URI 下的 `KindRegistry` 预注册外部 pid；bind 触发补偿删除；行移除；返回错误 `{:error, :worker_spawn_failed}` | PR #317 r4 HIGH-2 + r5 HIGH-B |
| 13 | AdapterInstall 顺序 (registry 任意顺序落) | register adapter alone → 无 worker spawn (BindingRegistry 空)；register binding → install 触发；worker spawn。再对称: binding-first → adapter-second → install 触发。 | PR #317 r5 HIGH-A |
| 14 | Happy path (所有 gate 通过) | 4 个 gate 全通过；DB 恰好 1 行；`KindRegistry` 恰好 1 worker；slice 恰好 1 binding；nonce 已 consume (FacadeNonceTable 无残留) | Sanity gate |

### 6.3 测试在返回值之外断言什么

对场景 1-6、11、12: 每个测试必须断言**没有下游可观察变更发生**。具体:

```elixir
# 每个 "拒绝" 测试用的辅助
defp assert_no_downstream_work(session_uri, adapter_id, target_id, mock_adapter) do
  # 1. adapter I/O 没触发 (gate 1、2、3 应在 gate 4 前短路)
  assert MockAdapter.call_count(mock_adapter, :target_ownership_check) == 0

  # 2. DB 行未写
  assert {:error, :not_found} =
           BindingRow.fetch_by_natural_key(session_uri, adapter_id, target_id)

  # 3. Worker 不在 KindRegistry
  worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)
  assert :error = KindRegistry.lookup(worker_uri)

  # 4. Slice 没变更 (对此元组仍 0 binding)
  {:ok, slice} = Ezagent.Kind.get_slice(session_uri, :external_mirror)
  refute Enum.any?(slice.bindings, &(&1.adapter_id == adapter_id and &1.target_id == target_id))
end
```

场景 5+6 豁免断言 #1 (adapter 调用**必须**触发以使 gate 4 拒绝)。场景 7-10 豁免 #1 (gate 4 已在 facade 的 "claim" 路径通过；拒绝在 action body 的 consume)。场景 11 豁免 #3 (insert 在 spawn 前失败)。场景 12 预期 #2 在测试中从 "行存在" 翻到 "行不存在" 当补偿运行时。

### 6.4 此 invariant 防止什么

如果未来贡献者:
- 重排 facade 中 gate 1-4 → 场景 1、5 可能失败 (cap 拒绝返回错形状或 adapter I/O 在不该触发时触发)。
- 重新引入可伪造的信任传递 flag → 场景 7 失败。
- 忘记 FacadeNonceTable 过期检查 → 场景 9 失败。
- 移除 persist-first 顺序 → 场景 11 可能 silently 通过 (取决于哪条路径被破坏) **但** 场景 12 失败 (补偿删除 + row 状态)。
- 把 AdapterInstall 回退到 AdapterRegistry insert 无条件触发 → 场景 13 失败 (worker 在 binding 注册前 spawn)。
- spawn 耗尽时返回 `:ok` 而非 `{:error, :worker_spawn_failed}` → 场景 12、14 失败 (状态分歧)。
- 破坏 workspace 隔离 facade 预检**或** dispatch §5.6 → 场景 3 或 4 分别失败。

**invariant 测试就是 gate。** 按 `feedback_completion_requires_invariant_test`: "在架构目标未达成时会失败的测试 — 那就是 gate"。此测试失败结构上等价于 "审计目标未达成"。

### 6.5 测试人体工学 — 辅助，不重复

`test/support/auth_model_test_helpers.ex` 提供:

- `MockAdapter.new(target_check_response: ..., delay_ms: ..., call_counter: :start)` — 记录每次 callback 调用的 instrumented mock。替代每测试的临时 mock 以更干净复用。
- `setup_caller(ctx :: %{caps: ..., workspace: ...})` — 构造带所请求 gate 的 cap 的 `caller_ctx` map。
- `bypass_facade_dispatch(session_uri, adapter_id, target_id, args_overrides)` — 构造一个绕过 `Ezagent.ExternalMirror.bind/4` 的 `Invocation.dispatch/1` 调用。供场景 4、7、8、9、10 用。
- `assert_no_downstream_work/4` — 如 §6.3 所示。

`test/ezagent/behavior/external_mirror_test.exs` 与 `test/ezagent/external_mirror/facade_test.exs` 中的已有测试**不**移除 — 它们仍测试单独代码路径。invariant 测试是**架构** gate；聚焦测试是单元级。**两层共存。**

---

## 7. 迁移计划

### 7.1 PR 范围

本审计产出 **两个 PR**:

**PR A — SPEC PR (本文档):**
- 分支: `docs/external-mirror-facade-audit-spec`
- 加: `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` + `.zh_cn.md`
- 标题: `docs(spec): facade auth-model audit — 4 gates + trust transfer + atomicity + invariant test`
- 正文: meta-finding 总结 + 章节头 + handoff 上下文 + 4 个 Allen 已定的答案 (Q1=A inline, Q2=A SPEC-pinned 5s, Q3=B 抬到 core, Q4=B facade 预检)
- Codex: `/codex:adversarial-review --background`。只 r1。若 r1 有架构 HIGH/CRIT，升级 Allen (没有审计上的审计)。
- 合并: 通过后 `gh pr merge --admin --squash --delete-branch`

**PR B — 实现 PR (PR A 合并后):**
- 分支: `feat/external-mirror-facade-audit-impl`
- 加:
  - `apps/ezagent_core/lib/ezagent/plugin.ex` — `publish_after_all_registered/2` (~30 LOC 公开 API)
  - `apps/ezagent_core/lib/ezagent/plugin/registration_hooks.ex` — 背后的 GenServer (~50 LOC)
  - `apps/ezagent_core/test/ezagent/plugin/registration_hooks_test.exs` — 原语的单元测试 (~80 LOC, ~5 场景)
  - `apps/ezagent_domain_external_mirror/test/invariants/auth_model_invariant_test.exs` — 14 场景架构 gate (~400 LOC)
  - `apps/ezagent_domain_external_mirror/test/support/auth_model_test_helpers.ex` — 测试人体工学 (~120 LOC)
- 改:
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex` — `maybe_install*/1` body 变为对 `publish_after_all_registered/2` 的一次调用
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex` — 加 `subscribe_register/2` callback
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_registry.ex` — 加 `subscribe_register/2` callback
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex` — 加 `check_workspace_iso/2` gate 3 facade 预检 (§2 表)
  - `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex` — 按 §3.3 标 `claim_nonce/5` ttl 参数 `@doc false` (无其他变更)
- 净 LOC: ~+650 生产 / +100 测试重构 (已有 8 个 r3 nonce 测试 + 5 个 r5 原子性测试在重叠处并入 14 场景 invariant 套件)
- 标题: `feat(external-mirror): facade auth-model audit — primitive + invariant test`
- Codex: `/codex:adversarial-review --background`。如需可到 r2。r3+ 升级 Allen。
- 合并: 通过后 `gh pr merge --admin --squash --delete-branch`

### 7.2 本审计**不**改什么

- 4 个 gate 的 enforcement 代码 (PR #317 r4/r5 已发)。已有测试保持绿。
- FacadeNonceTable 的运行时行为 (PR #317 r3 已发)。已有 8 个 nonce 测试保持绿。
- action body 的 persist-first/spawn-after 顺序 (PR #317 r5 已发)。已有测试保持绿。
- AdapterInstall maybe_install pattern 的外部可观察行为 (PR #317 r5 已发)。impl PR 通过新原语重新实现其 body — 同样的可观察契约。

审计是 **规范化 + gate**，不是行为重构。行为保留靠已有测试套件 (`main` 上 94 测试通过) **加** 新 invariant 测试验证。

### 7.3 出范围

- ExternalMirror PR-EM-FINAL (admin UI 清理、CLI 表面、feishu plugin 改写)。父 SPEC §9 跟踪。
- `dispatch.ex ReadyGate/PendingDelivery TOCTOU` (docs/futures/todo.md)。框架级关注；独立 SPEC。
- adapter 的热卸载语义 (父 SPEC §10 列为 V2)。
- 多节点 V2 (父 SPEC §10)。

---

## 8. 明确拒绝的反模式

按 `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05)，本 SPEC **不**包含任何:

1. **`:warning` + 降级路径。** 每个 gate 拒绝返回结构化错误；无 "log warning 然后以降级功能继续" 模式。(r4 HIGH-2 的 `spawn_worker_idempotently → :ok` 正是这反模式；修复返回 `{:error, :worker_spawn_failed}`。本 SPEC 把这修复钉为规范。)

2. **缺数据的默认值 / fallback。** 无 "cap 缺失则默认允许"。无 "workspace 不匹配则默认 caller 的 workspace"。缺数据是拒绝，不是 fallback。(最接近的 — class-wide cap 的 workspace `:any` — 是来自 caps-data-ownership v2 的**结构化授予形状**，不是默认；它表示 "明确授予的 admin 通配符"，由 `admin_wildcard?/1` 验证。)

3. **auth 边界的白名单 / allowlist。** 无 "此 adapter_id 豁免 gate 4"。无 "此 caller URI 绕过 cap 检查"。gate 在所有 adapter 与 caller 上统一；admin 通配符 (适用时) 是**结构化 cap**，不是隐式 allowlist。

4. **绕过结构性问题的配置开关。** FacadeNonceTable TTL 是 SPEC-pinned 5s，不是 `config :ezagent, :facade_nonce_ttl_ms`。需要不同 TTL 的部署在 dispatch 延迟上有结构性问题，本 SPEC 会通过改 dispatch 路径解决，而不是暴露开关。仅测试覆盖通过 `@doc false` 允许。

5. **针对 r3 之前 `_facade_checks_ok` flag 的 shim / 兼容层。** flag 已删；任何依赖它的 caller (`main` 上没有) 会响亮断裂。按父 SPEC Allen 2026-05-24 "no migration / no back-compat" 规则不提供向后兼容。

6. **对用户输入 `String.to_atom/1`。** caller 提供的 `opts` keys 保持字符串 (PR #317 r1 HIGH 修复)；SPEC 把这钉为规范。想要 atom keys 的 adapter 用 `String.to_existing_atom/1` 对编译期固定 allowlist 转换。

---

## 9. 开放问题 — 无

按 handoff 文档 `/tmp/handoff-facade-audit.md`，Allen 2026-05-25 已定 4 个开放问题:

- **Q1:** Cap 1 检查位置 → **facade INLINE** (按 r4 MED 状态)。烘焙在 §2.1 + §3.1。
- **Q2:** FacadeNonceTable TTL → **SPEC-pinned 5s** (不可配)。烘焙在 §3.3 + §8.4。
- **Q3:** "等相关 registry" 抽象 → **抬到 core** 为 `Ezagent.Plugin.publish_after_all_registered/2`。烘焙在 §5。
- **Q4:** Workspace 隔离 (gate 4 → 重编号为 gate 3) → **facade 预检** 先于 target_ownership_check (现在 gate 4)。烘焙在 §2.1 + §2.2。

实施前无需进一步设计讨论。Codex r1 可能浮现实现层开放问题；那些在 PR B 的迭代中处理，不在另一轮 SPEC 中。

---

## 附录 A — 交叉引用

- 父 SPEC: `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §4.2 / §8.2 / §3.1 / §7.1
- Caps SPEC: `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` §3.1 (data_owner) / §5.2 (grant enforcement)
- PR #317 commits (每个 commit body 是第一手来源):
  - a9d40af — PR-EM-3 基础实现
  - 89904b9 — r1 修复 (CRIT row-id + HIGH atom DoS)
  - 931a0203 — r2 修复 (HIGH-1+3 统一 AdapterInstall + HIGH-2 读 CapBAC)
  - 4a1637d8 — r3 修复 (CRIT FacadeNonceTable + HIGH-1 per-session read filter + HIGH-2 unique_constraint)
  - 017f5ff2 — r4 修复 (HIGH-1 BootReconciler 重试 + HIGH-2 let-it-crash + MED Check 1 顺序 + META 审计记录)
  - e3ca119f — r5 捕获 (HIGH-A AdapterInstall 顺序 + HIGH-B spawn-before-persist；已升级)
  - 4cc0e237 — r5 修复 (原子 persist-then-spawn + 对称 AdapterInstall 顺序)
- `docs/futures/todo.md` — "Facade-auth-model security audit" 章节承载本 SPEC 规范化的同样 5 个 r5 起点
- 记忆: `feedback_let_it_crash_no_workarounds`、`feedback_completion_requires_invariant_test`、`feedback_north_star_plugin_isolation`、`feedback_spec_codex_adversarial_review`

---

## 附录 B — "为什么不也抬 TrustTransfer" 决策矩阵

| 选项 | 表面变更 | 未来成本 | YAGNI 结论 |
|------|---------|---------|----------|
| FacadeNonceTable 留 domain.external_mirror，同名 | 0 模块移动 | 下个消费者来时那 PR 抬 | ✓ 选 |
| 泛化为 `Ezagent.ExternalMirror.TrustTransfer` (同 domain) | 1 模块改名 | 下个消费者无需抬即可重用 | ✗ 早 (尚无第二消费者) |
| 抬到 `ezagent_core` 的 `Ezagent.TrustTransfer` | 1 模块跨层移动 | 下个消费者跨 domain 重用 | ✗ 早 + 违反 plugin-isolation 北极星，直到第二消费者塑形 API |

`publish_after_all_registered/2` 原语**确实**抬到 core 因为 (a) 它结构上是 Plugin 关注，不是 ExternalMirror 关注，**且** (b) 下个消费者可预见 (任何带跨 registry 依赖的 plugin)。TrustTransfer 的下个消费者在 V1 **不**可预见 — 代码库里还没另一个 facade 需要对 action body 的伪造证明 handoff。当有时，那 PR 的作者将以 FacadeNonceTable 作为已工作的范例来抬。
