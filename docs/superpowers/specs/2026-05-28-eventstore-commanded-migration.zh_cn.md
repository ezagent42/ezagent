# SPEC — Ezagent 状态模型迁移到 EventStore + Commanded (CQRS / 事件溯源)

**状态：** r7 — **§1.5.7 添加 + codex r1 评审；结论 = Option B''（原生整合）**。Allen 2026-05-28 09:33 指令：ezagent 9 个月来一直在**有机地**实现事件溯源的原语 — 只是从未把它们**命名**为 ES 原语。§1.5.7 把存在的部分形式化 + 加上缺失的 30%，参考 Commanded 的设计教训 + CQRS 原则。主推荐：**Option B'' — 原生整合**，5 个内部模块共 ~880 LOC，约 2-3 周。Option B（Sage + ex_audit + Oban）保留作第一备选若 B'' 设计失败；Option A（Commanded 完整迁移）作第二备选若回放（P5）进入 6 个月窗口。B'' 是**面向未来 Commanded 的**：未来迁移到 Commanded 时成本从 ~10-12 周（Option B）压缩到 ~6-14 周（r7 诚实区间见 §1.5.7.5(e)；下限取决于 saga 清单 + 多少 Kind opt-in）。Codex r1 评审 §1.5.7 返回 REJECT 3 HIGH + 2 MED + 1 LOW；全部 6 条 inline 修复（合成事件不可回放须显式承认 / User Kind 实际是 Identity + UserCredentials + UserTokens + IdentityAdmin / SagaRunner-PM 「1:1」改为 convergent 不是 wrapping / EventLog 排序加 `id` tie-breaker / EventSubscriber partition 模式拉到 Phase 2 / audit args+result 当前未填充承认）。之前 r6 结论（条件性 Option B）降级为第一备选。之前的 r4-FINAL 状态若日后重审 Option A 仍适用于 §2-§12。2026-05-28。

## r7 changelog（相对 r6 的 delta）

Allen 2026-05-28 09:33 指令 — 「ezagent 在有机地做事件溯源；命名它 + 加缺失的 30%，参考 Commanded；B'' 成为推荐路径；B'' 是面向未来 Commanded 的，不是反 Commanded」。

- **§1.5.7 插入** — 「原生整合路径（Option B''）— 把 ezagent 已经在建的形式化，参考 Commanded」。7 个子节，约 600 行：
  - §1.5.7.1 — 前提：ezagent 在有机地做 ES（现有原语清单 + 修正 §1.3 关于「无事件日志」的说法）
  - §1.5.7.2 — 逐概念对比（ezagent 今天 | Commanded canonical | B'' 改进），覆盖 8 个 ES 概念：事件日志、命令/事件分离、aggregate 身份、snapshot、状态恢复、saga、投影、事件版本
  - §1.5.7.3 — CQRS 原则的应用（引用 5 条原则的源 URL + 具体的模块签名改动）：命令/查询分离（Greg Young）、事件作真理源（Fowler）、Aggregate 边界纪律（Vernon）、读侧最终一致性（Young）、幂等
  - §1.5.7.4 — 5 个具体的新内部模块（`Ezagent.EventLog`、`Ezagent.SnapshotStore`、`Ezagent.Kind.StateRebuilder`、`Ezagent.SagaRunner`、`Ezagent.EventSubscriber`），各自的签名、扩展点、测试策略、LOC 估算（合计 ~880 LOC）
  - §1.5.7.5 — 未来扩展点 roadmap（5 个场景：归档表、按 Kind 回放 opt-in、saga 持久 outbox、投影表、未来 Commanded 迁移）
  - §1.5.7.6 — 4 选项对比表（A vs B vs B' vs B''）跨 14 个维度，包括关键的「若未来需要 Commanded 时的迁移成本」一行（B'' 最短，~4-6 周）
  - §1.5.7.7 — 推荐：B'' 主选；Option B 第一备选；Option A 第二备选
- **§1.5.5 结论 更新** — B'' 成为主推荐；r6 的条件性 Option B 降级为第一备选若 B'' 设计有问题；Option A 第二备选。成本对比扩到 4 个选项。
- **§1.5.6 下游影响 更新** — 配套 SPEC 计划从「1 个广 / 3 个小 Path B SPEC」改为「5 个小 B'' SPEC（每个新模块一个，来自 §1.5.7.4）」。每个约 2-3 周独立落地。
- **顶部状态横幅** 重写 — 结论 = Option B''；备选顺序明确。

§1.5.1-§1.5.4（备选表 + 库风险 + 逐场景深挖）**未改** — 它们描述 Option B 的证据，作第一备选理由仍站得住。

§2-§12（Commanded 完整迁移材料）**未改** — 保留作第二备选场景。

**r7 codex r1 评审（2026-05-28，r7 初始提交 2816befd 后）** — §1.5.7 对抗评审返回 **REJECT — 3 HIGH + 2 MED + 1 LOW**。全部 6 条 inline 修复；§1.5.7 扩出 ~200 行。

- **HIGH-1 — Legacy `invoke/4` 合成事件不可回放（§1.5.7.2.b）**。初稿把 `%SliceMutated{}` 合成事件当成包括回放在内的可行 fallback 路径。Codex 追踪 `Behavior.Chat.invoke(:send)`（`chat.ex:297-370, 408-414`）显示 `MessageStore.write` + PubSub 广播 + 接收方派发与 slice 变更同时发生 — 仅从 slice diff 无法重建。**修复**：§1.5.7.2.b 重写 — `%SliceMutated{}` 显式仅作审计/通知/跨 Kind 触发用途；events-as-truth opt-in 要求按 Behavior 的原子三元组（`events_for/4` + `apply_event/2` + `effects/2`）；legacy Behavior 被**排除**在回放外直到三元组落地。
- **HIGH-2 — User Kind 回放路径是理论的（§1.5.7.5(b)）**。初稿说「第一个 Kind 需要回放 → 该 Kind 在每个 Behavior 上实现 events_for/4 + apply_event/2，~2-3 周」。Codex 拉出 User Kind 实际清单（`Identity`、`UserCredentials`、`UserTokens`、`IdentityAdmin` 按 `user.ex:226-231` + `application.ex:271-284`）并显示 `UserCredentials.invoke(:set_password)` 做 bcrypt + `users.password_hash` DB 写，`UserTokens.invoke(:mint_token)` 做 bcrypt + `entity_tokens` INSERT，`UserTokens.invoke(:revoke_token)` 预读 + DELETE — 这些**不是**纯 slice fold。**修复**：§1.5.7.5(b) 重写，含按 Behavior 的回放就绪评估 + 具体 `effects/2` 抽取计划 + 修正 ~3-4 周每 Kind 成本。
- **HIGH-3 — SagaRunner ↔ Commanded PM「1:1」夸大（§1.5.7.5(e)）**。初稿说 B'' → Commanded 迁移「~4-6 周（换 3-4 个内部模块）」，SagaRunner「1:1 映射到 Commanded PM」。Codex 正确标记：PM 有状态（3 callback：`interested?/1` + `handle/2` + `apply/2` + 按实例 correlation-id PM 状态）；SagaRunner 无状态（2 函数，闭包）。不是 1:1。**修复**：§1.5.7.5(e) 重写，含按组件诚实分解 — `EventLog`/`SnapshotStore`/`EventSubscriber` 是近 1:1 wrap（各 ~1 周）；`SagaRunner` → PM 要翻译（每个非平凡 saga ~3-4 周，加上跨调用工作流的额外成本）；slice-per-Behavior → single-aggregate-state 要决定融合或拆分。修正总数：~6-14 周区间。对比表行 + §1.5.7.7 推荐 #3 同步更新。
- **MED-4 — EventLog 排序 tie-breaker（§1.5.7.4 #1）**。初稿只按 `inserted_at` 排序；同微秒 tie 不稳。**修复**：加排序契约 — `(inserted_at ASC, id ASC)` 用现有 `invocations.id` 整数主键作 tie-breaker；cursor 分页用 pair。
- **MED-5 — EventSubscriber partition 模式欠规约（§1.5.7.4 #5）**。初稿在 `interested?/1` 返回类型里含 `{:partition, key}` 但无生命周期/GC/顺序/重启契约。**修复**：partition 模式从 v1 callback 返回类型移除；v1 仅返回 `boolean`；partition 模式留到 Phase 2 含 (i) 所有权、(ii) 按 key 顺序、(iii) 崩重放、(iv) GC、(v) 防 handler 重复 五项显式契约。
- **LOW-6 — Audit args/result 今天未填（§1.5.7.1、§1.5.7.2.a）**。SPEC 暗示每个 `invocations` 行都有 args + result JSON；当前 `Audit.Writer`（`audit.ex:93-116`）只在失败路径填，不在成功派发上填。**修复**：§1.5.7.1 承认差距；B'' 承诺通过 EventLog naming 配套 SPEC 扩展 `Audit.Writer` 捕获完整 args + result；「比 Commanded 更 SQL 查询」对比窄化为 args/result 填好后才适用。
- **附加修正 — slice-per-Behavior vs single-aggregate-state（§1.5.7.1）**。Codex 隐式标记：ezagent Kind 在 Kind 上 host 多个 Behavior，与 Commanded 单 aggregate 状态根本不同。**修复**：§1.5.7.1 加显式承认不对称段落 — slice-per-Behavior 真正不同；B'' **不**装作 1:1；未来 Commanded 迁移必须按 Kind 决定融合 vs 拆分。

修正后结论（Option B'' 主选，Option B 第一备选，Option A 第二备选）codex r1 后**不变** — 发现都是结构诚实修复，不是结论翻转。

## r6 changelog（相对 r5 的 delta）

对 §1.5（r5 新增段落）的 codex 评审返回 **REJECT — 3 HIGH + 2 MED**。r6 内联修复全部 5 条；§2-§12 未改。

- **HIGH-1 — P5 roadmap 主张没有内联证据（§1.5.3 P5）**。r5 引「事故复盘 / 未来工作里没有」但无内联证据。r6 降级到「§1.5 里没有当前证据；结论假设 Allen 在 grill-with-doc 时确认」+ 加 4 条未来回放驱动（合规、AI 训练数据、事故后调试、schema 迁移回填）+ 估算 Path B → Option A 的迁移成本（~3-4 个月 wall-time，与今天直接做 Option A 可比）。
- **HIGH-2 — Sage 持久性差距被低估（§1.5.2 矩阵 + §1.5.3 P1/P3）**。r5 说 Sage 完整覆盖 P1/P3 并把 Commanded 的持久 PM 状态贬为「纯粹开销」。r6 矩阵里把 Sage P1/P3 ✅ → ⚠️；P1 结论重写为要求 Path B 包含持久 saga 日志 / outbox（Oban 候选）做跨重启韧性；承认销毁还没上线，所以「没观察到中途崩」不是证据。
- **HIGH-3 — 库陈旧风险没定价（§1.5.4 新增）**。r5 把 Sage 2022-09 + ex_audit 2023-02 陈旧风险一笔带过。r6 加整段 §1.5.4「库依赖风险与依赖姿态」：fork-and-maintain 成本、各库 Ecto 耦合度、5 年情景（Sage 弃用、ex_audit 弃用、两个都弃用）、缓解成本（最差 ~2-4 周 DIY 转向）。即便最差情况 Option B → DIY 转向也比 Option A 第一天的成本低；陈旧本身不翻转结论，但要求锁版本纪律 + 年度审查。
- **MED-1 — Sage 在 P4 上过度声明（§1.5.2 矩阵）**。r5 给 Sage P4 ✅ 理由「Sage 跑在事务里」。r6 把 Sage P4 改为「—」（编排库，不是竞态修复）；L1（Ecto.Multi + DB 约束）是 P4 的明确归属。
- **MED-2 — 配套 Path B 范围（§1.5.6）**。r5 起名 `2026-05-28-destroy-cascade-sage-ex_audit.md` 但 Option B 覆盖 P1+P2+P3+P4。r6 §1.5.6 给 Allen 在 grill-with-doc 里两个选项：(2a) 单个更大 SPEC `2026-05-28-native-workflow-audit-race-hardening.md`，或 (2b — 推荐) 拆三个独立配套 SPEC（竞态强化第一，审计第二，工作流+outbox 第三），符合 cap-vis / URI-canonical 的「小 SPEC 快收敛」先例。

**重编号**：r5 §1.5.4「结论」→ r6 §1.5.5；r5 §1.5.5「下游影响」→ r6 §1.5.6。r6 在原 §1.5.3 和原 §1.5.4 之间插入 §1.5.4「库依赖风险与依赖姿态」。

## r5 changelog（相对 r4 的 delta，保留作 trail）

按 Allen 2026-05-28 08:15 指令添加 — SPEC 必须自我证立**为什么是 Commanded 具体**而非更轻的原生 Phoenix 路径。之前 SPEC 从 §1 问题直接跳到 §2 决策、零备选分析（0 处提到 Sage、ex_audit、"alternatives considered"）。

- **§1.5 插入**在 §1（问题）和 §2（决策）之间 — 「备选方案审视 — 原生 Phoenix 轻路径」。结构：5 条候选路径（L1 Ecto.Multi、L2 Sage、L3 ex_audit、L4 Oban Workflow、L5 DIY）× 5 个痛点（P1 销毁级联、P2 审计、P3 跨-Kind 工作流、P4 竞态、P5 回放）的诚实矩阵 + 5 段逐场景深挖。
- **§1.5 结论 = Option B**（r5 表述；r6 codex 评审降级到**条件性** Option B — 见上方 r6 changelog）。
- **⚠️ §2 前置说明添加**在 §2 顶部 — 标记 §2-§12 反映**被否决的** Commanded 路径，不应按现状合并。§1.5.6（r5 里是 §1.5.5）列出具体下一步（暂停 #442，起草 Path B SPEC）。
- §2-§12 本身**未改** — 逐字保留作上下文 / 若日后 P5 进入 roadmap 时重审。

## r4 后已知限制（带入 grill-with-doc）

Codex r4 REJECT 仍有 4 HIGH + 3 MED 未决。这些**不**继续阻塞 SPEC，原因：(a) 上限的 4 轮预算已耗尽；(b) 每条剩余项是实施 PR 层细节（具体列名、精确宏机制、carry-over 文本叙述一致性），不是架构基础。SPEC 核心架构决策（CQRS/ES + Commanded + 每 Phase 前向 import + facade-aware 一致性）成立；残留是未来 SPEC / 实施 PR 解决的清理。

**Allen 讨论的 carry-over 项目：**

1. **HIGH — §6.1 Phase 10-A 含两个协议块（r2 ExternalMirror 迁移 + r4 Worker-only-via-PubSub 都在）。** Codex 标 §6.1 同时保留 r2 措辞「Migrate `Behavior.ExternalMirror` actions on Session aggregate」与 r4 措辞「Session 完全 legacy」。**需 Allen 决定：** Phase 10-A scope 是 (A) Worker only + PubSub-bridging saga（r4 option a；Session 100% legacy）还是 (B) Worker + Session ExternalMirror slice（r2；部分 Session 迁）。impl-PR-A1 sub-SPEC 落实。

2. **HIGH — §4.8 `@consistency` 机制描述、未规范。** 朴素 Elixir `@attr` 不结构上附函数；invariant 必须用宏/registry（如 `defwrite name, consistency:, projections:`）。SPEC 描述合约但未定义宏形状。**解决：** impl-PR 造宏；宏签名是 sub-SPEC。

3. **HIGH — §6.0 parity 门列名与实际 schema 不匹配。**
   - `entity_profiles` 主键是 `entity_uri`（非 `uri`）；无 `registered_at` 列（用 `timestamps()`）。
   - `entity_tokens` 无 `token_id`/`scope`/`minted_at` 列；有 `id`、`token_hash`、`label`、`expires_at`、`last_used_at`、`workspace_uri`、`entity_uri`、timestamps。
   - **解决：** impl-PR Phase 10-B 的 verify-task sub-SPEC 规范化列名 — 投影列映射到 `entity_uri` + `inserted_at`；aggregate 事件 payload 字段名与投影列名对齐。

4. **HIGH — §6.0 MessageStore SQL 用签名 `recent_in_session/3` 等；实际 API 是 `in_session_since/2` + `recent_in_session/2` + `older_than/3`；`in_session_since` 用严格 `>` 不是 `>=` 且帽 replay。** **解决：** impl-PR 调整 SQL 匹配实际 cursor 语义 + arity。架构选择（archive+projection 上 UNION）不变。

5. **MED — §4.3 Sandbox 行仍写「test fixture only」；§4.1.5 正确分类为生产。** §4.1.5 校正后表叙述未同步。**解决：** impl-PR 起点 trivial 编辑。

6. **MED — §3.8 saga state 注释 + step 2 例子里仍有 r3 旧的「从 projection 读」表述。** execute 代码片段本身正确（读 aggregate state），但周围叙述带 r3 语言。**解决：** impl-PR Phase 10-C saga sub-SPEC 清理；架构选择（authoritative aggregate state）不变。

7. **MED — §6.4 cleanup execute 有崩溃窗口：DROP 成功 → 进程崩 → `.consumed` marker 未写 → 下次 execute（同 receipt）见无 marker、会重试 DROP。** 注：DROP 本身幂等（DROP IF NOT EXISTS），重试不破坏；但审计 trail 丢失原 execution_nonce。**解决：** impl-PR 在同一 execution path 内加 DB advisory-lock + DROP **前**写 `in_progress` audit 行；DROP 后 finalize 到 `consumed`。

**SPEC 在这 7 个 carry-over 明示下、即可进 Allen grill-with-doc。**

---

## r4 changelog（相对 r3 的 delta，保留作 trail）

回应 codex r3 REJECT 的 6 HIGH + 2 MED + 1 corollary HIGH（按 cap-vis / URI-canonical 4-轮上限，这是最终轮）：

- **HIGH-1（§4.1.5 仍误分类）：** r3 把 Echo + NpAgent 标为模糊「per-flavor」靠 `kind_snapshots` — 两者实际 `:ephemeral`（`echo.ex:21`、`np_agent.ex:65`）；Sandbox 标「test fixture only」但生产 `Entity.Agent` 在 `agent.ex:75` 声明它且暴露 `:read/:write_path/:destroy` actions @ `sandbox.ex:86`。**r4 fix：** §4.1.5 表更新 Echo + NpAgent 为 `:ephemeral`（无持久状态 — 仅以 message-reply 事件出现）；Sandbox 行加入 behavior 列表，显式迁移去向：作为 Agent aggregate 命令保留（真实 `:read`/`:write_path`/`:destroy` 命令 on Agent aggregate）。
- **HIGH-2（§4.1 旧「不迁」行与 §6.0 矛盾）：** r3 §4.1 关于 `kind_snapshots` 的行仍说「迁移 Kind 的现有 snapshot **不**迁；首条命令创建新鲜事件溯源状态」— 与 §6.0 强制 import 矛盾。**r4 fix：** §4.1 行重写为：「迁移 Kind 的现有 snapshot 数据经 §6.0 snapshot-import 作每 Phase 的 Step 0 前向迁移。`kind_snapshots` 表 import 后只读；删表本身经 §6.4 preflight 门控。」
- **HIGH-3（§4.8 AST 门追不到 facade）：** r3 AST 门只匹配 `handle_event/3` 中的直接 `Ezagent.CommandedApp.dispatch/2`。实际 LV 写经 facade：`Ezagent.Workspace.add_template/3` @ `workspace_detail_live.ex:307`、`EzagentDomainChat.create_session/3` @ `admin_live.ex:804`、chat.join @ `admin_live.ex:1019`、session routing @ `:1381`、`EzagentPluginFeishu.bind/2` @ `feishu_bindings_live.ex:88`、`ExternalMirror.bind/4` @ `session_external_mirror_live.ex:221`。**r4 fix：** §4.8 双门架构：(Gate 1) 每个 domain-context 写 facade 在公开 `def` 上声明 `@consistency` 模块属性；invariant `FacadeConsistencyDeclaredTest` 验所有发派发的 facade 都带属性。(Gate 2) `LVConsistencyTest` 走 LV `handle_event/3` 找 facade 调用 + 后续 `assign/2` 重读、按 facade `@consistency` 验。Projection→facade 映射表见新 Appendix D。
- **HIGH-4（§6.1 split-brain 对 bind→spawn→subscribe 仍不安全）：** r3 显式跑两份状态存储 + 比对 legacy slice 与 aggregate projection — 但 bind/spawn/subscribe 是一个跨 `:external_mirror` slice + `:publisher` 订阅的工作流，分裂仍不安全。**r4 fix：** Option a 默认 — **完全放弃 split-brain**。Session 在 10-A 保持完全 legacy GenServer（Chat + Publisher + ExternalMirror + OrchestratorAdmin slice 全留）。只有 Worker 迁到 aggregate。`BootstrapWorkerSaga` 订阅 legacy Session 的 `:slice_change` PubSub topic（不是事件流），观察绑定后派发 `%SpawnWorker{}` 到 Worker aggregate；Worker 反向订阅 Session publisher 经 `MigrationBridge` 走 legacy `Invocation.dispatch/1` 到 `Behavior.Publisher.SessionImpl.subscribe_from/4`。无种族；legacy + 新 aggregate 经 PubSub（push）+ bridge（pull）协调。SessionRouter 与 SessionSplitBrainConsistencyTest **删除**。
- **HIGH-5（§6.0 UNION 漏 workspace + cursor 类型错）：** r3 UNION 过滤/排序按 `m.inserted_at` 但漏 `m.workspace_uri == ?`（per `message_store.ex:174`/`:201`/`:149`）。r3 写 `older_than(session_uri, msg_id)` — 实际 cursor 类型是 `DateTime`，不是 msg_id（per `message_store.ex:195`）。**r4 fix：** §6.0 UNION 重写三个 SQL 模板：`recent_in_session(session_uri, workspace_str, n)`、`older_than(session_uri, workspace_str, before_dt :: DateTime, limit)`、`in_session_since(session_uri, workspace_str, since_dt :: DateTime)`。每个 SQL 在两半 UNION 中都带 `workspace_uri` 过滤 + `r.inserted_at` 排序。
- **HIGH-6（§5.1 + §6.0 User projection parity 未真正实施）：** r3 说 §5.1 更新了但 §6.0 verify 仍引用泛 `kind_snapshots.state_binary` parity。**r4 fix：** §5.1 投影列表显式枚举每个 User projection 的 COLUMNS；§6.0 `mix ezagent.aggregate.verify --kind user` 扩展显式 per-表 parity 断言：遍历 `entity_profiles` 每行断言对应 `user_profile_projection` 行 `display_name + email + workspace_uri + registered_at` 相等；遍历 `entity_tokens` 断言对应 `user_tokens_projection` 行 `token_hash + label + last_used_at + workspace_uri` 相等。
- **MED-7（§4.2.3 working-copy 嵌套字段名错）：** r3 写 `source_template_uri` — 实际字段 per `chat.ex:257` 是 `source_agent_template_uri` + `live_worker_uri` + `generation`。**r4 fix：** §4.2.3 working-copy 嵌套形状重写匹配 `default_template_working_copy/0` 原样 — `agent_slots: [{slot_name, source_agent_template_uri, live_worker_uri, generation}]`。
- **HIGH-8（§3.8 step 0 读过期投影）：** r3 `%CaptureDestroyPreSnapshot{}` 从 projection（最终一致）读 caps/sessions/lineage — projection 是最终一致；过期 baseline 不能作补偿源。Lineage 实际在 ETS（`agent_lineage.ex:31`）；caps 是 slice 状态（`identity.ex:89`）。**r4 fix：** Step 0 从 **AUTHORITATIVE** 源直接抓 — aggregate 的 `execute/2` 读 aggregate 自身的 `caps: MapSet`、`lineage_parent_uri`、`sessions: MapSet` 字段（都在 aggregate-load 从事件回放水合；无投影 lag 关心）。Aggregate 状态**就是**真值。
- **MED-9（§6.4 cooldown 其实是 expiry）：** r3 `expires_at = drill_completed_at + 24h` 并称之 cooldown；但 `execute` 允许 `now > drill_completed_at` — DROP 可立即跑。**r4 fix：** receipt schema 加显式 `earliest_execute_at = drill_completed_at + cooldown_hours`（默认 24h）作为**真的** cooldown；`expires_at` 单独成字段（默认 +7d）是有效窗口。Execute 验证 `earliest_execute_at < now < expires_at`。Receipt 一次性消费：execute 成功后写 `.consumed` marker；replay 受 marker 阻挡。`execution_nonce` 由 execute 生成、写 `audit_events` 行作取证。

---

## r3 之前的状态

## r3 changelog（相对 r2 的 delta，保留作 trail）

回应 codex r2 REJECT 的 6 HIGH + 2 MED（r2 无 CRIT — r1 CRIT 已闭合）：

- **HIGH-1（§4.1.5 清单仍错）：** r2 误把 `Ezagent.Workspace` 标为 `{:snapshot, :on_change}`（实际 `:ephemeral` @ `workspace.ex:61`），`ExternalMirrorWorker` 标为 `:on_terminate`（实际 `:ephemeral` @ `external_mirror_worker.ex:71`）；漏 `Ezagent.Entity.System`（真实 Kind，`:ephemeral` @ `system.ex:32`，带 Routing behavior）；漏 `Ezagent.Behavior.IdentityAdmin`（与 Identity 同文件，@ `identity.ex:328`）。**r3 fix：** §4.1.5 用静态校验的 persistence 值重写。新加 §4.1.5-table-note 澄清 `:ephemeral` Kind（Workspace、Worker、System）通过**外部表/registry**持久（Workspace → `workspaces` SQLite + `Workspace.Store`；Worker → `external_mirror_bindings` 重建；System → config-derived bootstrap singleton，不迁，作为 Pty 那样的文档化例外）。§6.0 import 任务按来源逐 Kind 调整。
- **HIGH-2（§4.8 一致性矩阵不全且文件名错）：** r2 引用了不存在的 `agents_live.ex`（实际：`agent_new_live.ex`），用了 TBD 行，漏了诸多 write→read site。**r3 fix：** §4.8 重写为静态校验的 file:line。新增：`users_live.ex:202`（set_password）、`:230`（promote_to_system）、`:250`（revoke from system）、`workspace_detail_live.ex:255`（remove member）、`routing_live.ex:307`（delete_rule）、`agent_api_keys_live.ex:159`（delete_api_key）。`agent_new_live.ex:120` 修正 create-agent。矩阵宣布为**真值**；r3 把不变式升级为 AST 扫描 `Ezagent.Invariants.ConsistencyMatrixTest`：遍历每个 LV 的 `handle_event/3` AST，找到 dispatch + 之后的 `assign/2` 重读，断言用 `:strong`。手表是文档；AST 扫描是门。
- **HIGH-3（§6.1 Phase 10-A 仍自相矛盾）：** r2 留着「Worker first（最小 Kind）— 一个 Kind 迁，其余不变」措辞，同时把 Session ExternalMirror 也拉进来。**r3 fix：** Phase 10-A 重命名为「ExternalMirror slice + Worker — bind-spawn 耦合边界」。「最小 Kind」框架放弃。新段落显式枚举 split-brain 协议：Session 的 `Behavior.Chat` + `Behavior.Publisher.SessionImpl` + `Behavior.OrchestratorAdmin` slice 留 GenServer；只有 `:external_mirror` slice 进 Session aggregate。Session GenServer 活着 AND Session aggregate 有事件流 — 同一 URI 在 10-A 期间**两个**状态存储。派发前流水线按命令来源 Behavior 路由：ExternalMirror 命令 → aggregate；其余 → legacy。新 `Ezagent.SessionRouter` 模块拥有路由决策。不变式：任何触及 Session URI 的测试必须把 GenServer slice 和 aggregate 状态都驱到一致。
- **HIGH-4（§6.0 messages archive 列名/JOIN 错）：** r2 说 "按 `created_at` 过滤"；实际 schema 列是 `inserted_at`（per `20260516070500_phase2_messages.exs:23`）；按 session 历史是 `message_routings ⋈ messages` JOIN（per `message_store.ex:174`）。**r3 fix：** §6.0 messages archive 段落重写：永久查询是有序 UNION，前半 `message_routings ⋈ messages` 过滤 `inserted_at < <cutover_at>`，后半 `session_messages_projection` 过滤 `inserted_at >= <cutover_at>`，按 `inserted_at ASC` 序。`recent_in_session` / `older_than` / `in_session_since` 三个查询形状的 parity 门。
- **HIGH-5（§4.2.1 User 投影仍漏字段）：** r2 把 profile/token 字段加到 aggregate state，但 §5.1 投影表行没反映。**r3 fix：** §5.1 投影表更新 — `user_profile_projection(uri, workspace_uri, display_name, email, registered_at, destroyed?)`；`user_tokens_projection(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`。§6.0 import 加字段级 parity 门：`entity_profiles` + `entity_tokens` 每行回放后必须产生对应投影行。
- **MED-6（§4.2.3 Session working-copy 形状欠定）：** r2 写 `template_working_copy: nil` — 实际默认是结构 map @ `chat.ex:255` 有 `agent_slots`、`routing_rules`、`orchestrator_template_uri`、`default_workspace_uri`、`description`。**r3 fix：** §4.2.3 扩展 — `template_working_copy` 是含 5 个具名子字段的子 struct，默认 per `default_template_working_copy/0`。加 replay 测试：populated working copy Session 重建所有 5 字段。
- **HIGH-7（§3.8 saga step 0 是注释、不是代码）：** r2 文档化 `pre_destroy_caps` / `pre_destroy_sessions` / `pre_destroy_lineage_parent` 在 saga defstruct 注释，实际 `defstruct` 行没有。**r3 fix：** §3.8 saga 重写显式 step 0：`%CaptureDestroyPreSnapshot{}` 命令在 `%AgentDestroyRequested{}` 之后立即 dispatch，aggregate 的 `execute/2` 在命令时读投影、发 `%DestroyPreSnapshotCaptured{}` 事件（payload 含 caps/sessions/lineage_parent），aggregate 的 `apply/2` 写到 aggregate 自身状态。补偿命令在补偿时直接从 aggregate 读 snapshot 字段。defstruct **扩展**这些字段。Step 2 DestroyChildAgents 仍宣布 non-compensable 按 saga forward-only 教条；post-r3 runbook 文档化 operator 修复路径（`mix ezagent.saga.repair --saga DestroyAgentSaga --uri <uri>` 读部分残留 + 发手工清理命令）。
- **MED-8（§6.4 cleanup gate 可被假 ticket 欺骗）：** r2 只验「匹配 docs/runbooks 条目」；不是真 artifact 门。**r3 fix：** §6.4 preflight 要求**drill receipt**：签名 JSON artifact `priv/cleanup_receipts/<timestamp>.json` 含 `{backup_path, backup_sha256, live_row_count, restored_row_count, parity_report_sha256, operator_email, drill_completed_at, expires_at: +24h, signature}`。`mix ezagent.cleanup.drill` 是唯一 writer；drill 时计算 SHA。`mix ezagent.cleanup.execute` 验证：(i) HMAC 签名；(ii) backup SHA 仍匹配；(iii) live DB 行数与 receipt 匹配（自 drill 起未变）；(iv) 重跑 parity；(v) `operator_email` 在 `priv/cleanup_operators.allowlist`；(vi) `drill_completed_at < now < expires_at`。任何篡改使 SHA 失效。receipt 不可凭 `--operator-approved` flag 单独伪造。CI 跑非存在 receipt + 假签名 receipt，断言两者退出非 0。

---

## r2 之前的状态

## r2 changelog（相对 r1 的 delta，保留作 trail）

回应 codex r1 REJECT 的 2 CRIT + 4 HIGH + 2 MED：

- **CRIT-1（缺前向数据迁移计划 — §4.1 / §6 / §8）：** r1 说迁移后的 Kind "不迁现有 snapshot；第一条命令创建新鲜事件溯源状态"。这在切换点丢失活的 User/Session/Agent/Workspace state，按 `feedback_destructive_migration_anti_pattern` 不可接受。**r2 fix：** 新增 §6.0（前向数据迁移）为每个 Phase 10-A 到 10-C 起点的强制 Step 0。它定义 per-Aggregate 的「snapshot import」事件类（如 `%UserSnapshotImported{}`），由 `mix ezagent.aggregate.import --kind <kind>` 任务在生产派发路由到 aggregate **之前**对每个现有 URI 发射一次。Import 事件携带完整的 pre-existing slice payload。Aggregate 的 `apply/2` 有专门子句处理 import 事件、水合 aggregate 状态。Parity 门（事件回放 aggregate 状态 vs `kind_snapshots` 行的回读对比）是 import 步骤的成功标准；切换在 parity 绿之前**不**发生。§6.1/6.2/6.3 扩展为含 import 任务作为每 Phase 的 Step 0。
- **CRIT-2（Phase 10-A 桥缺口 — §6.1 / §8.2）：** r1 Phase 10-A 只迁 Worker，但 legacy Session 的 `Behavior.ExternalMirror` 仍在 `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677` 直接调 `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)`。Session 仍为 GenServer 时不发 `BindingCreated` 事件，`BootstrapWorkerSaga` 永远不触发。**r2 fix：** Phase 10-A 修订为：(a) 把 Session ExternalMirror behavior + Worker 一起迁（推荐 — bind 调用点紧耦合）**或** (b) ship 显式 `Ezagent.MigrationBridge.LegacyBind` shim，把 legacy `Kind.spawn(Worker, params)` 翻译为新 aggregate 上的 `%SpawnWorker{}` 命令 + 向新事件流注入合成 `%BindingCreated{}` 事件触发 saga。r2 默认选 (a)；如 Session-side 迁移过于纠缠则 fallback 到 (b)。§6.1 扩展含 Session ExternalMirror behavior delta。
- **HIGH-3（缺读后写一致性矩阵 — §3.3 / §6.2）：** r1 只说 "per 派发点 opt 到 :strong"、不枚举。r2 新增 §4.8（LV / Channel / CLI 一致性矩阵）— 一张表列出所有写后立即重读 state 的 callsite 及其要求一致性模式。静态枚举的 sites：`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:137`（create→list_users）、`workspace_detail_live.ex:165`（add member→get_by_name）、`entity_caps_live.ex:142`（grant cap→reload caps）、`routing_live.ex:235`（add rule→reload rules）。所有这些**必须**用 `consistency: :strong`（或具名投影器列表）。Phase 10-B/10-C 不变式测试断言每个枚举 site 满足；CI grep 门拒绝在这些派发路径上显式用 `consistency: :eventual`。
- **HIGH-4（Kind/Behavior 清单不全 — §4.2 / §4.3）：** r1 "5 entity Kind + 11 Behavior" — 实际 checkout 计数大得多。r2 新增 §4.1.5（完整 Kind/Behavior 清单）从 checkout 静态枚举：15+ Kind 模块（含持久的 `Ezagent.Entity.AgentTemplate` + `Ezagent.Entity.SessionTemplate`，皆 `{:snapshot, :on_change}`，加 per-flavor `CurlAgent` / `Echo` / `NpAgent`），24 个 Behavior 模块（漏掉：`ApiKeys`、`Template`、`OrchestratorAdmin`、`Pty`、`UserBinding`、`FeishuAllow`，加 4 个插件 agent-flavor behavior）。每个加 per-Phase 迁移去向列。§4.3 用完整列表重写。
- **HIGH-5（Session aggregate state 漏耐久字段 — §4.2.3）：** r1 Session aggregate struct 漏 `owner_uri`、`last_seen`、`monitors`、`last_message_id`、`last_message`、`send_cursor`、`recent_messages`、`template_working_copy` + Publisher 的 `ring` / `cursor` / `retention`（都耐久 — `Behavior.Chat.init_slice` 在 `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144`-`:242` + `Publisher.SessionImpl.init_slice` 在 `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150`-`:165`）。r2 fix：§4.2.3 Session aggregate state struct **重写**枚举每个耐久字段；非耐久运行时字段（`monitors` — 进程 ref 跨重启不存活）显式排除并加注。Rejoin / external mirror dedupe / publisher cursor catchup 的 replay 测试加入 Phase 10-B 不变式测试。
- **HIGH-6（User 投影 schema 漏 profile + token 字段 — §4.2.1 / §4.7）：** r1 `user_profile_projection` 只 `(uri, workspace_uri, registered_at, destroyed?)`。当前 `Entity.Profile` schema（`apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`）有 `display_name`（必需）+ `email`。当前 `Entity.Token` schema（`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`）有 `token_hash`、`label`、`last_used_at`。**r2 fix：** §4.2.1 User aggregate 加 `:profile` 字段（`%{display_name, email}`）+ 命令 `%UpsertProfile{}` / 事件 `%ProfileUpserted{}`。Token aggregate state + events 扩展含 hash/label/last-used。§5.1 投影更新匹配。
- **MED-7（DestroyAgentSaga 补偿只 retry/stop — §3.8 / §4.4）：** r1 saga `error/3` 重试后停。当前清理路径（`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189` session-create rollback、`apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240` sandbox-destroy cleanup）做显式逆操作。**r2 fix：** §3.8 DestroyAgentSaga 重写为 `error/3` 回调用 `{:continue, [%ReverseCommand{}, ...], context}` per-step 补偿。每步文档化：(a) 幂等合约；(b) 失败残留；(c) 逆命令；(d) 续跑行为。Step-failure 测试是 Phase 10-C 不变式。
- **MED-8（Phase 10-D 破坏性清理缺 operator gate — §6.4 / §8.4）：** r1 "最后 data dump 后删 `kind_snapshots`"。按 `feedback_destructive_migration_anti_pattern` + `feedback_completion_requires_invariant_test`，那不是门。**r2 fix：** §6.4 Phase 10-D `DROP TABLE kind_snapshots` 由三项门控：(a) 迁移脚本里 operator 批准 flag（mix 任务需 `--operator-approved <ticket-id>`）；(b) 已验证 backup restore drill — operator 把上次 snapshot dump 恢复到 temp DB 并断言行数匹配；(c) restore 后 parity check — import-replay vs 原 snapshot 在所有迁移 URI 跨字段相等。门本身是 `mix ezagent.cleanup.preflight` 任务，除非 (a)+(b)+(c) 全成立否则非 0 退出。SPEC §8.4 扩展。

---

## r1（初版）状态

**Tier:** 跨切的架构迁移。涉及 `apps/ezagent_core/`（Kind / Behavior / Invocation / Persistence / Snapshot / Audit），所有 `apps/ezagent_domain_*/`（User、Session、Agent、Workspace、ExternalMirror Worker 实体 Kind），LiveView 读层（`apps/ezagent_plugin_liveview/`），CLI（`apps/ezagent_cli/`），Web 派发面（`apps/ezagent_web/`），以及所有插件的写法范例。引入三个新的 umbrella app（`ezagent_event_store`、`ezagent_commanded_app`、`ezagent_projections`）以及一段混合运行期 — 部分 Kind 已是 Aggregate、其余仍为 GenServer。

**触发：** Allen 2026-05-28 06:31 — 暂停 SPEC #440（实体销毁生命周期），原因是 4 轮 codex REJECT 后没有收敛。销毁级联的 3 条 critical 诊断（无跨-Kind 原子性、部分失败不一致窗口、saga 式恢复需要现有 Kind=GenServer 模型不具备的结构原语），在事件溯源语义 + Process Manager 下全部化解。Allen 提出更深的假设：**我们建过的每一个多-Kind 工作流（BootReconciler、SpawnRegistry race 类、cap grant-time 检查、workspace cap-vis 5 轮迭代）都撞同一面墙**。销毁阻塞是这一类问题里最显眼的一个实例。

**Scope of THIS SPEC：**
- 全系统的架构迁移设计
- 不只是销毁生命周期 — 覆盖所有 Kind、所有状态变更、所有跨 Kind 工作流
- Phoenix + Commanded 混合集成（Allen 标记的关键研究问题）
- 分阶段迁移计划
- 性能 + 运维成本分析
- 回滚 / 中止路径

**Companion:** `2026-05-28-eventstore-commanded-migration.md`（按 `feedback_bilingual_docs_convention`）。

**前置 memory (load-bearing)：**
- `feedback_let_it_crash_no_workarounds` — 不做 shim/双路。若采纳 CQRS/ES，snapshot 表就是 Aggregate 回放的缓存，**不是** 并行的真值源。迁移是 commit 式（每 Kind hard flip），不是开关。
- `feedback_completion_requires_invariant_test` — 每阶段的门槛是一个不变式测试，当架构目标未达成时它 FAIL。每个迁移完的 Kind 的门槛是「该 Kind 的状态仅凭事件流就能确定性重建」（无 slice/snapshot fallback）。Saga 的门槛是「该多-Kind 工作流走 Process Manager，而非直接的跨 Kind GenServer.call」。
- `feedback_north_star_plugin_isolation` — 插件作者写 Command + Event + Aggregate 的 `execute/2` + `apply/2`。他们**不**碰 `Commanded.Application`、事件存储配置、投影接线、saga 注册。边界更紧。
- `feedback_destructive_migration_anti_pattern` — 参见 §6 / §8。迁移**新增**事件存储库；**不**销毁现有 snapshot 数据。§12 中如果某阶段中止，明确地分叉回到 slice/snapshot。
- `feedback_register_lookup_key_parity` — Aggregate 身份必须与现有 Kind URI 用同一方式规范化（`Ezagent.URI.parse!/1`）。路由器 `:identify` 子句使用规范化后的 URI 字符串；派发点之间规范化不一致会静默地把一条命令路由到全新的 Aggregate ID。§4.6 强制。
- `feedback_uuid_is_canonical_identifier` — Aggregate UUID 必须是现有 Kind URI 的规范化字符串。我们**不**铸造新的 UUID 列。URI 就是身份。
- `feedback_subagent_must_load_project_skills` — 每个阶段的实施 subagent 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_review_every_pr` — 本 SPEC + 每个阶段的实施 PR 的 codex 审查都带逐字的 "no mix" 子句。
- `feedback_phase_planning_reads_main_docs` — §6 阶段编号符合 `IMPLEMENTATION_ROADMAP.md` §1.1（当前最新是 Phase 6 / partial）。本迁移会成为 Phase 10（在 Phase 9 PR-CC follow-ups 完成 + Phase 6 收尾之后）。
- `feedback_explain_problem_not_code_structure` — §1 先讲问题类（多-Kind 工作流缺原子性原语），§2 先讲决策（CQRS/ES），代码形状放 §4-§5。

**父级 / 历史上下文：**
- `IMPLEMENTATION_ROADMAP.md` §1.1 — Phase 0-6 已完成或在飞。本 SPEC 成为 Phase 10（跳过保留但未启动的 Phase 7-9 follow-up 工作）。
- `ARCHITECTURE.md` Decision Log #84 — 选了路径 B（`@behaviour Ezagent.Kind` + 共享 `Kind.Server` GenServer），而非路径 A（`use Ezagent.Kind` 宏）。本 SPEC 用路径 C（`Commanded.Aggregate`）取代两者。
- `ARCHITECTURE.md` Decision Log #59 + #60 — 同步 `on_change` snapshot 写 + 异步批 writer。事件溯源模型用「同步事件追加 + 每 N 事件可选 Aggregate snapshot」**取代**这套。
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — 当前承载所有 Kind 的共享 GenServer。每个迁移完的 Kind 之后 Phase 10-D 弃用。
- `apps/ezagent_core/lib/ezagent/invocation.ex`（步骤 1-4、11-12）+ `apps/ezagent_core/lib/ezagent/kind/runtime.ex`（步骤 5-10）— 12 步派发流。迁移后步骤 5-10 折叠进 `Commanded.Application.dispatch/2`；步骤 5.5（CapBAC）+ 5.6（workspace 隔离）移到派发前的预流水线（§4.5）。
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — per-Kind snapshot 表。对迁移 Kind 变成 Commanded aggregate snapshot 库；混合期间未迁移 Kind 继续使用。
- `apps/ezagent_core/lib/ezagent/audit.ex` + `Ezagent.Audit.Writer` — SQLite `invocations` 审计表。迁移 Kind 的领域事件**事件流即审计日志**；未迁移 Kind 以及非领域的跨切遥测（如 `[:ezagent, :authz, :denied]` 否决侧）**保留**在 SQLite 表。
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — 规范化 `%URI{}` 的 chokepoint。§4.6 Aggregate ID 的来源走 `Ezagent.URI.parse!/1` 并通过 `URI.to_string/1` 喂给路由 `:identify`。
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` — 派发时 authz 不变式（步骤 5.5 chokepoint）。本 SPEC §4.5 说明 authz 检查如何从 `Kind.Runtime.handle_dispatch/4` 移出，进入包裹 `Commanded.Application.dispatch/2` 的预流水线，chokepoint 性质保留。

**参考库：**
- [commanded](https://github.com/commanded/commanded) — Elixir 的 CQRS/ES 框架。v1.4.10 最新。([hexdocs](https://hexdocs.pm/commanded))
- [eventstore](https://github.com/commanded/eventstore) — Elixir 的 PostgreSQL 事件存储库。v1.4.8 最新。
- [commanded_eventstore_adapter](https://hex.pm/packages/commanded_eventstore_adapter) — 把 `commanded` 接到 `eventstore` 的 adapter。
- [commanded_ecto_projections](https://hex.pm/packages/commanded_ecto_projections) — Ecto-backed 的 read-model 投影 helper。
- [Conduit 参考 app](https://github.com/slashdotdash/conduit) — Phoenix + Commanded Medium 克隆。
- [Gift-card demo](https://github.com/slashdotdash/gift-card-demo) — Phoenix LiveView + Commanded 参考。

---

## 1. 问题陈述 — 为什么迁移

### 1.1 销毁生命周期 4 轮 codex 失败作为证据

SPEC #440（实体销毁生命周期）连续 4 轮 codex REJECT 没有收敛。每轮处理的是同一个结构缺口的不同侧面：

- **r1 REJECT — 原子性：** 7 步销毁级联（撤销 caps → 解绑外部 mirror → 终止子 agent → 退出 session → 解链 lineage → 终止 Kind 进程 → 写销毁审计行）在当前 Kind=GenServer 模型下无法原子。每一步是对不同 Kind 的独立 `Invocation.dispatch/1`；若第 4 步抛错（目标 Kind 半途崩溃），1-3 步已提交，且没有事务回滚原语。方案：每父 URI 的 "destroy_lock" GenServer 串行化并发销毁。Codex 标记：lock 给的是串行化、不是原子性；部分失败窗口仍在。
- **r2 REJECT — 篱笆 / saga：** 提出「destroy fence」机制 — 一个 sweeper 反复重跑步骤直到幂等。Codex 标记：sweeper 要求每一步 invoke handler 可重入幂等；把这个特性回填到 11 个现有 behavior 是另一个 SPEC；且 sweeper 的进度本身就是一个工作流、要自己的状态机。
- **r3 REJECT — 销毁作为状态标志：** 提出在每个 Kind 的 slice 上加 `:destroyed_at` 列，派发时拒绝对墓碑化 Kind 的调用。Codex 标记：墓碑是软删除；需求是硬删除 + cap 反解 + 审计；墓碑让死 URI 永远泄露、且不解决级联。
- **r4 REJECT — destroy_log 表：** 提出旁路表记录级联进度 + boot 时的 reconciler 续跑被打断的销毁。Codex 标记：**这就是事件溯源，做得很糙**。`destroy_log` 表是手卷的 append-only 事件流；reconciler 是手卷的 Process Manager；我们在一张张临时表里重造 Commanded 的内部原语。

**Codex r4 verdict（原文引用）：** *"destroy_log 这条路就是没有框架的事件溯源。你想解决的每一个问题 — 多 aggregate 原子操作、半途失败续跑、审计追溯不变式 — 都是 Commanded 设计的目标。本 SPEC 不断零碎地重造 Commanded 的内部。退一步：你需要保留 GenServer+slice 模型，还是这里已经触及架构天花板？"*

那段 codex 评语是 **本 SPEC 的直接成因**。在当前模型下原子销毁问题无解。CQRS/ES 模型有结构原语 — Aggregate 自带事件回放的状态、Process Manager 编排多 aggregate 工作流并内建补偿、EventStore 追加即审计日志、snapshot 是缓存而非真值 — 全部 4 类阻塞 codex 标记的问题不靠重造就能解决。

### 1.2 更大的类 — 每个多-Kind 工作流都撞这堵墙

销毁是最尖锐的实例，但同一模式反复出现：

- **`BootReconciler`**（Phase 3 PR-EM-9，external-mirror-domain SPEC §3.1）— 应用 boot 时扫描 `external_mirror_bindings` 投影表、为每个持久化 binding 重新拉起 Worker。Reconciler 是手卷的扫-起循环，与 Session boot 之间存在竞态（Worker `post_init/2` 可能先于目标 Session 进入 `:ready` 而跑，需要 `PendingDelivery` 的 buffer + 重试层）。在 CQRS/ES 下，「binding X 存在则 Worker for X 存在」是一个订阅 `BindingCreated` 事件、派发 `SpawnWorker` 命令的 saga。无 boot 扫描；无竞态；saga 状态机编码顺序。
- **`SpawnRegistry` race 类**（Phase 2-3 事故复盘）— 同一 URI 的并发 `Kind.spawn/2` 在 `DynamicSupervisor.start_child` 上竞速，调用者幂等地处理 `{:error, {:already_started, pid}}`，但**第二个调用者的 `init_slice/1` args 静默丢失**（第一次胜出）。在 CQRS/ES 下，「这个 aggregate ID 上的第一条命令负责创建它」是原语 — 在创建命令落到之前 aggregate 不存在；后续创建命令确定性地以 `{:error, :already_created}` 失败；aggregate 状态从第一次创建的事件构建，与哪个进程发起无关。
- **能力授予时检查的歧义**（PR-CC-2 / caps-cleanup-v1 SPEC）— `Behavior.Identity.grant_cap` 必须验证授予者在**授予的那一刻**持有底层 owner cap，但 caps 是 slice、每次授予都会变 — 这检查是对授予者自己 slice 的 read-after-write。当前模型靠同步 `GenServer.call` 顺序（`Kind.Server.handle_call` per-instance 串行化）解决。在 CQRS/ES 下，授予者在授予时刻的 caps 可从授予者 Aggregate 在 grant 命令应用瞬间的事件回放状态中推导；命令的 `execute/2` 读 aggregate 状态、原子地发射 `CapGranted` 事件（aggregate 级别的串行化给同样性质；并且持久于事件流，所以 "在授予 X 时这个授予者持有哪些 caps" 的审计查询变成事件流过滤、而非取证式 snapshot 读）。
- **Workspace cap-vis 5 轮迭代**（`2026-05-27-workspace-cap-based-visibility.md`）— 5 轮 codex REJECT，主要在策略 helper 放哪 + admin-bypass 边角。cap-vis SPEC 本身直白（`list_workspaces_for(caller, caps)`）；轮次都耗在 "helper 住哪"、"helper 是否匹配 cross-workspace 运行时语义"、"helper 是否覆盖 wildcard cap 路径"、"system-membership 谓词归 Identity 还是 Capability"。在 CQRS/ES 下，「caller 的 workspace 可见性」是对 `workspace_visibility_per_caller` 投影的读模型查询 — 投影在投影时把策略集中到一处；LV 读时的查询是 `SELECT workspace_uri FROM ... WHERE caller_uri = ?`。策略迭代发生在投影里、而非每个读处；读处不会与策略漂移。

主线：**每个多-Kind 工作流暴露当前模型里缺失的原语 — 跨-Kind 原子操作、saga 确定性续跑、可查询的历史状态、单点策略投影。** CQRS/ES 把每条提供为框架特性。当前模型每个 SPEC 都临时重造一个；每次临时重造花 3-5 轮 codex。

### 1.3 诊断 — 当前架构有 CRUD 但没有事件日志

当前 ezagent 状态模型结构上是：

```
外部请求 (LV / CLI / Feishu / MCP / HTTP)
  → Adapter 构造 %Invocation{}
  → Invocation.dispatch/1
    → Idempotency check (step 1)
    → ReadyGate gate (step 4)
    → Kind.Runtime.handle_dispatch (steps 5-10):
      - BehaviorRegistry lookup
      - CapBAC step 5.5
      - Workspace isolation step 5.6
      - Behavior.invoke/4 — 返回 {:ok, new_slice} | {:ok, new_slice, result}
      - Kind.Server 把 new_slice merge 进 state.state[slice_key]
      - 持久化写（若 :on_change 且变了）
      - Telemetry emit
    → reply/2 把结果发回调用者
```

状态变更**形状是 CRUD**：每个 `Behavior.invoke/4` 是 `(slice, args) -> new_slice` 的函数。没有正式的 command/event 切分。审计日志（`invocations` 表）是 telemetry handler 写出来的 `(caller, target, action, result)` 元组旁路记录 — 它**不是**真值（真值是 slice/snapshot）。跨-Kind 工作流是在调用者代码里命令式串起来的多次 `Invocation.dispatch/1`（例如 `EzagentDomainChat.create_session/3` 用 try/rescue 编排了跨 4 个 Kind 的 5 次派发，每步手工清理）。

这种形状留给我们的是：
- **没有正式命令** — `Behavior.invoke/4` 的 `args` 就是个 map；没有 Command struct、没有 router、没有命令的集中目录。
- **没有正式事件** — `Behavior.invoke/4` 的返回是新 slice + 可选结果；slice 变更未具名、不耐久、不可订阅。
- **没有 saga 原语** — 多-Kind 编排是命令式调用者代码 + 手工 try/rescue 清理；部分失败补偿是 ad-hoc per-callsite。
- **没有回放** — 重启时只恢复最新 snapshot；snapshot 之间的历史丢失（审计表是旁路、不可回放进 Kind 状态）。
- **没有订阅** — LV 通过 `Kind.get_slice/2`（同步 `GenServer.call`）直接读 slice；要响应 slice 变更，LV 要么轮询、要么依赖 Behavior 代码里手动的 `Phoenix.PubSub` 广播（如 `Behavior.Chat` 广播 `:message_appended`）。每条广播是 per-Behavior opt-in；没有自动事件流。

### 1.4 假设 — CQRS/ES 在结构上提供缺失的原语

Commanded + EventStore 提供：
- **Command** 作为 struct，通过带 `:identify` 子句的 router 按 aggregate UUID 路由派发。目录是 router 配置。
- **Event** 作为 struct，由 `Aggregate.execute/2` 发射，**先**持久化到事件流、**再** `Aggregate.apply/2` 改内存状态。审计是事件流。
- **Aggregate** 作为进程，由事件回放（+ 可选每 N 事件 snapshot）恢复。状态**派生**自事件。
- **Process Manager (Saga)** 作为有状态事件订阅者，依事件发射命令。多-aggregate 工作流是显式的 + 可续跑的 + 可补偿的。
- **Projection** 作为事件订阅的读模型更新器（用 `commanded_ecto_projections` 走 Ecto）。LV 读投影表；投影器从事件更新它。读模型解耦内建。
- **一致性模式** — `dispatch(cmd, consistency: :strong)` 阻塞直到强一致投影追上；`:eventual` 立刻返回。Read-after-write 问题是派发时的 flag，不是手卷等待循环。

§1.2 的每一条都化解为框架原语。迁移成本是真的（§6 的阶段计划），但**不**迁移的复发成本是每个触及多-Kind 工作流的 SPEC 3-5 轮 codex — 而我们每周都有一两个这样的 SPEC。

---

## 1.5 备选方案审视 — 原生 Phoenix 轻路径

在采纳 Commanded + EventStore（一个 3 个月的迁移、退役 `Kind.Server`、`KindRegistry`、`SpawnRegistry`、`Audit.Writer`、`Persistence` 对 slice 的写、并把 Postgres 引进 dev loop）之前，BEAM/Phoenix 生态用**原生原语或更轻的纯 Elixir 库**能不能解决 §1 的痛点？

本节为轻路径做 steel-man。Allen 的指令（2026-05-28 08:15）：SPEC 必须自我证立**为什么是 Commanded**，而不是默认「最重的锤子就赢」。按 `feedback_let_it_crash_no_workarounds`，这里假造 ❌ 与制造 Commanded-only 优势是同一个反模式 — 都掩盖结构真相。

### 1.5.1 5 条候选轻路径

| 路径 | 库 / 模式 | 星 / 年龄 / 稳定性 |
|---|---|---|
| **L1** | 纯 [`Ecto.Multi`](https://hexdocs.pm/ecto/Ecto.Multi.html) — 收紧事务范围 | 内建（`ecto_sql`）— 每个 Phoenix 应用都有 |
| **L2** | [Sage](https://github.com/Nebo15/sage) — 纯 Elixir saga 补偿 | 962⭐，零依赖，最后一次发布 2022-09（稳定；不再活跃但生产用） |
| **L3** | [ex_audit](https://github.com/ZennerIoT/ex_audit) — Ecto changeset → 审计日志 + revert | 380+⭐，活跃维护 |
| **L4** | [Oban Pro Workflow](https://oban.pro/docs/pro/1.5.0-rc.7/Oban.Pro.Workflow.html) — 带依赖 + 补偿的 job DAG | 付费库，成熟，活跃开发 |
| **L5** | DIY GenServer + append-only 事件日志表（无库） | 内建 |

（`Honeydew`、`Flow`、`GenStage` 已考虑并直接排除 — 它们解决并发 / 流，不解决多 aggregate 原子性或审计。不列。）

### 1.5.2 痛点矩阵 — 每条轻路径 vs §1 每个痛点

| # | 痛点（来自 §1） | L1 Ecto.Multi | L2 Sage | L3 ex_audit | L4 Oban Workflow | L5 DIY 事件日志 | Commanded |
|---|---|---|---|---|---|---|---|
| **P1** | 跨-Kind 销毁级联 — 7 步，部分失败需补偿 | ❌ 仅同库事务；跨-Kind = 跨进程 | ⚠️ 经典补偿模式，但状态仅在 `execute/1` 内存中 — 中途崩留孤儿；需**外挂持久 saga 日志 / outbox（Oban 候选）**以做跨重启韧性 | —（不是工作流库） | ✅ 仅异步 — 调用者拿不到同步结果 | ✅ 可行 — 但你在手卷 Sage | ✅ Process Manager — 跨崩溃/重启的持久状态原生支持 |
| **P2** | 审计日志支持任意 SQL 查询（"用户 X 昨天 14:00 持有哪些 cap？"） | ⚠️ 部分 — 需要手维护旁路 `audit_log` 表 | —（不是审计库） | ✅ 经典 — `Ecto.Changeset` → `version_table` 行，SQL 可查 | —（不是审计库） | ✅ DIY — 和 ex_audit 同形，但触发由你维护 | ⚠️ 事件流就是审计，但**不能直接 SQL 查** — 需要由事件 handler 维护的 `audit_projection` 表（多一跳，ex_audit 不需要） |
| **P3** | 跨-Kind 工作流编排（session 创建级联、worker 引导、cap-grant 验证） | ❌ 同 P1 — 事务范围内 | ⚠️ 与 P1 同样的单调用限制；跨多调用流（如 binding 事件触发的异步 worker 引导）需要 PubSub + 受监督 GenServer + outbox | — | ✅ 异步，带重试 | ✅ DIY | ✅ 带跨调用持久状态的 Process Manager |
| **P4** | 竞态（read-then-lock、授予时 cap 检查、注册/查找 key 一致性） | ✅ — 收紧 Ecto.Multi + DB 约束（唯一索引、exclusion constraint、FK cascade）是经典答案 | —（Sage 是编排库；竞态不在其范围 — L1 拥有此行） | — | — | ✅ — DIY + DB 约束 | ⚠️ — **同样的问题、不同的位置** — aggregate-process 串行化和当前 `Kind.Server.handle_call` 串行化等价；真正的竞态修复是 DB 约束，与模型无关 |
| **P5** | 时间旅行回放 / "重建 T 时刻状态" | ❌ | ❌ | ⚠️ — 数据在（审计表），但没有回放到状态的机制 | ❌ | ⚠️ — DIY（你有事件，自己写 fold 函数） | ✅ — aggregate 状态**派生**自事件回放；原生原语 |

**单元语义**：✅ = 该路径用所述机制解决该痛点。⚠️ = 部分 / 需多一跳，或有 §1.5.3 列出的注意事项。❌ = 该路径不覆盖此维度。"—" = 不在该库范围（不要因为库聚焦而扣分）。

**r6 codex 修正说明**：r5 给 Sage 的 P1/P3 和 P4 都打 ✅。r6 codex review（HIGH-2 + MED-1）把 Sage P1/P3 降级到 ⚠️ — Sage 状态在 `execute/1` 内存里，跨重启韧性要求 Path B 外挂 outbox（如 Oban）或接受这个缺口。Sage P4 降到 "—" — Sage 是编排库，不是竞态修复；L1（Ecto.Multi + DB 约束）才是 P4 的明确归属。

### 1.5.3 逐场景深挖

#### P1 — 销毁级联（这整个 SPEC 的触发器）

**Sage 直接解决。** §3.8 的 7 步级联映射到 Sage 的 `run/compensate` 对：

```elixir
defmodule Ezagent.DestroyAgent do
  import Sage

  def destroy(agent_uri, workspace_uri) do
    new()
    |> run(:snapshot,           &capture_pre_destroy_snapshot/2, &noop_compensate/3)
    |> run(:revoke_caps,        &revoke_all_caps_held_by/2,      &restore_caps_from_snapshot/3)
    |> run(:destroy_children,   &destroy_child_agents/2,         &respawn_children/3)
    |> run(:drop_memberships,   &drop_all_session_memberships/2, &restore_memberships_from_snapshot/3)
    |> run(:unlink_lineage,     &unlink_lineage/2,               &relink_lineage_from_snapshot/3)
    |> run(:terminate,          &terminate_agent/2,              &noop_compensate/3)
    |> run(:audit,              &write_destroy_audit_row/2,      &noop_compensate/3)
    |> execute(%{agent_uri: agent_uri, workspace_uri: workspace_uri})
  end

  defp restore_caps_from_snapshot(error, effects_so_far, %{agent_uri: uri}) do
    Ezagent.Capability.restore_for(uri, effects_so_far.snapshot.caps)
    {:ok, :restored}
  end
end
```

这是 Sage 的**经典**模式。Sage 的契约正是 §3.8 DestroyAgentSaga 需要的：每步一个 forward + 一个 compensate；若第 N 步失败，1..N-1 的补偿按逆序运行。Sage 负责编排；步骤就是函数。

**具体失败模式**：
- Sage 补偿**不能** raise（语义上 — 若 compensate 失败，saga 处于未定义状态而中止）。这与 Commanded Process Manager 的约束相同（compensation 中的 `handle/2` raise 同样致命）。不是 Sage 独有弱点。
- **Sage 的状态是 `execute/1` 调用期间的内存状态（r6 codex HIGH-2）**。若编排进程在 execute 中途崩 — BEAM 节点重启、`kill -9`、OS 重启、supervisor 重启 — saga 失去进度，留下部分状态。Commanded Process Manager 把状态持久化在事件存储里，跨重启 resume 是原生能力。
  - r5 草稿说「6 个月 dogfood 没观察到中途崩」。codex 正确指出**销毁还没上线** — 「没观察到事故」对一个未在规模上行使过的特性不是证据。诚实立场：我们不知道中途崩的频率。
  - **Path B 缓解要求**：配套 Path B SPEC 必须包含**持久 saga 日志**（Oban 作 outbox 候选，或手卷 `saga_executions` 表），以便部分级联可以在 BEAM 重启后 resume 或补偿。没有这个，Path B 相对 Commanded 有真实的正确性差距。

**P1 诚实结论**：Sage 解决销毁级联，**前提是** Path B SPEC 包含持久 saga 日志 / outbox。没有这个的话，Commanded Process Manager 在韧性上有真实优势。结论假设这个缓解会在 Path B 里落地。

#### P2 — 审计日志支持 ad-hoc SQL 查询

SPEC §1.3 把当前 audit 表诊断为「telemetry handler 的旁路记录」（`(caller, target, action, result)` 元组）。需要的形状是：「任意历史 SQL 查询（X 在时刻 T 持有哪些 cap；昨天 14:00 session S 的成员名单）的答案在可查表里」。

**`ex_audit`** 是纯 Phoenix 的经典答案：

```elixir
schema "capabilities" do
  field :uri, :string
  field :scope_uri, :string
  field :verb, :string
  field :holder_uri, :string
  # ex_audit 注入：
  # - changes 表跟踪每次 Ecto.Changeset 变更
  # - SQL 可查：`from c in CapabilityVersion, where: c.holder_uri == ^uri and c.recorded_at < ^t`
end
```

审计表**直接 SQL 可查**。无投影步骤，无事件回放再折叠。

**反之**：Commanded 的事件流**是**审计日志，但回答 "X 在 T 时刻持有哪些 cap" 需要：
1. 一张专门的 `caps_history_projection` 表，由 `CapsHistoryProjector` 维护（多一跳、多 LOC、投影器有延迟），**或**
2. 把 X 的 aggregate 事件回放到 T（服务端、慢、一次只能一个 aggregate）。

对 ad-hoc 管理查询 — 人在 psql 里查事故 — `ex_audit` + 原生 SQL **胜过** Commanded 事件流。事件流在「订阅未来 audit」（Commanded handler）上赢，但在「回答这个历史 SQL 问题」上输。

**P2 诚实结论**：对 SPEC 描述的审计需求，ex_audit **优于** Commanded 事件流。Commanded 的事件审计对 SQL 友好查询是降级。

#### P3 — 跨-Kind 工作流编排

形状同 P1。Sage 同样处理 `CreateSessionSaga`、`CreateUserInWorkspaceSaga`、`BootstrapWorkerSaga`、`RevokeCapCascadeSaga`、`CapGrantOwnershipVerifySaga` — 每个都是 `new() |> run(...) |> run(...) |> execute(ctx)`。

**唯一差异点**：Sage 的状态在 `execute/1` 内存里；若工作流要跨多个独立 caller 调用（如「用户点 Create，30 秒后 worker 在 binding 事件后异步引导」），Sage 的单 execute 范围不合适 — 你要把它实现为两个独立的 Sage，各在自己的 caller。Commanded PM 的持久状态会跨过。

**但是**：看 §4.4 saga 清单：
- `DestroyAgentSaga`、`DestroyUserSaga`、`DestroySessionSaga`、`DestroyWorkspaceSaga`：全是单调用级联。Sage 合适。
- `CreateSessionSaga`、`CreateUserInWorkspaceSaga`：单调用。Sage 合适。
- `BootstrapWorkerSaga`：由独立事务里的 `BindingCreated` 事件触发。**这一个**确实是跨 caller 边界的事件驱动 — Sage 不合适，但在原生模型里你也不需要 saga；它就是受监督 GenServer 里的一个 `Phoenix.PubSub.subscribe(:bindings)` + handler。「saga」的框架是 Commanded 形状的解 — 给一个 CQRS 外不存在的问题。
- `RevokeCapCascadeSaga`：由 membership 撤销触发。同 bootstrap — PubSub handler 即可。
- `CapGrantOwnershipVerifySaga`：这是一个**单命令**检查（验证授予者有 cap，然后授予或拒绝）。根本不是 saga — 是 guard 子句。「saga」的框架是过度建模。

**P3 诚实结论**：§4.4 的 9 个 saga 中 5 个是单调用级联 → Sage 处理（带 P1 持久性注意事项）。2 个是事件触发的跨调用 → 受监督 GenServer 里的 PubSub handler；**这些需要 outbox 跨过事件到达和效果应用之间的 worker 重启**（每事件触发一个 Oban job 是经典解法）。2 个根本不是 saga。Commanded 的框架把数字虚高了，但 Commanded 在 Sage 需要外挂的位置原生承担了跨重启持久性。

#### P4 — 竞态（read-then-lock、授予时检查、注册/查找一致性）

这是 §1 假设在严密审视下**最弱**的痛点。

§1.4 说：「在 CQRS/ES 下，授予者在授予时刻的 caps 可从授予者 Aggregate 在 grant 命令应用瞬间的事件回放状态中推导；aggregate 级别的串行化给同样性质。」

**再读一遍**：「aggregate 级别的串行化给同样性质」。这字面就是当前模型。`Kind.Server.handle_call` per-instance 串行化；`Commanded.Aggregates.Aggregate` 进程 per-aggregate-UUID 串行化。同形。竞态修复不是事件溯源 — 是 per-key 的进程串行化。两个模型都有。

**真正**的竞态修复，cap-vis-SPEC + URI-canonical-SPEC 都收敛到的，是：
1. 唯一索引（每个实体表的 `uri` 列 NOT NULL UNIQUE）
2. exclusion constraint（同 scope/verb 对上不能并存两个 grant）
3. 外键级联（删用户 → 级联删持有的 cap）
4. 更紧的 `Ecto.Multi` 事务边界（grant + audit 行在一个事务里）

这些是 DB 级约束。它们在 Commanded vs 当前模型上一样工作。Commanded 对竞态解决**没**增加任何东西 — 它只把串行化点从 `Kind.Server` 搬到 `Commanded.Aggregates.Aggregate`。DB 约束修的竞态在两个模型都修；aggregate 串行化修的竞态今天 `Kind.Server` 串行化也修。

**P4 诚实结论**：Commanded 在竞态解决上**没**胜过当前模型。修复是 L1（更紧 Ecto.Multi + DB 约束），与哪个 actor 模型包裹无关。

#### P5 — 时间旅行回放

这是矩阵里**唯一**Commanded 有结构优势、没有轻路径能匹的痛点。Aggregate 状态**就是**事件派生；回到 T 时刻就是把事件回放到 T，得到当时状态。原生 Elixir + ex_audit 给你审计数据，但「重建 T 时刻 slice」需要每个 Kind 手卷 fold-over-history 代码。

**关键问题 — ezagent 是否需要过回放？**

搜 docs/ futures、IMPLEMENTATION_ROADMAP、codex 拒收 trail 里的 "replay"、"time-travel"、"重建 T 时刻状态"：
- §3.7 把回放列为 Commanded 能力（正面）。
- §1.4 把「无回放」列为当前模型缺口。
- **§1.5 审视范围内**对 docs/issues 的搜索无法被仅读 §1.5 的审查者验证（r6 codex HIGH-1）。r5 草稿断言「roadmap 上没有」没有内联证据；r6 把这个降级为「**§1.5 里没有当前证据；结论假设 Allen 在 grill-with-doc 时确认**」。
- 销毁级联崩溃后续跑是最接近的类比，且 Sage 补偿 + **持久 saga 日志缓解**就能解（见 P1）。

**回放未来可能的驱动**（让审查者验证是否临近）：
- **合规** — 如 SOC 2 / GDPR「展示 2025-09-12 14:00 UTC 用户 X 的 cap 状态」需要可重建的历史状态。ezagent 当前不承担受监管业务，但可能。如果走 enterprise B2B，这就是入场费。
- **AI 训练数据重建** — 离线 RLHF 数据集需要回放历史 agent 对话 + tool-call 状态。不在 roadmap 上，但 12 个月内合理。
- **事故后调试** — 倒回系统状态以重现一个依赖特定历史配置的 bug。当前是 patch-forward；回放会让根因分析更快。
- **schema 迁移回填** — 若加一个新派生字段，回放事件为所有历史实例计算值。当前模型需要 per-Kind 回填脚本。

**若先走 Option B 之后才需要回放的迁移成本**：
- 加事件日志基础设施（Postgres + `eventstore` 库）：1-2 周
- per-Kind：在切换窗口里双写事件日志和当前写：2-3 周
- per-Kind：写 `apply/2` 事件 fold + 从事件构建状态的 handler：每 Kind 1-2 周 × 5 Kind = ~7 周
- saga 从 Sage 改 Commanded PM：1-2 周
- 生产切换 + 尾事件排空：1 周
- **总计：~3-4 个月 wall-time**，与今天直接做 Option A 迁移可比。**若延后，迁移成本并不为零。**

**P5 诚实结论**：回放是**唯一**结构上 Commanded 独占的优势。r5 「不在 roadmap 上」的说法若 Allen 在 grill-with-doc 时确认，则成立。若回放在 12-24 个月内进入 roadmap，Option B → Option A 的迁移成本 ~3-4 个月 — 与今天直接做 Option A 可比，所以**结论是「除非回放在今年进入需求集，否则延后迁移成本」**。

### 1.5.4 库依赖风险与依赖姿态（r6 — codex HIGH-3 修复）

r5 的结论没有给 Sage + ex_audit 长期依赖风险定价。codex 把这个标记为 HIGH 缺口。诚实姿态：

| 库 | 最后发布 | LOC | Ecto 耦合 | 若被弃用 fork-and-maintain 成本 | 推荐姿态 |
|---|---|---|---|---|---|
| **Sage** | 2022-09 | ~400（纯 Elixir、无依赖） | 无 — 操作普通 map | 低 — 单文件核心，ezagent 可在 repo 内 vendor 维护 | 锁 minor 版本；CI fixture；年度健康审查 |
| **ex_audit** | 2023-02 | ~1500 | 紧 — 包裹 `Ecto.Changeset` 生命周期 | 中 — Ecto API 漂移会破，fork+维护成本每次 Ecto 大版本升级 1-2 dev-week | 锁 minor；按需 vendor；若 12 个月无发布，切到 DIY `Ecto.Multi` + audit_log 表（P2 单元格 L5 即此 fallback） |

**5 年情景 + 缓解**：
1. **Sage 被弃用，BEAM/Elixir 27+ 破坏某个接口** → vendor Sage 核心到 `apps/ezagent_common/lib/ezagent/sage_local.ex`（单文件 ~400 LOC）。低风险 fork。
2. **ex_audit 被弃用，Ecto 4.x 重命名 `Ecto.Changeset` 内部** → 切到 L5 DIY 模式：`Ecto.Multi` callbacks 写 `audit_log` 表。~2 周迁移。数据格式相同（per row changeset diff），只是 writer 换了。
3. **两个库同时被弃用 + Elixir 社区漂移** → 关联风险低，但 L1+L5 DIY fallback 仍在原版 Ecto 上工作。最差情况：Path B 的 "Sage + ex_audit" 面变成「薄 DIY 编排 + 薄 DIY 审计」，仍不需要 Commanded 迁移。

**缓解成本有界**（若两个库都冷掉 ~2-4 周）。对比 Option A 的 3 个月前置迁移：**即使最差情况 Option B → DIY 转向也比 Option A 第一天的成本低。**库的陈旧本身不翻转结论到 Option A；但要求锁版本纪律 + 年度审查。

### 1.5.5 结论（r7 — Option B'' 主选；Option B 第一备选；Option A 第二备选）

**Option B''（原生整合）— 推荐的主路径**（完整设计见 §1.5.7）。约 880 LOC 跨 5 个新的内部模块（`Ezagent.EventLog`、`Ezagent.SnapshotStore`、`Ezagent.Kind.StateRebuilder`、`Ezagent.SagaRunner`、`Ezagent.EventSubscriber`），约 2-3 周第一天成本。把跑着的代码里已经有的 ES 原语命名清楚，并加上缺失的 30%（命令/事件正式拆分作 opt-in、SagaRunner 契约、EventSubscriber behaviour、通用化的 StateRebuilder）。**关键：B'' 把未来迁移到 Commanded 的成本从 Option B 的 ~10-12 周压缩到 ~4-6 周**（替换 3-4 个内部模块的实现）— 所以采纳 B'' 并不关上 Commanded 的门，反而让未来需要时更便宜推开它。

**Option B（Sage + ex_audit + Ecto.Multi + Oban outbox）— 第一备选**，若 B'' 设计被 codex review 否决或落地阶段撞到结构性问题。条件来自 r6 三个 predicate：

- **(a)** 库依赖风险审计（§1.5.4）确认 Sage + ex_audit 在 ezagent 5 年姿态下 fork-and-maintain 成本可接受。
- **(b)** Path B SPEC 的 saga 设计包含**持久 saga 日志 / outbox**（Oban 作 outbox 候选）做跨重启韧性。
- **(c)** 回放（§1.5.3 P5）由 Allen 确认未来 12 个月不进 roadmap。

**Option A（按 §2-§12 的 Commanded 完整迁移）— 第二备选**，若 B'' 和 Option B 都不可行，**或** 回放（P5）进入未来 6 个月的 roadmap。Commanded 的持久状态原语 + 事件日志回放届时成为值得付 3 个月迁移成本的差异化。

总成本对比四个选项：
- **Option A（Commanded）**：3 个月迁移，退役 7 个内部模块，Postgres 引进 dev loop，热路径派发延迟 +5x（按 §7.1），1500-2000 LOC saga 代码（按 §4.4），每个 aggregate 的 snapshot 调参是新的 ops 旋钮。
- **Option B（轻路径 + outbox）**：约 3-4 周加 Sage + ex_audit + Oban（outbox），写 9 个 Sage 模块（每个 ~50-150 LOC），建 saga-execution outbox 表 + worker，在现有领域模块里收紧 Ecto.Multi 范围，退役 0 个内部模块，dev loop 不变，无延迟开销，**但**继承 Sage 2022-09 + ex_audit 2023-02 陈旧风险。
- **Option B'（DIY Ecto.Multi + DIY 事件日志）**：约 4-5 周，~1200-1800 LOC，无依赖风险，但每个团队各写自己的编排/审计/约束 → 长期会漂移。
- **Option B''（原生整合）**：**约 2-3 周，~880 LOC，无新 umbrella app，无 Postgres 进 dev loop，无退役模块，无依赖风险。** 命名代码里已经有的结构性原语；保留未来 ~4-6 周迁移到 Commanded 的选项（vs Option B 的 ~10-12 周）。

**结论：B''**。按 Allen 2026-05-28 09:33 指令。结论不再是「条件性 Option B」 — B'' 在每个对比维度上都不弱于 Option B（除「今天就有原生回放」这一项 — 只有 Option A 拿下，且按 (c) 暂时延后无论选 B 还是 B''）。完整设计见 §1.5.7；对比表见 §1.5.7.6。

### 1.5.6 这个结论的下游影响

本 SPEC 起草时隐含假设销毁级联 4 轮 codex 失败（§1.1）需要 CQRS 才能解决。**这个假设现在被 §1.5.7 的前提（§1.5.7.1）所挑战**：ezagent 过去 9 个月一直在有机地实现 ES 原语 — `invocations` 表**就是**追加式事件日志；`kind_snapshots` **就是** aggregate snapshot；`Behavior.invoke/4` **就是**合并的 `execute + apply`；`ExternalMirror.BootReconciler` **就是**状态恢复。销毁级联可以通过命名 + 连接已有的部分（来自 §1.5.7.4 的 SagaRunner 模块 #4） + 来自 §1.5.7 缺失的 30% 来解决。

具体下一步（**本 SPEC 不承诺** — 这是给 Allen 的建议）：

1. **暂停 PR #442**（不要按现状合并 §2-§12；Decision 现在被 §1.5.7 的 B'' 推荐超越）。

2. **起草 5 个 B'' 配套 SPEC**，每个对应 §1.5.7.4 的一个新模块。每个都小 + 独立 + 2-3 周可落地：
   - `2026-05-28-ezagent-eventlog-naming.md` — 把现有的 audit-writer 管线命名为 `Ezagent.EventLog`；加 `stream_by_aggregate/2` 查询辅助；~150 LOC
   - `2026-05-28-ezagent-snapshotstore-naming.md` — 把 `Snapshot.Writer` + `Kind.Snapshot` 策略逻辑统一到 `Ezagent.SnapshotStore`；加 `:tolerate_failure` 显式开关；~200 LOC
   - `2026-05-28-ezagent-saga-runner.md` — 内联 ~200 LOC 的 `Ezagent.SagaRunner`；把 §4.4 的 saga 清单（销毁级联、session-create 等）重写到它上面；替换现有调用站点里 ad-hoc 的 `try/rescue`
   - `2026-05-28-ezagent-event-subscriber.md` — 命名 `Ezagent.EventSubscriber` behaviour；把现有的 2 个 PubSub 驱动跨调用工作流（ExternalMirror worker bootstrap、RevokeCapCascade）refactor 到它上面；~250 LOC
   - `2026-05-28-ezagent-state-rebuilder.md` — 把 `Kind.Server.init/1` 的恢复逻辑提升到 `Ezagent.Kind.StateRebuilder` behaviour；把 ExternalMirror 的 `BootReconciler` 通用化；~80 LOC

   **落地顺序**：EventLog 第一（基础）；SnapshotStore 第二（无依赖）；SagaRunner 第三（解决销毁级联 — §1.1 原始触发器）；EventSubscriber 第四（refactor 现有 PubSub 模式）；StateRebuilder 第五（搭好按 Kind 回放 opt-in 扩展点）。每个 SPEC 都按 `feedback_codex_review_every_pr` 走 codex adversarial-review。

3. **若 5 个 B'' SPEC 落地**：本 SPEC（#442）可以 `wontfix-superseded-by-B''` 关闭，保留 §1.5 作为理由。§2-§12 Commanded 材料留在 git 历史里，给未来回放需求场景。

4. **若 B'' 设计被严重否决**（例如 5 个模块形状中某一个无法保持对现有 Behavior 的向后兼容）：退到 **Option B**（Sage + ex_audit + Ecto.Multi + Oban outbox），按 §1.5.5 条件 (a)(b)(c)。r6 对 Option B 的严谨表述仍是备选契约；§1.5.6 r6 「1 个广 / 3 个小 SPEC」的指导若 Option B 被激活仍然适用。

5. **若回放（P5）在未来 6 个月内进入 roadmap**：触发第二备选 — Option A（按 §2-§12 的 Commanded 完整迁移）。B'' 让这个迁移变成 ~4-6 周（替换 3-4 个内部模块实现）而非从零开始。

6. **若 B'' 和 Option B 都不可行**：重审 Option A 为主选。Path B → Option A 的迁移成本 ~3-4 个月 wall-time（按 §1.5.3 P5）；B'' → Option A ~4-6 周（按 §1.5.7.5(e)）；两个都不灾难。

### 1.5.7 原生整合路径（Option B''）— 把 ezagent 已经在建的形式化，参考 Commanded

Allen 2026-05-28 09:33 指令 — 推一个新的顶级推荐。Path B（Sage + ex_audit + Ecto.Multi + Oban outbox）把事件溯源当成 **我们选择性附加的第三方关切**。但盘点一下，ezagent **过去 9 个月一直在有机地** DIY 实现 ES 原语 — 只是从未把它们命名为 ES。Option B'' = 「把存在的命名 + 加缺失的 30%」，参考 Commanded 用血泪换来的设计经验。

本节先纠正 §1.3 的一个结构性误判（§1.5.7.1），再逐概念把 ezagent 现有原语与 Commanded canonical 实现对比（§1.5.7.2），用 CQRS 原则锐化设计（§1.5.7.3），定义 5 个带扩展点的新内部模块（§1.5.7.4），规划未来增长场景（§1.5.7.5），最后以 4 选项对比表（§1.5.7.6）和新推荐（§1.5.7.7）收尾。

**B'' 不是反 Commanded；它是面向未来 Commanded。** 现在把抽象命名正确，未来迁移的成本就缩到 「替换 3-4 个内部模块实现」 而非 「在 5 个领域重写 Kind/Behavior」。

#### 1.5.7.1 — 前提：ezagent 在有机地做 ES

本 SPEC §1.3 断言：

> 「没有正式事件日志…… [`Behavior.invoke/4` 的] 返回是一个新 slice + 可选结果；slice 变更没有被命名、不持久、不可订阅。」

**这个说法部分错误。** 跑着的代码盘点（`apps/ezagent_core/` + `apps/ezagent_domain_*/`，路径在 `/Users/h2oslabs/Workspace/esr-ng` checkout 验证）：

| ES 概念 | ezagent 原语 | 真相来源 |
|---|---|---|
| 事件日志（追加式） | `invocations` 表 — `(id, trace_id, caller, target, action, args, result, duration_us, authz, exception, inserted_at)` | `apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6` |
| 事件写入器 | `Ezagent.Audit.Writer` — telemetry-handler 喂给 GenServer，100ms 批 `Repo.insert_all/2` flush | `apps/ezagent_core/lib/ezagent/audit/writer.ex:45` |
| Aggregate snapshot | `kind_snapshots(uri PK, kind_type, state_binary, state, version, workspace_uri, inserted_at, updated_at)` | `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex:25` |
| Snapshot 写入器（同步） | `Ezagent.Kind.Snapshot.save_now/3` — 严格，基础设施失败时 raise | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:319` |
| Snapshot 写入器（异步批） | `Ezagent.Snapshot.Writer.async_save/3` — 100ms 批，按 URI 后写覆盖 | `apps/ezagent_core/lib/ezagent/snapshot/writer.ex:45` |
| Snapshot 策略 | `:on_change`（同步、派发后）/ `:on_terminate` / `{:periodic, ms}` / `:ephemeral` / `:external` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:51` |
| Aggregate 进程 | `Kind.Server` GenServer，按 URI 各一个，`handle_call` 序列化 | `apps/ezagent_core/lib/ezagent/kind/server.ex` |
| Aggregate 身份路由 | `Ezagent.KindRegistry` + `Ezagent.SpawnRegistry`（URI → pid） | `apps/ezagent_core/lib/ezagent/kind_registry.ex` |
| Aggregate 命令执行 | `Behavior.invoke(action, slice, args, ctx) :: {:ok, new_slice, result} \| {:error, _}` | `apps/ezagent_core/lib/ezagent/behavior.ex:106` |
| 从 snapshot 恢复状态 | `Ezagent.Kind.Snapshot.load_or_init/3` — 拉 snapshot、URI canonicalize、剔除孤儿 slice、跑每 Behavior 的 `reconcile_after_load/2` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:51` |
| 启动 reconciliation | `Ezagent.ExternalMirror.BootReconciler` — 扫 `external_mirror_bindings`、幂等 spawn Sessions；有界重试 | `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/boot_reconciler.ex` |
| Slice-change 广播 cursor | `Ezagent.SliceChange.Cursors.next/1` — 每次派发前分配，用作 ring buffer key | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:110` |
| 派发前管线 | `Ezagent.Kind.Runtime.handle_dispatch/4` — authz（5.5）、workspace 隔离（5.6）、arg 校验，然后 `invoke/4`，然后提交后 slice-change emit | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:70` |
| 幂等 token | `Ezagent.Idempotency` 在 `Invocation.dispatch/1` 第 1 步 | `apps/ezagent_core/lib/ezagent/idempotency.ex` |

**对 §1.3 的更正。** `invocations` 表**是**追加式事件日志；它有**反规范化列 `(caller, target, action)` 比 Commanded `eventstore` schema 更 SQL 友好**（Commanded `events` 表 keyed `(stream_id, stream_version, event_type, data jsonb, metadata jsonb, created_at)`；caller/target/action 要从 `data` JSON 用 `jsonb_path` 查出来）。§1.3 框架（「审计表是 side-channel telemetry 记录，**不是**真理源」）一半对（**slice 现在是**真理源，不是 audit 行）一半错（audit 行**是**事件日志的形状；只是没被回放）。

**诚实承认（codex r7 LOW-6 关闭，2026-05-28）**：`args` 和 `result` 列在 schema 里存在（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:11,13`）但**当前 `Audit.Writer` 在成功 invocation 上 NOT 填它们**（`apps/ezagent_core/lib/ezagent/audit.ex:93-116` — 只有失败/错误路径填）。表**今天**是「派发元数据的结构化 tuple」；称它是完整领域事件 payload 夸大了当前形状。B'' 承诺通过 §1.5.6 配套 SPEC 扩展 `Audit.Writer` / `EventLog.append/1` 在每次派发上捕获完整 args + result。「比 Commanded 更 SQL 查询」对比**在** args/result 填好之后**才**适用；今天只是 caller/target/action 上的 shape 优势。

诚实的差距是「ezagent 不回放事件来重建 aggregate 状态」+「ezagent 当前事件日志没持久化完整 command/result 载荷」 — 不是「ezagent 没有事件日志」。

**承认的不对称（codex r7 — slice-per-Behavior vs single-aggregate-state）**：Commanded aggregate 是**单模块**：一个 struct + 一个 `execute/2` + 一个 `apply/2`。ezagent Kind 在 Kind 上 host **多个** Behavior（User 注册 Identity + UserCredentials + UserTokens + IdentityAdmin，按 `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:226-231` + `application.ex:271-284`）。状态是按 `behavior.state_slice()` keyed 的 map — 每个 Behavior 拥有**自己**的 slice；跨 Behavior 读需要显式 `reads_sibling_slices/0` 声明。**slice-per-Behavior 模型与 Commanded 单 struct aggregate 是真正不同的聚合模型。** B'' **不**装作它们 1:1：Kind opt-in 事件作真理源时，Kind 上**每一个** Behavior 必须实现 CQRS triplet（§1.5.7.2.b） — 即 Kind 的 aggregate 变成按 Behavior 的 aggregate **元组**，`apply_event/2` 按事件类型派发给拥有的 Behavior。未来 Commanded 迁移必须把它们融成一个 aggregate 状态 struct，**或者**把 Kind 拆成多个 Commanded aggregate（每个 Behavior 一个）；SPEC 不预先承诺哪个。B'' 设计两个选项都保留。

还**没**有的（缺失的 30%）：

- **没有正式 Command 结构体** — `args` 是 `map`，不是 `%Command{}`。合法命令的目录隐含活在每个 Behavior 的 `interface/0` 里。
- **没有正式 Event 结构体** — `Behavior.invoke/4` 返回新 slice，不返回事件列表。slice diff **是**事件，但没被命名也没被结构化。
- **没有回放** — `load_or_init/3` 读最新 snapshot；没 snapshot 就从 `init_slice/1` 重开。snapshot 之间的 `invocations` 历史不被查阅。
- **没有事件驱动的跨 Kind 编排** — 多 Kind 工作流是 caller 代码里的命令式 `try/rescue` 清理（例如 `EzagentDomainChat.create_session/3`）。销毁级联是最尖锐的例子。
- **没有 projection / 读模型分离** — LV 直接通过 `Kind.get_slice/2` 读 slice。没有订阅事件的最终一致性读视图。
- **没有按 command-id 的幂等** — 派发级 `Ezagent.Idempotency` keyed on `%Invocation{}` 信封的 trace_id，不是 caller 提供的 `command_uuid`。

#### 1.5.7.2 — 逐概念对比：ezagent 现在 → Commanded canonical → B'' 改进

每一行追三列：ezagent 今天有什么（带文件路径）、Commanded 怎么做（带文档代码片段）、B'' 承诺什么（参考 Commanded 教训但用 ezagent 现有原语的改进设计）。

##### a. 事件日志 / EventStore

- **ezagent 今天** — `invocations` 表（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6`），SQLite。`Audit.Writer` 通过 `[:ezagent, :invoke, :stop]` telemetry 100ms 批 flush。追加式（当前代码无 UPDATE/DELETE）。索引在 `(inserted_at)` 和 `(target, inserted_at)`。按 aggregate 流就是 `WHERE target = ^uri_str ORDER BY inserted_at, id`（今天就能跑；只是没被命名 — 且 `args` + `result` 列在 schema 里但当前对成功派发不填，见下方 codex r7 LOW-6 修正）。
- **Commanded** — `commanded_eventstore_adapter` 写 PostgreSQL `events` 表。流身份 = `<identity_prefix><aggregate_uuid>`。追加是按流的乐观并发检查（expected_version）。文档原话：「使用 PostgreSQL 持久化的开源事件存储。」
- **B'' 设计** — `Ezagent.EventLog` 模块薄封装现有 `invocations` 表。公开 API：
  ```
  Ezagent.EventLog.append(envelope :: map) :: :ok | {:error, term}
  Ezagent.EventLog.stream_by_aggregate(uri :: URI.t, opts) :: [event_row]
  Ezagent.EventLog.stream_by_workspace(ws :: URI.t, opts) :: [event_row]
  Ezagent.EventLog.stream_since(cursor :: DateTime, opts) :: [event_row]
  ```
  无 schema 变更；现有 telemetry-handler 路径变成 `append/1` 的实现。**扩展点** `Ezagent.EventLog.replay_aggregate/2` 在 §1.5.7.4 文档化，但 **v1 不实现**（还没 Kind 声明事件作真理源）。乐观并发检查也是 Phase 2 — v1 靠 `Kind.Server` GenServer 序列化拿到同样属性。

##### b. 命令 / 事件分离

- **ezagent 今天** — `Behavior.invoke(action, slice, args, ctx)` 是**合并的**原语：决定要做什么（命令）、变更状态（apply 事件）、可能返回结果。slice diff 是隐式事件载荷。来源：`apps/ezagent_core/lib/ezagent/behavior.ex:106`，具体例子 `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:297`。
- **Commanded** — 把 `execute(state, %Command{}) :: [%Event{}]`（决定 + 发射）和 `apply(state, %Event{}) :: new_state`（纯 fold）分开。文档原话：「单个命令可以产生多个事件…… aggregate apply 函数在执行步骤之间被调用，为后续操作维护更新后的状态。」片段：
  ```elixir
  def execute(%BankAccount{state: :active} = acct, %WithdrawMoney{amount: amt}),
    do: [%MoneyWithdrawn{account: acct.id, amount: amt, new_balance: acct.balance - amt}]

  def apply(%BankAccount{} = acct, %MoneyWithdrawn{new_balance: nb}),
    do: %{acct | balance: nb}
  ```
- **B'' 设计** — **不要求**每个 Behavior 都在第一天做这个拆分；那是对 24 个模块的破坏性变更。改成**把拆分作为未来扩展形状**，并**显式声明 legacy `invoke/4` Behavior 被排除在 events-as-truth 回放之外**：
  1. v1 保持 `Behavior.invoke/4` 不变。内部，`Kind.Runtime.handle_dispatch/4` 把每次成功的 invoke 包装成**合成事件** `%SliceMutated{kind_module, action, args, old_slice, new_slice, caller, at}` 并 append 到 `EventLog`。**`%SliceMutated{}` 只是审计 / 通知 / 跨 Kind 触发材料 — 它不是回放安全的事件。** slice diff 无法重建 `invoke/4` 执行的副作用（PubSub 广播、`MessageStore.write`、跨 Kind `Invocation.dispatch/1`、外部 IO）。Codex r7 评审 HIGH-1（2026-05-28）通过对 `Behavior.Chat.invoke(:send)` 的具体追踪（`chat.ex:297-370, 408-414`）将此点明确化：`MessageStore.write` + PubSub 广播 + 接收方派发都在 slice 变更返回之前发生 — `apply_event(%SliceMutated{}, slice) -> new_slice` 都无法回放。
  2. 新的可选 Behavior callback `events_for/4` — 若 Behavior 实现它，合成事件 fallback 被 Behavior 发射的列表替代。签名：`events_for(action, slice, args, ctx) :: [%Event{}]`。Behavior 同时获得 `apply_event/2 :: new_slice` 和 `effects/2 :: [side_effect]`。**三个一起是 events-as-truth opt-in 的原子要求。** `@behaviour` 默认是「events_for 未实现 → 合成事件路径 → 仅审计、无回放」。
  3. 按 Kind opt-in：想要事件作真理源的 Kind 声明其上**每一个** Behavior 都实现 `events_for/4` + `apply_event/2` + `effects/2`（按 Behavior 三元组原子）。Kind 的 `persistence/0` 只在**全部** Behavior CQRS-split 后返回 `:replay_enabled`。`replay_readiness/1` 不变量测试枚举每个 action × 每个 Behavior，任何路径缺三元组都失败。回放通过 `EventLog.stream_by_aggregate + Enum.reduce(events, init_slice, &apply_event/2)` 重建 slice；effects 在回放期间**不**重执行（它们在原派发时已经执行；回放是状态重建，不是副作用重放）。

  **为什么重要**：ezagent 今天保持可发布（不重写 Behavior）。第一个需要回放的 Kind 一次只迁一个 Kind，**但按 Kind 迁移成本是 Kind 上每个 Behavior 的完整 CQRS-split — 不是给一个 Behavior 加一个 callback。** 跨 Kind 编排（B'' §1.5.7.4 模块 #4 SagaRunner）不需要事件拆分 — 合成事件作触发足够，因为触发是审计形状（读「发生了什么」+ 决定下一步），不是回放形状（重建状态）。

##### c. Aggregate 身份

- **ezagent 今天** — `entity://kind/workspace/name` URI。通过 `Ezagent.URI.parse!/1` 规范化（SPEC #324 / URI-canonical chokepoint）。通过 `Ezagent.KindRegistry` 路由（URI → pid）。每个 URI 一个进程；并发派发通过 `Kind.Server.handle_call` 序列化。
- **Commanded** — aggregate UUID，可选 `identity_prefix`。流身份 = `<prefix><uuid>`。每个 UUID 一个进程；并发派发通过 aggregate 进程序列化。
- **B'' 设计** — 保留 ezagent URI 作 Aggregate 身份。文档化等价：ezagent URI = Commanded `<identity_prefix><uuid>`，其中 `identity_prefix = ""` 且 `uuid = URI.to_string(uri)`。**无代码变更** — 属性已经在那里；B'' 只是命名它。若未来切到 Commanded，身份层迁移是 no-op（按 `feedback_uuid_is_canonical_identifier`：URI **是**标识符；我们不增设并行 UUID 列）。

##### d. Snapshot

- **ezagent 今天** — `kind_snapshots` 表；策略通过 `Ezagent.Kind.Snapshot`（`:on_change` 同步、`:on_terminate` 同步、`{:periodic, ms}` 异步通过 `Snapshot.Writer`、`:ephemeral`、`:external`）。Snapshot 存为 `:erlang.term_to_binary(state)`（无损：MapSet、URI、DateTime、atom）。
- **Commanded** — 按 aggregate opt-in：`snapshot_every: N`（每 N 个事件后）+ `snapshot_version: V`（升版以使旧 snapshot 失效）。存到 event-store schema 的 snapshot 表。回放先读最新 snapshot 然后 fold 比 snapshot 新的事件。
- **B'' 设计** — `Ezagent.SnapshotStore` 模块封装 `Ezagent.Ecto.KindSnapshot` + `Ezagent.Kind.Snapshot` 策略逻辑。公开 API：
  ```
  Ezagent.SnapshotStore.latest(uri :: URI.t) :: {:ok, state, version} | :empty
  Ezagent.SnapshotStore.write(uri, kind_module, state, opts :: [tolerate_failure: boolean]) :: :ok | :not_durable | {:error, term}
  Ezagent.SnapshotStore.delete(uri) :: :ok
  Ezagent.SnapshotStore.policy_for(kind_module) :: persistence_policy
  ```
  策略保持 `:on_change` / `:on_terminate` / `{:periodic, ms}`（当前 ezagent 形状）。**扩展点**：`every_n_events/1` 策略变体（Commanded 形状）在任何 Kind opt-in 到事件作真理源时落地（因为按事件计数预设了事件被发射，预设了 §1.5.7.2.b 的事件发射路径）。文档化为 Phase 2。

##### e. 状态恢复 / 回放

- **ezagent 今天** — `Kind.Server.init/1` 调用 `Snapshot.load_or_init/3` → 返回 snapshot 或新 `init_slice/1` 输出。无事件回放。Boot reconciler 只存在于**一个**领域（`ExternalMirror.BootReconciler`）并从**投影表**（`external_mirror_bindings`）rehydrate，不从事件。Allen 2026-05-26 task #34 加了每 Behavior 的 `reconcile_after_load/2`（Kind.Snapshot:155） — 在 merge 状态后对 DB 投影做修正的 hook。
- **Commanded** — 状态 = snapshot（如有）然后 fold 比 snapshot 新的事件。aggregate 进程重启时自动回放；框架不暴露选择。
- **B'' 设计** — `Ezagent.Kind.StateRebuilder` behaviour。必需 callback `rebuild_from_snapshot(uri, snapshot_state) :: new_state`。可选 callback `rebuild_from_events(uri, snapshot_state, event_stream) :: new_state` — 只有 opt-in 到事件作真理源的 Kind（§1.5.7.2.b）实现这个。默认 `Kind.Server.init/1` 调用 `StateRebuilder.rebuild_from_snapshot/2`（当前行为）；按 Kind opt-in `:replay_enabled` flag 切换到事件路径。**扩展点**：`BootReconciler` 通用化 — 今天 `ExternalMirror.BootReconciler` 是按领域手写的。Opt-in 到回放的 Kind 自动获得 boot 时回放；不需要按领域复制粘贴 reconciler。

##### f. Saga / Process Manager

- **ezagent 今天** — ad-hoc PubSub handler（例如 ExternalMirror Worker 订阅 Session 的 `:slice_change` topic）+ ad-hoc 跨 Kind 命令式代码（例如 `EzagentDomainChat.create_session/3` 在 4 个 Kind 上做 5 次派发并在每步加 `try/rescue` 清理）。无公共抽象；每个 saga 都重发明 resume + compensate 原语。**这是 Commanded 风格思路的最强动机** — 每个多 Kind 工作流都是一次性的。
- **Commanded** — `Commanded.ProcessManagers.ProcessManager`：`interested?/1` 选事件、`handle/2` 返回要派发的命令、`apply/2` 变更 PM 自己的状态。PM 状态被 event-store 持久化；跨重启 resume 原生。片段：
  ```elixir
  def interested?(%TransferRequested{id: id}), do: {:start, id}
  def interested?(%TransferCompleted{id: id}), do: {:stop, id}
  def handle(state, %TransferRequested{from: from, to: to, amount: amt}),
    do: [%DebitAccount{account: from, amount: amt}]
  ```
  PM 把两个不同关切混在一起：**单次调用线性 saga**（销毁级联 — caller 一次调用里 N 步）和 **事件驱动跨调用工作流**（worker bootstrap 在 `BindingCreated` 上异步触发，很久后才跑）。
- **B'' 设计** — 把两者分开：
  1. **`Ezagent.SagaRunner`** — 给单次调用线性 saga。接受 `{forward_fn, compensate_fn}` 对的列表，顺序执行，失败时逆向补偿。状态在调用内存里。（这就是 Sage 会给的；B'' 内联 ~200 LOC 实现而非依赖一个未维护的库 — 按 `feedback_let_it_crash_no_workarounds` 我们宁可自有结构性原语也不依赖 §1.5.2 L2 已经标过风险的 2022 年陈旧库。）
  2. **`Ezagent.EventSubscriber`** — `@behaviour` 给 PubSub 驱动跨调用工作流。callback：`interested?(event) :: boolean | {:partition, key}` + `handle_event(event, state) :: [%Command{}]`。状态持久化是 Phase 2 扩展（见 §1.5.7.5(c)）；v1 EventSubscriber 状态在内存。

  **为什么拆**：Commanded PM 想兼任两者，而数据形状（PM-state-per-correlation-id）对一个 7 步销毁级联（saga 状态**就是**调用栈）来说杀鸡用牛刀。反过来，事件订阅器不需要回滚机制（它没发起链条，只是响应）。分开让每个模块都拿到最小契约。

##### g. Projection / 读模型

- **ezagent 今天** — slice **是**读模型**且是**写模型。LV 通过 `Kind.get_slice/2`（同步 `GenServer.call`）读；通过 `Invocation.dispatch/1` 写。没有最终一致性投影表 — 管理 LV 读活的 GenServer 状态，**强一致**但把 LV 人体工程学耦合到 GenServer 生命周期。
- **Commanded** — `Commanded.Projections.Ecto` 通过 `project %Event{}, fn multi -> Ecto.Multi.insert(multi, ...) end` 写投影表。读 = 投影表上的 `Repo.all/get`。一致性模式（强 / 最终）按投影；强模式派发阻塞到投影追上。
- **B'' 设计** — 显式读模型概念，**但不**立刻切到投影表：
  1. v1：`Ezagent.ReadModel` 是 `@behaviour`，默认实现 `slice_via_kind_server(uri, slice_key)`（当前行为）。LV 用 `ReadModel.read(...)` 代替 `Kind.get_slice(...)` — 同样返回，不同命名。
  2. Phase 2 扩展：Kind 可以 opt-in 到背靠的投影表。Behavior 发事件；`Commanded.Projections.Ecto` 形状的 projector 写投影；`ReadModel.read/2` 翻到 `Repo.get/all`。通过 Commanded 的 `consistency: :strong` flag（或 B'' 等价物：派发阻塞到投影追上）保持强一致性。

  **为什么延后**：cap-vis SPEC（§1.2）是投影表的 canonical case，即便那里 slice-as-read-model 已经发布数月而没烧着团队。B'' 承诺契约（`ReadModel` behaviour），不承诺实现。

##### h. 事件版本 / upcasting

- **ezagent 今天** — 无事件版本（事件不是一等公民）。Snapshot `version` 字段存在但不匹配时 fail-loud（`Kind.Snapshot:198`）。
- **Commanded** — `commanded_event_handler` 通过 `Commanded.Event.Upcaster` 协议支持事件 upcaster — 读旧 schema 事件，返回新 schema 事件。
- **B'' 设计** — v1 **不做**。文档化为 Phase 2 扩展点：一旦任何 Behavior 实现 `events_for/4`（§1.5.7.2.b），对应 `apply_event/2` clause 需要版本化。扩展点在 `Ezagent.EventLog.replay_aggregate/2` — 它收到原始行、调可选 upcaster 模块规范化旧 schema、然后喂给 `apply_event/2`。任何 Kind opt-in 之前，这只是文档。

#### 1.5.7.3 — CQRS 原则应用以锐化 B''

这里 B'' 超出「命名已有的」走向「**正确地**设计已有的」。每条原则下面引用 canonical 出处并展示**具体的模块签名形状变化** — 不是改名，是结构性形状变化。

##### 命令 / 查询分离（Greg Young，[cqrs.wordpress.com 2010](https://cqrs.wordpress.com/documents/cqrs-introduction/)）

原则：一个函数要么变更状态要么返回数据，绝不两者皆有。同一个模型不应同时服务写和读。

ezagent 今天违反这个的地方：`Behavior.invoke(action, slice, args, ctx)` 允许返回 `{:ok, new_slice, result}` — 它变更**且**返回。具体例子：`Behavior.Chat.invoke(:send, slice, %{message: msg}, ctx)`（`chat.ex:297`）写到 `MessageStore`、通过 PubSub 广播、通过 `Routing.Resolver` 计算 recipient、返回路由决定。一次调用里 5 个副作用 + 1 个返回值。

**B'' 改进** — `Behavior.invoke/4` 保持当前形状（在 24 个模块上变它是 gold-plating）；为想做 CQRS 的有纪律 Behavior **加**两个显式 hook：

```elixir
@callback execute_command(action, slice, args, ctx) :: [event] | {:error, term}
@callback apply_event(event, slice) :: new_slice
@callback effects(event, ctx) :: [side_effect]   # PubSub 广播、外部 IO、后续派发
```

`Kind.Runtime.handle_dispatch/4` 加一个分支：若 Behavior 实现新三元组就用它；若只实现 legacy `invoke/4` 就回退到合成事件包装（§1.5.7.2.b）。热路径保持单次分配；有纪律的路径是 opt-in。

关键：`effects/2` 返回**声明**，不是函数调用。Runtime 是唯一把 `%PubSubBroadcast{topic, payload}` 转成 `Phoenix.PubSub.broadcast/3` 的地方。Behavior 在 CQRS 意义上变得**纯**；副作用住在派发边界。这就是让 `apply_event/2` 回放安全（回放绝不能重新广播历史消息）的原因。

##### 事件作真理源（[Martin Fowler，"Event Sourcing"](https://martinfowler.com/eaaDev/EventSourcing.html)）

原则：事件是不可变历史记录；当前状态是**派生**；snapshot 是缓存。Fowler 原话：「Snapshots 纯粹是派生的 — 事件日志仍是系统记录。」

ezagent 今天违反这个的地方：snapshot **是**真理源（`Kind.Snapshot.load_or_init/3` 只读 snapshot；snapshot 之间的事件不被查阅）。若 snapshot 文件损坏但事件日志完好，slice 没了。

**B'' 改进** — 即便 v1 为热路径性能保留 snapshot 作真理源，把模块设计成将来可以反转：

1. `apply_event/2` 对任何 opt-in 的 Behavior 必须**纯 + 全函数**。无 DB 读、无时刻分支、无随机。回放安全是结构性属性，不是运行时检查。
2. `Ezagent.EventLog.append/1` 是**唯一**对外发布「状态变了」信号的写路径。今天 `SliceChange` emit 门控在 `Snapshot.commit/4` 返回 `:ok`；B'' 收紧到「门控在 `EventLog.append/1` 返回 `:ok`」。snapshot 变成下游缓存，在事件落地**后**写。
3. `Ezagent.SnapshotStore.write/3` 必须接受 `:tolerate_failure` flag（`:periodic` 默认 true，`:on_change` 默认 false）。事件后窗口里 `:on_change` snapshot 失败不回滚事件 — 只在下次派发时重试。

代价是 opt-in Kind 每次派发多一次写（事件 append + snapshot upsert）。按 §7.1 snapshot 写已经在那里；事件 append **就是**现有的 audit-writer cast。**无新 I/O。** 变化的是**顺序不变量**：先 append 事件，后写 snapshot。

##### Aggregate 边界纪律（[Vaughn Vernon，_Implementing DDD_](https://www.informit.com/store/implementing-domain-driven-design-9780321834577)；[Commanded 文档](https://hexdocs.pm/commanded/aggregates.html)）

原则：一个命令对准一个 aggregate。跨 aggregate 编排走 Process Manager / Saga。两个 aggregate 永不直接变更对方。

ezagent 今天违反这个的地方：`Behavior.invoke/4` 可以通过 `Ezagent.Invocation.dispatch/1` 同步派发到任何其它 Kind。例：`Behavior.Chat.invoke(:send, ...)` 在 sender 调用栈里同步派发 `:receive` 到每个 recipient Kind。若 recipient #3 的 GenServer 死了，sender 的调用在 #1、#2 已经变更后部分失败。

**B'' 改进** — `Behavior.invoke/4` **可以**派发到**其它** Kind，但跨 Kind 效应**必须**包装在：

- **`SagaRunner.run(steps, ctx)`** 给同步线性级联（销毁、session-create）。每步是 `{forward_fn, compensate_fn}`。第 N 步失败时，第 N-1..1 步逆序补偿。现在 `EzagentDomainChat.create_session/3` 里的 `try/rescue` 清理模式是这个的手写版。
- **`EventSubscriber`** 给异步跨调用工作流（worker bootstrap 在 `BindingCreated` 上）。
- **永远不在 `Behavior.invoke/4` 内部直接做编排** — `invoke/4` 可以发**一个**命令等价效应（slice 变更），可以发声明式 `effects/2`（PubSub 广播等），但**不**自己链式派发。

`Kind.Runtime.handle_dispatch/4` 加一个结构性检查：若 Behavior 的 `invoke/4` 直接调 `Ezagent.Invocation.dispatch/1`（通过进程字典探测），记 telemetry warning `[:ezagent, :anti_pattern, :cross_kind_from_invoke]`。Phase 2 升级到硬错；warning 让我们先审计 + 重构现有调用站点。

##### 读侧最终一致性（Greg Young，[_CQRS Documents_](https://cqrs.files.wordpress.com/2010/11/cqrs_documents.pdf)）

原则：CQRS 系统里读模型滞后写模型。读**可能**陈旧。接受陈旧是代价；读侧水平扩展是收益。

ezagent 今天怎么跑：`Kind.get_slice/2` 读是**强一致**（同步 GenServer.call 返回最新状态）。对 LV 人体工程学和写后立即读的等价（§4.8）来说**很棒**。对任何不需要实时新鲜的读（例如管理面板列出每个 workspace 的 session 数）来说**很糟糕** — 这些读和 `Kind.Server` 邮箱抢资源。

**B'' 改进** — 给热路径保留 slice 作强一致（LV 聊天流、派发时 authz 检查、写后立即读站点）。**显式建模**未来投影表的最终一致性读路径：

```elixir
Ezagent.ReadModel.read(uri, slice_key, consistency: :strong)   # 默认 — 当前行为
Ezagent.ReadModel.read(uri, slice_key, consistency: :eventual) # 当投影表存在时 opt-in
```

v1 忽略 `consistency:` flag（slice 是唯一读源）。Phase 2：按投影迁移把特定读站点翻到 `:eventual` 用背靠投影表。§4.8 一致性矩阵成为 LV 写站点 `:strong` 需求的真理源。

##### 幂等（Greg Young，[_Idempotent commands_](https://buildplease.com/pages/idempotent-commands/)）

原则：一个命令有稳定身份；重放同一命令在首次成功后**必须**是 no-op。

ezagent 今天怎么跑：`Ezagent.Idempotency` keyed 在 `%Invocation{}` 信封但 key 是 trace_id，不是 caller 提供的 `command_uuid`。§3.7 grant_cap 网络打嗝重试场景**不**幂等：若派发从 caller 角度看超时但服务端成功，caller 重试创建第二个 grant。

**B'' 改进** — 扩展 `Behavior.invoke/4` 的 ctx，加 **可选** `:command_uuid` key。存在时，在 `invoke/4` **前**用 `command_uuid` 作去重 key 调 `Ezagent.Idempotency.check_or_record/2`。SagaRunner 自动设 `command_uuid = "saga:<saga_id>:step:<N>"`。caller 可以传自己的（`POST /grants` HTTP handler 从 request body hash 出 UUID）。无 `command_uuid` 时行为不变。

这关上重试风暴差距不破坏现有调用站点：无 caller 被强迫造 UUID，但**造**了的 caller 跨崩溃获得 exactly-once 语义。

#### 1.5.7.4 — 具体模块层级与扩展点

5 个新内部模块整合现有原语。每个住在 `Ezagent.*`（无新 umbrella app — 目标是「命名已有的」，不是「再加一个可部署单元」）。

##### 1. `Ezagent.EventLog`

**签名**：
```elixir
@spec append(envelope :: map) :: :ok | {:error, term}
@spec stream_by_aggregate(uri :: URI.t, opts :: [from: DateTime.t, limit: pos_integer]) :: [event_row]
@spec stream_by_workspace(ws :: URI.t, opts) :: [event_row]
@spec stream_since(cursor :: DateTime.t, opts) :: [event_row]
```

**设计理由**：薄 facade 在现有 `invocations` 表上。envelope 形状标准化 telemetry handler 已经在写的；`Audit.Writer` 变成 `append/1` 的一个实现（批的那个）；未来 Postgres 后端实现直接换模块、调用方不变。Stream-by-aggregate 是新辅助。

**排序契约（codex r7 MED-4 关闭，2026-05-28）**：`stream_by_aggregate/2` 按 `(inserted_at ASC, id ASC)` 排序。`id` 列是现有 `invocations` 主键（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:7`，单调整数）。仅按 `inserted_at` 在同微秒 tie 下**不**稳定（测试批量插入、高吞吐生产） — `id` tie-breaker 让顺序在跨查询读时全序且稳定。Cursor 分页用 `(inserted_at, id)` 对作 cursor key：`WHERE (inserted_at, id) > (^cursor_at, ^cursor_id)`。这镜像 Commanded `RecordedEvent` 的 `(stream_version, event_number)` 对，只是 keyed on `(inserted_at, id)` 因为 ezagent invocations 表早于 per-stream-version-counter 设计。Phase 2 扩展点：加 `expected_version` 时，SPEC 迁移到真正的 per-stream version 列 — 但 (inserted_at, id) 排序保持作为 wire-format cursor 后向兼容。

**扩展点**：
- `replay_aggregate(uri, init_slice, apply_event_fn)` — v1 禁用；文档化为第一个 Kind opt-in 事件作真理源时的 Phase 2 入口。
- 可插拔存储后端：今天 SQLite via Ecto；Phase 3+ 可换到 Postgres 或 `commanded_eventstore_adapter`，调用方不变。
- `append/1` 上的乐观并发 `expected_version` 参数 — Phase 2（今天 `Kind.Server` GenServer 序列化拿到同样属性；`expected_version` 加入时引入 `stream_version` 列）。

**测试策略**：stream-by-aggregate 顺序 + cursor 分页的单元测试（含显式同微秒批量插入测试验证 `id` tie-breaker）；模拟 1000 次派发并断言 stream 有序 + 完整 + 跨查询可重现的集成测试。

**估算 LOC**：~150（大多是 delegation）。

##### 2. `Ezagent.SnapshotStore`

**签名**：
```elixir
@spec latest(uri :: URI.t) :: {:ok, state :: map, version :: non_neg_integer} | :empty
@spec write(uri :: URI.t, kind_module :: module, state :: map, opts :: [tolerate_failure: boolean]) :: :ok | :not_durable | {:error, term}
@spec delete(uri :: URI.t) :: :ok
@spec policy_for(kind_module :: module) :: persistence_policy
```

**设计理由**：把当前三个 snapshot 入口（`Snapshot.load_or_init/3`、`Snapshot.save_now/3`、`Snapshot.Writer.async_save/3`）统一到一个有名模块下。`write/4` 的 `:tolerate_failure` flag 是「我是定期 flush、丢一个 snapshot 没事」vs「我是事件后提交、snapshot 失败必须传播」的显式旋钮。当前调用站点把这个知识散布在 4 个模块；B'' 集中化。

**扩展点**：
- `every_n_events/1` 策略变体 — 在任何 Kind opt-in 到事件作真理源时加（按事件计数预设了事件被发射，预设了 §1.5.7.2.b 的事件发射路径）。
- 可插拔存储：今天 SQLite via `Ezagent.Ecto.KindSnapshot`；Phase 3+ 若事件日志搬走则 Postgres。

**测试策略**：每个 Kind 的 `persistence/0` 值都解析为有效 `policy_for/1` 形状的不变量测试；write→latest→decode 的往返测试。

**估算 LOC**：~200（现有 `Kind.Snapshot` 的逻辑大致不变地迁过来）。

##### 3. `Ezagent.Kind.StateRebuilder`（behaviour）

**签名**：
```elixir
@callback rebuild_from_snapshot(uri :: URI.t, snapshot_state :: map) :: new_state :: map
@callback rebuild_from_events(uri :: URI.t, snapshot_state :: map, event_stream :: Enumerable.t) :: new_state :: map
```

**设计理由**：今天 `Kind.Server.init/1` 硬编码 snapshot-only 恢复路径。提升到 behaviour 给按 Kind opt-in 到事件作真理源、不改调用站点。默认实现（由 `use Ezagent.Kind` 自动提供）是 `rebuild_from_snapshot/2 = fn _uri, snap -> snap end` 和 `rebuild_from_events/3 = :not_implemented`。Opt-in 的 Kind override 两个。

**扩展点**：
- `BootReconciler` 通用化 — 今天 `ExternalMirror.BootReconciler` 按领域手写。Opt-in 到 rebuild-from-events 的 Kind 免费获得 boot 时回放；不需要每领域 reconciler。
- 混合模式：Kind 可以实现 `rebuild_from_events/3`，用 snapshot 作起点然后 fold 比 snapshot 时间戳新的事件。

**测试策略**：每个 opt-in 的 Kind 发布「rebuild parity」测试 — 带 Kind 走 100 次派发、snapshot、kill、只从 snapshot 重建、只从事件重建，断言三个 slice 相等。

**估算 LOC**：~80（behaviour 定义 + 默认 macro 实现）。

##### 4. `Ezagent.SagaRunner`

**签名**（codex r7 契约关闭，2026-05-28）：

```elixir
defstruct steps: [], compensations: [], ctx: %{}, name: nil, command_uuid: nil

@type effect_map :: %{atom() => term()}   # step_name -> forward_fn 的 :ok 值

@spec new(name :: String.t, opts :: [command_uuid: String.t]) :: %SagaRunner{}
@spec run(
  saga,
  step_name :: atom,
  forward :: (effect_map -> {:ok, term} | {:error, term}),
  compensate :: (effect_map, effects_so_far :: effect_map -> :ok | {:error, term})
) :: %SagaRunner{}
@spec execute(saga, initial_ctx :: map) :: {:ok, effect_map} | {:error, step :: atom, reason :: term, compensated_steps :: [atom]}
```

**Ctx 传递契约**：
1. `execute/2` 把 `effect_map = initial_ctx` 作种（initial_ctx 折进 effect_map：`Map.merge(initial_ctx, %{})`）。
2. 每个 `forward/1` 接收当前 `effect_map`（含 initial ctx **加** 每个前序步的 `:ok` 结果按 step_name keyed）。`{:ok, value}` 时 runner 扩展 `effect_map = Map.put(effect_map, step_name, value)` 继续；`{:error, reason}` 时触发逆向补偿。
3. 每个 `compensate/2` 接收 `(this_step's_effect_map_entry, effect_map_built_through_prior_steps)`。第一个 arg 是**本**步 forward 返回的（`Map.get(effect_map, step_name)`）；第二个是前序步建好的完整 prior-state map，给跨步补偿用（例如第 3 步 compensate 需要读第 1 步的 snapshot）。
4. 补偿按 step 逆序跑（步 N-1 → 1 — 失败步 N 本身无 `:ok` 值可补偿）。
5. 成功返回：完整 `effect_map`，调用方看到每步结果。

用法示例（销毁级联）：

```elixir
Ezagent.SagaRunner.new("destroy_agent:#{uri}", command_uuid: trace_id)
|> SagaRunner.run(:snapshot,    &capture_pre_destroy/1,    &noop/2)
|> SagaRunner.run(:revoke_caps, &revoke_all_caps/1,        &restore_caps/2)
|> SagaRunner.run(:terminate,   &terminate_agent/1,        &noop/2)
|> SagaRunner.run(:audit,       &write_destroy_audit/1,    &noop/2)
|> SagaRunner.execute(%{agent_uri: uri, workspace_uri: ws_uri})
```

上面级联里，`capture_pre_destroy/1` 收 `%{agent_uri: ..., workspace_uri: ...}`（initial ctx），返回 `{:ok, %{caps: caps, sessions: sessions, lineage: parent}}`；若 `terminate` 在 cap 已被 revoke 后失败，`restore_caps/2` 就能拿到该 snapshot 作 `effects_so_far[:snapshot]`。

**设计理由**：B'' 内联 saga 原语而非依赖 Sage（§1.5.4 风险：Sage 2022-09、ex_audit 2023-02）。内联是 ~200 LOC；依赖 Sage 是同样 LOC 加上依赖陈旧风险。按 `feedback_let_it_crash_no_workarounds` 我们自有结构性原语。契约故意是 **Sage 的子集** — 我们不需要 Sage 暴露的异步/并行特性；ezagent 的 saga 清单（§4.4）都是线性步。

**扩展点**：
- `run_async/4` — Phase 2；今天 SagaRunner 只同步。异步需要跨调用的状态持久化。
- `Ezagent.SagaOutbox` — Phase 2 跨重启持久 saga 状态（`saga_executions` 表 + 轮询 worker）。关上 §1.5.3 codex HIGH-2 标记的 Sage 内存状态差距。任何 saga 的中途崩变得可观测频繁之前，这是 Phase 2。
- `command_uuid` 传播 — 每步的 invoke keyed on `"saga:<name>:step:<step_name>"` 给重试时自然幂等。

**测试策略**：前向 happy path；前向第 N 步失败逆向补偿第 N-1..1 步逆序；补偿自身失败留 marker 给 operator-repair（与 §3.8 r3 saga doctrine 一致）。

**估算 LOC**：~200。

##### 5. `Ezagent.EventSubscriber`（behaviour）

**签名**（codex r7 MED-5 关闭，2026-05-28 — partition 模式拉到 Phase 2）：

```elixir
@callback interested?(event :: map) :: boolean
@callback handle_event(event :: map, state :: map) :: {:ok, new_state} | {:dispatch, [%Command{}], new_state} | {:error, term}
@callback initial_state(opts) :: map  # 默认 %{}
```

v1 的 `interested?/1` 返回类型只是 `boolean`。先前的 `{:partition, key}` 形状被提到 Phase 2 扩展点，因为 v1 无法诚实规约分区生命周期、按 key 顺序、重启行为、GC 策略、重复处理 — 没有 outbox（Phase 2 — Ext.c）支撑。v1 subscriber 单进程，subscriber 模块内一次一个；顺序是 `EventLog.stream_by_aggregate` 顺序；并发通过注册多个 subscriber 模块达成。

注册机制（`use Ezagent.EventSubscriber, application: :ezagent_core`）监督每个注册的 subscriber 一个进程，订阅 `EventLog` 的 append 后 PubSub topic。`BindingCreated` 上的 worker bootstrap 变成：

```elixir
defmodule Ezagent.ExternalMirror.WorkerBootstrapSubscriber do
  use Ezagent.EventSubscriber, application: :ezagent_domain_external_mirror
  def interested?(%{action: :bind, kind_module: Ezagent.Entity.Session}), do: true
  def interested?(_), do: false
  def handle_event(%{target: session_uri, args: %{adapter: a, params: p}}, state),
    do: {:dispatch, [%SpawnWorker{session_uri: session_uri, adapter: a, params: p}], state}
end
```

**设计理由**：今天同样的效果要写一个自定义 GenServer 订阅 PubSub 然后再派发。EventSubscriber 命名模式 + 标准化契约。关键：这跟 SagaRunner **分开** — EventSubscriber 没发起链条（不需要回滚机制）；SagaRunner 发起了。

**扩展点**：
- `Ezagent.EventOutbox` — Phase 2 给 subscriber 在 handler 中途崩时持久重试。今天 subscriber 崩 + supervisor 重启会重订阅但丢正在处理的事件。Outbox 在 subscriber 处理事件**前**把派发意图写到 `event_subscriber_outbox` 表；轮询 worker drain。
- **分区模式（Phase 2 — codex r7 MED-5 关闭）** — 给高量 topic，按 key（例如 workspace_uri）分区起 N 个并行 subscriber 进程。Phase 2 契约**必须**规定：(i) 分区所有权（按 key 一进程，或固定 N 池按 hash keyed），(ii) 按分区顺序保证，(iii) 崩 + 重启的回放行为，(iv) GC 策略（按分区 idle timeout 或持久），(v) 通过 `command_uuid` 防重 handler。v1 的 `interested?/1` callback 仅返回 `boolean` — `{:partition, key}` 待 Phase 2 SPEC 定义 (i)-(v) 后再落地。

**测试策略**：派发触发事件，断言 subscriber 的 `handle_event/2` 恰好跑一次；杀掉 subscriber 在 handler 中途、重启、断言 handler 不重跑（通过 §1.5.7.3 的 `command_uuid` 幂等）。

**估算 LOC**：~250（behaviour + supervisor + registry）。

**新代码总计**：跨 5 个模块 ~880 LOC。对比 Option A 的 1500-2000 LOC saga 代码（按 §4.4）+ umbrella-app 添加。

#### 1.5.7.5 — 未来扩展点 roadmap

5 个具体扩展场景 + B'' 的生长路径。每个命名触发条件 + 结构性变化，按 LOC 和周数计量。

##### a. 若 `invocations` 表长得太大

**触发**：SQLite 文件 > 5 GB；全表扫描超过 1 秒。

**B'' 生长路径**：冷归档到 `invocations_archive`（独立表），按 cutoff 日期切。`EventLog.stream_by_aggregate/2` UNION 查两个表。schema 基本相同；活动表保持小 + 索引以利热写。现有 `MessageStore.older_than/3` 已经用这个模式（按 `feedback_register_lookup_key_parity` 在 §6.0 r4 的先例）。**成本**：迁移 + UNION 查询 + cutover 约 3-4 天。

**调用方无代码变更** — `EventLog.stream_by_aggregate/2` 对是否 UNION 是不透明的。

##### b. 若第一个 Kind 需要回放（P5 进入 roadmap）

**触发**：合规要求重建历史状态（例如 SOC 2 审计「user X 在 2025-09-12 14:00 UTC 时持有哪些 cap」）；**或** 某个 Kind 受益于事件驱动的事故后复现。

**B'' 生长路径**：该 Kind 把其上每个 Behavior 都 opt-in 到 CQRS triplet（`events_for/4` + `apply_event/2` + `effects/2`）。`EventLog.replay_aggregate/2` 亮起（被实现）。Kind 的 `persistence/0` 返回 `:replay_enabled`。`StateRebuilder.rebuild_from_events/3` 接上。其它 Kind 不受影响。按 `feedback_let_it_crash_no_workarounds`，无 shim 或双模式 — 一旦 Kind opt-in，每次重启都走事件路径。

**具体走查 — User Kind（codex r7 HIGH-2 关闭，2026-05-28）**。User Kind 实际注册的 Behavior（按 `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:226-231` 加 `application.ex:271-284` 的 `IdentityAdmin` 扩展）：**`Identity`、`UserCredentials`、`UserTokens`、`IdentityAdmin`**。按 Behavior 的回放就绪评估：

- **`Identity`** — caps slice 是内存 `MapSet`；cap grant/revoke 是 slice 变更；`reconcile_after_load/2` 从 `users.caps_json` rehydrate（`identity.ex:156-206, 228-245`）。回放路径：`events_for(:grant_cap, ...)` 发 `%CapGranted{cap}`，`apply_event(%CapGranted{cap}, slice) = MapSet.put(slice.caps, cap)`。**可回放** 若 `users.caps_json` 投影写变成 `effects/2` 声明而非内联 DB 写。
- **`UserCredentials`** — `invoke(:set_password, ...)` bcrypt-hash + 通过 `Ezagent.Entity.User.update_password/2` 写 `users.password_hash`（`user_credentials.ex:112-122`，`users.ex:100-112`）。DB 写是 canonical 来源 — slice 不带 password。回放路径：`events_for(:set_password, ...)` 发 `%PasswordChanged{hash}`；`apply_event` 对 slice 是 no-op（无内存表示）；`effects/2` 声明 `%DbWrite{table: users, set: %{password_hash: hash}}`，Runtime 执行。**可回放** 仅当 `effects/2` 在回放期间**不**重执行（否则回放会重写历史）。B'' 契约（§1.5.7.2.b）是回放重新 fold 事件但**不**重执行 effects — 已验证。
- **`UserTokens`** — `invoke(:mint_token, ...)` 生成 token、bcrypt-hash、插入 `entity_tokens`（`user_tokens.ex:120-146`，`token.ex:75-91`）；`invoke(:revoke_token, ...)` 预读 + 删除（`user_tokens.ex:173-191, 260-272`）。Token 表是真理源 — slice 镜像它做热路径读。回放路径：`events_for(:mint_token, ...)` 发 `%TokenMinted{token_id, label, hash}`；`apply_event` 更新 slice MapSet；`effects/2` 声明 `entity_tokens` insert。Revoke 对称。**可回放** 同 `UserCredentials` 的 effects-not-replayed 属性。`mix ezagent.user.replay` 任务**不会**重新 mint token；只从现有事件重建 slice 的 token-MapSet。
- **`IdentityAdmin`** — admin-scope grant。与 `Identity` 同形状。**可回放**。

**User Kind opt-in 总成本**：~3-4 周（非最初 2-3 周 — r7 修正）。分解：`UserCredentials` + `UserTokens` 各 ~1 周（DB-写 Behavior 需要小心提取 `effects/2`）；`Identity` + `IdentityAdmin` 各 ~3 天（仅 slice）；`replay_readiness/1` 不变量测试 + 集成测试（从 100 个事件重建 User 并对比 snapshot 版本）~1 周。**第一个 Kind opt-in 是贵的**，因为测试 scaffolding 是 greenfield；后续 Kind 摊销到 ~2 周。

**关键属性**：按 Kind 迁移，不是 big-bang。对比 Option A 在一个 Phase-10 计划里迁所有 5 个实体 Kind（本 SPEC §6，~3 个月 wall-time）。**但**：B'' 回放 opt-in 门控在 Kind 上**每个** Behavior 通过 `replay_readiness/1`。一个 Behavior 未迁的 Kind 不能 opt-in。这是 §1.5.7.2.b 原子三元组不变量强制的结构性成本。

##### c. 若 saga 持久变成需要（跨重启 resume）

**触发**：可观测性显示 >1% 的销毁级联在执行中途崩（例如 operator 在长跑级联中 kill BEAM）；operator-repair 太频繁。

**B'' 生长路径**：加 `Ezagent.SagaOutbox` — `saga_executions` 表 + 轮询 worker。SagaRunner 的 `execute/2` 加 `:durable` opt；设了之后每步开始/结束写到 outbox；BEAM 重启时轮询 worker 从最后完成的步 resume 未完成 saga。**成本**：~2 周（schema + worker + 测试）。关上 §1.5.3 给 Sage 提的 codex HIGH-2 差距。

**关键属性**：按 saga opt-in，不是一刀切。大多数 saga（§4.4 的 5 个单次调用级联）不需要持久因为 <100ms 完成。

##### d. 若投影表变成需要（最终一致性读）

**触发**：某读站点（管理面板、CLI 列出、HTTP endpoint）对 `Kind.Server` GenServer 邮箱有可测量竞争；**或** 分析用例需要不重启 Kind 也能读历史状态。

**B'' 生长路径**：`Ezagent.Projection` behaviour + 每投影 `init_from_events/1`（初始 backfill）+ `handle_event/2`（增量更新）。投影表是自己的 Ecto schema。`ReadModel.read(uri, slice_key, consistency: :eventual)` 翻到查投影表。slice 保留给热路径强一致读（LV 聊天流、派发时 authz 检查）。**成本**：每投影 ~1-2 周。

**关键属性**：按投影迁移，不是按 Kind。cap-vis SPEC 的 `workspace_visibility_per_caller` 投影（本 SPEC §1.2）作独立投影落地、不碰其它读。

##### e. 若我们真的需要 Commanded — 迁移路径是所有选项中**最短**的

这一点关键。§1.5.7.6 比较的 4 个选项在 Allen 未来决定 ezagent 应该采纳 Commanded 时的迁移成本不同：

- **Option A（Commanded 直接）** — 已经在那。成本：0。
- **Option B（Sage + ex_audit）** — strangle 模式迁移：事件得从 `Ecto.Changeset` 历史回溯推断；saga 模块从 Sage 重写到 Commanded PM。成本：~10-12 周。
- **Option B'（DIY Ecto.Multi）** — 事件得从零建模；saga 重写。成本：~14-16 周。
- **Option B''（原生整合）** — 事件已存在（在 `EventLog` / `invocations`）；aggregate 已存在（按 Kind）；snapshot 已存在（`SnapshotStore` / `kind_snapshots`）。saga 存在于 `SagaRunner` 形状里，**概念上邻近但与** Commanded PM **不是 1:1**（codex r7 HIGH-3 关闭，2026-05-28）：`SagaRunner` 是无状态调用内闭包列表（`run/4` + `execute/2`）；Commanded PM 是有状态的，含 `interested?/1` + `handle/2` + `apply/2` + 按实例的 correlation-id PM 状态。saga 迁移**不**是 wrapping swap — 它要求把每个 `SagaRunner.execute` 调用站点翻译成带 `interested?` clause + correlation id + 持久 PM 状态 + 停止条件的 PM。

  按组件迁移成本分解：
  - `EventLog` → `commanded_eventstore_adapter`：~1 周（主要是 schema 迁移 + 双写 cutover；公共 API **已经**是 stream-by-aggregate 语义的 1:1 wrap）。
  - `SnapshotStore` → Commanded snapshot：~3-4 天（策略不同 — `:on_change` / `:on_terminate` 是 ezagent 形状 vs Commanded 的 `snapshot_every: N`；迁移转换策略声明）。
  - `EventSubscriber` → `Commanded.Event.Handler`：~1 周（订阅者注册语义匹配；partition 模式（B'' Ext.）映射到 Commanded 的 `subscribe_to: :all` + handler 并发）。
  - **`SagaRunner` → `Commanded.ProcessManagers.ProcessManager`：每个非平凡 saga ~3-4 周**，因为每步的 forward/compensate 闭包变成 PM 事件 handler 分支，含 correlation id 派生 + interested? 选择器 + apply/2 fold + 停止条件。§4.4 的 5 个单调用级联各 ~3-5 天；跨调用工作流如 `EzagentDomainChat.create_session/3` 流（lock + spawn + bind + 异步 cast `chat.join` + grant owner cap + `ensure_orchestrator_with_meta` 带 `:partial` 有界重试 — `ezagent_domain_chat.ex:143-200, 540-615, 619-648`；`session.ex:850-889, 984-1003`）各 ~1-2 周，因为异步腿和 `:partial`-结果分支需要持久 PM correlation 状态。
  - 每 Kind `events_for/4` + `apply_event/2` + `effects/2` 三元组 → Commanded `execute/2` + `apply/2`：每个 opt-in 的 Kind ~1-2 周（slice-per-Behavior 模型必须融合成单一 aggregate 状态 struct — 见下方 §1.5.7.1 codex r7 HIGH 承认）。

  **诚实修正总数**：~6-10 周（最简单组合：1-2 个小 saga，无跨调用工作流，无 Kind opt-in 到事件作真理源），~10-14 周（若有 2+ 跨调用工作流 + 多 Behavior Kind 需要迁移）。先前「~4-6 周」是乐观下限；codex r7 HIGH-3 评审正确标记为低估。**即便在修正区间，B'' → Commanded 仍比 Option B → Commanded 便宜（仅 saga 就 ~10-12 周，加上事件得从零推断），比 Option B' → Commanded 戏剧性更便宜（~14-16 周）。**

**修正后「面向未来 Commanded」的意思。** 通过让 `EventLog`、`SnapshotStore`、`EventSubscriber` 与 Commanded 等价物近 1:1，且 `SagaRunner` 提供 ezagent 今天需要的 saga 形状（线性、同步）**加** 难情况下到 PM 的清晰迁移路径，我们既保留选项又**缩小**未来成本（最低限度省了 Option B 受困的「事件得推断」~6 周）。B'' 不是 Commanded 的 1:1 wrapper；它是**会合性**设计 — 大多数概念紧密对齐；saga 需要翻译但不需要重发明。

#### 1.5.7.6 — 对比总结表

| 维度 | Option A (Commanded) | Option B (Sage + ex_audit + Oban) | Option B' (DIY Ecto.Multi + 事件日志) | Option B'' (原生整合) |
|---|---|---|---|---|
| **第一天 LOC delta** | +5000-7000（3 个新 umbrella app + 9 个 saga + 5 个 aggregate + 8 个 projector） | +1500-2000（Sage 模块 + ex_audit 接线 + Oban outbox） | +1200-1800（DIY 编排 + DIY 审计 + DIY 约束） | **+880（5 个内部模块）** |
| **第一天 wall-time** | ~3 个月 | ~3-4 周 | ~4-5 周 | **~2-3 周** |
| **第一天基础设施变更** | Postgres 进 dev loop；新 umbrella app | Postgres 给 Oban；无 umbrella 变化 | 无 | **无** |
| **第一天退役模块** | 7 个内部（Kind.Server、KindRegistry、Audit.Writer、Persistence、Snapshot.Writer 等） | 0 | 0 | **0** |
| **长期回放** | 原生 | 按 Kind 手写 | 按 Kind 手写 | **按 Kind opt-in 原生（Ext.b）** |
| **长期分布式扩展** | 原生（多节点 aggregate） | 可能通过 Oban 分布 | 可能通过 Postgres | **可能通过 SagaOutbox / EventOutbox（Ext.c/Ext.d）** |
| **长期多租户** | 按 aggregate 强隔离 | Workspace 通过 DB scoping | Workspace 通过 DB scoping | **Workspace 通过 `Persistence.scope_by_workspace`（已经在）** |
| **若未来需要 Commanded 时的迁移成本** | 0 | ~10-12 周 | ~14-16 周 | **~6-14 周（按 §1.5.7.5(e) r7 诚实区间；下限取决于 saga 清单 + Kind opt-in 数）** |
| **依赖风险** | Commanded 自身（活跃、好维护）；EventStore lib | Sage 2022 陈旧；ex_audit 2023 陈旧；Oban Pro 付费 | 无（stdlib + Ecto） | **无（用现有 ezagent 原语）** |
| **派发延迟开销** | +5x 按 §7.1 | 0 | 0 | **0** |
| **Dev-loop 摩擦** | Postgres 必须 | Postgres 必须（Oban） | 无 | **无** |
| **与 `feedback_let_it_crash_no_workarounds` 对齐** | 高（CQRS 是结构性的） | 中（Sage 加 workaround 给缺失的结构性原语） | 中高（DIY 是结构性但 ad-hoc） | **高（命名我们已有的结构性原语）** |
| **与 `feedback_north_star_plugin_isolation` 对齐** | 高（插件作者待在 `execute/2` / `apply/2`） | 中（插件作者学 Sage + ex_audit + Oban） | 低（插件作者学 N 个 ad-hoc 模式） | **高（插件作者继续写 `invoke/4`；按 CQRS 原则 opt-in 到 `execute_command/apply_event`）** |
| **按 `feedback_completion_requires_invariant_test`** | 每 aggregate 新不变量 | 每 saga 新不变量 | 每 Ecto.Multi 新不变量 | **现有不变量保留；只给 opt-in Kind 加新不变量** |
| **架构漂移风险** | 低 — Commanded 强制形状 | 中 — Sage + ex_audit + Oban 微妙地交互 | 高 — DIY 长期漂移 | **低 — 抽象有命名 + 测试** |

##### 诚实承认

- B'' **今天不**解决 P5（回放） — 它在第一天 0 成本提供扩展点（Ext.b）。若回放在 <6 个月内需要，Option A 仍是正确选择。
- B'' **今天不**解决中途 saga 持久 — 与 Option B 的差距同形状。SagaOutbox（Ext.c）是需要时的关门器。
- B'' 是在同一架构上的重构，不是替换。Allen 可以争论这是错的抽象层。反驳：每个其它选项**也**保留当前架构**并**叠加新层；B'' 是唯一**少于 1000 LOC 新代码**的选项，也是唯一命名已有部分的选项。

#### 1.5.7.7 — 推荐

**B'' 是推荐路径。** 理由：

1. **最小第一天足迹** — ~880 LOC、无新 umbrella app、无 Postgres 进 dev loop、无退役模块。~2-3 周发布。对比 Option B 的 ~3-4 周 + outbox 依赖，B'' 足迹更低**且**结构上更干净因为消除了 Sage/ex_audit/Oban 依赖三角。

2. **无依赖风险** — Option B 继承 Sage 2022-09 + ex_audit 2023-02 陈旧（§1.5.4）。B'' 用 ezagent 自身原语 + 标准 Ecto + Phoenix.PubSub。唯一加的「库」是 `ezagent_core` 里已存在模块的名字。

3. **对未来 Commanded 迁移最优位置** — §1.5.7.5(e)。B'' → Commanded 的迁移 ~6-14 周（codex r7 HIGH-3 诚实区间；下限取决于 saga 清单 + Kind opt-in 数）。便宜部分（`EventLog`、`SnapshotStore`、`EventSubscriber`）是近 1:1 wrap；贵部分（saga → Commanded PM）需要翻译而非改名。即便上限仍比 Option B 的 ~10-12 周（事件推断 **加** saga 重写）便宜，比 Option B 的 ~14-16 周戏剧性更便宜。B'' 让最终 Commanded 迁移成为非平凡路径里**最便宜**的。

4. **对齐 `feedback_let_it_crash_no_workarounds`** — 每个其它选项加 shim（Sage 的 saga 状态、Oban 的 outbox、ex_audit 的 changeset interceptor）。B'' 不加 — 它命名的每个原语都是已经在代码里的结构性真相。「缺失的 30%」是模块命名，不是新行为。

5. **对齐 `feedback_north_star_plugin_isolation`** — 插件作者继续写 `Behavior.invoke/4`。CQRS 升级路径（`execute_command/2` + `apply_event/2`）是按 Behavior opt-in。无插件作者被强迫学 Sage 或 ex_audit 或 Oban；核心保持不变。

**备选顺序** 若 B'' 设计被 codex review 否决或 impl-PR 起草失败：

1. 第一备选：**Option B**（Sage + ex_audit + Ecto.Multi + Oban outbox 按 §1.5.5）。是之前的结论；若 (a)(b)(c) 成立且依赖风险可接受，仍可行。
2. 第二备选：**Option A**（按本 SPEC §2-§12 的 Commanded 完整迁移）。仅在回放（P5）成为 roadmap 项**或** B'' 和 B 都不可行时才正当化。

**前进路径**：

1. 本 SPEC（#442）更新 §1.5.5 结论和 §1.5.6 下游影响，反映 B'' 为主选。
2. 5 个配套 SPEC（每个对应 §1.5.7.4 的一个 B'' 模块）起草；每个都小 + 独立 + 2-3 周可落地：
   - `2026-05-28-ezagent-eventlog-naming.md` — 把现有 audit-writer 管线命名为 EventLog
   - `2026-05-28-ezagent-snapshotstore-naming.md` — 把 Snapshot.Writer + Kind.Snapshot 统一到 SnapshotStore
   - `2026-05-28-ezagent-saga-runner.md` — 内联 ~200 LOC SagaRunner；按它重写 §4.4 saga 清单
   - `2026-05-28-ezagent-event-subscriber.md` — 命名 EventSubscriber behaviour；refactor 2 个现有 PubSub 驱动 subscriber
   - `2026-05-28-ezagent-state-rebuilder.md` — 把 `Kind.Server.init/1` 的恢复提升到 StateRebuilder behaviour
3. 每个配套 SPEC 按 `feedback_codex_review_every_pr` 走 codex adversarial-review。
4. 若任何配套 SPEC 在 review 中失败到抽象形状变化，本 §1.5.7 重审。

---

## 2. 决策 — 采用 Commanded + EventStore 作为主状态模型

> ⚠️ **§2 前置说明（r7）**：§1.5 结论是 **Option B''（原生整合）**（r7 更新 — 替代 r6 的「条件性 Option B」）。§1.5.7 详述：ezagent 9 个月来一直在有机实现 ES 原语；B'' 把它们命名 + 加上缺失的 30%，通过 5 个小内部模块（~880 LOC，~2-3 周）。下方 §2-§12 反映的是 Commanded 完整迁移路径（Option A），保留作 **第二备选** 落在 Option B（按 §1.5.5 是第一备选）之后。Option A 只有在 B'' 和 Option B 都不可行 **或** 回放（P5）进入未来 6 个月 roadmap 时才成为主路径。§1.5.6 列出超越本 SPEC 的 5 个 B'' 配套 SPEC。**不要按现状合并 §2-§12**。

### 2.1 采纳的组件

| 组件 | 库 | 角色 |
|---|---|---|
| `Commanded.Application` | `commanded` | per-deployment 派发 + aggregate 承载边界 |
| `Commanded.Commands.Router` | `commanded` | Command → Aggregate 通过 `:identify` 路由 |
| `Commanded.Aggregates.Aggregate` | `commanded` | 替代 `Ezagent.Kind` 的 GenServer 模式的 behaviour |
| `Commanded.ProcessManagers.ProcessManager` | `commanded` | 多 aggregate 工作流（销毁级联等的新家） |
| `Commanded.Event.Handler` | `commanded` | 非投影的事件订阅者（如把事件镜像到外部系统、发后续命令但无状态 — 当状态机过重时的 process manager 简化版） |
| `Commanded.Projections.Ecto` | `commanded_ecto_projections` | 用 Ecto.Multi 在事件上更新表的读模型投影器 |
| `EventStore` | `eventstore` | Postgres-backed 的事件持久化 |
| `Commanded.EventStore.Adapters.EventStore` | `commanded_eventstore_adapter` | 把 `commanded` 接到 `eventstore` 的 adapter |
| `Commanded.EventStore.Adapters.InMemory` | 内置 | test / dev 循环用的事件存储 |

### 2.2 暂不采纳的

- **EventStoreDB**（独立 Erlang/Scala 事件存储，走 `commanded_extreme_adapter`）— 比 Postgres + `eventstore` 库运维更重，目前规模无集群需求。Postgres 运维普及；EventStoreDB 小众。（§7.4 + §10 OQ-1 讨论。）
- **EventStoreDB 上的 snapshot 存储** — 我们用 Commanded 内建的 snapshot-every-N，存在同一个 Postgres `eventstore` schema。每 Kind 迁移时现有 `kind_snapshots` SQLite 表退役。
- **多 app Commanded 拓扑**（每个 bounded context 一个 `Commanded.Application` + 跨 app 事件桥）— 对 5-Kind 模型过度；我们跑**一个** `Ezagent.CommandedApp`，含所有 aggregate + 所有 process manager + 所有投影器。规模需要时再分拆是 Phase N+1 的事。

### 2.3 不变的（外部 API 面）

- Phoenix.Channel 的 `handle_in/3` 回调。当前构造 `%Invocation{}` 调 `Invocation.dispatch/1`；迁移后构造 `%Cmd{}` 调 `Ezagent.CommandedApp.dispatch/2`。从 JS 客户端看 channel topic、消息形状、响应形状不变。
- LiveView `mount/3` + `handle_event/3`。同样的改动：派发 Command 替代 Invocation。读从投影查询替代 `Kind.get_slice/2`（§5）。
- CLI `mix ezagent.*` 任务。同样的派发改动。读自投影表。
- HTTP plug 控制器（如 `EzagentWeb.SessionController.create`）。同样。
- 基于 URI 的寻址模型。Aggregate UUID **就是** 规范化的 URI 字符串；不引入新的寻址方案。
- 能力语义。Cap struct + 匹配器不变。检查从 `Kind.Runtime` 步骤 5.5 移到派发前流水线（§4.5）。
- 对插件作者可见的 Behavior 合约面在**语义上**保留 — 他们声明一个 Kind（现在是 Aggregate）、状态（现在事件派生）、actions（现在 commands）、invoke 逻辑（现在 `execute/2` 返回事件 + `apply/2` 返回新状态）。接口语法不同，但心智模型保留（§4.2 逐回调映射）。

### 2.4 必须变的（内部）

- `Ezagent.Kind.Server` 每 Kind 迁移完即退役。共享 GenServer 被 Commanded `AggregateRegistry` 管理的 `Commanded.Aggregates.Aggregate` 进程取代。
- `Ezagent.Kind.Snapshot` 每 Kind 迁移完即退役。Commanded snapshot 存储（Postgres-backed，由 `snapshot_every:` 配置）取代它。
- `Ezagent.Audit.Writer`（`invocations` SQLite 表）对领域事件路径退役；事件流**就是**审计日志。非领域 telemetry（被否决的 authz、持久化失败、跨切 boot/teardown）保留在 SQLite audit 表（§4.7）。
- `Ezagent.Invocation.dispatch/1` 作为公共派发入口退役。由 `Ezagent.CommandedApp.dispatch/2` 取代。12 步流变为 5 步派发前流水线 + Commanded 的 aggregate 承载（§4.5）。
- `Ezagent.KindRegistry` 每 Kind 迁移完即退役。Aggregate 查找由 Commanded 内部处理；跨-Kind 引用走事件 + saga、不走 registry。
- `Ezagent.SpawnRegistry` 每 Kind 迁移完即退役。「Spawn」变成「aggregate ID 上的第一条命令创建它」— aggregate 在创建命令应用前不存在；后续创建命令确定性地失败。
- `Ezagent.PendingDelivery` Phase 10-A 后退役（not-yet-ready buffer 模式）。Aggregate 没有同样意义的 `:not_ready` 状态 — 它要么已创建（历史非空）、要么未创建（历史空）；对未创建 aggregate 的派发要么创建（按 `execute/2` 对空状态的子句）、要么以「未创建」错误失败。
- `Ezagent.Persistence.scope_by_workspace/2` 和 `workspace_uri_for/1` 保留 — 现在用在**投影**表上、而非 slice 写。workspace 隔离不变式在投影器 + 读查询里强制。

### 2.5 决策边界 — 本 SPEC 承诺什么、不承诺什么

本 SPEC **承诺**：
- 采纳 Commanded + EventStore 作为未来的状态模型。
- §6 的 4 阶段迁移计划（Phase 10-A 到 10-D），每个阶段边界有显式 unwind。
- §4.4 当前 Kind → Aggregate 的映射表 + §4.4.2 的跨-Kind 工作流清单（定义迁移后存在哪些 Process Manager）。
- Dev 循环故事（fast tests 用 in-memory adapter；dev + prod 用 Postgres）。见 §7.3。
- §4.7 审计分解 — 领域事件走事件存储、纯 telemetry 留 SQLite。

本 SPEC **不**承诺：
- 每个 Aggregate 的精确事件 schema（每 Aggregate impl SPEC 在 Phase 10-B 到 10-D）。
- 每个 read-model 的精确投影表形状（impl-time per phase 决定）。
- Process Manager 是跑在 Commanded Application 内部还是 sibling supervisor（§10 OQ-5）。
- Per-Aggregate snapshot-every-N 调参（默认 = 50，benchmark 证明时 per-Aggregate 覆盖）。
- 任何命令的精确 CLI / LV 表单变化（per `IMPLEMENTATION_ROADMAP.md` §1.4 现有的 CLI ↔ LV 同构不变式；迁移后保留，具体绑定细节在实施 PR）。

---

## 3. Phoenix + Commanded 混合集成 — 关键研究问题

这是 Allen 明确指明深挖的章节。集成**不**新颖（§3.6 列出生产参考），但模式很微妙。整个 CQRS 的要点是写路径（命令派发到 aggregate、事件持久化）与读路径（投影查询）的不对称。LiveView 和 Phoenix.Channel 同时坐在**两**条路径上。本节枚举每种交互。

### 3.1 "Phoenix 在边、Commanded 在核" 模式

跨 Conduit、gift-card-demo、segment-challenge、Honeydew 的标准模式：

```
                       ┌─────────────────────────────┐
                       │  外部传输                    │
                       │  (HTTP / WS / LV / CLI / MCP)│
                       └──────────────┬──────────────┘
                                      │
                                      ▼  (构造 %Cmd{})
                       ┌─────────────────────────────┐
                       │  派发前流水线                │
                       │  - authn (已存在)            │
                       │  - authz (CapBAC step 5.5)   │
                       │  - workspace 隔离 5.6        │
                       │  - 幂等性检查                │
                       │  - URI 规范化                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  Ezagent.CommandedApp.dispatch(cmd, opts)
                       ┌─────────────────────────────┐
                       │  COMMANDED.APPLICATION       │
                       │  Router → 按 id :identify    │
                       └──────────────┬──────────────┘
                                      │
                                      ▼
                       ┌─────────────────────────────┐
                       │  AGGREGATE                   │
                       │  execute(state, cmd)         │
                       │   → [event(s)] | error       │
                       │  apply(state, event)         │
                       │   → new_state                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  事件追加到事件存储
                       ┌─────────────────────────────┐
                       │  事件存储 (Postgres)         │
                       └──────────────┬──────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
        ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
        │ 投影器       │    │ Process Mgr  │      │ Handler      │
        │ Ecto.Multi   │    │ saga 状态 +  │      │ 副作用       │
        │ 更新读表     │    │ 发命令       │      │ (通知、扇出) │
        └──────┬───────┘    └──────┬───────┘      └──────────────┘
               │                   │
               ▼                   ▼
       ┌─────────────┐     ┌─────────────┐
       │  LV / API   │     │  Aggregate  │
       │  读读表     │     │  (后续命令) │
       └─────────────┘     └─────────────┘
```

Phoenix.Channel 和 LiveView 坐在顶（写侧，构造命令）和底（读侧，查投影）。Commanded 拥有中间。插件作者写命令、事件、aggregate、投影器、process manager — 永远不直接碰事件存储。

### 3.2 LiveView 写路径 — handle_event/3 → dispatch

参考自 `gift-card-demo/lib/gift_card_demo/gift_cards.ex`：

```elixir
defmodule GiftCardDemo.GiftCards do
  alias GiftCardDemo.AppRouter
  alias GiftCardDemo.GiftCard.Commands.{IssueGiftCard, RedeemGiftCard}

  def issue_gift_card(amount) do
    command = %IssueGiftCard{id: UUID.uuid4(), amount: amount}
    AppRouter.dispatch(command)
  end

  def redeem_gift_card(id, amount) do
    command = %RedeemGiftCard{id: id, amount: amount}
    AppRouter.dispatch(command)
  end
end
```

LV `handle_event/3` 调 `GiftCards.issue_gift_card(amount)`。函数构造 Command struct 并派发。不直接访问 EventStore；不手动发事件；aggregate 的 `execute/2` 决定发什么事件。

**对 ezagent**，等价的 context 模块是 per-Domain 的（每个 `apps/ezagent_domain_*` 一个）— `Ezagent.Domain.Chat.create_session(...)`、`Ezagent.Domain.Identity.grant_cap(...)` 等。每个 context 函数：
1. 构造 `%Cmd{}` struct，aggregate 的规范化 URI 作为 `:id`。
2. 用 `opts`（依调用者意图决定 — `consistency: :strong` 用于 read-after-write 路径；其它 `:eventual` — 见 §3.3）调 `Ezagent.CommandedApp.dispatch(cmd, opts)`。
3. 返回 `:ok` / `{:error, reason}`。

派发前流水线（§4.5）包住 `Ezagent.CommandedApp.dispatch/2`，让 authz、workspace 隔离、幂等性、URI 规范化在边界处发生**一次**，而不是每个 domain context 函数里。

### 3.3 Read-after-write 一致性 — 关键问题

当 LV `handle_event` 派发命令然后 re-render，re-render 能看到新状态吗？

**Commanded 支持三种模式：**

**(a) `consistency: :eventual`（默认）。** 事件持久化后 dispatch 即返回 `:ok`。投影器异步跑。LV 在 dispatch 返回时立刻 re-render — 但投影表可能尚未反映变化。下一次来自 PubSub 或投影器 `after_update/3` 的推送触发后续 render，带新状态。UX：短暂的过期读；用户在典型 1-10ms 投影器延迟内看到变化。

**(b) `consistency: :strong`。** Dispatch 阻塞直到**所有**标 `consistency: :strong` 的投影器都提交完。LV 在 dispatch 后的 re-render 同步看到新状态。代价：dispatch 延迟 = 事件追加（5-50ms）+ 最慢强一致投影器提交（典型再 5-20ms）。扇到多个强一致投影器时，上界是其中最大值。（[hexdocs Commands.md](https://hexdocs.pm/commanded/Commanded.Commands.Router.html)）

**(c) `consistency: [ProjectorA, ProjectorB]`。** 阻塞直到具名投影器追上。折中：只对喂这个 LV 的投影器同步等待、其它异步。

**ezagent 的选择 — per 派发点，默认 `:eventual`，opt-in `:strong`：**

`Ezagent.CommandedApp.dispatch/2` 的默认是 `consistency: :eventual`，因为大多数派发（chat 发送、纯审计写、扇出式变更）派发点不需要 read-after-write。派发点 opt-in `:strong`（或具名投影器列表）的场景：

- 同一个 LV render 回读它刚更新的投影（如 create_session → 向导跳转到 /sessions/X 并 render session detail — detail 投影必须就位）。
- CLI 命令把结果状态打到 stdout（确定性 CLI 返回）。
- 控制器响应 201 并返回创建资源的投影状态。

opt-in 机制在派发点显式：`Ezagent.CommandedApp.dispatch(cmd, consistency: :strong)`。默认 `:eventual` 让热路径快；LV/PubSub 模式（3.4）让 eventual 几乎对用户不可见。

**Process Manager 发出的命令永远用 `:eventual`** — saga 自己是事件订阅者，等它派发后续命令时原事件已经持久化；让 saga 内部各步在强一致上阻塞会与 saga 自己的事件订阅死锁。

### 3.4 LiveView 读路径 — 订阅投影、不订阅事件

参考自 gift-card-demo：

```elixir
defmodule GiftCardDemoWeb.GiftCardSummaryLive do
  use Phoenix.LiveView
  alias GiftCardDemo.GiftCards

  def mount(_session, socket) do
    if connected?(socket), do: GiftCards.subscribe()
    {:ok, fetch(socket)}
  end

  def handle_info({:gift_card_summary, %GiftCardSummary{}}, socket) do
    {:noreply, fetch(socket)}
  end

  defp fetch(socket) do
    assign(socket, gift_cards: GiftCards.list_gift_cards())
  end
end
```

投影器里：

```elixir
project %GiftCardIssued{...} = event, fn multi -> ... end

def after_update(_event, _metadata, %{gift_card_summary: summary}) do
  Registry.dispatch(Registry.GiftCardSummary, :gift_card_summary, fn entries ->
    for {pid, _} <- entries, do: send(pid, {:gift_card_summary, summary})
  end)
end
```

**流：**
1. LV `mount/3` 订阅 per-投影 Registry topic。
2. LV 初次 render 直接读投影表（同步 DB 查询）。
3. 投影器的 `after_update/3` 回调（`commanded_ecto_projections` 钩子）把更新行扇出给所有订阅者。
4. LV `handle_info` 重读 + re-render。

**对 ezagent**，把 `Registry` 换成 `Phoenix.PubSub`（代码库里已用；统一 topic 命名）。Per-Aggregate-class 投影器定义 topic 如 `"ezagent:projections:user:#{user_uri}"` 并在 `after_update/3` 广播。LV 在 mount 时订阅。

跨 5 个 Kind 模式对称 — User、Session、Agent、Workspace、Worker，每个都有投影器 + PubSub topic；LV 按它 render 的 URI 订阅。

**冷加载问题。** LV mount 时投影还没追上最新事件（一个竞态窗口：LV mount 与投影器订阅并行），初次 render 显示过期状态。两个方案：

- **`Commanded.Subscriptions.wait_for/3`** — LV mount 在特定 aggregate UUID + version 上阻塞，直到投影器追上。比标准模式稍同步，但消除 LV 紧贴 dispatch 后 mount 的过期窗口（如向导 redirect-then-mount）。
- **Dispatch-then-mount-with-aggregate-version** — 派发代码把 dispatch 结果的 `:aggregate_version` 通过 redirect URL 或 session 透传；LV mount 等到**那个**特定 version 再 render。这是 gift-card-demo 的扩展模式。

对 ezagent，标准 LV 模式是 redirect 前的 dispatch 用 `consistency: :strong`；目标 LV 在 dispatch 返回后 mount，所以投影在 mount 时一定已追上。wait_for/3 helper 作为跨 tab 竞态（tab 2 在 tab 1 dispatching 时打开详情页）的 fallback。

### 3.5 Phoenix.Channel 写路径（CLI、agent_bridge、feishu）

Phoenix.Channel `handle_in/3` 结构上与 LV `handle_event/3` 相同 — 构造命令并派发。区别仅在回复机制：

- **LV** — re-render 由 `assign/2` 自动触发；用户在 HTML 里看到结果。
- **Channel** — `handle_in/3` 返回 `{:reply, {:ok, payload}, socket}`，JS 客户端（cli、agent_bridge）收回复。dispatch 结果（典型 `:ok` 或 `{:ok, %ExecutionResult{}}`）被序列化到 channel payload。

对需要把数据返回给调用者的命令（如 CLI `mix ezagent.user.token --mint` 打出铸的 token）：
- dispatch 用 `consistency: :strong`（这样 token 在读模型里）。
- dispatch 返回后派发点立刻查读模型。
- dispatch 结果 + 读模型行一起返回给 channel。

Commanded 没有 `Behavior.invoke/4` 那种「返回值在事件里」的模式 — 事件是过去事实，不是返回值。若调用者需要返回值，返回值在 dispatch **之后**从读模型派生。

### 3.6 生产参考

| 项目 | 技术栈 | 备注 | URL |
|---|---|---|---|
| **Conduit** | Phoenix + Commanded | RealWorld 示例 app（Medium 克隆）；成熟；演示 router、aggregate、投影器、process manager、Phoenix view | https://github.com/slashdotdash/conduit |
| **Gift-card-demo** | Phoenix LiveView + Commanded | 更小、LV 重点；演示 projection-via-Registry 模式 + `after_update/3` 钩子 | https://github.com/slashdotdash/gift-card-demo |
| **Segment Challenge** | Phoenix + Commanded | Strava 赛事的生产 app；更大规模的 aggregate 清单 | https://github.com/slashdotdash/segment-challenge |
| **Honeydew** | Phoenix LiveView + Commanded + Postgres（"CELP 栈"）| 入门模板；演示标准接线 | https://github.com/quarterpi/honeydew |
| **Casavo（medium post）** | 生产公司 | 用 Commanded + LiveView 在事件存储顶上做监控/调试工具；演示「LiveView 作为事件存储观察者」模式（我们会用同样模式做 `/admin/events`） | https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99 |
| **ElixirMerge 指南** | walkthrough | EventStoreDB + Phoenix + LiveView CQRS/ES 指南 | https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview |
| **Cantido 博文** | Phoenix LV 事件溯源 | LV 订阅 `$all` 事件流 + push_event 给 JS hook 做高频 render | https://dev.to/cantido/phoenix-liveview-but-event-sourced |
| **Christian Alexander 博文** | Phoenix API + Commanded | Read-after-write 强一致模式 walkthrough | https://christianalexander.com/2022/05/09/elixir-commanded/ |

**成熟度判定：** 集成已建立；参考 app 存在；社区 Q&A 在 ElixirForum 可追溯到 2018。**不**是开创性的。「Phoenix 在边、Commanded 在核」模式是事实标准。ezagent 落在已有用例的舒适区。

### 3.7 失败模式 — 可能哪里出错

| 失败 | 原因 | 恢复 | SPEC §引用 |
|---|---|---|---|
| **Aggregate 进程回放中崩溃** | 流里有损坏事件**或** `apply/2` 有 bug 导致重建抛错 | Commanded `AggregateRegistry` 重启 aggregate；回放从最近 snapshot 续。若 bug 在 `apply/2`，崩溃循环到代码修好。约束：每 N 事件 snapshot 限制回放范围，代码修好后立即恢复（回放从 snapshot 起、不从事件 0 起）。 | §4.4 + §6 Phase 10-A |
| **EventStore Postgres 宕机** | DB 挂 | `dispatch/2` 返回 `{:error, _}`。调用者按 transient failure 处理（重试策略）。内存中 aggregate 状态存活；Postgres 恢复时派发恢复。Sagas 暂停（订阅停收事件）；恢复后从最后处理事件续跑。 | §7.4 + §8 |
| **Saga 部分失败** | Process Manager 的 `handle/2` 返回了目标 aggregate 拒绝的命令 | Saga 的 `error/3` 决定：带退避重试、补偿（派发逆向命令）、跳过续跑、停止。补偿逻辑是 saga 里的显式代码；没有框架自动回滚。 | §3.8 销毁级联专门 |
| **现存 aggregate 加新事件类型** | 代码加了 aggregate 现在发的新事件 variant | `apply/2` **必须**有该新事件的子句。Aggregate 等价的 `behaviors/0` 列表（aggregate 模块本身）是真值；新事件也加到投影器的 `project` 子句。 | §10 OQ-3 + §11 q#6 — 事件 schema 演进 |
| **旧事件类型移除** | 代码停止发某类历史流里有的事件 | `apply/2` **仍**必须有该历史事件的子句（回放需要）。该子句若字段不再相关可为 no-op；事件**本身**不从历史里删。 | §10 OQ-3 |
| **现存事件加字段** | 需要给 `MessagesPosted` 事件加 `caller_metadata` | `Commanded.Event.Upcaster` impl 在事件读时跑，把旧事件变成新形状后再喂 `apply/2`。历史事件磁盘字节不动；内存形状被升级。 | §10 OQ-3 |
| **投影偏离 aggregate** | 投影器有 bug，写错列 | 从事件流重建：停投影器 → 截断投影表 → 重启投影器并 `start_from: :origin`。代价：O(events) 回放；aggregate snapshot 由 `snapshot_every` 限界、投影回放无此限（投影回放读全流）。对我们规模是分钟、不是小时。 | §7.4 + §8 |
| **热 aggregate 10K+ 事件** | 重用的 Session 在生命周期内累 10K MessagesPosted | snapshot_every: 50 把冷启动回放限到 ≤50 事件；热 aggregate 留内存。最坏回放 = ~50 事件 × `apply/2` 延迟（每事件 μs 级）≈ 1ms。 | §7.2 |
| **两个写者同 aggregate 竞速** | 并发的 LV + CLI 派发同 aggregate UUID 的命令 | Commanded 在 aggregate 级串行化（per-UUID 一个进程）；第二条命令在第一条后面排队。只有显式设 `expected_version` 才报乐观并发错（ezagent 不设 — 接受隐式串行）。 | §4.5 |
| **事件存储 schema 破坏变更** | Commanded major 版本升级引入事件存储表变更 | 升级迁移在 Postgres 跑；事件**不**重写（事件 payload 是 JSON、schema 灵活）；只周围 metadata 列变。每次升级前读 [commanded changelog](https://hexdocs.pm/commanded/changelog.html)。 | §7.4 |

### 3.8 销毁级联的 saga 补偿模式（最初的触发）

来自 SPEC #440 的销毁级联，表达为 Process Manager：

```elixir
defmodule Ezagent.Saga.DestroyAgentSaga do
  use Commanded.ProcessManagers.ProcessManager,
    application: Ezagent.CommandedApp,
    name: "DestroyAgentSaga"

  defstruct [:agent_uri, :workspace_uri, :step, :caps_revoked, :children_destroyed]

  # 在 AgentDestroyRequested 事件上启动（Agent aggregate 接收 Destroy 命令时发出）。
  def interested?(%AgentDestroyRequested{agent_uri: uri}), do: {:start, uri}

  # 对 saga 发的命令的后续事件继续。
  def interested?(%AgentCapsRevoked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentChildrenDestroyed{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentMembershipsDropped{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentLineageUnlinked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentTerminated{agent_uri: uri}), do: {:stop, uri}

  # 步骤 1：撤销该 agent 持有的所有 cap。
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}
  end

  # 步骤 2：cap 撤完，销毁子 agent（lineage 级联）。
  def handle(%__MODULE__{step: :caps_revoked} = pm, %AgentCapsRevoked{}) do
    case Ezagent.Projection.AgentLineage.children_of(pm.agent_uri) do
      [] -> %SkipChildrenDestruction{agent_uri: pm.agent_uri}
      children -> %DestroyChildAgents{agent_uri: pm.agent_uri, children: children}
    end
  end

  # 步骤 3：退出所有 session。
  def handle(%__MODULE__{step: :children_destroyed} = pm, %AgentChildrenDestroyed{}) do
    %DropAllSessionMembershipsFor{agent_uri: pm.agent_uri}
  end

  # 步骤 4：解链 lineage。
  def handle(%__MODULE__{step: :memberships_dropped} = pm, %AgentMembershipsDropped{}) do
    %UnlinkLineage{agent_uri: pm.agent_uri}
  end

  # 步骤 5：终止 aggregate（最终）。
  def handle(%__MODULE__{step: :lineage_unlinked} = pm, %AgentLineageUnlinked{}) do
    %TerminateAgent{agent_uri: pm.agent_uri}
  end

  # 状态机 — 跟踪步骤推进。
  def apply(%__MODULE__{} = pm, %AgentDestroyRequested{} = ev),
    do: %{pm | agent_uri: ev.agent_uri, workspace_uri: ev.workspace_uri, step: :requested}

  def apply(pm, %AgentCapsRevoked{}), do: %{pm | step: :caps_revoked, caps_revoked: true}
  def apply(pm, %AgentChildrenDestroyed{}), do: %{pm | step: :children_destroyed, children_destroyed: true}
  def apply(pm, %AgentMembershipsDropped{}), do: %{pm | step: :memberships_dropped}
  def apply(pm, %AgentLineageUnlinked{}), do: %{pm | step: :lineage_unlinked}

  # 错误 / 补偿。
  def error({:error, :agent_not_found}, _cmd, _ctx) do
    # 到步骤 5 时 agent aggregate 不存在 — 级联已经走过另一路径销毁了 — 幂等。
    {:skip, :discard_pending}
  end

  def error({:error, _failure}, _cmd, %{context: %{retries: n}}) when n >= 3 do
    # 同一步三次失败 — 停下要求运维介入。Saga 状态持久；运维可检查 + 续跑。
    {:stop, :too_many_failures}
  end

  def error({:error, _failure}, _cmd, %{context: ctx}) do
    {:retry, 1_000, Map.update(ctx, :retries, 1, &(&1 + 1))}
  end
end
```

**与 SPEC #440 destroy_log 表方案的对比：**

| SPEC #440 r4 (destroy_log 表) | 本 SPEC (DestroyAgentSaga) |
|---|---|
| 手卷的 append-only 旁路表 | 事件流（已经定义就是 append-only） |
| 手卷的 boot 时续跑 reconciler | Saga 订阅自动从最后处理事件续跑 |
| 每个 behavior 手卷「这一步是否幂等」纪律 | 每一步是对特定 aggregate 的命令；aggregate 自己处理幂等（重复销毁返回 `{:error, :already_destroyed}`） |
| 手卷的部分失败补偿 | `error/3` 回调 + `{:retry, ...}` / `{:stop, ...}` 框架原语 |
| 手卷的「销毁级联推进到第 N 步」审计行 | 每一步发领域事件；saga 状态**就是**级联审计 |

销毁级联变成 ~100 行 saga 代码 + per-aggregate 命令/事件 variant。框架拥有「原子」性质（步骤边界处原子、步骤间显式补偿）。

### 3.9 Phoenix 集成专门的开放问题

冒上 §11 codex 评审：

- 我们 LV 代码用 `assign_new/3` 和 per-tab session state 够多吗，足以把读路径改成投影驱动？（够 — 当前 LV 已经把 `Kind.get_slice/2` 包在 `assign/2`，替换是机械的。）
- 我们有任何代码路径在某个 Kind 的 `Behavior.invoke/4` **内部**读**另一个** Kind 的 slice 吗（派发内跨 Kind 读）？（有 — `Behavior.Identity.check_grant_authorized` 读 owner URI 的 slice。迁移后这必须从投影读、或通过新一次派发查目标 aggregate — 见 §11 q#5。）
- 是否有地方按 SQL 谓词（workspace_uri、时间范围）查询审计表 `invocations` 行？（有 — `/admin/audit` LV。迁移后对领域事件的审计查询变成事件流过滤**或**对 `audit_events` 投影表的查询。§4.7 + §11 q#8。）

---

## 4. 把当前 ezagent 架构映射到 CQRS

### 4.1 概念到概念的映射

| 当前 | 新 | 迁移备注 |
|---|---|---|
| `Ezagent.Kind` behaviour 模块 | 实现 `Commanded.Aggregates.Aggregate` behaviour 的模块 | Kind 模块的 `type_name/0` / `behaviors/0` / `persistence/0` 回调 → aggregate 的 `execute/2` / `apply/2`。`behaviors/0`（Kind 组合的 Behavior 列表）由 aggregate per-event `apply/2` 子句编码 — 旧 behaviors 中任何一个发的事件对应一条子句。 |
| `Ezagent.Behavior.X` 模块 + `actions/0` + `invoke/4` | per-Behavior 命名空间的 Command 模块 + Event 模块 + per-Aggregate `execute/2` 子句 | 如 `Behavior.Chat.actions == [:send, :join, :leave]` 变成 `Behavior.Chat.Commands.SendMessage`、`JoinSession`、`LeaveSession` + 对应 `MessagesPosted`、`MemberJoined`、`MemberLeft` 事件。派发把命令路由到 Session aggregate；它有每命令的 `execute/2` 子句。 |
| per-Kind slice 状态（`state.state[behavior.state_slice()]`） | Aggregate state struct | Kind GenServer 的 `state.state` slice 映射变成 aggregate `defstruct` 字段。不再「slice key」 — 每个字段就是 aggregate 上的 struct 字段。 |
| `Ezagent.Kind.Snapshot.save_now/3`（同步 `:on_change`） | Commanded snapshot-every-N（Postgres-backed） | 默认 `snapshot_every: 50` 事件。benchmark 证明时 per-Aggregate 覆盖。替代 `:on_change` 和 `:periodic` 两种策略。`:ephemeral` 变「无 snapshot 配置」（永远事件回放）。`:on_terminate` 变无关（Commanded 中 aggregate 无 terminate 钩子）。 |
| `Ezagent.Persistence` per-workspace 范围（`scope_by_workspace/2`） | 同模块 + 同范围、对投影表 | workspace 隔离不变式从 slice 写移到投影写 + 读查询。函数原样保留；它在 `projections.*` 表上跑而已。 |
| `Ezagent.Invocation.dispatch/1` | `Ezagent.CommandedApp.dispatch/2`（由派发前流水线包裹） | 12 步流折叠（5-10 变 Commanded 内部）；1-4 + 5.5-5.6 + 11-12 保留（现在在派发前流水线 + 投影器触发的 `after_dispatch`）。 |
| `Ezagent.KindRegistry`（URI → pid） | Commanded 内部 aggregate registry | 直接查找（如给 `Kind.get_slice/2`）由投影读替代。`KindRegistry.lookup/1` 的外部调用者迁移后无幸存。 |
| `Ezagent.SpawnRegistry` + `Kind.spawn/2` | 隐式（aggregate ID 上的第一条命令创建它） | 「spawn」动词消失；aggregate 由它的第一条创建命令（`%RegisterUser{}`、`%CreateSession{}` 等）创建。`{:error, {:already_started, pid}}` 竞速变 aggregate `execute/2` 确定性返回的 `{:error, :already_created}`。 |
| 跨-Kind 级联在调用者命令式代码（如 `EzagentDomainChat.create_session/3` 跨 4 Kind 的 5 派发编排） | 订阅源事件的 Process Manager (Saga) | 如 `SessionCreated` 事件触发 `GrantOwnerCapsSaga`，发 `GrantCap` 命令；saga `error/3` 处理补偿。 |
| `Ezagent.Audit.Writer` 写 `invocations` SQLite 表 | 事件流**就是**审计日志（对领域事件） + audit-events 投影做可查子集 | 跨切 telemetry（被否决 authz、持久化失败、cc_bridge 事件）留 SQLite audit；领域事件移事件流 + 可查投影。见 §4.7。 |
| `kind_snapshots` SQLite 表 | Commanded snapshot 存储（在 `eventstore` Postgres schema 中） | 对迁移完的 Kind：现有 snapshot **不**迁移（per `feedback_destructive_migration_anti_pattern`）；迁移后 Aggregate 上的第一条命令创建新鲜的事件溯源状态。混合期间未迁移 Kind 的 snapshot 数据原样不动。 |
| `Ezagent.ReadyGate`（状态 `:ready` / `:not_ready` / `:unknown`） | 隐式（aggregate 存在 ⇔ 命令可派发） | post-init 缓冲的 `:not_ready` 模式变「第一条创建命令必先于其它命令」；后续命令在 aggregate 创建前失败。Buffering（旧 `Ezagent.PendingDelivery`）对迁移 Kind 退役。 |
| `Ezagent.PendingDelivery`（对未 ready Kind 的 cast 缓冲） | 对迁移 Kind 退役 | 对未创建 aggregate 的 cast 命令在派发时失败（`{:error, :aggregate_not_found}` 或 Commanded 对未创建 aggregate cast 的返回 — 见 §11 q#8）。 |
| `Ezagent.Behavior.X.post_init/2` + `handle_continue/3`（Kind register 后的延迟工作） | 订阅 `AggregateCreated` 类事件的 Process Manager | external-mirror-domain SPEC §6.1 的 split-init 模式变成：aggregate 创建命令发 `WorkerCreated`；`WorkerBootstrapSaga` 订阅该事件、派发后续命令（订阅 publisher 等）。 |
| `Ezagent.Kind.Server.handle_call({:ezagent_get_slice, slice_key}, ...)` | 投影表查询 | 跨进程 slice 读变 `Ezagent.Projection.X.get(uri)`。查询走读模型模块；读时不碰 aggregate 进程。 |
| `Ezagent.CapabilityRegistry` + `Ezagent.BehaviorRegistry` | 原样保留 | 编译/启动期注册 cap subject；registry 在派发前流水线被查。无事件溯源相关。 |
| `@behaviour Ezagent.Behavior` + cap_subjects/0 + data_owner/1 | 保留（语义微变）— cap_subjects 表示哪些命令通过 CapBAC 受门控；data_owner 表示哪个 aggregate 拥有底层数据 | 派发前的 CapBAC chokepoint 不变；cap_subject **就是**命令的 behavior + action 轴。data_owner 现在指向 aggregate URI 而非 Kind 的拥有 principal。 |

### 4.1.5 完整 Kind / Behavior 清单（r2 — 静态生成）

r1 说「5 entity Kinds + 11 Behavior modules」— 实际 checkout 枚举：

**耐久 Kind 模块（`{:snapshot, :on_change}` 或 `:on_terminate`）— 全部需迁移目标：**

| Kind 模块 | App | 持久化 | 迁移目标 |
|---|---|---|---|
| `Ezagent.Entity.User` | ezagent_domain_identity | `{:snapshot, :on_change}` | `Ezagent.Aggregate.User`（§4.2.1） |
| `Ezagent.Entity.Session` | ezagent_domain_chat | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Session`（§4.2.3） |
| `Ezagent.Entity.Agent` | ezagent_domain_chat | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Agent`（§4.2.2） |
| `Ezagent.Workspace` | ezagent_domain_workspace | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Workspace`（§4.2.4） |
| `Ezagent.Entity.AgentTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` | **`Ezagent.Aggregate.AgentTemplate`**（r2 §4.2.6 新加） |
| `Ezagent.Entity.SessionTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` | **`Ezagent.Aggregate.SessionTemplate`**（r2 §4.2.7 新加） |
| `Ezagent.Entity.ExternalMirrorWorker` | ezagent_domain_external_mirror | `:on_terminate` | `Ezagent.Aggregate.ExternalMirrorWorker`（§4.2.5） |
| `Ezagent.Entity.CurlAgent` | ezagent_plugin_curl_agent | `{:snapshot, :on_change}` | `Aggregate.Agent` 的 flavor 变体 |
| `Ezagent.Entity.Echo` | ezagent_plugin_echo | 视 flavor | `Aggregate.Agent` 的 flavor 变体 |
| `Ezagent.Entity.NpAgent` | ezagent_plugin_np | 视 flavor | `Aggregate.Agent` 的 flavor 变体 |

**Behavior 模块（24 个 — `find apps -path "*/behavior/*.ex"` 静态枚举），含 r1 漏掉的 ApiKeys / Template / OrchestratorAdmin / Pty / UserBinding / FeishuAllow 等 — 完整表见 EN §4.1.5。**

**Phase 门（per `feedback_completion_requires_invariant_test`）：** 每阶段的不变式测试枚举范围内所有 Behavior、断言每个有对应迁移目标（或显式"保留 runtime"决定）。新 `Ezagent.Invariants.NoBehaviorLeftBehindTest` 在 Phase 10-D 合并前走 BehaviorRegistry、若有可派发 Behavior 缺 Aggregate 命令映射则 FAIL。

### 4.2 5 个实体 Kind — 每 Kind 的迁移目标

#### 4.2.1 `Ezagent.Entity.User` → `Ezagent.Aggregate.User`

**当前状态形状（slice）：**
```elixir
%{
  identity: %{caps: MapSet.t(Capability.t())},
  user_credentials: %{...counter state...},
  user_tokens: %{...counter state...}
}
```

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.User do
  defstruct [
    :uri,            # 规范化 URI 字符串 — 也是 aggregate ID
    :workspace_uri,
    :registered_at,
    :password_hash,  # mirror users.password_hash 列
    caps: MapSet.new(),
    tokens: %{},     # token_id → %{minted_at, expires_at, scope, ...}
    destroyed?: false
  ]
  ...
end
```

**命令：**
- `%RegisterUser{uri, workspace_uri, password_hash, initial_caps}` → 发 `%UserRegistered{}`
- `%GrantCapToUser{uri, cap, granted_by}` → 发 `%CapGrantedToUser{}`（或若 granter 缺 data-owner cap，返 `{:error, :grant_not_owner}`）
- `%RevokeCapFromUser{uri, cap, revoked_by}` → 发 `%CapRevokedFromUser{}`
- `%MintTokenForUser{uri, token_id, scope, expires_at}` → 发 `%TokenMintedForUser{}`
- `%RevokeTokenForUser{uri, token_id}` → 发 `%TokenRevokedForUser{}`
- `%RotatePasswordForUser{uri, new_password_hash}` → 发 `%PasswordRotatedForUser{}`
- `%DestroyUser{uri}` → 发 `%UserDestroyRequested{}`（触发 `DestroyUserSaga` 级联）

**事件** — 每个命令一个；payload 是命令减去路由 UUID。

**投影：**
- `user_caps_projection` — Ecto 表 `projections.user_caps(uri, cap_json, granted_by, granted_at)`。由 `Behavior.Identity` 查询和 `/admin/users` LV 读。`consistency: :strong` 对要 LV read-after-write 的 cap-grant 派发。
- `user_profile_projection` — Ecto 表 `projections.user_profile(uri, workspace_uri, registered_at, destroyed?)`。由用户列表 LV 读。
- `user_tokens_projection` — Ecto 表 `projections.user_tokens(uri, token_id, scope, minted_at, expires_at, revoked_at)`。由 `entity_tokens` 查询读（替代现有 `entity_tokens` SQLite 表）。

**持久化：** 每 50 事件一次 snapshot。User aggregate 事件量低（每次 cap 授予 + 每次 token mint 一个事件）；50 事件对活跃用户 ≈ 数周活动。

#### 4.2.2 `Ezagent.Entity.Agent` → `Ezagent.Aggregate.Agent`

**当前状态（slice）：** 复杂 — flavor 特定状态 + lineage parent_uri + api_keys + workspace_uri + per-template fork 状态。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Agent do
  defstruct [
    :uri,
    :workspace_uri,
    :flavor,           # :cc | :codex | :curl | :np | :echo | ...
    :parent_template_uri,
    :lineage_parent_uri,
    :config_dir,
    :api_keys,         # 加密 map；api_keys behavior 的 slice
    caps: MapSet.new(),
    flavor_state: %{},  # per-flavor 子状态，对非-flavor 代码不透明
    sessions: MapSet.new(),  # 该 agent 加入的 session URI
    destroyed?: false
  ]
end
```

**命令** — 拆分 flavor-agnostic 核心 + per-flavor 扩展：

核心：
- `%CreateAgent{uri, workspace_uri, flavor, parent_template_uri, lineage_parent_uri, initial_caps, config_dir}` → 发 `%AgentCreated{}`
- `%GrantCapToAgent{uri, cap, granted_by}` → 发 `%CapGrantedToAgent{}`
- `%RevokeCapFromAgent{uri, cap, revoked_by}` → 发 `%CapRevokedFromAgent{}`
- `%PutApiKeyForAgent{uri, key_name, encrypted_key}` → 发 `%ApiKeyPutForAgent{}`
- `%JoinSessionAsAgent{uri, session_uri}` → 发 `%AgentJoinedSession{}`
- `%LeaveSessionAsAgent{uri, session_uri}` → 发 `%AgentLeftSession{}`
- `%DestroyAgent{uri}` → 发 `%AgentDestroyRequested{}`（触发 `DestroyAgentSaga`）

Per-flavor（cc、codex 等）：
- 每 flavor 暴露 `%FlavorSpecific{...}` 命令 variant；aggregate `execute/2` 派发到 flavor 逻辑 + 发 flavor 特定事件。flavor 的 `apply/2` 子句不透明地变更 `flavor_state`。

**投影：**
- `agent_profile_projection` — 列表 LV。
- `agent_caps_projection` — cap 查询。
- `agent_lineage_projection` — 替代 `Ezagent.AgentLineage` registry（父子关系）。

#### 4.2.3 `Ezagent.Entity.Session` → `Ezagent.Aggregate.Session`

**当前状态：** 代码库里复杂度最高 — Chat slice + Publisher slice + ExternalMirror slice；members；rules；routing。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Session do
  defstruct [
    :uri,
    :workspace_uri,
    :template_uri,
    :owner_uri,
    members: MapSet.new(),         # 成员 URI（users + agents）
    messages_count: 0,             # 背压度量；完整历史在事件流
    publisher_subscribers: %{},    # 订阅者 pid → cursor
    external_mirror_bindings: [],  # 绑到该 session 的 worker
    template_working_copy: nil,
    destroyed?: false
  ]
end
```

**命令** — 多；按命令数最大的 aggregate。

核心生命周期：
- `%CreateSession{uri, template_uri, owner_uri, workspace_uri}` → 发 `%SessionCreated{}`
- `%DestroySession{uri}` → 发 `%SessionDestroyRequested{}`（触发 `DestroySessionSaga`）

成员（`Behavior.Chat` actions）：
- `%JoinSession{uri, joiner_uri}` → 发 `%MemberJoinedSession{}`
- `%LeaveSession{uri, leaver_uri}` → 发 `%MemberLeftSession{}`
- `%TransferSessionOwnership{uri, new_owner_uri}` → 发 `%SessionOwnershipTransferred{}`

消息：
- `%PostMessageToSession{uri, message}` → 发 `%MessagePosted{}`（也触发投影侧扇出）

Publisher（`Behavior.Publisher.SessionImpl`）：
- `%SubscribeToSessionPublisher{uri, subscriber_pid, cursor}` → 发 `%PublisherSubscriberAdded{}`
- `%UnsubscribeFromSessionPublisher{uri, subscriber_pid}` → 发 `%PublisherSubscriberRemoved{}`
- （注：事件中 PID 是味道 — 见 §11 q#5。也许订阅者在 aggregate 外跟踪。）

External mirror（`Behavior.ExternalMirror`）：
- `%BindExternalMirror{uri, binding_descriptor}` → 发 `%ExternalMirrorBound{}`
- `%UnbindExternalMirror{uri, binding_id}` → 发 `%ExternalMirrorUnbound{}`

**投影** — 多：
- `session_profile_projection` — 列表 LV 用的基础 session 状态。
- `session_messages_projection` — 替代当前 `messages` SQLite 表。每个 `MessagePosted` 事件 → 插一行。
- `session_members_projection` — `(session_uri, member_uri, joined_at, left_at)` 给成员查询。
- `external_mirror_bindings_projection` — 替代当前 `external_mirror_bindings` SQLite 表。

#### 4.2.4 `Ezagent.Workspace` → `Ezagent.Aggregate.Workspace`

**当前状态：** 小 — workspace 元数据 + 拥有关系。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Workspace do
  defstruct [
    :uri,
    :name,
    :created_by,
    :created_at,
    members: MapSet.new(),
    destroyed?: false
  ]
end
```

**命令：**
- `%CreateWorkspace{uri, name, created_by}` → 发 `%WorkspaceCreated{}`
- `%AddMemberToWorkspace{uri, member_uri}` → 发 `%MemberAddedToWorkspace{}`
- `%RemoveMemberFromWorkspace{uri, member_uri}` → 发 `%MemberRemovedFromWorkspace{}`
- `%DestroyWorkspace{uri}` → 发 `%WorkspaceDestroyRequested{}`（触发 `DestroyWorkspaceSaga` — 级联销毁该 workspace 所有 session/agent/user；昂贵）

**投影：**
- `workspaces_projection` — picker LV。替代当前 `workspaces` SQLite 表。
- `workspace_members_projection` — 给 cap-vis SPEC 的 `list_workspaces_for/2`。Cap-based 可见性变成对该表 + cap 投影的 JOIN。

#### 4.2.5 `Ezagent.ExternalMirror.Worker` → `Ezagent.Aggregate.ExternalMirrorWorker`

**当前状态：** binding 特定的 worker 状态。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.ExternalMirrorWorker do
  defstruct [
    :uri,
    :session_uri,
    :workspace_uri,
    :binding_descriptor,
    :cursor,                # publisher cursor
    :adapter_state,         # per-adapter 内部状态
    destroyed?: false
  ]
end
```

**命令：**
- `%SpawnWorker{uri, session_uri, binding_descriptor}` → 发 `%WorkerSpawned{}`（触发 `BootstrapWorkerSaga`）
- `%AdvanceWorkerCursor{uri, new_cursor}` → 发 `%WorkerCursorAdvanced{}`
- `%TerminateWorker{uri}` → 发 `%WorkerTerminated{}`

**投影：**
- `external_mirror_workers_projection` — live worker 状态 + last-cursor。

### 4.3 11 个 Behavior 模块 — 去向

| Behavior | 去向 | 备注 |
|---|---|---|
| `Behavior.Identity` | 拆为 per-aggregate 的 cap-handling 命令 | Cap grant/revoke 命令落到相关 aggregate（User/Agent）；Behavior 模块变成命令的命名空间 + CapBAC 注册用的 cap_subjects/0 回调。data_owner/1 保留（驱动 saga 补偿路径）。 |
| `Behavior.Chat` | Session aggregate 命令 + 投影器 | 所有 action 变 Session 命令；Behavior 模块变命名空间 + cap_subjects + 消息投影更新逻辑。 |
| `Behavior.Publisher` + `Behavior.Publisher.SessionImpl` | Session aggregate 命令；订阅者跟踪移到投影侧 | 见 §11 q#5 — 事件里 PID 是味道；订阅者跟踪是运行时关心、不是事件溯源关心。 |
| `Behavior.ExternalMirror` | Session aggregate 命令 + Worker aggregate 命令 | Binding 作为 Session 事件持久化；worker spawn 是 saga（BootstrapWorkerSaga 订阅 BindingCreated 派发 SpawnWorker）。 |
| `Behavior.IdentityAdmin` | Workspace aggregate 命令 + admin-shortcut helper 模块 | admin-cap-bypass 逻辑住派发前 authz 流水线；命令本身落到 Workspace aggregate。 |
| `Behavior.UserCredentials` | User aggregate 命令 | 改密是 User 命令。`users.password_hash` 列变投影。 |
| `Behavior.UserTokens` | User aggregate 命令 | Token mint/revoke 是 User 命令。`entity_tokens` 表变投影。 |
| `Behavior.WorkspaceUserAdmin` | Workspace aggregate 命令 | workspace admin 创建用户 → Workspace 上的 `AddUserToWorkspace` + User 上的 `RegisterUser`。两命令序列打包在 saga（`CreateUserInWorkspaceSaga`）。 |
| `Behavior.Presence` | 保留 slice（**不**迁移） | Presence 是实时运行态、不是耐久历史。保留为非-Aggregate 的 `Ezagent.Presence` GenServer（或原生迁 `Phoenix.Presence`）。§11 q#7。 |
| `Behavior.Sandbox` | 保留运行时 only | 测试 fixture 专用；不是生产状态模型一部分。 |
| `Behavior.Routing` | 路由是 workspace 范围规则，存为 Workspace aggregate 状态 | Workspace 命令 `AddRoutingRule` / `RemoveRoutingRule` + 对应事件。 |
| `Behavior.Notifications` | 订阅相关事件 + 发通知的事件 handler | 见 §11 q#5 — 通知发射是副作用 handler、不是状态变更。`Commanded.Event.Handler` impl。 |
| `Behavior.Lifecycle` | 由 aggregate 创建/销毁命令吸收 | Lifecycle 作为 Behavior 迁移后消失；每个 Kind 的 create/destroy 命令替代它。 |

### 4.4 跨-Kind 工作流 — saga 清单

迁移后取代 ad-hoc 跨-Kind 编排的 saga：

| Saga | 触发于 | 级联 |
|---|---|---|
| `DestroyAgentSaga` | `AgentDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents → DropAllSessionMembershipsFor → UnlinkLineage → TerminateAgent |
| `DestroyUserSaga` | `UserDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents（用户为父）→ DropAllSessionMembershipsFor → TerminateUser |
| `DestroySessionSaga` | `SessionDestroyRequested` | EvictAllMembers → UnbindAllExternalMirrors → DestroyAllChildAgents → TerminateSession |
| `DestroyWorkspaceSaga` | `WorkspaceDestroyRequested` | DestroyAllSessions → DestroyAllAgents → DestroyAllUsers → TerminateWorkspace（昂贵 — 需要显式确认 + admin caps；复用每个子的销毁 saga） |
| `CreateSessionSaga` | `SessionCreated` | GrantOwnerOrchestratorAdminCap（URI canonicalization SPEC 的 bug 2 路径）→ InvokeTemplateClassInitHooks → AnnounceSessionReady |
| `CreateUserInWorkspaceSaga` | `WorkspaceAdminRequestedUserCreate` | RegisterUser → GrantDefaultCaps → AddUserToWorkspaceMembers → MintInitialToken（可选） |
| `BootstrapWorkerSaga` | `BindingCreated` | SpawnWorker → SubscribeToSessionPublisher → AnnounceWorkerReady |
| `RevokeCapCascadeSaga` | `WorkspaceMembershipRevoked` | RevokeAllWorkspaceScopedCapsFor（被取消 workspace 成员资格的 principal 失去该 workspace 范围所有 caps） |
| `CapGrantOwnershipVerifySaga` | `CapGrantRequested` | VerifyGranterHasDataOwnerCap（命令时读 granter 的 cap 投影）→ 派发实际 grant 或以 `:grant_not_owner` 拒绝 |

每个 saga ~50-150 行 + per-step 命令/事件 variant。Saga LOC 总计 ≈ 1500-2000 LOC。替代当前 domain 模块中 ~3000 LOC 的 ad-hoc 跨-Kind 编排。

### 4.5 派发前流水线 — 步骤 5.5 + 5.6 + 幂等性的新家

当前派发把步骤 5.5（CapBAC）+ 5.6（workspace 隔离）走 `Kind.Runtime.handle_dispatch/4`、在 Kind GenServer `handle_call` 内。迁移后这些检查在 `Commanded.Application.dispatch/2` **之前** — 在派发前流水线模块。

```elixir
defmodule Ezagent.CommandedApp.Dispatch do
  alias Ezagent.CommandedApp

  @spec dispatch(cmd :: struct(), opts :: keyword()) ::
    :ok | {:error, term()}
  def dispatch(cmd, opts \\ []) do
    with :ok <- Ezagent.URI.canonicalize_cmd(cmd),         # 步骤 1 — 规范化 cmd 中 URI
         :ok <- check_idempotency(cmd, opts),              # 步骤 1.5 — 幂等 key 检查
         :ok <- check_capbac(cmd, opts),                   # 步骤 5.5 — CapBAC chokepoint
         :ok <- check_workspace_isolation(cmd, opts),      # 步骤 5.6 — 跨 workspace 否决
         :ok <- CommandedApp.dispatch(cmd, opts) do        # 步骤 6+ — Commanded 内部
      :ok
    end
  end

  defp check_capbac(cmd, opts) do
    caller = Keyword.fetch!(opts, :caller)
    caps = Keyword.fetch!(opts, :caps)
    needed = Ezagent.CapabilityRegistry.cap_for_command(cmd.__struct__)
    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp check_workspace_isolation(cmd, opts) do
    caller_workspace = Keyword.fetch!(opts, :caller_workspace)
    target_workspace = cmd.workspace_uri  # 每个 cmd 携带 workspace_uri
    if caller_workspace == target_workspace or admin?(opts),
      do: :ok,
      else: {:error, :cross_workspace_denied}
  end

  ...
end
```

每个外部入口（LV、Channel、CLI、MCP）调 `Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts)`。派发前流水线是新 chokepoint — 等价于今天的步骤 5.5 + 5.6。

`Ezagent.CommandedApp.dispatch/2`（裸 Commanded application）对该模块**私有**；外部无直接调用。不变式测试：对 `Ezagent.CommandedApp.dispatch` 在 `Ezagent.CommandedApp.Dispatch` 之外的 grep 为空（镜像当前的 `single_dispatch_entry_test.exs`）。

### 4.6 Aggregate ID 派生 — URI 规范化对等

per `feedback_register_lookup_key_parity` + `feedback_uuid_is_canonical_identifier`：

- 每个命令**必须**携带规范化 URI 字符串，字段名 `:uri`（或对应变体如 `:agent_uri`、`:session_uri`）。
- Router `identify` 子句用这字段：
  ```elixir
  identify(Ezagent.Aggregate.User, by: :uri, prefix: "")
  ```
- 规范形式是 `Ezagent.URI.parse!(...) |> URI.to_string()` — 与 URI 规范化 SPEC 相同。
- 派发前流水线在派发前规范化 URI 字段。
- 跨 aggregate 引用（如 Session 命令引用 Agent URI）以规范字符串携带两个 URI。

Aggregate ID 对 aggregate 不透明（它是路由 key、不是状态）；aggregate 状态里的 URI 是同一个规范字符串。单一真值；路由与状态无分歧。

### 4.7 审计日志 — 什么是领域事件 vs telemetry

今天混在一个 `invocations` 表里的两个不同概念，迁移后**分开**：

**领域事件（在事件流）：**
- `UserRegistered`、`CapGrantedToUser`、`MessagePosted`、`SessionCreated`、`MemberJoinedSession`、`WorkerSpawned`、... — 每个状态变更事件。
- 完整 payload 持久化于事件存储；通过投影可查（`audit_events_projection`）。
- 事件流即审计日志；无独立 audit writer。

**纯 telemetry 事件（留在 SQLite `audit` 表）：**
- `[:ezagent, :authz, :denied]` — 派发被拒；无状态变更；不是领域事件。
- `[:ezagent, :persistence, :failed]` — 基础设施级失败；不是 aggregate 历史。
- `[:ezagent, :cc_bridge, :event]` — 桥侧通道；非状态变更。
- `[:ezagent, :chat, :receive, :dropped]` — 运行时 drop；非状态变更。
- `[:ezagent, :notification, :emit]` — 副作用发射记录；对源 aggregate 非状态变更。

**审计查询模式：**
- "用户 X 在 A 到 B 时间里做了什么" → 在事件流中查 `metadata.caller == "X"` AND `created_at BETWEEN A AND B` 的事件。或经 Postgres event store SQL、或经 `audit_events_projection`（反规范化的读模型加速查询）。
- "为什么这次派发被拒" → 在 SQLite `audit` 表查 `[:ezagent, :authz, :denied]` 行（这**不**在事件流，因为领域没发生事情）。
- "用户 X 当前 cap 集" → 查 `user_caps_projection`。
- "用户 X 的 cap-grant 历史" → 在事件流查 `CapGrantedToUser` / `CapRevokedFromUser` 事件，按 `metadata.target == "X"` 过滤。

此分法保持领域事件纯净（只状态变更事实；无 telemetry 噪声）、同时保留 telemetry 给运维 + 调试。

---

### 4.8 LV / Channel / CLI 写后立即重读一致性矩阵（r2 — HIGH-3 fix）

Codex r1 HIGH-3：r1 只说 "per 派发点 opt 到 :strong"、不枚举 site。默认 `:eventual` 在任何写后立即重读 state 的 callsite 都不安全。

**静态枚举的写→读 site 必须用 `consistency: :strong`**（或具名投影器一致性列表）：

| Callsite | 文件:行 | 写 | 立即重读 | 要求模式 |
|---|---|---|---|---|
| 建用户 | `users_live.ex:137` | RegisterUser | `list_users()` | `:strong`（或 `[UserProfileProjector]`） |
| 加 workspace 成员 | `workspace_detail_live.ex:165` | AddMemberToWorkspace | `Workspace.Store.get_by_name/1` | `:strong` |
| 授予 cap | `entity_caps_live.ex:142` | GrantCapToUser/GrantCapToAgent | reload caps | `:strong`（或 `[UserCapsProjector, AgentCapsProjector]`） |
| 加 routing rule | `routing_live.ex:235` | AddRoutingRule | reload rules | `:strong` |
| 建 session（向导） | `home_live.ex` 向导提交 | CreateSession | redirect→/sessions/X mount | `:strong` |
| 铸用户 token（CLI） | `ezagent.user.token.ex:75` | MintTokenForUser | 打印 token 行 | `:strong` |
| 建 agent（CLI + LV） | `agents_live.ex`、`mix ezagent.agent.create` | CreateAgent | reload agent | `:strong` |
| 置 api_key（LV） | agent api_keys LV — TBD | PutApiKeyForAgent | reload keys 列表 | `:strong` |
| 绑外部 mirror | feishu bind LV/CLI | BindExternalMirror | reload bindings | `:strong` |
| Workspace 建 | `workspaces_live.ex` | CreateWorkspace | redirect→detail | `:strong` |
| Profile upsert | `users_live.ex:177` | UpsertProfile | reload user | `:strong` |
| 发 chat 消息 | LV / Channel chat send | PostMessageToSession | （无重读；fanout 经 PubSub） | `:eventual`（可接受 — 异步 UI 更新） |

**Phase 10-B/10-C 不变式测试：** `Ezagent.Invariants.ConsistencyMatrixTest` 走枚举 callsite、解析 AST、断言 dispatch 调用用 `consistency: :strong`（或具名投影器列表）。CI grep 门拒绝任何枚举派发路径显式用 `consistency: :eventual`。

**未来 callsite：** 任何新的写→立即读模式**必须**在 SPEC 时加入此矩阵 + 不变式更新。矩阵是纪律；不变式是门。

---

## 5. Read Model 策略

### 5.1 每个逻辑读视图一个投影

每个 LiveView 页面 / API 端点对应一张投影表：

| 投影 | 源事件 | 由谁读 |
|---|---|---|
| `user_profile` | UserRegistered、PasswordRotatedForUser、UserDestroyRequested | `/admin/users`、登录流 |
| `user_caps` | CapGrantedToUser、CapRevokedFromUser | `/admin/caps`、派发 authz |
| `user_tokens` | TokenMintedForUser、TokenRevokedForUser | `entity_tokens` 读、bearer auth |
| `agent_profile` | AgentCreated、AgentDestroyRequested | `/admin/agents`、agent picker |
| `agent_caps` | CapGrantedToAgent、CapRevokedFromAgent | `/admin/caps`、派发 authz |
| `agent_lineage` | AgentCreated（带 parent_uri）、AgentDestroyRequested | lineage 查询 |
| `agent_api_keys` | ApiKeyPutForAgent | 运行时凭证读取（注：投影里也加密；同当前 `agent_api_keys` 表的加密） |
| `session_profile` | SessionCreated、SessionDestroyRequested、SessionOwnershipTransferred | `/sessions`、session picker |
| `session_messages` | MessagePosted | `/sessions/X`、聊天历史（替代 `messages` SQLite 表） |
| `session_members` | MemberJoinedSession、MemberLeftSession | 成员查询、`/sessions/X` |
| `external_mirror_bindings` | ExternalMirrorBound、ExternalMirrorUnbound | bindings reconciler、`/admin/mirrors` |
| `external_mirror_workers` | WorkerSpawned、WorkerCursorAdvanced、WorkerTerminated | worker 状态 |
| `workspaces` | WorkspaceCreated、WorkspaceDestroyRequested | workspace picker、`Workspace.list_*` |
| `workspace_members` | MemberAddedToWorkspace、MemberRemovedFromWorkspace | `list_workspaces_for/2` cap-vis 查询 |
| `audit_events` | （所有领域事件经审计投影器过滤） | `/admin/audit` 可查历史 |

每个投影是一个模块：

```elixir
defmodule Ezagent.Projection.UserCaps do
  use Commanded.Projections.Ecto,
    application: Ezagent.CommandedApp,
    name: "UserCapsProjection",
    consistency: :eventual  # 给 read-after-write 的 LV opt 到 :strong

  project %CapGrantedToUser{} = event, fn multi ->
    Ecto.Multi.insert(multi, :cap, %Ezagent.Projection.UserCap{
      user_uri: event.user_uri,
      cap_json: Jason.encode!(event.cap),
      granted_by: event.granted_by,
      granted_at: event.granted_at
    })
  end

  project %CapRevokedFromUser{} = event, fn multi ->
    Ecto.Multi.delete_all(multi,
      :cap,
      from(c in Ezagent.Projection.UserCap,
        where: c.user_uri == ^event.user_uri and c.cap_json == ^Jason.encode!(event.cap))
    )
  end

  def after_update(_event, _metadata, _changes) do
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "ezagent:projections:user_caps", :updated)
    :ok
  end
end
```

### 5.2 投影的 workspace 范围

每个 workspace 范围的投影行带 `workspace_uri` 列（与当前 SQLite 表同惯例）。`Ezagent.Persistence.scope_by_workspace/2` 原样用于投影；现有 workspace 隔离不变式测试指向投影表。

### 5.3 冷加载处理

LV mount 时读投影（同步 DB 查询）。若 LV 是从派发点 redirect 过来，派发用 `consistency: :strong`、投影已追上。

跨 tab 竞速（tab 1 派发，tab 2 在投影追上前 mount 过期 LV）：
- LV mount 用 `Commanded.Subscriptions.wait_for/3`，在该 URI 已知的最新 aggregate version 上等。已知则等。未知则接受 eventual。
- LV 订阅该投影的 PubSub topic；投影器 `after_update/3` 发订阅者；LV re-render。

冷加载防御与 gift-card-demo 相同：订阅 + 更新时重读 + 初次 render best-effort。最坏：≤10ms 过期窗口。

### 5.4 per-投影器的 strong vs eventual

默认：所有投影器 `consistency: :eventual`。Opt 到 `:strong` 只给那些控制派发点立即 redirect 的投影器（如 `user_profile` 给 `/admin/users/create` → redirect 到 `/admin/users/X` 流，需要新用户在 profile 投影里）。

权衡：每个 `:strong` 投影器给每次声明 `:strong` 一致性的派发加延迟。默认 `:eventual` 让热路径快。

---

## 6. 迁移计划 — 分阶段

迁移作为 **Phase 10** 在 IMPLEMENTATION_ROADMAP 中。四个子阶段（10-A 到 10-D），每个由 /goal + per-phase 不变式测试把关。

### 6.0 前向数据迁移 — snapshot import（r2 — CRIT-1 fix）

**Codex r1 CRIT-1：** r1 说迁移 Kind "不迁现有 snapshot；第一条命令创建新鲜事件溯源状态"。这在切换点丢失活的 User/Session/Agent/Workspace state。按 `feedback_destructive_migration_anti_pattern` **不可接受**。

**r2 fix — 每个 Phase 10-A 到 10-C 都在生产派发路由到 aggregate 之前先跑 Step 0（snapshot import）：**

每个 Aggregate 类定义专门的 `%XSnapshotImported{}` 事件 variant。Aggregate 的 `apply/2` 有处理 import 事件的子句、从 snapshot payload 水合 aggregate 状态。事件由 `mix ezagent.aggregate.import --kind <kind>` 任务在 per-Phase 切换前对每个现有 URI 发射**一次**。

**Per-Kind import 事件：**

| Kind | Import 事件 | Payload |
|---|---|---|
| User | `%UserSnapshotImported{}` | 完整 pre-existing slice（identity caps、user_credentials counter、user_tokens counter），加 `users.password_hash`、`entity_profiles.*`、`entity_tokens.*` JOIN 列 |
| Session | `%SessionSnapshotImported{}` | 完整 Chat slice + Publisher slice + ExternalMirror slice + members + ring 状态 |
| Agent | `%AgentSnapshotImported{}` | 完整 per-flavor slice + lineage + api_keys |
| Workspace | `%WorkspaceSnapshotImported{}` | name、members、routing rules |
| ExternalMirrorWorker | `%WorkerSnapshotImported{}` | binding descriptor + cursor 状态 |
| AgentTemplate | `%AgentTemplateSnapshotImported{}` | identity caps + template content |
| SessionTemplate | `%SessionTemplateSnapshotImported{}` | identity caps + template content |

**Import 任务：**

```
mix ezagent.aggregate.import \
  --kind user \
  --batch-size 100 \
  --dry-run    # 默认 — 打印将 import 的内容、退出
```

去掉 `--dry-run` 后：
1. 对 Kind type 匹配的每个 `kind_snapshots` 行，读 `state_binary`。
2. JOIN 补充表（User 是 `users.password_hash`、`entity_profiles.*`、`entity_tokens.*`；Session 不含 `messages` — 见下）。
3. 构 `%XSnapshotImported{}` 事件 payload。
4. 作为 aggregate stream 上第一个事件派发（经 `EventStore.append_to_stream/4`，**不**经 aggregate `execute/2` — 这些不是命令，是构造期 aggregate 接受的直接事件）。
5. 重放 aggregate；`apply/2` 子句水合状态。

**Session 的 `messages` 表处理：** 现有 `messages` SQLite 表含全部历史消息。把每条历史消息作 `%MessagePosted{}` 事件 import 会让事件存储膨胀。**决定：** `%SessionSnapshotImported{}` 事件 payload 只载 `last_message_id` + `recent_messages` ring（耐久 Chat slice 字段）；**完整**消息历史**留**在 SQLite `messages` 表（变只读归档表；投影表 `session_messages_projection` 装切换后的新消息）。查询历史消息时 JOIN 两表、按 `created_at < <切换时间戳>` 过滤。Phase 10-D 把这作为永久形状文档化；`messages` 表**不**删。

**Parity 门（切换准则，per `feedback_completion_requires_invariant_test`）：**

```
mix ezagent.aggregate.verify --kind <kind>
```

读每个 URI 的事件回放 aggregate 状态 + 与原 `kind_snapshots.state_binary` 跨字段比对。断言 §4.2.* 枚举的所有耐久字段相等。任何不匹配 → import 不全；切换被阻塞。

**切换是这个瞬间：** 派发前流水线把目标为 Aggregate 的命令路由到 `Commanded.Application.dispatch/2` 而非 legacy `Invocation.dispatch/1`。所有迁移 URI 的 parity 门绿后切换提交。

**切换前回滚：** 微 — 从 aggregate stream 删事件；aggregate 恢复新鲜。原 `kind_snapshots` 数据不动。

**切换后回滚：** 较难 — 切换后由生产派发写入的事件需经 §12 unwind 路径回放到 slice/snapshot。

### 6.1 Phase 10-A — 依赖 + 骨架 + 先迁 Worker（最小 Kind）

**目标：** 证明集成。一个 Kind 迁移；其余不动。若 10-A 失败，整个迁移中止（恢复 deps + 骨架 + Worker 代码；其它无变化）。

**Deliverables：**
1. 给根 mix 加 deps：`commanded ~> 1.4`、`eventstore ~> 1.4`、`commanded_eventstore_adapter ~> 1.4`、`commanded_ecto_projections ~> 1.3`、`postgrex ~> 0.19`。
2. 新建 umbrella app `apps/ezagent_event_store` — `eventstore` 库的配置（Postgres 后端；dev 用本地 5432 端口 Postgres，test 经 Commanded 内置 test adapter 用 in-memory）。
3. 新建 umbrella app `apps/ezagent_commanded_app` — `Ezagent.CommandedApp` 模块 + router + 派发前流水线（§4.5）。
4. 新建 umbrella app `apps/ezagent_projections` — 投影表（Ecto repo 对接现有 SQLite 做投影存储；事件住 Postgres；不对称是有意的 — 见 §7.3）。
5. 把 `Ezagent.ExternalMirror.Worker` 迁到 `Ezagent.Aggregate.ExternalMirrorWorker`。
   - Worker 是最小 Kind（117 LOC），最隔离（自己的 domain app），内部订阅者有界。
   - 现有 `Ezagent.Entity.ExternalMirrorWorker` Kind 模块**替换** — 不弃用。同 URI 形状；同调用者（本阶段也加 boot-spawn Worker 的 BindingCreated saga）。
6. 实现 `BootstrapWorkerSaga`（替代 boot reconciler 扫描）。
7. 实现 `external_mirror_workers_projection`。
8. 与 Worker 对话的 Phoenix.Channel + LV 走 `Ezagent.CommandedApp.Dispatch`。

**Phase 10-A 不变式测试（门槛，per `feedback_completion_requires_invariant_test`）：**
- `Worker aggregate 状态仅凭事件流即可确定性重建` — 测试拉起 aggregate、派 N 条命令、停 aggregate、重启、断状态相等。
- `BootstrapWorkerSaga 在 BindingCreated 事件后续跑而不重跑 binding` — 测试播 BindingCreated 事件、杀 saga 进程、重播、断无重复 SpawnWorker 派发。
- `Worker → Session 的跨-Kind 调用走事件订阅而非直接 GenServer.call` — 对 Worker 代码 grep；无跨-Kind 读用 `Kind.get_slice/2` 或 `KindRegistry.lookup/1`。

**Phase 10-A unwind（若失败）：**
- 回滚 mix.exs 全部 deps。
- 删三个新 umbrella app。
- 从 git 恢复 `Ezagent.Entity.ExternalMirrorWorker`。
- 无数据迁移；worker 状态本就由 `external_mirror_bindings` 行派生（从未移动）。

### 6.2 Phase 10-B — User + Session

**前置：** Phase 10-A 合并 + 1 周 dev/staging 浸泡。

**目标：** 两个最常用 Kind。User：中（240 LOC）；Session：大（2272 LOC）；都对所有用户面流关键。

**Deliverables：**
- `Ezagent.Aggregate.User` + 命令/事件/投影（§4.2.1）。
- `Ezagent.Aggregate.Session` + 命令/事件/投影（§4.2.3）。
- Saga：`CreateSessionSaga`、`DestroySessionSaga`、`DestroyUserSaga`、`CapGrantOwnershipVerifySaga`。
- 所有 User + Session 调用点迁到新命令-based API。现有 `EzagentDomainChat.create_session/3` 要么变成构造 `%CreateSession{}` + 派发点的薄包装，要么改为直接派发。

**Phase 10-B 不变式测试：**
- User caps 从事件流重建。
- Session 消息从事件流重建。
- `CreateSessionSaga` 确定性完成（无遗漏 GrantOwnerOrchestratorAdminCap 步）。
- `DestroyUserSaga` 在模拟步骤失败下正确补偿（destroy_lifecycle 4 轮失败解决）。

**Phase 10-B unwind：**
- 更复杂。User + Session aggregate 已写事件到生产事件存储。Unwind 需要：
  1. 停派发（新命令走 GenServer-Kind 代码）。
  2. 重放事件流 → 经一次性 `mix ezagent.unwind.user_session` 任务写回 slice/snapshot 表。
  3. 验 slice/snapshot 与投影一致。
  4. 从 git 恢复 GenServer Kind 模块。
- 已文档化 + 可逆；代价是手工重放步骤。

### 6.3 Phase 10-C — Agent + Workspace

**前置：** Phase 10-B 合并 + 2 周浸泡。

**目标：** 剩余 Kind。Agent：大（798 LOC）+ per-flavor variant；Workspace：小但跨切。

**Deliverables：**
- `Ezagent.Aggregate.Agent` + 命令/事件/投影（§4.2.2）。
- `Ezagent.Aggregate.Workspace` + 命令/事件/投影（§4.2.4）。
- Saga：`DestroyAgentSaga`（触发的 SPEC #440）、`DestroyWorkspaceSaga`、`CreateUserInWorkspaceSaga`、`BootstrapWorkerSaga`（重构 — 在 Phase 10-A 但在此用 Workspace 上下文丰富）。
- 所有 per-flavor agent 代码迁移。Flavor Behavior（cc、codex、curl、np、echo）获得 Command + Event 词汇表。

**Phase 10-C 不变式测试：**
- Agent lineage 查询与 aggregate 状态匹配（无投影漂移）。
- `DestroyAgentSaga` 完成 7 步级联或干净补偿。
- `DestroyWorkspaceSaga` 级联所有 child session/agent/user。

### 6.4 Phase 10-D — 弃用 + 清理

**前置：** Phase 10-A 到 10-C 合并 + 1 月浸泡。

**目标：** 删旧代码。

**Deliverables：**
- 删 `Ezagent.Kind.Server`、`Ezagent.Kind.Snapshot`、`Ezagent.KindRegistry`、`Ezagent.SpawnRegistry`、`Ezagent.PendingDelivery`、`Ezagent.ReadyGate`。
- 删 `Ezagent.Invocation`（及其所有调用者）。
- 删 `kind_snapshots` SQLite 表（最后一次给运维记录的 data dump 后）。
- 删领域事件路径的 `Ezagent.Audit.Writer`；telemetry 路径保留。
- 删 `Ezagent.Behavior`（和所有 Behavior 模块）— 由 Command 模块 + per-Aggregate execute 子句取代。
- 更新 `IMPLEMENTATION_ROADMAP.md` §1.1 标 Phase 10 完成 + 新架构基线。
- 更新 `CLAUDE.md` skill `ezagent-developer` 指向新派发/aggregate 模式。

**Phase 10-D 不变式测试：**
- 跨 `apps/` grep `Ezagent.Kind.Server`、`Ezagent.Invocation`、`KindRegistry.lookup` 等为空。
- 所有 LV 从投影读；任何地方无 `Kind.get_slice/2`。

### 6.5 阶段估时

| 阶段 | 估计日历时（1 开发者 + codex 评审） |
|---|---|
| 10-A | 2-3 周 |
| 10-B | 4-5 周 |
| 10-C | 4-5 周 |
| 10-D | 1-2 周 |
| **合计** | **~3 个月** |

粗估 — 假设无重大阻塞、10-A 模式可泛化。Allen 需输入这是否对齐当前优先级（见 §10 OQ-2）。

---

## 7. 性能 + 运维成本分析

### 7.1 热路径派发延迟

| 操作 | 当前延迟 | 新延迟 | 备注 |
|---|---|---|---|
| 对现存 Kind 派 `:cast` | ~1ms（`GenServer.cast` + slice 更新 + `:on_change` SQLite 写） | ~5-50ms（事件追加到 Postgres） | Postgres 事件追加主导；与今天 SQLite `:on_change` 同量级但更慢 per-op（fsync 语义） |
| 对现存 Kind 派 `:call` | ~5ms（`GenServer.call` + slice + 写 + 回复） | ~10-60ms（事件追加 + aggregate apply + 回复） | 类似形状 |
| `consistency: :strong` `:call` | n/a — 当前模型经 GenServer 串行隐式强一致 | ~15-80ms（事件追加 + 强投影器提交 + 回复） | 新「强」模式与当前有效行为相似 |
| 冷 aggregate 重放（重启后） | n/a — Kind GenServer 从最新 snapshot 起 | ~5-50ms（加载 snapshot + 重放 snapshot 后事件） | `snapshot_every: 50` 限重放到 ≤50 事件 |
| LV mount + 初次读 | ~1ms（Kind.get_slice 同步调） | ~1-5ms（Postgres SELECT） | 大致相当；SQLite 本地盘比 Postgres 网络快、但差距 ms 级 |
| LV 更新（投影驱动） | n/a（当前由 Behavior 经 PubSub 推） | ~10-20ms（投影器提交 + PubSub 广播 + LV re-render） | 与当前相似 — 当前也有广播跳 |

**结论：** 事件存储驱动派发在最坏情况下**比当前每次派发慢 5-10 倍**（50ms vs 5ms），但仍在人类感知边界内（<100ms）。对批工作流（CLI）可接受；对实时 UI 无缝。

### 7.2 Aggregate snapshot 频率调参

`snapshot_every: 50` 事件是推荐默认。Per-Aggregate 覆盖：

- **Session** — 高事件量（每消息一个事件）。`snapshot_every: 100` 摊销 snapshot 成本。最坏冷重放 = 100 事件 × 每个 50μs = 5ms。
- **User** — 低事件量。`snapshot_every: 20` 即可；重放成本可忽略。
- **Workspace** — 极低量。`snapshot_every: 10`。
- **Agent** — 中量；`snapshot_every: 50` 默认。
- **Worker** — 中量（每 cursor 推进一个事件）；`snapshot_every: 100`。

这些是起点；上线后按生产 telemetry 调。

### 7.3 Dev 负担 — Postgres 进 dev 循环

当前 dev 循环用 SQLite（零配置）。Postgres 要：
- 本地跑 `postgres`（Docker：`docker run -p 5432:5432 postgres:16`，或 homebrew：`brew install postgresql@16 && brew services start postgresql@16`）。
- 首次 setup 跑 `mix event_store.create` + `mix event_store.init`。
- 给事件存储 schema 额外一个 repo（与现有 SQLite 投影 repo 分开）。

**缓解：**
- **Test 模式用 in-memory adapter** — `Commanded.EventStore.Adapters.InMemory` 进程内跑；`mix test` 无需 Postgres。从 dev 角度 test 环境不变。
- **`docker-compose.dev.yml`** 提供 Postgres + adminer 容器；`mix ezagent.dev.up` 拉起。Onboarding 成本：clone 时一条 Docker 命令。
- **Snapshot 存储也在 Postgres**（Commanded 内置 `snapshotting` 配置）— dev 里无独立 snapshot 基础设施。
- **迁移路径文档化在 CONTRIBUTING.md** — Phase 10-A 后第一次 PR 的开发者读新 setup 指南；现有开发者需要 pull docker-compose 改动。

**承认权衡：** 零配置 dev 体验丢失。需 Allen 输入（§10 OQ-2）。

### 7.4 运维负担 — Postgres 备份、复制、PITR

Postgres 运维普及；工具成熟：
- **备份**：`pg_dump` 全量；WAL 归档给 PITR。
- **复制**：流复制；standby 容错。
- **PITR**：基于 WAL；标准 `recovery.conf`。

对 ezagent 规模（Allen 当前运维模式：每部署单租户），单 Postgres 节点 + 每夜 `pg_dump` + WAL 归档够用。云托管（RDS、Cloud SQL、Supabase）都行。不需新运维技能、只是「我们现在除了 SQLite 还跑 Postgres 做投影 + telemetry」。

**SQLite 保留：**
- 投影（投影 schema 住 SQLite，兼容所有现有读路径）。
- Telemetry 审计（非领域事件 `audit` 表）。
- 应用配置 / 模板 / fixture。

**Postgres 只处理：**
- 事件存储（`eventstore` 库 schema）。
- Aggregate snapshot（Commanded snapshot 存储，与 `eventstore` schema 共享）。

**为什么拆：** SQLite 在低延迟本地读上无敌；Postgres 的事件存储 schema 是唯一非要 Postgres 的库要求。这种拆分让我们对一切不**必须**用 Postgres 的保留 SQLite、只对必须的付 Postgres 代价。不对称、但务实。

### 7.5 磁盘占用

事件存储单调增长（事件追加，永不删）。估：
- 每事件：~200-1000 字节 JSON payload + ~100 字节 metadata。
- ezagent 活跃率：极粗估稳态 ~1000-10,000 事件/天。
- 日增：~1MB-10MB/天；~1GB/年最坏。

事件归档策略：snapshot 让回放无论流多长都快，所以事件不必为了性能删。可归档（移冷存）省成本；多年不必。§11 q#8 处理归档事件上的查询模式。

---

## 8. 迁移风险 + 回滚计划

### 8.1 Per-phase 回滚

每阶段在 §6 有显式 unwind。摘要：

| Phase | 回滚复杂度 | 数据风险 |
|---|---|---|
| 10-A（仅 Worker） | 微 — 恢复代码；无数据迁移 | 无 — Worker 状态本就由 `external_mirror_bindings` 派生，从未移动 |
| 10-B（User + Session） | 中 — 经 `mix` 任务手工事件重放 → slice/snapshot | 低 — 事件在事件存储，可回放到 slice |
| 10-C（Agent + Workspace） | 中 — 同 10-B | 低 — 同 |
| 10-D（清理） | 难 — 旧代码已删；回滚意味着从 git 恢复 + 重跑 10-B/10-C unwind | 中 — 仅在前所有阶段失败时触发 |

### 8.2 混合期异质化风险

在 Phase 10-A 到 10-C，部分 Kind 是 Aggregate、其余仍 GenServer。它们如何交互：

- **Aggregate → GenServer Kind 跨-Kind 调：** Saga 发命令到 GenServer Kind。该命令的「派发」对那个 Kind 走**旧** `Ezagent.Invocation.dispatch/1` 路径。桥：派发前流水线发现命令目标 URI 映射到未迁移 Kind，则走 `Invocation.dispatch/1`。桥模块是 `Ezagent.MigrationBridge.dispatch_to_legacy/2`。
- **GenServer Kind → Aggregate 跨-Kind 调：** `Behavior.invoke/4` 调入迁移 Kind。桥：构造命令并经新流水线派发。在桥模块同样显式。

桥模块是允许混合运行的 SHIM。它有意窄 — 恰好上述两个方向。Phase 10-D 删桥。

§11 q#5 给 codex 评审枚举此点。

### 8.3 实施期间事件 schema 破坏

若 Phase 10-B impl PR 加了一种事件类型而 Phase 10-B v2 需要重命名字段，每个历史事件磁盘上仍是旧形状。`Commanded.Event.Upcaster` 处理：

```elixir
defimpl Commanded.Event.Upcaster, for: MessagePosted do
  def upcast(%MessagePosted{content: c} = ev, _meta) when not is_nil(c) do
    %MessagePosted{ev | body: c, content: nil}
  end
  def upcast(%MessagePosted{} = ev, _meta), do: ev
end
```

模式被 Commanded 良好支持（[hexdocs](https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html)）。每次事件 schema 变更加一个 Upcaster impl；历史事件只读。

### 8.4 生产数据丢失风险

per `feedback_destructive_migration_anti_pattern`：
- **迁移期间对现有 SQLite 表不 DROP / TRUNCATE。** 新代码从事件派生投影读；旧代码从 slice 表读（混合期）。共存。
- **最终清理（Phase 10-D）只在 10-C 后 1 月干净运行后** 才删 `kind_snapshots`。
- **事件存储由构造 append-only** — 没有显式运维动作不会意外删事件。

风险有界：最坏（每阶段失败），数据可从从未截断的 SQLite 表恢复。Phase 10-D 是唯一不可回头点，且由 1 月浸泡把关。

---

## 9. 向后兼容 / 外部 API

### 9.1 保留的面

- Phoenix.Channel topic 名 + 消息形状 — 不变。
- HTTP 端点路径 + JSON 形状 — 不变。
- LiveView URL + Assigns — 从用户视角不变。
- CLI 命令名 + flag 形状 — 不变。
- MCP 工具 schema — 不变。
- `URI` 寻址方案 — 不变。
- Capability struct 形状 — 不变。

### 9.2 变的面

- 插件作者：不再 `@behaviour Ezagent.Kind` + `Ezagent.Behavior` 模块，他们写 `@behaviour Commanded.Aggregates.Aggregate` + Command 模块 + Event 模块 + per-Aggregate execute 子句。`ezagent-developer` skill 在 Phase 10-D 重写。
- Domain context 模块：`EzagentDomainChat.create_session/3` 要么变薄包装（构造 `%CreateSession{}` 并派发），要么删并由 LV / channel 直接派发取代。每 impl PR 决定。
- 审计消费者：对领域事件查 SQLite `invocations` 表的查询在 10-D 后失败 — 那些查询必须迁到 `audit_events_projection`、或经 `EventStore.read_stream_forward/4` 的事件流过滤。Phase 10-B / 10-C 期间分段迁移。

### 9.3 插件兼容

umbrella 外的插件（如未来在独立 git remote 的插件）需把 Kind 定义迁到 Aggregate。per `feedback_north_star_plugin_isolation`，迁移成本有界 — 插件写命令 + 事件 + aggregate；他们**不**碰事件存储、router、或 saga 基础设施（住 `ezagent_commanded_app`）。

现有 SPEC 的 3-tier 规则保留：
- **Tier 1 — core：** `apps/ezagent_core/`、`apps/ezagent_commanded_app/`、`apps/ezagent_event_store/`、`apps/ezagent_projections/`。拥有 Commanded 接线。
- **Tier 2 — domain：** `apps/ezagent_domain_*/`。拥有他们 domain Kind 的 aggregate + 命令 + 事件 + 投影器 + saga。
- **Tier 3 — plugin：** `apps/ezagent_plugin_*/`。拥有 flavor 特定的 aggregate 扩展（per-flavor 命令 + 事件 + Agent aggregate 上的 per-flavor execute 子句）。

插件不能跨到其它插件的 aggregate；走事件 + saga。

---

## 10. 给 Allen 的开放问题

### OQ-1. DB 选择 — Postgres 给事件存储、SQLite 给投影 — 接受？

决定：是（推荐）。备选：
- (a) **全迁 Postgres** — 弃 SQLite。更干净；一个 DB。代价：现有基于 SQLite 的代码（audit、fixture、template）必须迁；扰动更大。
- (b) **除事件存储外都 SQLite** — 当前推荐（§7.4）。不对称但务实。
- (c) **找一个 SQLite 事件存储 adapter** — 无维护版本；要建并维护自定义 `Commanded.EventStore.Adapter` impl。高风险；不推荐。

### OQ-2. 迁移日历 — 3 个月可接受、或要不同分阶段？

需 Allen 输入。分阶段计划保守（每阶段一类 Kind + 1-2 周浸泡）。加速选项：
- (a) Phase 10-B 和 10-C 并行（风险高；两团队；我们没两团队）。
- (b) 跑完 10-A 然后对所有 Kind 直跳 10-D 等价（big bang；按 `feedback_destructive_migration_anti_pattern` 拒）。
- (c) Phase 10-A 到 10-C 期间暂停非迁移特性工作（Allen 拍板）。

### OQ-3. Dev 体验 — Postgres 进 dev 循环、负担可接受？

§7.3 缓解。Allen 决定 daily dev 加 docker-compose 跳是否可接受。

### OQ-4. 多租户 — 事件溯源改变租户隔离关心吗？

当前 per-workspace 隔离不变式（Phase 9 / SPEC v3 §7）前向移植：每个领域事件携带 `workspace_uri`；投影在查询里强制隔离。事件流**本身**默认**不**按 workspace 分区 — 所有 workspace 的所有事件住同一流。这可能是运维关心点（不经 full dump-filter-restore 循环不能把一个 workspace「从事件日志删除」）。

备选：每 workspace 一个事件流。Commanded 自然支持 per-stream 订阅；多流 aggregate 需要小心。§11 q#6。

### OQ-5. 混合期互操作 — 桥模块放哪

Phase 10-A 到 10-C 桥模块 `Ezagent.MigrationBridge`。该住 `apps/ezagent_core/`（Tier 1）还是 `apps/ezagent_commanded_app/`（也是 Tier 1）？大概后者 — 桥是迁移专用脚手架、非永久特性。Allen 同意？

### OQ-6. Saga — 监督在 `Ezagent.CommandedApp` 内还是 sibling supervisor？

Commanded 两者皆支持。app 内更简单（单监督树）；sibling 更隔离。默认推荐：Phase 10-A 走 app 内；saga 数过 ~20 时再考虑。

### OQ-7. Presence — 保留 slice-based 还是迁 `Phoenix.Presence`？

per §4.3，Presence 不迁事件溯源（瞬态运行状态）。两选：
- (a) 当前 `Ezagent.Presence` GenServer + slice 保留。
- (b) 原生迁 `Phoenix.Presence`（更好测；CRDT-backed；集群就绪）。

独立于本 SPEC 决策；此处标记。

### OQ-8. 审计保留 — 何时归档旧事件？

EventStore 单调增长（§7.5）。~1GB/年，归档多年不急。何时要策略？

---

## 11. Codex 对抗评审问题

为 codex r1 预载的攻击向量：

1. **Phoenix + Commanded 集成成熟度 — 有可比规模的生产参考、还是我们在开创？** §3.6 列 Conduit、Gift-card-demo、Segment Challenge、Honeydew、Casavo。无「数千 aggregate 类型」规模的。判定：模式已建立；ezagent 规模落在已有用例。

2. **LV 的 read-after-write 一致性 — 用户派发命令并 LV re-render 时，它会看到更新状态吗？`:strong` 是对答案、还是它阻塞命令返回直到投影追上？** §3.3 解释三模式；推荐默认 `:eventual` + per 派发点 opt-in `:strong`。阻塞正是「向导 → redirect → 详情页」需要的。Codex：验证我们具体的 LV → 派发 → re-render 流都有 opt-in 路径文档化。

3. **Saga 部分失败：销毁级联 7 步；第 4 步失败，Saga 如何补偿？有发表的补偿模式吗？** §3.8 展示带 `error/3` 回调的销毁 saga。Commanded saga 中补偿显式（无自动回滚）；saga 代码**必须**编码补偿。Codex：验证销毁 saga 补偿逻辑完整（第 4 步失败是要回滚 1-3 步、还是只重试第 4 步？— 取决每步幂等性）。

4. **Postgres vs SQLite — ezagent 用 SQLite；能两者都支持、还是必须全迁？** §7.4 + OQ-1：推荐分（Postgres 给事件存储 + snapshot；SQLite 给投影 + audit + 其它）。不对称但可行。Codex：验证不对称不产生跨 DB 查询问题（不应有 — 投影 + 事件存储不共享查询；它们只共享投影更新操作，这是投影自己 SQLite repo 里的 Ecto.Multi）。

5. **异质化迁移 — Phase 10-A 到 10-C 部分 Kind Aggregate、部分 GenServer。混合模式下跨 Kind 工作流怎么走？** §8.2 + `Ezagent.MigrationBridge`。Codex：验证桥模块处理两个方向（Aggregate → GenServer + GenServer → Aggregate）且 Phase 10-D 桥删除时不留遗弃调用者。

6. **事件 schema 演进 — 给现存事件类型加字段、回放老事件。** §8.3 + Commanded `Event.Upcaster` 模式。Codex：验证 Phase 10-B/10-C 每个预期 schema 变更的 Upcaster impl 路径（从销毁 SPEC 至少 5 个已知演进排队）。

7. **性能：带 N 事件 aggregate 的最坏事件流回放时间。热 Aggregate 可能 10K+ 事件。** §7.2 + snapshot_every: 50-100。Codex：验证 50 事件 × 50μs = 2.5ms 冷启动对我们 LV mount 预算可接受（是）。

8. **审计查询：今天 `invocations` 表可 SQL 查。EventStore 下 ad-hoc 审计查询需事件流扫描或投影。定义审计查询模式。** §4.7。Codex：验证 `audit_events_projection` schema 可满足现有 `/admin/audit` LV 过滤谓词（workspace_uri、caller、时间范围、action 类型）。今天若有投影满足不了的查询，记为 Phase 10-B impl-blocker。

---

## 12. 整体中止路径回滚计划

若 Phase 10-A 合并 + 10-B / 10-C 在进行中后，Allen 决定迁移不行：

1. **停新派发。** 在派发前流水线设 feature flag，把所有命令路由经旧 `Ezagent.Invocation.dispatch/1` 路径。新派发停发事件；Aggregate 停收命令。
2. **重放事件回 slice/snapshot。** 对每个迁移完的 Aggregate，`mix ezagent.aggregate.unwind --uri <uri>` 任务读事件流 + 写等价 slice 状态到 `kind_snapshots`。回放确定性（Aggregate 的 `apply/2` **就是**事件到状态的投影）。
3. **验证对等。** `mix ezagent.aggregate.verify` 任务断言：每个迁移 URI 的 slice-snapshot 状态等于事件回放的 Aggregate 状态。若对等失败，unwind 在此中止（数据保留在事件存储 + SQLite snapshot — 运维检查）。
4. **恢复 GenServer Kind 代码。** 从 git：回滚 per-Phase 把 `Ezagent.Entity.X` 换成 `Ezagent.Aggregate.X` 的代码。旧 `Kind.Server` 从（现已回放好的）snapshot 启动。
5. **保留事件存储数据。** 即使中止，事件保留。未来重启迁移可从同一事件存储开始。

Unwind 每 Aggregate 文档化 + 自动化。代价：运维驱动会话（鉴于投影已是反方向形状，估计 5 个 Aggregate 类全 unwind 1-2 小时）。

---

## 附录 A — 事件存储 schema（Postgres）

标准 `eventstore` 库 schema；文档见 https://hexdocs.pm/eventstore/EventStore.html。表：

- `event_store.events` — append-only 事件日志。
- `event_store.streams` — per-stream 元数据（每 Aggregate UUID = 规范 URI 字符串一个流）。
- `event_store.subscriptions` — 投影器 + saga 订阅状态（重放事件位置）。
- `event_store.snapshots` — aggregate snapshot（Commanded 管）。

Phase 10-A 无需自定义 schema；per-投影表住 SQLite 投影 repo（§4 + §5）。

## 附录 B — 示例命令 + 事件 + aggregate execute 子句

```elixir
# 命令
defmodule Ezagent.Aggregate.User.Commands.GrantCapToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :idempotency_key]
end

# 事件
defmodule Ezagent.Aggregate.User.Events.CapGrantedToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :granted_at]
end

# Aggregate execute 子句
defmodule Ezagent.Aggregate.User do
  alias Ezagent.Aggregate.User.Commands.{GrantCapToUser, ...}
  alias Ezagent.Aggregate.User.Events.{CapGrantedToUser, ...}

  @behaviour Commanded.Aggregates.Aggregate

  defstruct [:uri, :workspace_uri, :registered_at, caps: MapSet.new(), destroyed?: false]

  # GrantCapToUser → CapGrantedToUser
  def execute(%__MODULE__{destroyed?: true}, %GrantCapToUser{}),
    do: {:error, :user_destroyed}

  def execute(%__MODULE__{uri: nil}, %GrantCapToUser{}),
    do: {:error, :user_not_registered}

  def execute(%__MODULE__{} = state, %GrantCapToUser{} = cmd) do
    %CapGrantedToUser{
      user_uri: cmd.user_uri,
      workspace_uri: cmd.workspace_uri,
      cap: cmd.cap,
      granted_by: cmd.granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # apply — 状态变更
  def apply(%__MODULE__{} = state, %CapGrantedToUser{} = ev),
    do: %{state | caps: MapSet.put(state.caps, ev.cap)}

  # ... 其它命令/事件/apply 子句 ...
end

# Router 子句
defmodule Ezagent.CommandedApp.Router do
  use Commanded.Commands.Router

  identify(Ezagent.Aggregate.User, by: :user_uri)
  dispatch([
    Ezagent.Aggregate.User.Commands.GrantCapToUser,
    Ezagent.Aggregate.User.Commands.RevokeCapFromUser,
    ...
  ], to: Ezagent.Aggregate.User)
end

# 派发点（如 EzagentDomainIdentity.Users 中）
def grant_cap(user_uri, cap, granted_by, caller_caps) do
  cmd = %GrantCapToUser{
    user_uri: URI.to_string(Ezagent.URI.parse!(user_uri)),
    workspace_uri: Ezagent.URI.entity_workspace_uri_string(user_uri),
    cap: cap,
    granted_by: granted_by,
    idempotency_key: UUID.uuid4()
  }
  Ezagent.CommandedApp.Dispatch.dispatch(cmd,
    caller: granted_by,
    caps: caller_caps,
    consistency: :strong
  )
end
```

## 附录 C — 参考 URL

- Commanded: https://github.com/commanded/commanded · https://hexdocs.pm/commanded
- EventStore (库): https://github.com/commanded/eventstore · https://hexdocs.pm/eventstore
- commanded_eventstore_adapter: https://hex.pm/packages/commanded_eventstore_adapter
- commanded_ecto_projections: https://hex.pm/packages/commanded_ecto_projections · https://hexdocs.pm/commanded_ecto_projections
- Awesome-Elixir-CQRS (项目清单): https://github.com/slashdotdash/awesome-elixir-cqrs
- Conduit 参考 app: https://github.com/slashdotdash/conduit
- Gift-card-demo: https://github.com/slashdotdash/gift-card-demo
- Segment Challenge: https://github.com/slashdotdash/segment-challenge
- Honeydew CELP 起点: https://github.com/quarterpi/honeydew
- Casavo Phoenix LiveView + ES 工具: https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99
- "Phoenix LiveView but event-sourced" (cantido): https://dev.to/cantido/phoenix-liveview-but-event-sourced-7pe
- Christian Alexander Phoenix API + Commanded: https://christianalexander.com/2022/05/09/elixir-commanded/
- ElixirMerge ES/CQRS 指南: https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview
- Commanded process managers / sagas: https://hexdocs.pm/commanded/process-managers.html
- Commanded read-model projections: https://hexdocs.pm/commanded/Read%20Model%20Projections.md
- Commanded event upcasting: https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html
- Saga pattern in Elixir (Peter Ullrich): https://peterullrich.com/saga-pattern-in-elixir
