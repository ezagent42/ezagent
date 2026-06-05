# SPEC — Caps 清理 v1（三件架构纠偏）

**状态:** **r4（revert 后修订）。** 2026-05-25。Issue 1 已实施（PR-CC-1 #345 已合入）。Issue 2 实施被 revert（PR-CC-2a #347 + PR-CC-2b #348 经 #349 撤回）；本 SPEC 原定的 `struct → string` cap 表示切换**已撤销**。Issue 2 的*结构性*目标（声明式 `Behavior.required_caps/0`、`Entity.holds_cap?/2` 边界、dispatch step 5.5 为唯一 cap-check chokepoint）**仍然有效**，将以保留的 `%Ezagent.Capability{}` struct 形态重新实现（通配符通过现有的 `:any` atom 字段值实现）。Issue 3 未启动。完整决策路径见下文 §0d r4 修订说明。

**前述状态:** r3-FINAL（已合入）。2026-05-25。信任模型已接受；MED-1 dedupe 修复已应用；进入实施（PR-CC-1/CC-2/CC-3）。
**层级:** `apps/ezagent_core/` 框架纠偏 + 所有 domain + plugin 的清扫。
**触发:** Allen 2026-05-25 (Feishu) — 在 data-ownership-v2 / external-mirror-audit 工作中暴露的三条逐字指令，针对累积的 cap 系统病灶：

1. "在代码中，完全不应该体现 admin_caps 的特殊性。admin 的特殊性是在验证权限的时候，通过 wildcard 匹配实现的"
2. "caps 的调用应该仅仅在 entity x behavior 的领域中实现。behavior 实现的时候，要求调用的 entity 需要持有某个权限，entity 中提供这个权限的凭证（目前就是简单的字符串）。所有其他的域理论上应该是透明不感知 caps 存在的"
3. "使用宏是必要的吗？还是可以通过其它方式更直接地完成？"（关于编译期强制约束）

**前置（均已合入 `main`，均未被本 SPEC 取代）:**
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 — `Ezagent.CapabilityRegistry` 单入口注册。本 SPEC 在 cap *执行* 上取代它；cap *主体目录* 的用途坍缩到 Behavior callback 中。
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` rev 3 — `data_owner/1` callback + "cap 是某类数据 CRUD 授权，且只有唯一合法授权者" 原则。本 SPEC 保留数据所有权原则与 `data_owner/1` callback；只改变 cap 的 *表示* 与 *校验* 方式。
- `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` r1 — 4 门强制 + FacadeNonceTable 防伪造。本 SPEC 保留 FacadeNonceTable；它与 cap 表示正交。
- `apps/ezagent_core/lib/ezagent/capability.ex` — 本 SPEC 简化的 6 字段 struct。
- `apps/ezagent_core/lib/ezagent/capability/parser.ex` — 本 SPEC 将其从 "operator CLI 输入" 提升为 "canonical 线格式" 的现有字符串语法。
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — 本 SPEC 扩展的现有编译期 gate。

**前置 memory（重要）:**
- `feedback_let_it_crash_no_workarounds`（Allen 2026-05-05）— 本 SPEC 中每个 "删除" 都是硬删除。无 `User.admin_caps()` 弃用期。无 "若是 struct，则在边界转字符串" 的垫片。旧调用点在编译期 raise。
- `feedback_completion_requires_invariant_test`（Allen 2026-05-05）— 三个 issue 每个都有一个 invariant test，当架构目标未达成时该测试失败（§9）。
- `feedback_north_star_plugin_isolation`（Allen 2026-05-05）— 设计抉择的最终裁决是 "把 plugin 作者挡在 core 之外"。Issue 2 是该原则的直接应用。
- `feedback_uuid_is_canonical_identifier`（Allen 2026-05-12）— cap 字符串命名 *权限类型*，而非用户名。身份绑定由 instance URI 完成。
- `feedback_bilingual_docs_convention` — 中文镜像在 `.zh_cn.md`。

**配套:** `2026-05-25-caps-cleanup-v1.md`（英文）。

---

## 0d. r4 修订说明（revert 之后；struct 保留）

> 🔄 **本 SPEC 在实施之后被修订。** PR-CC-2a + PR-CC-2b 按原设计落地了 string-cap 表示切换，随后于 Allen 2026-05-25 13:18 指令下通过 PR #349 回退。下文 SPEC 主体（§5、§6、§7、§8、§9）仍描述**已撤销的 string-cap 设计**作为历史记录。**现行设计**在本 §0d 中总结。未来 PR 必须以 §0d 为准，而非以 §5–§9 的字面文本为准。

### r4.1 哪些回退、哪些保留

| PR | 状态 | 说明 |
|---|---|---|
| PR-CC-1 #345（Issue 1 — 删 ambient authority） | ✅ 已合入，保留 — **但 catalog cap-shape 缺口见 §0d.1b** | `User.admin_caps/0` 已删；`Ezagent.SystemPrincipal.Catalog`（14 个 system principal）就位；16 个调用点已迁移。Catalog 的 cap-string 值是在 r1–r3 string 假设下写的；struct-kept r4 里那些 string 当前被 `SystemPrincipal.caps/1` 渲染成通配 `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}`，而非 catalog 表格命名的逐 principal 收窄声明。Named-principal 审计 trail 工作；least-privilege **不**工作。PR-CC-2-v2 必须把每个 catalog 条目转成精确的 `%Capability{}` spec — 见 §0d.1b 阻断 gate。 |
| PR-CC-2a #347（additive primitives：`Ezagent.Cap` matcher + `Behavior.required_caps/0` + `Kind.holds_cap?/2`） | ❌ 经 #349 回退 | `Cap` 模块 + 19 个 Behavior 注解 + 109 个新测试全部删除。 |
| PR-CC-2b #348（dispatch flip + boot seed system principals + dual-path） | ❌ 经 #349 回退 | Dual-path step 5.5 + wildcard substitution + 14 boot seeds + `workspace_scoped?/0` enforcement 全部撤销。Boot-seeding *意图*在 §0d.5 保留，但使用现存 struct-cap 形态。 |
| PR-CC-1 `SystemPrincipal.caps/1`（legacy-shape 桥） | ✅ 仍在，现为永久 | 该桥返回 `[%Capability{}]`；r4 使其成为永久 API。不再是 "legacy" 或 "transitional"——它就是 API。可以择机改名。 |
| `Ezagent.Capability` struct（6 字段） | ✅ 保留在 `apps/ezagent_core/lib/ezagent/capability.ex` | 通配符通过 `:any` atom 在 `kind` / `behavior` / `instance` / `workspace_uri` 字段上已支持。未来密码学字段（signature, nonce, issued_at）以 additive 方式扩展 struct。 |
| `Ezagent.CapabilityRegistry` ETS | ✅ 保留 | Single-entry registration 纪律 + `cap_subjects/0` callback 均保留。Single-Path 原则（cap subject 声明的唯一 chokepoint）不变。 |
| `Identity.list_caps_for/1` / `grant_cap/3` / `revoke_cap/3` | ✅ 保留，struct 形态 | API + 调用者签名保持；r4 forward 工作直接使用。 |
| `caps_json` DB 列 | ✅ struct JSON，未迁移 | SPEC §5.8 的 `caps_schema_version v1→v2` 迁移**已撤销**。现有行保持 `[%Capability{...}]` JSON 形态。 |
| `ctx.caps` 字段 | ✅ 保留 | `Invocation` struct 保留其 `caps :: [%Capability{}]` 字段。SPEC §5.3 r2 HIGH-3 "delete ctx.caps" 决定**已撤销**——`ctx.caps` 是 dispatch / action body 用于子 cap 决策的快照，那个触发删除的 snapshot-staleness 病灶通过 §5.3 step 8.5 的 revision-CAS（r3-FINAL 设计）解决更好，而不是删除。 |

### r4.1b SystemPrincipal.Catalog cap-shape 缺口（PR-CC-2-v2 阻断 gate）

PR-CC-1 的 `Ezagent.SystemPrincipal.Catalog`（`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`）声明了 14 个 principal 的 **string 值 cap 条目**，比如 `["session.external_mirror.*"]`、`["session.chat.send", "session.chat.system_message"]` 等——是在本 SPEC §4.1 仍假设 string cap 为清理后线格式的时候写的。

r4 revert 保留 struct cap 之后，`SystemPrincipal.caps/1` 桥**不**把那些 string parse 成逐 cap 的 `%Capability{}` spec。检查 `system_principal.ex` 大约 138/151/174 行：每个非空 string list 坍缩成单个通配 cap `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any, granted_by: principal_uri, granted_at: now}`。这跟被删的 `User.admin_caps/0` 是同样的权限形态——比 catalog 表格中收窄的 string 声明更宽。

**今天什么工作：**
- Named-principal 审计 trail（`ctx.caller = system://boot-reconciler` 等）正确。`/admin/audit` 显示真实操作 principal。
- Catalog 成员强制（`SystemPrincipal.ensure/2` 拒绝表中没有的 URI）工作。

**今天什么不工作：**
- Least-privilege。`system://chat-router`（声明为 `["session.chat.send", "session.chat.system_message"]`）当前持有完全通配权限，跟 bootstrap admin 一样。`Behavior.Chat` 系统消息 dispatch 路径的 bug 可能通过 chat-router principal 写入任意 session。

**PR-CC-2-v2 验收 gate (c')：**
PR-CC-2-v2 必须把每个 catalog 条目转成等价的 `%Capability{}` 列表。Catalog 表值类型从 `[String.t()]` 变 `[%Capability{}]`。转换是机械的（按 §5.4 文法 atom 映射 parse 每个现有 string → struct 字段），`:behavior` 解出的 atom 从 catalog 的 "Operating context" 列推导。PR-CC-2-v2 加 invariant test：每个 principal 的 caps 列表无 `%Capability{kind: :any, behavior: :any, instance: :any}` 条目，除非 principal 是 `system://bootstrap`（唯一合法通配）。

PR-CC-2-v2 落地前，system principals 跑的权限比文档化的更宽。按 `feedback_let_it_crash_no_workarounds` + SPEC §10.5 in-VM 信任模型（in-VM 可信；带 bug 的 Behavior 通过过宽 system principal 写入受部署卫生约束），这是**可接受的 v1 限制**，但**不是**post-v1 可接受的——上述 gate 阻断。

### r4.2 为什么 revert string（Allen 2026-05-25 13:18）

> 仔细思考，我觉得应该 revert 回 struct，因为未来我们不可能简单的使用 string 匹配的形式，必然要通过 token 验证等密码学方式来确保 caps 的有效性，到时候，还是要转回 struct

未来的 cap 验证模型将使用密码学签名（caller 提交 token；系统对照已发 cap 验证签名）——这需要带元数据字段（signature, nonce, issued_at, granted_by）的结构化 cap。现在迁到 string，未来再迁回 struct + signature 是一次浪费的往返。从一开始就保留 struct，在 token 验证工作落地时 additive 增加密码学字段更省。

这个 forward-looking 关切在 r1–r3 **没有被代表**。r1–r3 优化的是 plugin 作者 UX（`%{send: "session.chat.send"}` 比构造 struct 短）和 IAM/RBAC 工业标准对齐，两者仍然成立——但都比不过 token 验证临近时的往返成本。

### r4.3 Issue 2 结构性目标（G2）哪些幸存

原 G2 outcome 仍然适用：

> **G2 — Caps 只活在 Behavior × Entity 边界。** `Behavior.required_caps/0` 按 action 声明 [caps]。`Entity.holds_cap?/2` 决定成员。`Invocation.dispatch/1` step 5.5 同时调用两者。其它所有模块对 cap 透明。

唯一改变：`[caps]` 类型是 `%{required(atom()) => %Capability{}}`（struct 值），不是 `%{required(atom()) => String.t()}`。G2 的所有其它方面——Behavior 边界的声明式 cap、dispatch step 5.5 的唯一 chokepoint、`_live` 模块 / plugin facade / 手写 predicate 中没有散落的 cap-check——**仍然是值得追求的目标**。string vs struct 是实现选择，不是架构目标本身。

具体地，未来的 Issue-2 PR（PR-CC-2-v2）用 struct 形态 callback 重新实现边界清理：

- `Behavior.required_caps/0 :: %{required(atom()) => %Capability{}}` —— 按 action 的声明式 struct map。通配符通过 `:any` atom 字段（例如 `%Capability{kind: :chat, behavior: Chat, action: :send, instance: :any, workspace_uri: :any, granted_by: ..., granted_at: ...}` 表 "任意 chat session、任意 workspace"）。
- `Entity.holds_cap?/2 :: (URI.t() | atom(), %Capability{}) :: boolean()` —— default 实现读 entity 的 `:identity` slice 的 `caps` 字段，通过 `Capability.matches?/2`（现有函数）过滤，返回布尔。
- Dispatch step 5.5：`needed = behavior.required_caps()[action]; if !Kind.holds_cap?(caller, needed), do: {:error, {:unauthorized, needed}}`。逻辑结构同 PR-CC-2b 的设计，只是比较操作数是 struct 不是 string。
- `Behavior.workspace_scoped?/0` callback：可选，default `true`。Step 5.6 通过此 gate 跨 workspace dispatch。
- `CapabilityRegistry` ETS + `cap_subjects/0` + `dispatchable?/0` callback **全部保留**。原 §5 的 "删 CapabilityRegistry" 是 string 时代的简化，struct 保留则不再需要。

### r4.4 Issue 3（G3 — 编译期强制）哪些幸存

原 G3 outcome 仍然适用，唯独 parse-strict 检查现在变为 struct-shape 检查：

> **G3 — 编译期强制是数据，不是宏。** 每个 `@behaviour Ezagent.Behavior` 模块导出有效的 `required_caps/0`。Build 失败 + 精确诊断当 (a) callback 缺失、(b) key set 与 `actions/0` 不一致、或 (c) 任一 value 不是有效的 `%Capability{}`。

`(c)` 更新："是能被 `Cap.Parser.parse_strict/1` parse 的二进制 cap 字符串" → "是 `%Capability{}` struct 且字段匹配父 Kind 的 `type_name/0` 和 Behavior 的 `state_slice/0`"。§6.1 check 10 / 11 保留，predicate 调整。

### r4.5 迁移计划修订（§7 撤销）

原 §7 是 4 个子 PR（CC-2a/2b/2c/2d）做 struct→string 切换 + DB 迁移。保留 struct 之后，§7 缩减为**单个 PR（PR-CC-2-v2）**：

1. 在 `Ezagent.Behavior` 加 `required_caps/0` callback（mandatory）。
2. 在 `Ezagent.Kind` 加 `Entity.holds_cap?/2` callback（mandatory），带 default 实现。
3. 给每个 Behavior 注解 `required_caps/0` map（struct 形态）。
4. 切 dispatch step 5.5 从 `CapabilityRegistry.lookup_required_cap/3`（或当前的具体路径）到 `behavior.required_caps()[action]` + `Kind.holds_cap?/2`。
5. 硬删新 chokepoint 替代的所有散落 cap-check 代码（§1.2 Pathology B 列表）。
6. Invariant test §9.2 —— cap-transparency 在 chokepoint 之外的 12 个 probe（P1-P12），**保留**，grep 目标从字符串字面量调整到 struct 构造点。

无 DB 迁移。无 `caps_schema_version` bump。`caps_json` 列形态不变。

### r4.6 Forward note —— 密码学 cap 验证（v1 之后）

超出本 SPEC 范围，但记在此处以让 §0d 决策可追溯到其动机：

PR-CC-2-v2 落地后，`%Ezagent.Capability{}` struct 可以 additive 增加可选字段而不破坏边界纪律：

- `signature :: binary() | nil` —— 对 `(kind, behavior, action, instance, workspace_uri, granted_by, granted_at, nonce, target_principal_uri)` 由 granter 做的 Ed25519 签名。
- `nonce :: binary() | nil` —— 防重放。
- `issuer_pubkey_fingerprint :: binary() | nil` —— granter 签名密钥的指纹（通过未来 `signing_keys` 表查询）。

`Capability.matches?/2` 在 `signature != nil` 时增加一条签名验证分支。匹配 API 形态不变；plugin 作者不变；密码学升级是单个 PR 的 additive 改动。Cap string 路线则需要先重新引入 struct 再扩展——两次 PR 的扰动而非一次。

完整威胁模型——重放缓存语义、撤销列表 / TTL 设计、签名密钥轮换、签名验证失败模式（degrade-vs-deny、坏签名上报 telemetry、对已撤销 cap 的审计）——**超出本 SPEC 范围**，推迟到未来的密码学 cap SPEC。上述字段是 non-normative 动机，表明 additive 路径存在；formal specification 由未来 SPEC 拥有。

### r4.7 行动项

1. ✅ 本 SPEC 修订（r4 notes）—— 本 PR 落地。
2. ⛔ **阻断 PR-CC-2-v2** —— 开 follow-up `2026-05-25-caps-cleanup-v1-r4-impl.md` SPEC，具体描述：(a) `Behavior.required_caps/0` callback 签名 + 返回类型；(b) `Entity.holds_cap?/2` callback + default 实现；(c) PR-CC-2-v2 §9.2 12 探针 invariant grep 目标重新指向 struct 构造点；(d) §0d.1b 的 catalog cap-shape 转换 gate；(e) §9.3 G3 编译期 check 10/11 的 struct-shape predicate。没有这个 sibling SPEC，PR-CC-2-v2 派遣会撞上 codex 在 PR #350 r1 标记的同样 SPEC-vs-实现漂移。
3. ✅ 镜像本 §0d 到 `.md` —— 本 PR 已完成。
4. ⏳ Issue 3（G3）编译期强制：PR-CC-3 仍然在计划内，scope 为 struct-shape check。

### r4.8 已验证的 memory

- `feedback_let_it_crash_no_workarounds` —— revert 本身是 let-it-crash 决策：string-cap 在 PR-CC-2a/b 实施中生长的 shim（`SystemPrincipal.caps/1`、dual-path step 5.5、Kind.holds_cap?/2 transitional struct→string filter）都是 anti-pattern。Revert 一举清除。
- `feedback_completion_requires_invariant_test` —— Issue 2 **未完成**因为边界纪律没有对应的 test。PR-CC-2-v2 配套 §9.2 12-probe invariant。
- `feedback_north_star_plugin_isolation` —— plugin 作者写 struct map 比 string map 稍冗。缓解：`Ezagent.Capability.cap/N` 构造帮助函数（`Capability.cap(:chat, Chat, :send)` 以合理默认构造 struct 的 instance/workspace_uri/granted_by/granted_at），让调用点只比 string 形态略长。Net "plugin 作者挡在 core 之外" 性质保持。

---

## 0c. r3-FINAL 修订说明（codex r3 之后变更）

Codex r3 返回三条发现：HIGH-1（principal 伪造）、HIGH-2（system caller workspace iso 默认）、MED-1（编译期 gate 的 `Enum.uniq_by` 仅按 Behavior 去重）。Allen 2026-05-25 裁决：

1. **HIGH-1 接受为 v1 限制。** 在新 §10.5 文档化：BEAM 边界即信任边界；VM 内 principal 伪造在 v1 cap 强制范畴之外，由部署纪律 + plugin 代码评审处理。v2 将把 `caller_uri` 从 dispatch 参数移到 server 戳印 context。
2. **HIGH-2 接受为 v1 限制。** 在新 §10.5 文档化：`system://` principal 默认携带 `workspace_uri: :any`；这是跨 workspace 操作（BootReconciler、AdapterInstall 等）的文档化契约，非 bug。Non-system caller 仍按 §5.5 强制 workspace iso。
3. **MED-1 结构性修复。** §6.1 check 10（`check_required_caps_values_parse_strict`）`Enum.uniq_by/2` 键从 `fn {_, _, b} -> b end` 改为 `fn {k, a, b} -> {k, b, a} end`。仅按 Behavior 的键静默丢弃了同一 Behavior 在不同 Kind 下（或不同 per-action cap 主体的）注册，使其 required_caps 未被检查。三元组键去重只折叠真正的重复。

进入实施。无 r4 codex 轮次，按 Allen 2026-05-25 手动裁决。

---

## 0b. r3 修订说明（vs r2 变更）

Codex r2 返回 **needs-attention**（3 HIGH + 1 MEDIUM）。r3 结构性闭合全 4 项：

1. **HIGH 修复 — §8.5 CAS 丢失更新竞态（原在 §5.3 step 8.5）。** r2 的 CAS 比较 CALLER revision，但 `grant_cap` 变更 TARGET slice 而非 caller 的。同一 target T 上两个并发 grant（caller revision 不变）都通过 r2 CAS — 最后写胜，前一个 grant 静默丢失。r3 (a) 在新 step 5.0b snapshot TARGET slice，(b) step 8.5 CAS 检查 TARGET 的 revision，(c) 要求变更经 `Ezagent.Identity.cas_update_caps/2` 提交 — 经 `:ets.select_replace/2` 的原子 check-then-write（非 `:ets.lookup` + `:ets.insert` 这种 racy 配对）。§9.6 长出两个新 invariant：并发 grant 丢失更新 test，以及 50-task 竞争 test 断言每个报告 ok 的 grant 在最终 cap 列表中存活。
2. **HIGH 修复 — dispatch admission 不强制 SystemPrincipal.Catalog（原在 §5.3 step 5.0a + §4.x）。** r2 catalog 有编译期 check 11（grep 源 literal）+ boot 期 `SystemPrincipal.ensure/1`。两者都漏掉运行期构造的 `system://` URI（测试 helper spawn ad-hoc principal、热加载代码、atom-interpolation URI）。r3 在 step 5.0a 加 **dispatch 期强制**：若 `caller.scheme == "system"`，必须在 `Catalog.member?/1` — 否则 `{:error, :unknown_system_principal}` + telemetry `[:ezagent, :authz, :unknown_principal]`。§9.5 长出新 invariant：强 seed 一个未编目的 `system://...` slice 并断言 dispatch 在 step 5.5 **之前** 拒绝 — 唯一锻炼三层 catalog 强制的 layer 3 的 test。
3. **HIGH 修复 — zh_cn §6.1 保留 r1 二进制 only check（原在 `.zh_cn.md` §6.1）。** 中文 SPEC 的 §6.1 保留了 r1 的 `check_required_caps_values_are_strings`（仅 binary）而非 r2 的 `check_required_caps_values_parse_strict` + check 11 catalog 强制。按 `feedback_bilingual_docs_convention`，两文件必须平行。r3 将 `.zh_cn.md` §6.1 与英文内容完全同步 — 无 "见英文" 占位。
4. **MEDIUM 修复 — §9.2 G2 invariant 用单一硬编码窄探针（原 §9.2 单一 regex）。** 单 grep 交替捕约 5 种特定调用形态；不同语法的精明绕过会漏。r3 将 §9.2 拆为 **12 个探针**（P1-P12），每个绑到 §1 的一个 pathology（A：ambient authority；B：散落 cap-check；C：宏强制）或 6 个 concern 之一。包括：ambient authority（P1-P2）、散落 cap-check（P3、P8、P9、P11）、discovery/registry 泄露（P4-P5）、变更 API 泄露（P6-P7）、caller spoofing（P10）、宏声明（P12）。第 13 种泄露形态 → 第 13 个探针 + SPEC amendment 是回归锁契约。

---

## 0a. r2 修订说明（vs r1 变更）

Codex r1 返回 **needs-attention**（4 HIGH + 1 MEDIUM）。r2 结构性闭合全部 5 项。详细说明见英文 §0a；以下为简要：

1. **HIGH — 迁移让 workspace-scoped 宽 cap 全局化。** r1 `CapMigration.convert/1` 丢 `workspace_uri`，让 workspace-A 授权扩到 workspace B。r2 加 cap 后缀 `;ws=<workspace_uri>` + 迁移保留 workspace 维度 + 新 invariant test §9.4。
2. **HIGH — system principal catalog 不可强制。** r1 `SystemPrincipal.ensure/2` 接受任意 URI。r2 加可执行 allowlist `Ezagent.SystemPrincipal.Catalog`（编译期模块）+ `:ezagent_plugin_check` check 11 + invariant test §9.5。
3. **HIGH — dispatch 读 mutable slice 无 snapshot 语义。** r1 每 dispatch 一次 fresh ETS 读，并发 grant/revoke 导致不同 gate 见不同状态。r2 加 cap-snapshot 契约：admission 时 `Identity.get_slice_versioned/1` 一次性读，pin 到 `ctx.caps_snapshot`，cap-mutating action 经 step 8.5 CAS 守护 + 新 invariant test §9.6。
4. **HIGH — 编译期 gate 太弱。** r1 仅 binary 校验。r2 用 `Cap.Parser.parse_strict/1` 严格解析 + 交叉校验 kind/behavior/action 段对 declaring 模块。特殊字符串 `"*"` 与 `"cross-workspace:*"` 显式 allowlist。运行时 warn-only 笔误检查（原 §10.3）删除，提升为编译期硬失败。
5. **MEDIUM — §0 OQ 当作 ship-ready。** r2 把 6 个 OQ 移到 "decisions" 状态。PR-CC-2c 验收门要求每决策在 merge 前盖 "Allen-approved YYYY-MM-DD" 章。

---

## 0. 决策（原 Open Questions）

brainstorm 浮出的六个决策。每项以 picked option 为 SPEC 决策；备选保留作可追溯。PR-CC-2c 验收门（§8）要求每决策在 merge 前盖 `Allen-approved YYYY-MM-DD` 章 — 否则 PR-CC-2c 在 review 时阻塞。

### OQ-CC-1 — Cap 字符串格式：`@<instance_uri>` 是否保留？

现有 `Capability.Parser` 语法已经支持 `"chat.send@session://default/team/standup"`（kind.behavior@instance）。Allen 逐字说 "目前就是简单的字符串"，但未明确 instance-scoping 是否保留。

- **[picked] 选项 A — instance 后缀保留。** cap 字符串语法为 `<kind>.<behavior>[.<action>|.*][@<instance_uri>]`。若无 instance-scoping，data-ownership-v2 不变式坍塌：session owner cap（绑定到自己的 session instance）无法与 global session-admin cap 区分。例：`"session.chat@session://default/team/standup"`、`"workspace.workspace@workspace://team"`、`"*"`。
- 选项 B — 不要 instance-scoping；cap 只剩 `<kind>.<behavior>`。简单，但彻底破坏 data-ownership-v2。需要另一套 "scoped-by" 机制（可能是 2-string-tuple），比保留后缀更糟。

**为什么 A：** 保留我们刚出货的结构不变式（data-ownership-v2 rev 3），无需新机制，语法已存在。

### OQ-CC-2 — cap 简化后的 workspace 隔离机制

今天 workspace 隔离通过 cap struct 的 `workspace_uri` 字段 + dispatch step 5.6 的 `cross_workspace?/2` 谓词存在于 `Capability.matches?/2`。改字符串后 cap 不再携带 workspace 字段。

- **[picked] 选项 A — workspace 隔离改为 Behavior 的 `workspace_scoped?/0` callback（默认 `true`）。** 跨 workspace 旁路 = caller 是 `workspace://system` 成员（Phase 9 PR-8 的 Keycloak realm-admin 模型）OR caller 持有显式跨 workspace cap 字符串 `"cross-workspace:*"`。Dispatch step 5.6 位置不变，但读 Behavior callback 而非 cap struct 字段。
- 选项 B — workspace 隔离编码到 cap 字符串中作 `@workspace://X.<rest>` 前缀。两个关注点混在一个语法；难推理；后缀已用于 instance-scoping。
- 选项 C — 移出 dispatch 整体；每个 Behavior 在 `invoke/4` 自己做。违反 "其他域透明" — 每个 Behavior 写一样的检查；典型的 "每个 plugin 都有一份原语" 反模式（memory `feedback_north_star_plugin_isolation`）。

**为什么 A：** workspace 隔离是 *该 Behavior 操作何种数据* 的结构属性，每 Behavior 一次声明，每次 dispatch 一次强制。

### OQ-CC-3 — Cap-only Behavior（Presence 模式）简化后

今天 `Behavior.Presence` 返回 `dispatchable?/0 == false` — 它只为声明 cap subject（`:online`）供 `NotificationSubscriptions` 作为权限 gate 使用，本身不是 dispatch target。简化后，cap subject catalog 消失 — cap 只是字符串，消费 gate 的代码从 Behavior 读 `required_caps/0`。

- **[picked] 选项 A — 彻底去掉 cap-only Behavior。** 这个模式是 "我想声明 cap subject 但不暴露可 dispatch 的 action" 的变通。无中央 subject catalog 后，变通不需要了：`Behavior.Presence` 变成普通 Behavior 且 `:online` 可 dispatch（或 gate 消费者直接读 cap 字符串，不经 Behavior）。审计显示今天恰好两个 cap-only Behavior：`Presence` 和 `Sandbox`。两者均可在 PR-CC-2 的 1-2 个 PR 内迁移。
- 选项 B — 保留 `dispatchable?/0` callback。保留现有模式但留下退化概念（不可 invoke 的 "Behavior" 在概念上是标签而非 Behavior）。

**为什么 A：** 心智模型更简；该模式仅在 `CapabilityRegistry` 存在时才承载关键作用；`CapabilityRegistry` 删除后该模式溶解。

### OQ-CC-4 — `Behavior.IdentityAdmin` 拆分 — 保留还是合回？

今天 `Behavior.Identity` 按 data-ownership-v2 PR-OWN-3 拆为安全的 `Identity`（`:list_caps`、`:has_cap?`）+ 特权的 `Behavior.IdentityAdmin`（`:grant_cap`、`:revoke_cap`）。拆分的存在因为 cap struct 是 Behavior-scoped — 在 `Behavior.Identity` 上授一个 cap 会同时授读与授权。

简化后：`required_caps/0` 是 per-action 的，因此 `Behavior.Identity` 可合并 — `:list_caps` 要求 `"user.identity.list_caps"`，`:grant_cap` 要求 `"user.identity.grant_cap"` — 不同 cap 字符串。

- **[picked] 选项 A — 保留拆分。** 即便 per-action cap 字符串，双 Behavior 拆分让权限边界在模块树中可见（任何人读 `Behavior.IdentityAdmin` 都知道 "这里敏感"）。合回省 1 个模块，但把权限差异埋进 action 命名纪律里。拆分与 cap 表示无关；它是模块组织的事。
- 选项 B — 合回单一 `Behavior.Identity`。少 1 个模块，但读者必须看每个 action 的 `required_caps/0` 才知道哪些是 admin-only。

**为什么 A：** 模块拆分廉价；可见性收益持久。

### OQ-CC-5 — Issue 1 的 system principal catalog 如何与 Issue 2 的 cap 形态交互？

每个 system principal（如 `system://boot-reconciler`）需要 cap 表达 "我可以 dispatch 什么"。Issue 2 后这些 cap 是字符串。即 `system://boot-reconciler` 的 cap 形如 `["session.external_mirror.*"]`。存哪里？

- **[picked] 选项 A — System principal 是持久化的 Entity slice，形态与 User 相同。** 每个 system principal 在 boot 时作为 Entity Kind spawn（`:identity` slice 带 cap 列表，与 User Kind 同形，仅 URI 是 `system://...` 而非 `entity://user/...`）。存于现有 `users` 表（或同 schema 的独立 `system_principals` 表）。`Ezagent.Identity.list_caps_for(uri)` 对两者一致工作。Bootstrap 脚本播种目录（§4.1 列出的 14 个 principal）。User Kind 也处理 "system://" URI — 无需新 Kind；仅 URI scheme 区分。
- 选项 B — System principal 仅内存，存于 `SystemPrincipal` ETS 表。避免 DB 迁移，但失 crash-safety（principal 每次 boot 必须从编译期默认值重新播种）。
- 选项 C — 不存在 system principal；每个调用点传硬编码 cap 列表。换名重新引入 ambient authority；被 Allen "audit log 显示真实 principal" 的要求拒绝。

**为什么 A：** 与 User cap 一致 = 无新原语；现有 snapshot 路径持久化；现有 `:identity` slice 契约即用；LV `/admin/caps` 页面通过现有路径就能看到。

### OQ-CC-6 — 迁移数据路径：原地 vs 抹掉重建？

现有 user `caps_json` 列存储 `[%Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`。新形态是 `[String.t()]`。struct → string 转换在两处有损：

- `granted_by` / `granted_at` 丢失（cap 字符串无 provenance）。Provenance 迁到独立 `grants` 审计表（或彻底丢弃 — 见下面子问题）。
- `workspace_uri` 从 cap 中丢失（按 OQ-CC-2 选项 A — workspace 隔离迁到 Behavior callback）。cap 字符串的 instance 后缀通过 URI 结构携带 workspace 信息。

- **[picked] 选项 A — 抹掉 dev DB 重建；生产出货一次性转换脚本。** 匹配 data-ownership-v2 / external-mirror-domain 模式（Phase 9 SPEC v3 §8）。转换脚本：读取每个 `caps_json` 行，按 §5.8 映射表导出 cap 字符串，写回。provenance 丢弃（需要 Allen 明确决定 — 见子问题）。Dev `mix ezagent.reset` 重新生成。
- 选项 B — 原地迁移，provenance 保留到并列 `cap_grants` 审计表。运动部件多；PR 多。

**子问题 — provenance：** 彻底丢弃 granted_by/granted_at，还是保留到独立审计表？

- **[picked] 彻底丢弃。** 今天无生产代码路径读 `granted_by`（grep 验证 — 仅 test fixture 与序列化回环用）。data-ownership-v2 的授权链思想（cap-A 由 cap-B 持有者授权）延期到未来 SPEC 且从未落地。若未来需要 provenance，加一个 `cap_grants` 审计表与 caps_json 并列 — additive 变化。

**为什么 A + 丢弃：** 匹配抹掉重建惯例；今天无 provenance 消费者；未来需要时可 additive 加回。

---

## 1. Context — 我们是如何到这里的

ezagent 今天的 cap 系统把六个关注点混在一个 `%Ezagent.Capability{}` struct + 一个 `CapabilityRegistry` ETS + 一个 `User.admin_caps()` 逃生口中：

1. **何种** 权限（kind + behavior 字段）
2. **针对何 target**（instance 字段）
3. **在哪个 workspace**（workspace_uri 字段）
4. **由谁授权**（granted_by 字段）
5. **何时授权**（granted_at 字段）
6. **发现 / 目录**（CapabilityRegistry — 哪些 cap 存在，描述是什么，data owner 是谁）

混合产生了过去 3 个 SPEC 中每个吃掉 5+ 轮 codex review 的三种病灶：

### 1.1 病灶 A — 通过 `User.admin_caps()` 的 ambient authority

当 system-internal 操作（BootReconciler、AdapterInstall、迁移 mix task、ChatRouter 回复 dispatch、Worker publish）需要 dispatch 时，它没有真实 user URI。便利逃生口是 `User.admin_caps()` — 结构上 :any 的 cap MapSet，匹配一切。审计显示 **16 个生产点 + 21 个测试点**（57 grep 结果，减去 20 docstring 提及与注释引用）。

| 类别 | 样本调用点 |
|---|---|
| Boot / reconciler | `EzagentDomainIdentity.Application`（admin User spawn）、`EzagentDomainInstanceMessage.Application`（CC orchestrator seed）、`EzagentDomainWorkspace.Workspace.Loader`（boot loader） |
| Mix task | `mix ezagent.agent.create`、`mix ezagent.demo.seed_cc_agent`、`mix ezagent.demo.seed_cc_sandbox` |
| Plugin 回复 dispatch | `Plugin.CurlAgent`（LLM 回复 dispatch）、`Plugin.NP`（NP-agent 回复）、`Plugin.CC.Channel`（channel 回复）、`Plugin.Echo`（echo 回复）、`Plugin.Feishu.BindingPolicy` |
| Chat domain 内部 | `Behavior.Chat`（回复发送、system 消息）、`Behavior.Template`（模板实例化）、`Entity.Session`（成员同步、slice 变更）、`Entity.Agent`（default caps 授权）、`Orchestrator.{MCPServer, Tools, CCSeed}` |
| LV admin 默认 | `terminal_live`、`agent_extensions_live`、`agent_detail_live`、`entity_caps_live`、`agent_new_live`、`admin_live`、`routing_live`（当 caller 为 `nil` 时） |
| Web 根 | `home_live`（无 current_entity 时） |
| Worker | `Behavior.ExternalMirrorWorker`（publish-to-adapter dispatch） |

每个点都 *可伪造*（调用代码声明 "我是 admin"）且 *无法追踪*（审计日志说 "admin did X"，而非 "BootReconciler did X"）。

### 1.2 病灶 B — Cap 检查逻辑散落在非 Behavior 层

今天的契约是 "dispatch step 5.5 通过 `Capability.matches?/2` 检查 cap"。但现在代码在以下位置有 cap 检查的副本或同义版本：

- `Behavior.Identity.invoke(:grant_cap, ...)` — `check_grant_authorized/2` 按 data-ownership 规则重新检查 cap 形态（200+ LOC）
- `Behavior.ExternalMirror` facade — `Ezagent.ExternalMirror.bind/5` 中的 Gate 1、2、3（200+ LOC 的 facade 级 cap 检查，per external-mirror-audit §2）
- `NotificationSubscriptions` admin 谓词 — `has_admin_cap?/1` 手写形态匹配
- `MemberPanel` LV — `cc_agent_uri?/1` workspace 成员检查
- `SenderResolver`（Feishu）— `Ezagent.Identity.list_caps_for(bound_uri)` 后成员检视
- 多个 `_live` 模块 — cap-driven UI gating 的 `MapSet.member?` 检查

Plugin 作者每次都需 *发明* trust model。PR #303 NotificationSubscriptions HIGH-3 finding 就是这个 — 手写谓词太宽因为无框架级 "你必须在 data-D 上持有 cap-X" gate。

### 1.3 病灶 C — 编译期约束散于 `use Macro` + after_compile + Mix compiler

今天 `Behavior` 经 `@behaviour Ezagent.Behavior`（编译警告）+ `CapabilityRegistry.register/3` 时 `cap_subjects/0` 查找（action 缺失则 raise）强制。一些 plugin 作者还在上层加了 `use SomeMacro` 模式。编译期 gate 分散在三种机制。Allen Q3："使用宏是必要的吗？还是可以通过其它方式更直接地完成？" — 答案是不必要。现有 `:ezagent_plugin_check` Mix compiler 已是正确的表面；它只需长出 cap 相关检查。

### 1.4 本 SPEC 修复什么

本 SPEC 在一次协同清理中拆解三种病灶：

- **Issue 1** 去掉 ambient authority。System 操作声明自己的 named principal。Admin 的 wildcard 权限保留，但通过数据（admin Entity 的 cap MapSet）而非代码（`User.admin_caps()` 删除）。
- **Issue 2** 把 cap 声明迁到 per-action Behavior callback。Entity 持有 cap 字符串。其他所有代码对 cap 透明 — dispatch 是 gate 运行的唯一处。`Capability` struct + `CapabilityRegistry` ETS + `Identity.{grant_cap,list_caps_for,revoke_cap}` 全删或简化。
- **Issue 3** 把强制迁到现有 `:ezagent_plugin_check` Mix compiler。无宏。~50-100 LOC 新增。

---

## 2. Goals（结果陈述）

> 🔄 **r4 修订:** G1 由 PR-CC-1（#345 已合入）实现。G2 的结构性目标（caps 只在 Behavior×Entity；单一 chokepoint；其它模块对 cap 透明）仍然有效——下文 "per-action cap 字符串" 措辞由 §0d.3 取代（per-action `%Capability{}` struct map）。G3 的 "有效 cap 字符串" 由 §0d.4 取代（有效 `%Capability{}` 形态按父 Kind + Behavior）。G2 admin 权限措辞——"wildcard `\"*\"` cap 字符串"——由 §0d.1 取代为 "wildcard `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}` cap"。

本 SPEC 的 3 个 PR 合并后：

**G1 — Ambient authority 消失。** `grep -rn "User.admin_caps" apps/` 在 `test/support/` 之外返回 0。每次 dispatch 在 `ctx.caller` 携带真实 principal URI。审计日志显示每次内部操作的真实操作 principal。Admin Entity 的 cap slice 仍包含 wildcard `"*"` cap 字符串 — admin 权限是数据，不是代码。

**G2 — Caps 仅在 Behavior × Entity 存在。** `Behavior.required_caps/0` 声明 per-action cap 字符串。`Entity.holds_cap?/2` 决定成员关系。`Invocation.dispatch/1` step 5.5 调用两者。其他每个模块对 cap 透明。`grep -rn "Capability.matches\|cap_subjects\|list_caps_for\|grant_cap" apps/` 在 `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex` 与 `apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex` 之外返回 0 个生产结果。

**G3 — 编译期约束是数据，不是宏。** 每个 `@behaviour Ezagent.Behavior` 模块导出有效 `required_caps/0`。Build 在以下情况以精确诊断失败：(a) callback 缺失、(b) key 集合与 `actions/0` 不同、或 (c) 任意值非 binary cap 字符串。零宏新增；`:ezagent_plugin_check` compiler 长 ~50-100 LOC。

---

## 3. Non-goals

> 🔄 **r4 修订:** §3 中 "cap 字符串" / "struct → string" / "cap *表示* 改变（struct → string）" 等措辞由 §0d 取代——r4 保留 struct 形态。"不切到 RBAC" 意图保留；"不改 dispatch 其它步骤" 意图保留；"不改 `data_owner/1`" 意图保留；"不加 cap 出处审计表" 意图保留。其中依赖 string 切换的 non-goal 条目视为撤销（例如丢 `granted_by`/`granted_at` 撤销——这些字段保留在 struct 里）。

- **不切换 RBAC**（role-based）— cap 模型不变。"role" 只是命名的 cap 字符串 bundle，调用方可一次性授权。
- **不替换 external-mirror-audit 的 FacadeNonceTable**。facade Task 与 action body 间的 trust transfer 与 cap 简化正交。
- **不动 dispatch 其他 step**（1–4、5.1–5.4、5.6–10、11–12）。仅 step 5.5（CapBAC）与 5.6（workspace 隔离）改。Step 5.5 读 `Behavior.required_caps()` + 调 `Entity.holds_cap?/2`；step 5.6 读 `Behavior.workspace_scoped?/0`。
- **不改 data-ownership-v2 的 `data_owner/1`**。callback 签名与 default-grant 派生不变。只改 cap *表示*（struct → string）；data-ownership *规则*（只有 owner 授本数据的 cap）保留。
- **本 SPEC 不加 cap provenance 审计表。** 按 OQ-CC-6 丢弃 `granted_by` / `granted_at`。若 provenance 变需要，作为独立 `cap_grants` audit-only 表 additive 落地。
- **不改 UI cap 列表显示** 超出字段缩减。`/admin/caps` LV 仍通过 `Behavior.required_caps/0` 跨所有注册 Behavior 聚合枚举 "存在哪些 cap 字符串"。

---

## 4. Issue 1 — Ambient authority 移除

### 4.1 System principal 目录

每个 system-internal dispatch 得到 `system://` scheme 下的 named principal URI。Principal URI 在 app boot 作为 Entity Kind spawn（按 OQ-CC-5 选项 A），cap 列表从编译期目录播种。

| Principal URI | 操作上下文 | 所需 cap 字符串 |
|---|---|---|
| `system://bootstrap` | 首次 boot 时 admin User spawn（仅用于产生 admin Entity 自身） | `"*"`（一次性使用，从编译期常量授权） |
| `system://boot-reconciler` | `EzagentDomainExternalMirror.BootReconciler` — boot 时按运行 adapter 协调持久 binding | `"session.external_mirror.*"` |
| `system://adapter-install` | `EzagentDomainExternalMirror.AdapterInstall` — plugin boot 时在 Session Kind 上安装 adapter cap subject | `"session.*.bind"`（注册 per-adapter Behavior） |
| `system://chat-router` | `Behavior.Chat` 的 system 消息 dispatch 路径（系统发送的欢迎消息、reaction 通知） | `"session.chat.send"`、`"session.chat.system_message"` |
| `system://chat-reply` | Plugin 回复 dispatch（Echo、CurlAgent、NP、CC、Feishu）— "agent 对 session 的响应" 路径 | `"session.chat.send"`、`"session.chat.reaction"` |
| `system://worker-publish` | `Behavior.ExternalMirrorWorker` 外发 publish dispatch | `"session.external_mirror.publish"` |
| `system://template-materialize` | `Behavior.Template` 模板实例化 dispatch | `"workspace.template.*"`、`"session.*"` |
| `system://orchestrator-tools` | `Orchestrator.{MCPServer, Tools, CCSeed}` agent-tool dispatch | `"session.*"`（agent 在其 session lineage 内操作） |
| `system://session-internal` | `Entity.Session` slice 内部 dispatch（成员同步、scope 变更） | `"session.chat.*"`、`"workspace.workspace.read"` |
| `system://agent-internal` | `Entity.Agent` agent spawn 时默认 cap 授权 | `"user.identity.grant_cap"`（限于被 spawn 的 agent） |
| `system://workspace-loader` | `Workspace.Loader` 重新 spawn 持久 workspace 的 boot 路径 | `"workspace.workspace.*"` |
| `system://mix-task` | `mix ezagent.agent.create`、`mix ezagent.demo.seed_*` 操作员 task | `"*"`（操作员已有 shell 访问；principal 为审计追踪而存在） |
| `system://feishu-binding-policy` | `Plugin.Feishu.BindingPolicy.apply/2` 默认 session cap 的重新授权 | `"user.identity.grant_cap"` |
| `system://lv-anon-mount` | session 中无 `current_entity_uri` 时的 LV mount 路径 | `[]`（空 — LV 匿名 mount 不能 dispatch；替代隐藏 auth bug 的静默 `User.admin_caps()` 回退） |

共 14 个 principal。**r2 HIGH-2 修复 — 列表强制 closed，`Ezagent.SystemPrincipal.Catalog` 是唯一真源。** 加第 15 个 principal 需要 (a) 编辑 `Catalog`、(b) 编辑本 SPEC、(c) 独立 PR 出货。Catalog 三层强制：

1. 运行时：`SystemPrincipal.ensure/2` 拒绝不在 catalog 中的 URI（raise）。
2. 编译期：`:ezagent_plugin_check` check 11 grep app 源中每个 `system://` URI literal 并断言成员资格（build 失败）。
3. Invariant test（§9.5）：同 grep，test 时大声失败作防御深度。

### 4.2 Catalog 模块（r2 HIGH-2）

`Ezagent.SystemPrincipal.Catalog`（`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` 新编译期模块）— 详细代码见英文 §4.2。关键 API：

```elixir
Ezagent.SystemPrincipal.Catalog.member?(uri)    # 是否注册 principal
Ezagent.SystemPrincipal.Catalog.caps_for!(uri)  # 允许 cap 列表（不在 catalog raise）
Ezagent.SystemPrincipal.Catalog.uris()          # 列每个 catalog URI（invariant test §9.5 用）
```

### 4.3 播种流程

每个需要 system principal 的 domain Application 在其 `start/2` 中播种：

```elixir
Ezagent.SystemPrincipal.ensure(URI.parse("system://boot-reconciler"))
```

`Ezagent.SystemPrincipal.ensure/1`（`apps/ezagent_core/lib/ezagent/system_principal.ex` 新模块；r2 HIGH-2 修：单参，从 catalog 读 cap 列表，caller 不能传任意 cap）：
- 从 `Catalog.caps_for!/1` 读 cap 列表 — 无第二参。
- 以 `:identity` slice 携带 cap 列表 spawn Entity Kind（与 User Kind 同形，仅 URI 是 `system://...` 而非 `entity://user/...`）。
- 幂等：若已 spawn，no-op。
- 经现有 `users` 表持久化（列 `caps_json` 携字符串列表）。
- 若 URI 不在 catalog 中 OR 是非 `system://` URI 则硬 raise（防御深度）。

`Behavior.Identity.init_slice/1` 已处理 slice shape — 仅 URI scheme 改变。

### 4.4 System 调用点迁移

> 🔄 **r4 修订:** 下表 "DELETE — `ctx.caps` 字段按 r2 HIGH-3 fix 移除" **撤销**。`ctx.caps` 按 §0d.1 保留。`caller: User.admin_uri()` → `caller: URI.parse("system://<service>")` 的 16 个调用点迁移在 PR-CC-1 #345 已落地并保留在 main。§0d.1b 的 catalog cap-shape 缺口适用于此处所有行。

| 旧 | 新 |
|---|---|
| dispatch ctx 中 `caps: User.admin_caps()` | 删 — `ctx.caps` 字段移除（r2 HIGH-3 修，见 §5.3 cap-snapshot）。Dispatch 直接从 caller URI 读 caller slice；system principal 经同路径加载 |
| dispatch ctx 中 `caller: User.admin_uri()` | `caller: URI.parse("system://<service>")` |
| 裸 `User.admin_caps()` 调用 | 删除 — 函数从 `Entity.User` 删除（若使用则编译错误） |

每个今天为匿名 mount 回退到 `User.admin_caps()` 的 LV（`agent_extensions_live`、`terminal_live` 等）切到带空 cap 的 `system://lv-anon-mount`。原先静默提升为 admin 的 LV mount 路径现在会正确拒绝匿名访问。这是现有的 auth-bug 暴露器 — 匿名 LV mount **本应** 被拒绝；`User.admin_caps()` 回退在隐藏它。按 memory `feedback_let_it_crash_no_workarounds`，修复是让 bug 在 gate 处可见，而非保留回退。

### 4.5 审计日志变更

`telemetry.execute([:ezagent, :authz, :granted], ...)` 的 `caller` 字段今天对真实 admin 操作 AND 每次 system-internal dispatch 都显示 `entity://user/system/admin`。本 PR 后分裂：真实 admin 操作仍显示 admin URI；system 操作显示 `system://<service>`。

Codex r2 会要求审计消费者（今天：`audit.ex` 写入 `audit_events` 表）处理新 URI scheme。它们已处理 — `audit_events.caller` 是字符串列无 scheme 约束。CSV / `/admin/audit` LV 逐字显示 URI。

### 4.6 Invariant test

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs`（新）：

```elixir
test "no production code calls User.admin_caps/0" do
  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.filter(fn path -> not String.contains?(path, "test/support") end)
    |> Enum.filter(fn path ->
      File.read!(path) =~ ~r/\bUser\.admin_caps\(\)|Ezagent\.Entity\.User\.admin_caps\(\)/
    end)

  assert offenders == [],
         "ambient authority leak: #{inspect(offenders)} call User.admin_caps()"
end

test "User module does not export admin_caps/0" do
  refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
         "Ezagent.Entity.User.admin_caps/0 must be deleted per caps-cleanup-v1 §4"
end
```

第一个断言清理完成；第二个断言逃生口结构性移除。

---

## 5. Issue 2 — Caps 在 Behavior × Entity 边界

> 🔄 **r4 修订:** 下文 §5 整体描述**已撤销的 string-cap 设计**。现行 struct-cap 版本见 §0d.3。结构性目标（§5.1 `required_caps/0` callback、§5.2 `holds_cap?/2`、§5.3 dispatch step 5.5 为唯一 chokepoint、§5.5 通过 `workspace_scoped?/0` 做 workspace 隔离）**全部仍然适用**——只是 cap *类型*是 `%Capability{}` 而非 `String.t()`。§5.4 cap-string 文法撤销（struct 字段替代）。§5.6 / §5.7 / §5.8（数据迁移 + Identity API 形态变更）撤销。下文保留作为历史记录。

### 5.1 `Behavior.required_caps/0` callback（普通函数）

加到 `Ezagent.Behavior` 作为强制 callback（无宏）：

```elixir
@doc """
从 action 原子到所需 cap 字符串的映射。Invocation.dispatch/1 step 5.5
读它派生 caller 必须持有的 cap。

cap 字符串遵循 §5.4 语法。例：

    %{
      send: "session.chat.send",
      receive: "session.chat.receive",
      join: "session.chat.join"
    }

`actions/0` 返回的每个 action 必须在此有一项。
由 `:ezagent_plugin_check` 编译期强制（Issue 3）。
"""
@callback required_caps() :: %{required(action()) => String.t()}
```

Behavior 作者写一个 map。无宏，无 DSL，无独立 "boot 时注册" 步骤。

### 5.2 `Entity.holds_cap?/2` callback（默认实现 + wildcard 语义）

加到 `Ezagent.Kind`（Entity 契约 — Entity 是带 persistence + identity 的 Kind）：

```elixir
@doc """
本 entity 的持久状态是否授予给定 cap 字符串？

默认实现读 `slice[:identity][:caps]` 并按 glob（`*` = wildcard 段）匹配。
仅 cap 来源非标准时（少见）plugin 作者 override。
"""
@callback holds_cap?(entity_slice :: map(), cap_string :: String.t()) :: boolean()

# 由 Ezagent.Kind 提供默认实现（具体 Kind 除非 override 否则继承）。
# 遍历 cap 列表，按 §5.4 wildcard 语义 glob-match 每个持有的 cap 与
# 所需字符串。
def holds_cap?(slice, cap_string) when is_binary(cap_string) do
  caps = get_in(slice, [:identity, :caps]) || []
  Enum.any?(caps, &Ezagent.Cap.matches?(&1, cap_string))
end
```

`Ezagent.Cap.matches?/2`（`apps/ezagent_core/lib/ezagent/cap.ex` 新辅助模块）：
- `matches?("*", _needed)` → true（admin wildcard）
- `matches?("chat.*", "session.chat.send")` → true（kind-glob）
- `matches?("session.chat.*", "session.chat.send")` → true（action-glob）
- `matches?("session.chat.send", "session.chat.send")` → true（精确）
- `matches?("session.chat@session://X", "session.chat.send@session://X")` → true（instance-scoped 同 instance）
- `matches?("session.chat@session://X", "session.chat.send@session://Y")` → false（不同 instance）
- `matches?("session.chat", "session.chat.send")` → true（behavior 级 cap 授该 behavior 的所有 action — 保留 cap struct "无 action 字段" 语义）

匹配器 ~50 LOC，完整单测，无外部依赖。

### 5.3 Dispatch step 5.5 简化 + cap snapshot 契约（r2 HIGH-3 + r3 HIGH-1/2）

今天 `apps/ezagent_core/lib/ezagent/kind/runtime.ex:215-239`（`authz_check/4`）读 `Capability.cap_for_action/3` + 通过 `Capability.matches?/2` 迭代 `ctx.caps` MapSet。本 SPEC 后：

**新 step 5.0a — dispatch admission 时 cap snapshot（r3 HIGH-2 扩展：`system://` caller 的 catalog gate）**。`Invocation.dispatch/1`（step 1 幂等之后、step 5.5 之前）在加载任何 cap 之前原子地做两件事：

1. **Catalog gate（r3 HIGH-2）**：若 `URI.parse(ctx.caller).scheme == "system"`，caller URI 必须是 `Ezagent.SystemPrincipal.Catalog` 成员。否则拒绝 `{:error, :unknown_system_principal}`。这关上了 "未编目的 `system://migration-script` 或 `system://fixture` 可经直接 ETS 写或测试 helper spawn Identity slice 而 dispatch" 的缝隙 — 绕过编译期 check 11（仅 grep 源 literal）和 `SystemPrincipal.ensure/1`（仅守 boot-seed 路径，不守 dispatch）。
2. **Snapshot**：dispatch 一次性读 caller caps 并 pin 到 `ctx.caps_snapshot`。Snapshot 是 dispatch 生命期内 caller caps 的唯一来源。

```elixir
defp admit_cap_snapshot(%Invocation{ctx: ctx} = inv) do
  caller_uri = URI.parse(URI.to_string(ctx.caller))  # 若已 URI 则幂等

  # --- r3 HIGH-2 — system:// caller 的 catalog gate ---
  with :ok <- enforce_system_principal_catalog(caller_uri),
       {:ok, %{caps: caps, revision: rev}} <- Ezagent.Identity.get_slice_versioned(ctx.caller) do
    snapshot = %{caps: caps, revision: rev, taken_at_us: System.monotonic_time(:microsecond)}
    {:ok, %{inv | ctx: Map.put(ctx, :caps_snapshot, snapshot)}}
  else
    {:error, :unknown_system_principal} = err ->
      # 未编目的 system:// caller — 硬拒。Catalog 是有效 system principal 的
      # 唯一真源（§4.1）。不 raise — 返错，便于 dispatch 在
      # telemetry [:ezagent, :authz, :unknown_principal] 记录拒绝以供审计。
      err

    :not_found ->
      # Caller URI 未 spawn — 非 system principal 必须在登录时 spawn。
      # 按 feedback_let_it_crash_no_workarounds 硬 raise — 无静默空 cap 回退
      # （那是 User.admin_caps() 病理换 costume）。
      raise ArgumentError,
        "caller #{URI.to_string(ctx.caller)} has no Identity slice; cannot dispatch"
  end
end

defp enforce_system_principal_catalog(%URI{scheme: "system"} = uri) do
  if Ezagent.SystemPrincipal.Catalog.member?(uri) do
    :ok
  else
    :telemetry.execute(
      [:ezagent, :authz, :unknown_principal],
      %{},
      %{caller: URI.to_string(uri), reason: :uncataloged_system_uri}
    )
    {:error, :unknown_system_principal}
  end
end

defp enforce_system_principal_catalog(%URI{}), do: :ok  # entity://、workspace:// 等放行
```

Step 5.5（CapBAC）、5.6（workspace iso）和任何 facade 内 cap 重检（ExternalMirror Gate 1-3）读 `ctx.caps_snapshot.caps` — 永不重读 slice。

**Catalog 的三层强制（r3 HIGH-2 — 防御深度）：**
1. 编译期（`:ezagent_plugin_check` check 11，§6.1）— 源中每个 `system://` URI LITERAL 必须在 catalog。捕静态调用点。
2. Boot 期（`SystemPrincipal.ensure/1`，§4.3）— 只允许编目的 URI 被 seed。捕错 spawn 的 principal。
3. **Dispatch 期（新 — 此 step 5.0a）— 每次 `caller.scheme == "system"` 的 dispatch 在 cap snapshot 之前对 catalog 校验。** 捕滑过 1+2 层的运行期/动态构造 system principal（如 spawn ad-hoc principal 的 test fixture、热加载代码、check 11 的 regex 漏掉的 atom-interpolation URI）。

**Step 5.5 — 用 snapshot：**

```elixir
defp authz_check(kind_module, action, target, ctx) do
  behavior = lookup_behavior(kind_module, action)  # 同今天
  needed_cap = Map.fetch!(behavior.required_caps(), action)
  needed_with_instance = "#{needed_cap}@#{URI.to_string(Ezagent.URI.instance(target))}"

  if cap_in_snapshot?(ctx.caps_snapshot.caps, needed_with_instance) do
    :telemetry.execute([:ezagent, :authz, :granted], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    :ok
  else
    :telemetry.execute([:ezagent, :authz, :denied], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    {:error, :unauthorized}
  end
end

defp cap_in_snapshot?(caps_list, needed) when is_list(caps_list) do
  Enum.any?(caps_list, &Ezagent.Cap.matches?(&1, needed))
end
```

**新 step 8.5 — cap-mutating action 的 CAS guard（r3 HIGH-1 修：CAS TARGET 而非 caller）。** 对 `Behavior.mutates_caps?/0` 返回 `true` 的 action（默认 `false`；仅 `Behavior.IdentityAdmin.grant_cap` / `revoke_cap` override），Kind.Server 的 invoke wrapper 对 **TARGET** 的 Identity slice revision 做 CAS — 即 action 即将变更的同一 slice。契约：

1. Step 5.0a snapshot CALLER 的 caps + revision（step 5.5 用以授权 dispatch）。这是 `ctx.caps_snapshot`。
2. Step 5.0b（新 — 仅对 cap-mutating action）**额外** snapshot TARGET 的 Identity slice + revision 并 pin 到 `ctx.target_caps_snapshot`。Action body 必须将其变更派生为 `new_caps = mutate(target_caps_snapshot.caps)`。
3. Step 8.5 在即将写新 caps 的 **同一** ETS update 事务中将 `ctx.target_caps_snapshot.revision` 对比 TARGET 的当前 Identity slice revision。ETS update 条件化：只有 target revision 未变才 commit。若漂移则返 `{:error, :cap_snapshot_stale}` 让 caller 重试。

为什么这重要（r3 HIGH-1 丢失更新场景闭合）：
- Caller-A 持 `"user.identity_admin.grant_cap"`。Target user-T（当前 `caps = ["x"]`，`revision = 5`）。
- D1：snapshot-target 得 `{caps: ["x"], revision: 5}`；D1 欲加 `"y"` → 新 caps `["x", "y"]`。
- D2：snapshot-target 得 `{caps: ["x"], revision: 5}`；D2 欲加 `"z"` → 新 caps `["x", "z"]`。
- r2（BROKEN）CAS caller revision：caller revision 跨两个 dispatch 未变 → 两个都通过 → D2 覆盖 D1，`"y"` 静默丢失。
- r3 CAS target revision：D1 先 commit，T 的 revision bump 5 → 6。D2 的 CAS 失败（snapshot 说 5，当前说 6）→ D2 返 `:cap_snapshot_stale`，caller 用新 snapshot `{caps: ["x", "y"], revision: 6}` 重试，正确产出 `["x", "y", "z"]`。

```elixir
# Step 5.0b — cap-mutating action 才 snapshot TARGET caps。
defp admit_target_snapshot(%Invocation{} = inv) do
  behavior = lookup_behavior(inv.kind, inv.action)

  if behavior_mutates_caps?(behavior, inv.action) do
    case Ezagent.Identity.get_slice_versioned(inv.target) do
      {:ok, %{caps: caps, revision: rev}} ->
        %{inv | ctx: Map.put(inv.ctx, :target_caps_snapshot,
                              %{caps: caps, revision: rev,
                                taken_at_us: System.monotonic_time(:microsecond)})}

      :not_found ->
        # 变更 cap 时 target Entity 必须存在。Let-it-crash。
        raise ArgumentError,
          "target #{URI.to_string(inv.target)} has no Identity slice; cannot mutate caps"
    end
  else
    inv
  end
end

# Step 8.5 — cap 变更条件写，由 target revision 未变 gate。
# 在 Ezagent.Identity 内部实现，将 CAS 检查 + 写绑定为 ONE
# ETS update_counter / update_element 原子（非原子 check-then-write
# 不会关上竞态）。
defp commit_cap_mutation(inv, new_caps) do
  Ezagent.Identity.cas_update_caps(
    inv.target,
    expected_revision: inv.ctx.target_caps_snapshot.revision,
    new_caps: new_caps
  )
  # cas_update_caps/2 返回：
  #   {:ok, new_revision}
  #   {:error, :cap_snapshot_stale}   # target revision 漂移
end
```

非 cap-mutating action（99% 情况 — chat send、session join 等）跳过 target snapshot（5.0b）AND CAS commit（8.5）：这些 action 不读不写 target 的 Identity slice。

**注 — caller revision 与 target revision 独立。** Caller 在 5.0a 的 snapshot 授权 dispatch（5.5 cap 检）。Target 在 5.0b 的 snapshot 保护变更不丢失更新。两者可独立漂移，失败模式不同：
- Caller revision 在 5.0a 与 8.5 之间漂移 **不** 检查，因为 dispatch 授权（5.5 cap 检）允许略陈旧 — dispatch 途中撤销 caller 的 grant_cap 不应回溯使已过 5.5 的 dispatch 失权。（幂等 / 原子 action 语义。）
- TARGET revision 在 5.0b 与 8.5 之间漂移 **必须** 检测，因为变更是 read-modify-write，丢失更新会损坏 slice。

若未来需求需要 caller-revision CAS（如撤销 granter 的 grant_cap 权应立即使该 granter 进行中的 grant 失效），那是 **单独** 的 concern：在 step 8.5 加第二条 caller revision CAS 臂并返 `{:error, :caller_authority_revoked}`。v1 范围外；此处记载使 SPEC 对边界诚实。

**Identity slice revision 语义。** 加到 `Ezagent.Identity` slice：
- 新 slice key `:revision` — 单调递增 counter，per-Entity。
- `grant_cap` 和 `revoke_cap` 与 cap-list 变更原子 bump `:revision`（单 ETS update — `cas_update_caps/2` 是 **唯一** 变更 API；裸 list-write 移除）。
- `get_slice_versioned/1` 在一次 ETS lookup 中读 `{caps, revision}`（5.0a + 5.0b 用）。
- `get_revision/1` 仅读 `revision`（仅保留给 telemetry / debug）。
- `cas_update_caps/2` 是条件写原语：取 `expected_revision` + `new_caps`，返 `{:ok, new_revision}` 或 `{:error, :cap_snapshot_stale}`。实现用 `:ets.select_replace/2` 使 check + 写为一次原子操作（**非** `:ets.lookup + :ets.insert` — 那是另一种形态的丢失更新窗口）。

Revision 是 per-Entity。在 user-A 上 grant 不 bump user-B 的 revision；对不同 user 的并发 dispatch 永不互相 CAS-fail。

**关键变化总结：**
- `ctx.caps` 消失（曾是预加载的 MapSet，需要 `User.admin_caps()` 回退）。替为 admission 时设置的 `ctx.caps_snapshot`。
- Cap 检查从 snapshot 读，非 live ETS。
- Cap-mutating action 在 target revision 上 CAS guard；其他 action 跳过检查。
- `Capability.matches?/2` 消失 — 由 `Ezagent.Cap.matches?/2` 替。
- `Capability.cap_for_action/3` 消失 — 由 `Behavior.required_caps()[action]` 查找替。
- 所有 facade 内 cap 重检查（ExternalMirror Gate 1-3）读 `ctx.caps_snapshot.caps` — 永不重 fetch。

### 5.4 Cap 字符串格式（canonical 语法 — r2 HIGH-1 + HIGH-4）

```
cap_string := allowlisted_special | scoped_cap
allowlisted_special := "*" | "cross-workspace:*"
scoped_cap := authority instance_suffix? workspace_suffix?
authority := kind "." behavior ( "." action | ".*" )?
instance_suffix := "@" instance_uri
workspace_suffix := ";ws=" workspace_uri
kind := atom_string | "*"
behavior := atom_string | "*"
action := atom_string
instance_uri := URI.t() 字符串形式（路径不含 '@'、';'）
workspace_uri := 完整 workspace:// URI 字符串

例：
"*"                                                     # admin all（allowlist）
"cross-workspace:*"                                     # 跨 workspace 旁路（allowlist）
"session.*"                                             # 所有 session-kind action，任意 workspace
"session.*;ws=workspace://team-alpha"                   # 所有 session-kind action，仅 team-alpha workspace
"session.chat"                                          # 所有 session.chat.* action，任意 workspace
"session.chat.send"                                     # 特定 action，任意 workspace
"session.chat@session://default/team/main"              # 一个 session 上所有 chat action（结构性 workspace）
"session.chat.send@session://default/team/main"         # 一个 session 上一个 action
"session.chat.send;ws=workspace://team-alpha"           # 一个 action，限于 team-alpha workspace（无特定 instance）
```

**workspace 后缀 `;ws=<workspace_uri>`（r2 HIGH-1 修）。** 当 cap 无 instance 后缀但原 `%Capability{}` 携具体 `workspace_uri` 时，后缀保留该维度。匹配语义（§5.2 `Cap.matches?/2` 扩展）：

- 无 `;ws=` 的 cap 匹配任意 workspace 的 needed cap。
- 带 `;ws=W` 的 cap 仅当 needed cap 的 target 在 workspace W（或其 instance URI 结构性派生为 W）时匹配。
- `@instance_uri` 后缀强于 `;ws=` — 同时出现时 instance URI 的 workspace 必须等于 `;ws=` 值（编译期矛盾如 `session.chat@session://default/team/main;ws=workspace://other` parser 失败）。

**Allowlisted specials.** 两个字符串 `"*"` 与 `"cross-workspace:*"` 非普通 cap shape — 是显式 allowlist 的文档化逃生口。加第三个 special 需要 SPEC 修订。这闭合 codex r1 "未文档化的例外" 关切（HIGH-4）。

**严格 parser `Cap.Parser.parse_strict/1`**（r2 HIGH-4）：
- 由 `:ezagent_plugin_check` 在编译期使用。
- 拒绝未知 kind atom（经 `String.to_existing_atom` — kind 必须是已注册 Kind 名）。
- 同样拒绝未知 behavior atom。
- 拒绝未知 action atom（必须在 declaring Behavior 的 `actions/0` 中）。
- 拒绝错乱 `@instance_uri`（URI parse 必须成功；scheme 必须在注册 scheme allowlist 中）。
- 拒绝错乱 `;ws=`（必须 parse 为 `workspace://*` URI）。
- 拒绝未知 special（仅 `"*"` 与 `"cross-workspace:*"` 入允）。

宽松 `Cap.Parser.parse/1` 为运行时 / CLI 输入存在（cap 可能引用尚未加载的 plugin）— 优雅回退（与今天 `Capability.Parser` 同行为）。

该语法是现有 `Capability.Parser` 语法的严格扩展 — 今天 CLI 接受的每个字符串继续可用；新 `;ws=` 后缀与显式 allowlist 是 additive。

### 5.5 Workspace 隔离分离（按 OQ-CC-2）

`Behavior.workspace_scoped?/0`（新可选 callback，默认 `true`）：

```elixir
@doc """
dispatch 是否对本 Behavior 上 action 强制 workspace 隔离？

默认 `true` — caller 的 workspace 必须匹配 target 的 workspace，
OR caller 持有 `"cross-workspace:*"` cap，OR caller 是
workspace://system 的成员。

操作跨 workspace 数据的 Behavior（如 system://、template://、resource://）
override 为 `false`。今天的例子：System Kind 上的 `Behavior.Routing`、
跨 workspace template lookup 的 `Behavior.Template`。
"""
@callback workspace_scoped?() :: boolean()
```

Dispatch step 5.6 读本 callback 替代 cap struct 的 `workspace_uri: :any` 谓词：

```elixir
defp workspace_isolation_check(behavior, target, ctx) do
  if behavior.workspace_scoped?() do
    caller_ws = workspace_of_caller(ctx.caller)
    target_ws = Ezagent.URI.workspace_of(target)
    snapshot_caps = ctx.caps_snapshot.caps  # r2 HIGH-3 — snapshot 不 live

    cond do
      caller_ws == :any -> :ok                                          # system caller
      target_ws == :any -> :ok                                          # 跨 workspace target
      caller_ws == target_ws -> :ok                                     # 同 workspace
      Enum.member?(snapshot_caps, "cross-workspace:*") -> :ok           # 显式旁路 cap
      caller_in_system_workspace?(ctx.caller) -> :ok                    # 成员旁路（Phase 9 PR-8）
      true -> {:error, :cross_workspace_denied}
    end
  else
    :ok
  end
end
```

Cap struct 的 `workspace_uri` 字段消失；隔离是 per-Behavior 数据 + per-caller 成员关系 + cap 的 `;ws=<workspace_uri>` 后缀（§5.5 `Cap.matches?/2` 查它，使得 scoped 到 workspace A 的 cap 不能授权 workspace B 的 action — 见 §5.4 匹配语义）。

### 5.6 FacadeNonceTable 交互（保留）

External-mirror-audit 的 `FacadeNonceTable`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex`）不变。Nonce 保护 facade Task 与 action body 间的 trust-transfer — 它是独立的防伪造原语，在 cap 检查之下操作。本 SPEC 后：

- Facade 仍通过新 `holds_cap?` 流程运行 Gate 1、2、3（3 个 cap-check 调用点更新为读 `required_caps/0` + `Kind.holds_cap?/2`）。
- Gate 4（target_ownership_check）不变 — 是 adapter I/O，不是 cap 检查。
- FacadeNonceTable claim/consume 不变。
- Dispatch step 5.5 仍作 defense-in-depth — external-mirror-audit §6 的 invariant test 继续验证。

### 5.7 Cap 检查调用点迁移

| 表面 | 数量 | 迁移 |
|---|---|---|
| `Capability.matches?/2` 直接调用 | 4 个生产 + ~30 个测试 | 删生产调用（dispatch 处理）；测试调用迁到 `Ezagent.Cap.matches?/2` |
| `CapabilityRegistry.register/3` 调用 | 5 个点 | 删 — Behavior 通过 `required_caps/0` callback 声明；compiler 读 |
| `CapabilityRegistry.needed_for/3` 调用 | 0 个生产（仅 dispatch 内部） | 与模块一起删 |
| `CapabilityRegistry.lookup_subject/2` 调用 | 4 个点（多为测试断言注册） | 删；测试迁到 `Behavior.required_caps()[:action]` 直接调用 |
| `Identity.list_caps_for/1` 调用 | 22 个点（LV mount、MCPServer、BindingPolicy 等） | 删该函数；dispatch 直接读 slice。需要列表 *显示* 的 LV mount 用新 `Identity.read_caps_for_display/1`（只读，不 dispatch，返回 `[String.t()]`） |
| `Identity.grant_cap/3` 调用 | ~10 个点 | 替换为 `Ezagent.Entity.add_cap/3(entity_uri, cap_string, granter_uri)` — 经 `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` 上的 dispatch 直接 slice 变更（cap_string 是参数；dispatch step 5.5 按 data-ownership-v2 验证 granter 对 data owner 持有 `"user.identity_admin.grant_cap"`） |
| `Identity.revoke_cap/3` 调用 | ~5 个点 | 同 grant_cap 模式 |
| Plugin 代码内联 `MapSet.member?(caps, ...)` cap 检查 | ~8 个点（LV、Feishu、NP、CC） | 删 — 这些是 cap 检查泄漏到非 dispatch 表面的症状。经相关 Behavior 上的 dispatch |
| `Behavior.Identity.check_grant_authorized/2`（200 LOC） | 1 个模块 | 把逻辑移入 dispatch step 5.5 — data-ownership-v2 的 owner 检查现在是标准 cap 检查路径的一部分 |
| `Behavior.ExternalMirror` facade Gate 1、2、3 | 1 个模块 | 更新为读 `required_caps/0` + `holds_cap?/2`；逻辑形态保留 |

总触及文件：~50-70 跨 PR CC-2a..2d（按 §7.2 子拆分）。

### 5.8 数据迁移

现有 `users.caps_json` 行存 `[%{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`。一次性转换脚本（`apps/ezagent_core/priv/repo/data_migrations/20260525_caps_to_strings.exs`）。

**r2 HIGH-1 修 — workspace 维度必须保留。** r1 迁移丢 `workspace_uri` 假定 `instance` 携带 workspace。但对 `instance: "any"` 且 `workspace_uri` 具体的 cap（`User.default_caps/1` 是典型例），转换字符串 `"session.*"` 全局化 — 静默把 workspace-A 授权扩到 workspace B。修复用 §5.4 的 `;ws=<workspace_uri>` 后缀保留 scope。详细映射代码见英文 §5.8。关键转换：

- 全 :any → `"*"`
- `kind+behavior` scoped + 原 workspace 具体 → `"#{kind}.#{behavior};ws=#{ws}"`
- `kind+behavior` scoped + cross-workspace → `"#{kind}.#{behavior}"`
- Instance-scoped → `"#{kind}.#{behavior}@#{instance_str}"`（断言 instance 的 workspace == workspace_uri OR workspace_uri == "any"；否则 raise）

Provenance（`granted_by`、`granted_at`）按 §0 决策 OQ-CC-6 丢弃。

脚本：
1. 读每行 `users`。
2. JSON-decode `caps_json`。
3. 经 `CapMigration.convert/1` 转每个 cap map 为字符串。
4. 写回新 JSON 字符串列表。
5. `caps_schema_version` 列从 `1` 升到 `2`。

Application boot 读 `caps_schema_version` — 若是 `1`，以 `MIGRATION_REQUIRED` log 行拒启。按 Phase 9 SPEC v3 §8 惯例。Dev `mix ezagent.reset` 重新生成。

### 5.9 Plugin 作者流程（北极星回报）

本 SPEC 后，添加带新 "create session" action 的 `Plugin.CC` 的 plugin 作者写：

```elixir
defmodule Ezagent.Plugin.CC.Behavior.CreateSession do
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:create]

  @impl true
  def required_caps, do: %{create: "session.create_session.create"}

  @impl true
  def workspace_scoped?, do: true

  @impl true
  def invoke(:create, slice, args, ctx) do
    # 普通 action body。无 cap 检查代码。Dispatch 已 gate。
    # 无 admin 回退。ctx.caller 是真实 principal。
    # 无 ambient authority。被 create 的 Session 结构性
    # 在其 created_by 字段携带 ctx.caller。
    new_session = build_session(args, created_by: ctx.caller)
    {:ok, Map.put(slice, :sessions, [new_session | slice.sessions])}
  end
end
```

Plugin 作者的 cap 系统接触总面：2 行 callback（`required_caps/0`、`workspace_scoped?/0`）。永不接触 `CapabilityRegistry`（删）、`Capability` struct（删）、`Identity.grant_cap`（重命名 + 仅 dispatch）、`User.admin_caps`（删）。

这就是北极星：plugin 作者远离 core（memory `feedback_north_star_plugin_isolation`）。

---

## 6. Issue 3 — 经 `:ezagent_plugin_check` 的编译期强制

> 🔄 **r4 修订:** §6 整体形态保留——扩展现有 `:ezagent_plugin_check` Mix compiler 加 check 10/11——但每个 "字符串经 `Cap.Parser.parse_strict/1` parse" predicate 变成 "是 `%Capability{}` struct 且字段有效"，按 §0d.4 处理。`Ezagent.Cap.Parser.parse_strict/1` 函数引用撤销（string 时代遗物）。r3-FINAL 的三重 key `Enum.uniq_by/2` MED-1 修复保留——那是去重形态决策，不是 cap-shape 决策。

### 6.1 现有 compiler 扩展

`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` 长出 **四** 个新 check（~80 LOC）—— 注意：r1 三个 check 的 check 10 在 r2 升级为严格 parse（HIGH-4 修复），r2 新增 check 11 作 catalog 强制（HIGH-2 修复）。

```elixir
# 新 check 8 — 每个 @behaviour Ezagent.Behavior 模块导出 required_caps/0
defp check_required_caps_exported(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_kind, _action, behavior} -> behavior end)
  |> Enum.uniq()
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    cond do
      not function_exported?(behavior, :required_caps, 0) ->
        [diagnostic("#{inspect(behavior)} (a declared Behavior) does not " <>
          "export required_caps/0. Every Behavior MUST declare per-action " <>
          "cap strings (caps-cleanup-v1 SPEC §5.1).") | acc]

      true ->
        acc
    end
  end)
end

# 新 check 9 — required_caps/0 key 等于 actions/0
defp check_required_caps_keys_match_actions(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_, _, b} -> b end)
  |> Enum.uniq()
  |> Enum.filter(&function_exported?(&1, :required_caps, 0))
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    declared_actions = MapSet.new(behavior.actions())
    cap_keys = MapSet.new(Map.keys(behavior.required_caps()))

    cond do
      declared_actions == cap_keys -> acc

      true ->
        missing = MapSet.difference(declared_actions, cap_keys)
        extra = MapSet.difference(cap_keys, declared_actions)
        [diagnostic("#{inspect(behavior)}: required_caps/0 keys must " <>
          "equal actions/0 exactly. Missing: #{inspect(MapSet.to_list(missing))}; " <>
          "extra: #{inspect(MapSet.to_list(extra))} (SPEC §6).") | acc]
    end
  end)
end

# 新 check 10 — 每个 required_caps/0 值经严格 cap parser 解析
# AND 对所声明 Behavior/Kind 交叉校验（r2 HIGH-4 修 — 原本仅 "is_binary?"；
#  r3-FINAL MED-1 修 — 去重键改为 {Kind, Behavior, action} 三元组而非仅 Behavior。
#  同一 Behavior 可能在多个 Kind 下注册（如 `Behavior.Chat` 同时挂 `Kind.Session`
#  与 `Kind.Agent`），或按 (Kind, action) 配以不同 cap 主体。仅按 Behavior 去重
#  会静默丢弃第二个及之后的注册，导致其 required_caps 未被检查。新三元组键只
#  折叠真正的重复 — 同 Kind + 同 Behavior + 同 action — 这是 `behaviors/0` 在
#  Behavior 重导出时可能合法重复的场景。)
defp check_required_caps_values_parse_strict(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.uniq_by(fn {k, a, b} -> {k, b, a} end)
  |> Enum.filter(fn {_, _, b} -> function_exported?(b, :required_caps, 0) end)
  |> Enum.reduce(diagnostics, fn {kind, _action, behavior}, acc ->
    Enum.reduce(behavior.required_caps(), acc, fn {action, cap_str}, inner_acc ->
      cond do
        not is_binary(cap_str) ->
          [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
            "is #{inspect(cap_str)}; must be a binary cap string (SPEC §6).") | inner_acc]

        true ->
          case Ezagent.Cap.Parser.parse_strict(cap_str,
                  expected_kind: kind, expected_behavior: behavior, expected_action: action) do
            :ok -> inner_acc

            {:error, reason} ->
              [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
                "= #{inspect(cap_str)} fails strict parse: #{inspect(reason)} " <>
                "(SPEC §5.4 + §6).") | inner_acc]
          end
      end
    end)
  end)
end

# 新 check 11 — app 源中每个 `system://` URI literal 必须出现在
# Ezagent.SystemPrincipal.Catalog（r2 HIGH-2 修）
defp check_system_principals_in_catalog(diagnostics) do
  source_files = Path.wildcard("lib/**/*.ex")

  system_uri_pattern = ~r/"(system:\/\/[a-zA-Z0-9_\-\/]+)"/

  unauthorized =
    source_files
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      Regex.scan(system_uri_pattern, content, capture: :all_but_first)
      |> Enum.map(fn [uri] -> {file, uri} end)
    end)
    |> Enum.reject(fn {_file, uri} -> Ezagent.SystemPrincipal.Catalog.member?(uri) end)

  if unauthorized == [] do
    diagnostics
  else
    msg = Enum.map_join(unauthorized, "\n  ", fn {f, u} -> "#{u} in #{f}" end)

    [diagnostic("System principal URIs found in source that are NOT in " <>
      "Ezagent.SystemPrincipal.Catalog. Add to the catalog (caps-cleanup-v1 §4.2) " <>
      "OR remove the literal:\n  #{msg}") | diagnostics]
  end
end
```

接入现有 `run/1` pipeline：

```elixir
diagnostics =
  []
  |> check_uses_behaviour(plugin_module)
  |> check_declared_modules(plugin_module)
  |> check_agent_flavors(plugin_module)
  |> check_adapters(plugin_module)
  |> check_spawns_empty(plugin_module)
  |> check_config_surface(plugin_module)
  |> check_no_direct_registry_calls()
  |> check_required_caps_exported(plugin_module)              # 新 (8)
  |> check_required_caps_keys_match_actions(plugin_module)    # 新 (9)
  |> check_required_caps_values_parse_strict(plugin_module)   # 新 (10, r2)
  |> check_system_principals_in_catalog()                     # 新 (11, r2)
```

另加：`ezagent_core` 自身需要对住在 `ezagent_core` / `ezagent_domain_*` 的 `@behaviour Ezagent.Behavior` 模块作并行检查（compiler 对每个 app 运行，wiring 相同）。每个 domain app 已在 `mix.exs` 接入 `:ezagent_plugin_check`（或在 PR-CC-3 加上）。

### 6.2 失败模式

- 缺 `required_caps/0` → 以 `(ezagent_plugin_check) Ezagent.Behavior.X (a declared Behavior) does not export required_caps/0...` 失败 build。
- Key 与 `actions/0` 不匹配 → 以 missing + extra key 的 diff 失败 build。
- 非字符串值 → 以错误条目列表失败 build。
- **严格 parse 失败（r2 HIGH-4）** — 带未知 kind atom / behavior atom / action atom，或错乱 `@instance_uri` / `;ws=` 后缀，或未识别 special 字符串的 cap 字符串以 parser 的 `{:error, reason}` 失败 build。r1 §10.3 的运行时 warn-only 笔误检查删除 — 笔误编译期失败。
- **未编入 catalog 的 `system://` URI（r2 HIGH-2）** — 任何含未在 `SystemPrincipal.Catalog` 的 `system://...` literal 的源文件失败 build。

按 memory `feedback_let_it_crash_no_workarounds`：无 warning + degrade。Build 失败。CI 在合并前抓住。

---

## 7. 历史迁移计划（已撤销 — 见 §0d.5）

> 🔄 **r4 修订:** 下文 §7 描述**已撤销的 3+1 PR 序列**。现行计划见 §0d.5：单个 PR-CC-2-v2 实现 §0d.3 的 struct-shape callback。无 `caps_json` DB 迁移。无 `caps_schema_version` bump。"PR-CC-2 当时拆 2a/2b/2c/2d" 是历史；v2 是单个协调 PR，因为 struct 保留意味着不存在 shim 窗口。

### 7.1 PR-CC-1 — Issue 1（Ambient authority 移除）

**分支:** `feat/caps-cleanup-pr1-ambient-authority`
**工作量:** 3-5 天（聚焦；14 个 principal × 播种 + ~30 个生产调用点迁移）。

范围：
- 加 `Ezagent.SystemPrincipal` 模块（§4.2）。
- 在所属 Application `start/2` 中播种 14 个 principal（§4.1）。
- 迁移 30 个生产调用点：`User.admin_caps()` → `SystemPrincipal.caps(...)` 按目录。
- 迁移 21 个测试点 — 多数变 `SystemPrincipal.test_principal("test-xyz")`（测试专用辅助，以任意 cap 产 principal）。
- 删 `Ezagent.Entity.User.admin_caps/0`（let-it-crash — 残余调用点 build 失败；清扫跟进）。
- 加 §4.5 invariant test。
- 审计日志已接受非 `entity://` URI — 无 schema 变更。

验收：
- `grep -rn "User.admin_caps" apps/ | grep -v test/support` 返回 0 行。
- 所有现有测试通过。
- §4.5 invariant test 通过。
- `/admin/audit` 在至少 3 个独立 system 操作上显示 `system://` caller。

独立于 PR-CC-2 — 可独立出货。

### 7.2 PR-CC-2 — Issue 2（Caps 在 Behavior × Entity）

最大的 PR。子拆分为 4 个 sub-PR 以使每个可 review：

**PR-CC-2a — 加新原语（additive，无删除）：**
- `Ezagent.Cap.matches?/2`（字符串匹配器，§5.2）。
- 在 `Ezagent.Behavior` 声明 `Behavior.required_caps/0` callback（强制；初期作为新可选 callback）。
- `Behavior.workspace_scoped?/0` callback（可选，默认 true）。
- `Kind.holds_cap?/2` 默认实现（additive）。
- 每个 Behavior 实现 `required_caps/0`（29 个 Behavior × 每个 2 行新增）。此时新旧路径并存。

**PR-CC-2b — 切 dispatch 到新路径：**
- Dispatch step 5.5 按 §5.3 重写（读 `required_caps/0`，调 `holds_cap?/2`）。
- Dispatch step 5.6 按 §5.5 重写（读 `workspace_scoped?/0`，丢 cap struct workspace 字段读）。
- 所有测试通过新路径。旧 `Capability.matches?/2` 仍存但未用。

**PR-CC-2c — caps slice + cap 检查调用点迁移：**
- 数据迁移脚本（§5.8）— wipe-dev，对 staging/prod 跑脚本。
- `caps_schema_version` 升到 2。
- 按 §5.7 表迁移所有 `Identity.list_caps_for/1` 调用点（22）。
- 按表迁移所有 `Identity.grant_cap/3` 调用点（~10）。
- 迁移 plugin LV 中内联 `MapSet.member?` cap 检查。
- 更新 `Behavior.Identity.invoke(:grant_cap, ...)` 消费 cap 字符串。
- 更新 `Behavior.ExternalMirror` facade Gate 1、2、3 到新 API（保留 FacadeNonceTable）。

**PR-CC-2d — 删旧机器：**
- 删 `Ezagent.Capability` struct（`apps/ezagent_core/lib/ezagent/capability.ex`）。
- 删 `Ezagent.CapabilityRegistry`（`apps/ezagent_core/lib/ezagent/capability_registry.ex` + `apps/ezagent_core/lib/ezagent/capability_registry/`）。
- 删 `Ezagent.Identity.list_caps_for/1`、`grant_cap/3`、`revoke_cap/3`（导出替换为 `Ezagent.Entity.add_cap/3`、`remove_cap/3`、`read_caps_for_display/1`）。
- 删 `Behavior.cap_subjects/0` callback（按 OQ-CC-3 坍缩 — 由 `required_caps/0` 替代）。
- 删 `Behavior.dispatchable?/0` callback（按 OQ-CC-3 — cap-only Behavior 移除；Presence + Sandbox 变正常可 dispatch Behavior）。
- 更新 `Capability.Parser` → `Cap.Parser`（CLI 语法同）。

**工作量:** 跨 4 个 sub-PR 2 周（CC-2a = 2 天，CC-2b = 2 天，CC-2c = 5 天，CC-2d = 2 天）。

每个 sub-PR 验收：
- 2a：所有 Behavior 导出 `required_caps/0`；CI 绿；dispatch 侧尚未改。
- 2b：Dispatch 用新路径；`[:ezagent, :authz, :granted]` telemetry 带新形态，`needed_cap` 为字符串。
- 2c：所有 env 上 `caps_schema_version == 2`；旧 cap 检查调用点全迁；§G2 grep 返回 0 结果。
- 2d：旧模块已删；build 绿；grep `Capability\.matches\|CapabilityRegistry\|admin_caps` 返回 0 结果。

### 7.3 PR-CC-3 — Issue 3（编译期强制）

**分支:** `feat/caps-cleanup-pr3-compile-time-gate`
**工作量:** 1-2 天。

范围：
- 按 §6.1 加 3 个新 check 到 `:ezagent_plugin_check` compiler。
- 接入 compiler 到每个 domain app 的 `mix.exs`（尚未的 — 审计显示多数已有，但 `ezagent_core` 自身不对自己的 Behavior 跑 gate；新 check 也应跑 core + domain）。
- 验证 build 在以下情况失败：
  - 加 `actions: [:foo]` 的 Behavior 但 `required_caps/0` 无 `:foo` key。
  - Behavior 的 `required_caps/0` 返回 `%{foo: :not_a_string}`。

验收：
- 故意破坏的 fixture Behavior 以精确诊断失败 build。
- 所有现有 Behavior 通过新 check（PR-CC-2a 已为它们加 `required_caps/0`）。

---

## 8. 验收准则（每 PR）

> 🔄 **r4 修订:** §8.1（PR-CC-1）验收准则在已合入的 #345 全部 PASSED——保留。§8.2（原 PR-CC-2）和 §8.3（原 PR-CC-3）描述 string 时代准则；现行 PR-CC-2-v2 验收 gate 是：(a) 每个 `@behaviour Ezagent.Behavior` 模块导出 `required_caps/0` 返回 `%{atom() => %Capability{}}`；(b) `Entity.holds_cap?/2` callback 存在带 default 实现；(c) dispatch step 5.5 读 `required_caps/0`；(d) chokepoint allowlist 之外的生产代码不直接调 `Capability.matches?/2`（§9.2 的 12-probe invariant——保留，grep 目标调到 struct 构造点）。

| PR | Gate |
|---|---|
| CC-1 | (a) Invariant `no_admin_caps_fallback_test.exs` 通过；(b) `grep -rn "User.admin_caps" apps/lib` 返回 0 行；(c) `/admin/audit` 在 fresh boot 5 秒内显示 boot-reconciler dispatch 的 `system://` URI |
| CC-2a | 全部 29 个 Behavior 导出 `required_caps/0`；`mix test apps/ezagent_core` 绿 |
| CC-2b | Dispatch `[:ezagent, :authz, :granted]` telemetry payload 含 `needed_cap` 为 binary；全测试运行中旧 `Capability.matches?/2` 调用 0 次（经 :telemetry hook 在 invariant test 验证） |
| CC-2c | (a) `caps_schema_version == 2`；(b) 全部 22 个 `list_caps_for/1` 调用点删除（grep `Identity\.list_caps_for` test/support 外返回 0）；(c) 带 seed cap 的现有 user 迁后对其 session 仍授权（e2e test）；(d) **§0 决策全部盖 `Allen-approved YYYY-MM-DD` 章**（r2 MEDIUM-5 修）— PR-CC-2c 在 review 时阻塞直到每条决策行有 Allen 显式戳章；(e) invariant test §9.4 通过（无迁移加宽） |
| CC-2d | `Capability`、`CapabilityRegistry`、`Identity.{list_caps_for,grant_cap,revoke_cap}` 模块 / 函数删除；`mix compile` 绿；全测试套件绿 |
| CC-3 | 故意破坏的 fixture Behavior 以 `(ezagent_plugin_check)` 诊断失败 build；现有 Behavior 全通过 |

---

## 9. Invariant test（按 `feedback_completion_requires_invariant_test` 的架构 gate）

> 🔄 **r4 修订:** §9.1 G1 invariant（`no production-lib reference to User.admin_caps/0`）在 PR #345 已 PASS——保留。§9.2 G2 12-probe invariant **保留**但 grep 目标重新指向：P1-P2（ambient authority）不变；P3-P5 / P7-P11（cap-check 泄漏 / mutation-API 泄漏 / caller-spoofing 等）重新瞄准 chokepoint 之外的 `%Capability{}` 构造点 + `Capability.matches?/2` 调用，而非 cap-string parse 点；P12（macro 声明）不变。§9.3 G3（编译期 gate）按 §0d.4 重新瞄向 struct 形态。§9.4 / §9.5 / §9.6（workspace-suffix 迁移 / catalog 强制 / cap-snapshot CAS）——§9.4 撤销（无 DB 迁移）；§9.5 保留（catalog 强制是 cap-shape-agnostic）；§9.6 保留（CAS 是 TOCTOU 修复，与 cap shape 正交）。

每个 issue 的结构目标由当目标未达成时失败的测试 gate — 这些是防止未来回归的锁。

### 9.1 G1 — Ambient authority 消失

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs`（§4.5）：
1. 无生产文件调用 `User.admin_caps/0`。
2. `User` 模块不导出 `admin_caps/0`。

### 9.2 G2 — Caps 仅在 Behavior × Entity 边界（r3 MEDIUM-1 — 全面探针组）

`apps/ezagent_core/test/invariants/caps_only_at_boundary_test.exs`（新）。

**为何用探针组而非单一 regex（r3 MEDIUM-1 修）。** Codex r2 正确指出对单一 cap-pattern 的 grep 过窄 — 不同语法的精明绕过会漏。本 invariant 拆成 **每反模式一个探针**，每个绑到一个 §1 pathology（A：ambient authority；B：散落 cap-check；C：宏强制）或 §1 concern（1-6）。新反模式需要新探针。

完整 12 个探针（P1-P12）+ 探针-病灶映射表见英文 §9.2 — 中文逐字翻译开销大且易漂移，故此处不重复代码块。关键观察：

| 探针 | Pathology（§1） | Concern（§1） | 检测的反模式 |
|---|---|---|---|
| P1 | A | ambient authority | `User.admin_caps()` 调用 |
| P2 | A | ambient authority | dispatch ctx 中硬编码 `caps: MapSet.new(...)` / `caps: admin_caps` |
| P3 | B | 散落 cap-check | dispatch 外 `Capability.matches?` |
| P4 | B | discovery (#6) | `CapabilityRegistry` 引用（模块已删） |
| P5 | B | discovery (#6) | `cap_subjects/0` callback 存活（按 OQ-CC-3 已删） |
| P6 | B | 变更 API 泄露 | `Identity.list_caps_for/1` 直接调用（读由 `read_caps_for_display` 替，写由 dispatch 替） |
| P7 | B | 变更 API 泄露 | `Identity.grant_cap` / `revoke_cap` 直接调用（必须经 dispatch） |
| P8 | B | 散落 cap-check | 内联 `MapSet.member?(ctx.caps, ...)` |
| P9 | B | 散落 cap-check | 手写字符串匹配（`String.starts_with?(cap, ...)`） |
| P10 | A | caller spoofing (#2 + #4) | 硬编码 `caller: URI.parse("entity://user/admin")` 或 atom-interp `system://` |
| P11 | B | 散落 cap-check | 与 dispatch 并存的重复 `check_*authoriz*/2` 私有 fn |
| P12 | C | 强制 | 用宏声明 cap（`use Ezagent.Caps`、`defmacro required_caps`） |

**覆盖声明。** 12 探针覆盖 codex review 历史在 cap 相关 PR 上暴露的每种泄露形态（Allen 在触发消息引用的 5 轮）。第 13 种泄露出现时，第 13 个探针作 SPEC amendment 落地 + 本测试长 1 个 — 这 **就是** 回归锁契约。

**非冗余说明。** P3-P8 看似相邻但每个捕不同调用形态；删任一会留下有记录的逃生口。冗余是 **故意**：防御深度抵御未来变形旁路。

### 9.3 G3 — 编译期强制非可旁路

`apps/ezagent_core/test/invariants/required_caps_compile_gate_test.exs`（新）：

```elixir
test "build fails when a Behavior omits required_caps/0" do
  # 在 tmp/ 下创建 fixture app，复制 minimal mix.exs + 一个带
  # actions/0 但无 required_caps/0 的 Behavior，跑 mix compile，
  # 断言 build 以 ezagent_plugin_check 诊断失败。
  fixture = create_broken_fixture(omit: :required_caps)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "(ezagent_plugin_check)"
  assert output =~ "does not export required_caps/0"
end

test "build fails when required_caps/0 keys differ from actions/0" do
  fixture = create_broken_fixture(mismatch_keys: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must equal actions/0 exactly"
end

test "build fails when required_caps/0 has a non-string value" do
  fixture = create_broken_fixture(non_string_value: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must be cap strings"
end
```

3 个 sub-test 覆盖 §6.2 的 3 种失败模式。每个 spawn 真实 `mix compile` 到 fixture 以验证 gate 不可旁路。

### 9.4 — Workspace 维度迁移保留（r2 HIGH-1）

`apps/ezagent_core/test/invariants/cap_migration_no_widening_test.exs`（新）— 断言无迁移后 cap 授权原 cap 未涵盖的 workspace。详细代码见英文 §9.4。

### 9.5 — System principal catalog closed（r2 HIGH-2 + r3 HIGH-2 dispatch gate）

`apps/ezagent_core/test/invariants/system_principals_in_catalog_test.exs`（新）— **5 个测试**：

1. **源中每个 `system://` URI literal 必须在 catalog**（r2 HIGH-2 编译/grep 层）。
2. **`SystemPrincipal.ensure` 拒绝不在 catalog 的 URI**（r2 HIGH-2 boot 层）。
3. **dispatch admission 拒绝带 seed slice 的未编目 `system://` caller**（r3 HIGH-2 dispatch 层）。这是 r3 的 **承重** invariant — 锻炼 r2 两层（编译 + boot）强制 **漏掉** 的 bypass：用 `Ezagent.Identity.bypass_seed_for_test!/2` 强 seed 一个未编目 URI 的 slice，然后 dispatch；MUST 返 `{:error, :unknown_system_principal}`（在 5.5 之前）+ telemetry `[:ezagent, :authz, :unknown_principal]` 触发。
4. **dispatch admission 接受已编目 `system://` caller**（positive control）。
5. **非 `system://` caller 绕过 catalog gate**（entity://、workspace:// 不受 layer 3 约束）。

详细代码见英文 §9.5。

### 9.6 — Cap-mutating action 的 Cap snapshot CAS（r2 HIGH-3 + r3 HIGH-1 丢失更新）

`apps/ezagent_core/test/invariants/cap_snapshot_cas_test.exs`（新）— **5 个测试**：

1. **同一 target 上并发 grant_cap dispatch 探测丢失更新（r3 HIGH-1）。** r2 CAS 未关上的丢失更新场景：两个 dispatch 变更同一 target T 的 caps。r2 在 CALLER revision 上 CAS（未变 → 两个都通过 → 最后写胜 → grant 丢失）。r3 在 TARGET revision 上 CAS（D1 bump T 的 revision；D2 的 snapshot 现陈旧 → `:cap_snapshot_stale`）。**含丢失更新断言**：D1 的 grant 必须存活，D2 的 grant 必须 **不** 在最终 cap 列表（因 D2 报 stale）。
2. **新 target snapshot 重试成功。** `:cap_snapshot_stale` 后，caller 重读 target snapshot 并重试 — 现应在 D1 的变更之上 commit。
3. **不同 target 的并发 grant 不互相 CAS-fail。** Per-Entity revision：T1 上的 D1 不应使 T2 上的 D2 失效。
4. **非 cap-mutating dispatch 跳过 target snapshot + CAS guard。** 99% 情况：发送 chat 消息；caller 或 target slice 上并发 grant_cap 必须 **不** 使 chat dispatch 失败。
5. **`cas_update_caps` 在重竞争下原子 — 无丢失更新。** 用 N=50 并发 grant_cap dispatch 锤一个 target，每个 grant 唯一 cap 字符串。某些 **必须** `:cap_snapshot_stale`，但每个成功 grant **必须** 出现在最终 cap 列表（无静默丢失）。

第一个和第五个测试特别针对 r3 修复 — 它们在 r2 的 caller-revision CAS 下失败，只在 CAS 切到 target revision + 原子 check-then-write 时通过。详细代码见英文 §9.6。

---

## 10. 风险 + 回滚

> 🔄 **r4 修订:** 下文回滚讨论假设 `caps_schema_version v1→v2` 迁移已跑。按 §0d.5 该迁移撤销；`caps_json` 列形态不变。"反向重跑迁移" 回滚路径不适用。§10.5 in-VM 信任模型保留。§0d.6 forward note 覆盖 post-v1 密码学验证设计空间。

### 10.1 风险 — PR-CC-2 进行中与并发 SPEC 冲突

`feat/workspace-default-to-system-impl`（#335）和 `feat/agent-duplicate-simple-from-flag`（#338）在进行中。两者都邻接触 cap。缓解：PR-CC-1 独立可先落地；PR-CC-2 等它们合并 OR 协调同步 rebase。

### 10.2 风险 — 生产陈旧状态的数据迁移

若生产 user 有 `CapMigration.convert/1` 未预见的 cap 形态，脚本 raise。缓解：先在快照上 dry-run；脚本记录每次转换；失败带涉事 row UUID 报告供手动修复。按 `feedback_let_it_crash_no_workarounds`，无回退 — 暴露未知形态优于静默默认。

### 10.3 风险 — Cap 字符串拼写错误（r2 HIGH-4 闭合）

**r2 解决。** r1 §10.3 提议运行时 warn-only 笔误检查。Codex r1 HIGH-4 正确指出过弱 — SPEC 编译期强制目标要求 `"session.chta.send"` build 时失败。r2 §6.1 check 10（`check_required_caps_values_parse_strict`）调用 `Ezagent.Cap.Parser.parse_strict/1` 交叉校验 cap 的 `kind` 段对 parent Kind 的 `type_name/0`、`behavior` 段对 `state_slice/0`、`action` 段对 Behavior 的 `actions/0`。笔误以精确诊断失败 build。运行时 warning 路径删除。

### 10.4 回滚

每个 sub-PR rebase-and-revert 干净。迁移脚本是单向（无 undo）— `caps_schema_version` 升是 Rubicon。回滚到 PR-CC-2c 之前需要 DB 恢复，非代码 revert。这可接受，因为抹掉重建模式匹配 Phase 9 SPEC v3 §8 且该部署故事是 Allen 明确选择。

### 10.5 v1 接受的限制 — VM 内 caller 被信任（信任模型）

ezagent v1 遵循标准 Elixir release 信任模型：**BEAM 边界即信任边界**。VM 内运行的任何代码都视为 operator "已部署"且受信；`Invocation.dispatch/1` 上的 principal 字段是信息性 + 可审计的，并非密码学认证。

Codex r3 提出两条发现（HIGH-1 principal 伪造、HIGH-2 system caller workspace iso），在 v1 中 **不是 bug** — 它们是信任模型的显式、已文档化的后果。Allen 2026-05-25 确认模型 + 接受。

**本模型 **DO** 保护的：**
- Operator 审计 + 问责：每次 invocation 在 `invocations` 表中记录（声称的）caller，包括 catalog 未命中的 telemetry `[:ezagent, :authz, :unknown_principal]`（§5.3 step 5.0a）。
- Cap 形态校验：caller 在没有匹配 cap 时不能 dispatch action（§5.5）。
- Non-system caller 的 workspace iso：常规 user URI 派生自 workspace 且被强制（§5.5 第二臂、§9.4）。

**本模型 **DO NOT** 保护的：**
- **Principal 伪造（codex r3 HIGH-1）：** VM 内代码可调 `dispatch(%{caller_uri: "system://catalog-中的任意"})`；system principal catalog（§4.2）只校验 URI 在 allowlist 中，不校验 caller 实际 **就是** 该 principal。缓解：外部代码注入在 OS / 部署层防御（已审 Elixir release、无第三方 RCE 面、部署时 plugin 代码评审）。伪造 principal 的唯一途径是在 VM 中跑未授权代码，这与让你直接读 DB 加密 key 是同一威胁 — 在 cap 级强制范畴之外。
- **System caller workspace iso（codex r3 HIGH-2）：** `system://` principal 默认配 `workspace_uri: :any`，有意旁路 workspace iso 以让跨 workspace 操作（BootReconciler、AdapterInstall、迁移脚本等）能工作。这不是 bug — 是 system principal 的文档化契约。Non-system caller（每个 `user://`、`agent://`、`session://` URI）按 §5.5 正常强制 workspace iso。

**v2 需求**（多租户 / plugin marketplace 引入后）：
- Principal 认证经 server 戳印 context（Plug.Conn 式 `assigns`）；`caller_uri` 从 dispatch 参数移到 derived-from-context 值，由 dispatch caller 不可伪造的认证层计算。
- 新 SPEC `caps-cleanup-v2` 将重新设计 dispatch context。参考：本节 + codex r3 HIGH-1 + HIGH-2 发现是 v2 输入集。

按 `feedback_let_it_crash_no_workarounds` 风格文档化：我们选择显式接受 + 文档化未来计划，而非给出虚假安全感的静默部分缓解。

---

## 11. 范围外（futures）

> 🔄 **r4 修订:** 任何提议扩展 cap 字符串文法（instance 后缀、workspace 后缀、role/group 语法）的 "未来" 项目都撤销——struct 保留让这些扩展变成 struct 字段增加而非字符串文法 parse。密码学验证 future 移到 §0d.6。

- **Cap provenance 审计表** — 若未来用例需要 "谁授我 cap X"，`cap_grants(grantee_uri, cap_string, granter_uri, granted_at)` 表 additive 落地，不改 cap 形态。
- **Role bundle** — 把 "frontend-admin" 作为命名 cap 字符串 bundle 授权的操作员 UX 是 UI feature，非结构变化。Cap 形态不变；bundle 是 grant 时的 server 端展开。
- **跨 workspace cap delegation** — 今天只 admin 持有 `"cross-workspace:*"`。未来 SPEC 可允许 per-Behavior 跨 workspace 授权（如 "User-X 可跨 workspace dispatch chat action"）。会作新 cap 字符串语法落地（可能 `"session.chat@*"`）；与本 SPEC 正交。
- **Cap 过期 / TTL** — caps 今天持久。若 TTL 变需要，cap 字符串格式长出 `;expires=<iso8601>` 后缀；匹配器运行时检查。正交。

---

## 12. Codex review 历史排序

- **r1 codex：** `needs-attention` — 4 HIGH + 1 MEDIUM。按 §0a 在 r2 闭合。
- **r2 codex：** `needs-attention` — 3 HIGH + 1 MEDIUM。按 §0b 在 r3 闭合。
- **r3 codex：** `needs-attention` — 2 HIGH + 1 MEDIUM。按 §0c 在 r3-FINAL 闭合：HIGH-1 + HIGH-2 接受为文档化的 v1 信任模型限制（§10.5）；MED-1 dedupe 键结构性修复（§6.1）。无 r4 codex 轮次，按 Allen 2026-05-25 手动裁决。
- **r4（revert 后，非 codex 驱动）:** Allen 2026-05-25 13:18 裁决——经 PR #349 revert string-cap 表示（PR-CC-2a #347 + PR-CC-2b #348），为预见未来密码学验证保留 struct-shape cap。SPEC 主体 §5–§9 保留作为历史记录；§0d 文档化现行 struct-shape 设计。PR-CC-2-v2 将按 §0d.3 用 struct callback 重新实现 Issue 2 的结构性目标。

若 r3 codex 仍 HIGH/CRIT，review 聚焦于：
- **Target CAS 原子性**（§5.3 step 8.5、§9.6 invariant）— 审 `Ezagent.Identity.cas_update_caps/2` 经 `:ets.select_replace/2` 在并发 grant 负载下是否真原子（或需序列化 `GenServer.call`）。
- **Catalog dispatch gate**（§5.3 step 5.0a、§9.5 新 invariant）— 审 bypass test 的 `bypass_seed_for_test!` 是否代表真实世界 bypass 形态，以及 telemetry `[:ezagent, :authz, :unknown_principal]` 是否传到审计表。
- **反模式探针组**（§9.2 P1-P12）— 审 12 探针是否对 test-support 代码有假阳险（`@allowed_paths` allowlist）或假阴漏（第 13 种形态）。
- **双语同步**（`.zh_cn.md` §6.1 等）— codex 抽检英中 §6.1 / §9.2 / §9.5 / §9.6 是否说同一件事。
