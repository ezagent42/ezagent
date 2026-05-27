# SPEC — URI 跨边界规范化 (Bug 2)

**状态:** r4 — DRAFT,等待 codex adversarial-review (第 4 轮)。2026-05-27。

**层级:** `apps/ezagent_core/` (`Ezagent.URI` 解析器 / 规范化器) + 扫除所有构造 `%URI{}` 的 Domain + Plugin (`apps/ezagent_domain_*/`、`apps/ezagent_plugin_*/`、`apps/ezagent_web/`、`apps/ezagent_cli/`) + `apps/*/lib/mix/tasks/` 下的操作员面对 mix tasks (r2 扩展)。

**触发:** 测试失败 `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66` — wizard `create_session` 流程因 `caller == owner` 严格相等比较在同一规范字符串的 `URI.parse` 形式 (authority:"user") 与 `URI.new!` 形式 (authority:nil) 之间失败,返回 `:grant_owner_orchestrator_admin_cap_failed`。

**英文版:** `2026-05-27-uri-canonicalization.md` (按 `feedback_bilingual_docs_convention`)。

## r4 changelog (相对 r3 的差异)

处理 codex r3 REJECT 的 1 个 HIGH:

- **HIGH (§5.2.1 基于计数的 `URI.new/1` 正则仍假阴性)** — r3 声称 `~r/\bURI\.new\(/` 也匹配 `URI.new!(` 的前导部分。Codex r3 静态验证它**不**匹配 (模式要求 `(` 紧跟 `new`,但 `URI.new!(` 在两者之间有 `!`),所以对抗性行 `foo = URI.new(s); bar = URI.new!(t)` 公式给出 `bare=1, bang=1, diff=0`,漏掉违规。**r4 修复:** 切换到单个 PCRE 负向前瞻正则 `~r/\bURI\.new(?!!)\(/` (Elixir 的 PCRE 正则支持此)。前瞻 `(?!!)` 拒绝 `new` 紧跟 `!` 的匹配。通过 `elixir` REPL 实际验证:对抗性行产生 `bare=1` (裸 URI.new),反向 (`foo = URI.new!(s); bar = URI.new(t)`) 也产生 `bare=1`,全 bang 行产生 `bare=0`。完全放弃两阶段计数公式 — 单个正则正确且清晰。§5.5 / Appendix B 对抗性回归测试保留,现在通过。

---

## r3 changelog (相对 r2 的差异,保留用于追踪)

处理 codex r2 REJECT 的 2 个 HIGH + 1 个 MED:

- **HIGH-1 (§9.2 snapshot canonicalize_uris/1 设计)** — r2 伪代码内部不一致:在 `%URI{}` 子句**之前**匹配 `is_map(state)` (所以 struct 短路,永远不到达 URI 规范化分支);调用裸 `URI.new/1` 而非强制的 `Ezagent.URI.parse!/1`;没有 tuple 子句但文本声称支持 tuple;map-key 处理文本与实现矛盾。**r3 修复:** 重写伪代码,严格子句顺序 (`%URI{}` → 自定义 struct → map → list → tuple → 回退),`Ezagent.URI.parse!/1` 作为规范化器 (`URI.new/1` 仅作 §3.7 外部回退 rescue),通过 `Tuple.to_list → walk → List.to_tuple` 显式 tuple 子句,map 子句中 key+value 对齐遍历。新增明确"子句顺序是承载性"备注。§5.5 不变量测试扩展为覆盖每个必需形态 (map value、list element、深度嵌套、map key、tuple element、自定义 struct)。
- **HIGH-2 (§5.2.1 `URI.new/1` 不变量假阴性)** — r2 实现是二元的:"行包含 `URI.new(`" AND "行**不**包含 `URI.new!(`"。像 `foo = URI.new(s); bar = URI.new!(t)` 这样的行漏过。**r3 修复:** 切换到基于计数的检查:`length(Regex.scan(~r/\bURI\.new\(/, line)) - length(Regex.scan(~r/\bURI\.new!\(/, line)) > 0`。bare 计数包括两种形式 (正则 `\bURI.new\(` 也匹配 `URI.new!(` 的前缀);减去 bang 计数隔离 bare-only 贡献。在 §5.5 / Appendix B 添加对抗性回归单元测试。
- **MED (§9.3 操作员产物 — `docs/notes/evidence/` 实际不干净)** — r2 声称"scripts/docs 全部引用 URI 字符串,不引用 struct 形式,所以无额外 grep 目标"。Codex r2 发现 `docs/notes/evidence/pr49-demo-rpc-script.sh` 在第 33、43、53 行嵌入活的 `elixir -e` 块通过 `URI.parse/1` 构造 `%URI{}`。**r3 修复:** §4.2 和 §9.3 现在明确包括 `docs/notes/evidence/*.sh` 和 `scripts/*.sh` 中嵌入 `elixir -e` / `iex --eval` 的 body。新的扫除 grep:`rg -n "URI\.(parse|new!?)\(" scripts docs/notes/evidence -g '*.sh' -g '*.exs'`。

---

## r2 changelog (相对 r1 的差异,保留用于追踪)

处理 codex r1 REJECT 的 4 个 blocker + LOW + NIT:

- **Gate 1 (§4 审计穷尽性)** — §4.1 阶段列表现在由 `rg -n "URI\.(parse|new!?)\(" apps/*/lib` 清单驱动 (共 284 个命中 — 165 个 `URI.parse`、72 个 `URI.new!`、47 个 `URI.new`)。明确枚举 external-mirror 生产命中 (`adapter_install.ex:197`、`worker_spawn.ex:230`、`external_mirror.ex:209,250,391,550`、`behavior/external_mirror.ex:821`、`behavior/external_mirror_worker.ex:640,676`)。新增 workspace `store.ex:203,212`。每个 app 的计数在 §4.1。
- **Gate 5 (§5 不变量覆盖 `URI.new/1`)** — §5 现在禁止 `apps/ezagent_core/lib/ezagent/uri.ex` 之外的非 bang `URI.new/1`,以及内联文档化的明确外部 URI fallback 允许列表。grep 扫描捕获**全部三个**构造器 (`URI.parse`、`URI.new!`、`URI.new`)。
- **Gate 4 (§9 扫除包括操作员产物)** — §4.2 扫除目标**扩展**为包括 `apps/*/lib/mix/tasks/`、`scripts/`、`docs/notes/evidence/`。枚举的 mix-task 命中:`apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex:161,220`;`apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent_external_mirror_migrate_feishu_bindings.ex:153`;`apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex:201,243`;`apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex:62,63,142`;`apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex:504`;`apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex:231`;`apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.token.ex:75`。
- **Gate 3 (OQ-4 snapshot 规范化提升为强制)** — §9.2 将 snapshot load-path 规范化从可选提升为强制。选择**选项 (b) — `Kind.Snapshot` decode 路径的 load-path 规范化 pass**:递归遍历解码的 `state` map 并通过 `Ezagent.URI.parse!/1` 重新解析每个 `%URI{}` 字段。实现位于新的 `Ezagent.Kind.Snapshot.canonicalize_uris/1` 递归助手,从 `decode_state/1` 调用 (在 merge 之前)。选项 (a) — 操作员驱动的 `mix ezagent.snapshot.purge_pre_canonical` 删除 — 文档化为 (b) 在实现期不可行时的**后备**。
- **LOW (cap:// 引用)** — r1 SPEC 实际上没有引用 `cap://` (通过 `grep -n "cap://"` 验证)。Codex r1 标记是假阳性;r2 在 §3.7 明确枚举 6-scheme 允许列表 (`entity, workspace, session, template, resource, system`) 并为 codex r2 审阅者交叉检查留下注释。
- **NIT (zh_cn 内容对齐)** — r2 zh_cn 按 `feedback_bilingual_docs_convention` 翻译全部 r2 EN 内容 (完整章节、完整 §Appendix A 枚举、完整 §Appendix B 测试伪代码)。相同的章节计数、相同的不变量编号、相同的表行。

**先验记忆 (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — 不允许双路径。已有规范化助手;生产者经它路由;边界站点的非规范构造器被**删除** (不是 deprecated,不是 alias,不是 feature-flag)。
- `feedback_completion_requires_invariant_test` — 合并门是一个不变量测试,当未来贡献者重新引入对 Ezagent-scheme URI 的边界 `URI.parse/1`、`URI.new!/1` 或 `URI.new/1` 调用时会失败 (§5)。测试通过 + 手动代码审查**不是**合并门;捕获违规的结构化测试**是**。
- `feedback_register_lookup_key_parity` — 这个 bug 就是 register/lookup-key-parity 教训在 URI 结构表示上的重演。
- `feedback_north_star_plugin_isolation` — Plugin 作者写新的 Behavior 时**不**需要知道 `URI.parse` vs `URI.new!` vs `URI.new`。规范化助手是唯一边界 chokepoint。
- `feedback_uuid_is_canonical_identifier` — 规范形式不能依赖于显示可变字段。URI 的身份是其字符串规范化,`%URI{}` 结构的 `:authority` 字段是伪装成身份的解析器 quirk。
- `feedback_subagent_must_load_project_skills` — impl 子代理 dispatch 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_review_every_pr` — 此 SPEC + impl PR 的 codex review 携带原文 "no mix" 子句。
- `feedback_destructive_migration_anti_pattern` — 见 §4.1/§9:持久化 URI 字符串已经字节相同往返,所以 DB 序列化保持字节相同。**本 SPEC 不需要破坏性 DB 迁移**。(r2 强制的 snapshot load-path 规范化仅在内存 — 无 DB 写/删除。)

**父级 / 历史上下文:**
- `docs/notes/uri-design.md` §5 — SPEC v3 URI 形状规则。本 SPEC 向该文件追加结构化规范化规则 (§5.15 — 在 impl PR 中追加)。
- `apps/ezagent_core/lib/ezagent/uri.ex:124-143` — `Ezagent.URI.parse!/1` **已存在** 且**已使用** strict `URI.new/1`。
- `apps/ezagent_core/lib/ezagent/uri/scheme_registry.ex:16-18` — 6-scheme 允许列表 (`entity, workspace, session, template, resource, system`)。r2 确认:**不存在** `cap://` scheme。
- `apps/ezagent_core/lib/ezagent/capability.ex:320-348` — `Capability.instance_match?/2` 已通过 `URI.to_string/1` 比较。匹配器路径已免疫。
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` — 已有的手写 `URI.parse(URI.to_string(uri))` 往返是本 SPEC 形式化规则的局部、未文档化版本。
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:312` — `:erlang.term_to_binary(state)` 按字面写入 `%URI{}` 字段。r2 §9.2 强制 load-path 规范化以处理迁移前 snapshot。
- `2026-05-27-capability-action-axis.md` — 并发 SPEC,添加 `:action` 字段。独立。
- `2026-05-27-workspace-cap-based-visibility.md` — 并发 SPEC,基于 cap 的可见性。在 URI 轴独立。

---

## 1. 问题陈述 — 精确分歧

### 1.1 分歧

```elixir
URI.parse("entity://user/system/admin")
# %URI{authority: "user", host: "user", path: "/system/admin", ...}

URI.new!("entity://user/system/admin")
# %URI{authority: nil, host: "user", path: "/system/admin", ...}
```

两者 `URI.to_string/1` 产生**相同**的 8 字节序列 `entity://user/system/admin`。作为 `%URI{}` 结构体它们**不**相等。

stdlib `URI.parse/1` 自 Elixir 1.13 起 deprecated,因为它是非严格的 (RFC 2396)。stdlib `URI.new/1` (及 `!` 变体) 是严格的 (RFC 3986),保留 `:authority` 为 nil。两个构造器对同一输入产生结构上不同的 `%URI{}`。

### 1.2 失败路径 (Bug 2 wizard 测试)

`apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66`:

1. `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` 在**编译时**构造 `@admin_uri URI.parse("entity://user/system/admin")` — authority:"user"。
2. wizard 的 `EzagentWeb.LiveAuth.parse_entity_uri/1` 经 `Ezagent.URI.parse!/1` 路由 — authority:nil。
3. 两个 `%URI{}` 到达 `grant_owner_orchestrator_admin_cap/3`。
4. `has_equiv?` 检查使用 `cap.instance == want.instance` 原始结构相等。差在 `:authority`,所以为 `false`。
5. grant 进入 `check_grant_authorized/2`,其 `caller == owner` 短路也是原始结构相等。落到 `{:error, :grant_not_owner}`。

`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` 的手写 `URI.parse(URI.to_string(uri))` 往返为 `Session.spawn_from_template/2` 路径修补**同一** bug,但**没有**为直接 `EzagentDomainChat.create_session/3` 路径修补。这种 parity 漂移**就是** bug。

### 1.3 Bug 类别

代码库任何位置原始 `==` 两个 `%URI{}` 结构体,当生产者可能使用不同构造器时,就是静默的授权拒绝。

代码库 (按 r2 `rg -n "URI\.(parse|new!?)\(" apps/*/lib`) 在 `apps/*/lib/` 有 284 个生产构造器站点:165 个 `URI.parse/1`、72 个 `URI.new!/1`、47 个 `URI.new/1`。

---

## 2. 决策

**选项 D — 边界处的单一规范构造器。** 采纳。

`Ezagent.URI.parse!/1` 成为**所有** scheme 在 SchemeRegistry allowlist 中的 `%URI{}` 的构造器。所有生产代码通过 `Ezagent.URI.parse!/1` 路由 URI-from-string。直接 stdlib `URI.parse/1` 从生产代码删除。直接 stdlib `URI.new!/1` 从生产代码删除,**除了** `?action=...` query-bearing 形式 (§3.4) 和编译时模块属性 (§3.5)。直接 stdlib `URI.new/1` (非 bang) 从生产代码删除,**除了**文档化的外部 URI fallback 允许列表 (§3.7,见 §5.2.1 允许列表枚举)。

为什么选 D 而非 A/B/C:见 §7。

Chokepoint 已存在。SPEC 是**提升**它 (形式化规则、扫除生产者、添加不变量测试) 而非引入它。

---

## 3. 语义 — 规范 URI 规则

### 3.1 规则 (一句)

**对于 scheme 在 `Ezagent.URI.SchemeRegistry` 中的任何 URI (即 Ezagent-domain URI),规范 `%URI{}` 内存表示是 `Ezagent.URI.parse!(string)` 返回的。任何代码路径不得通过其他方式构造 Ezagent-scheme `%URI{}`。**

### 3.2 "规范"保证

给定两个通过 `Ezagent.URI.parse!/1` 在 `URI.to_string/1` 相同字符串输入上产生的 `%URI{}` 值 `a` 和 `b`:

1. **结构相等:** `a == b` 为 `true`。
2. **模式匹配:** `%URI{scheme: s, host: h, path: p} = a` 和 `b` 绑定相同的 `s/h/p`。
3. **`:authority` 字段:** `a.authority == b.authority == nil` (RFC 3986)。
4. **往返:** `URI.to_string(Ezagent.URI.parse!(URI.to_string(a))) == URI.to_string(a)`。
5. **DB 往返:** `Ezagent.Ecto.URI.load(Ezagent.Ecto.URI.dump(a) |> elem(1)) == {:ok, a}`。

(1) 是承载保证。(2)–(5) 是衍生。

### 3.3 谁调用 `Ezagent.URI.parse!/1`

五个边界表面 (字符串进入处):

**B1. CLI 输入。** `apps/ezagent_cli/lib/ezagent_cli/{exec,dispatch,tree_builder,coercion}.ex` 已经将字符串解析为 URI;SPEC 扫除将这里的每个 `URI.parse/1` / `URI.new/1` / `URI.new!/1` 替换为 `Ezagent.URI.parse!/1`。

**B2. HTTP / Phoenix params。** `apps/ezagent_web/lib/ezagent_web/live_auth.ex:341` 已经调用 `Ezagent.URI.parse!/1`。

**B3. DB load。** `Ezagent.Ecto.URI.load/1` 今天使用 `URI.new/1`。Ezagent-scheme 字符串迁移到 `Ezagent.URI.parse!/1`;非 Ezagent scheme 回退到普通 `URI.new/1`。见 §3.7 双回退契约。

**B4. Snapshot reload。** `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:160` (`URI.new`), `:361` (`URI.parse`), `:159-164` (`URI.new` in `reconcile_after_load_behaviors`)。全部迁移到 `Ezagent.URI.parse!/1`。失败 (raise) 冒泡到 supervisor。r2 §9.2 **新增**强制的 `canonicalize_uris/1` pass 处理嵌入 `URI.parse`-built `%URI{}` 结构的迁移前 snapshot。

**B5. 外部 plugin payload。** 迁移到 `Ezagent.URI.parse!/1` 包在 try/rescue 在边界处 (Invariant #9)。

### 3.4 构造 query-bearing dispatch target

代码库模式 `URI.new!("#{URI.to_string(uri)}?action=behavior.action")` (89 个生产站点)。Carve-out:这是生产中**唯一**允许 stdlib `URI.new!/1` 的情况。

### 3.5 编译时常量

模块属性如 `@admin_uri` 需要编译时可调用的形式。**Route 1:** 在编译时使用 `URI.new!/1` (严格规范形式)。Carve-out:**编译时**模块属性持有硬编码 URI **可以**使用 `URI.new!/1`。不变量测试 (§5) 捕获 `@constant URI.parse(...)` 但允许 `@constant URI.new!(...)`。

### 3.6 dispatch 内的生产者

`Ezagent.URI.instance/1` 从规范输入派生 `%URI{}`。无需更改。
`Capability.workspace_of/1` 通过 `URI.new!("workspace://" <> workspace_name)` 构造。按构造规范。
`Ezagent.URI.entity_workspace_uri/1` 使用 `URI.new!/1`。按构造规范。

### 3.7 非 Ezagent-scheme URI (6-scheme 允许列表)

SchemeRegistry 允许列表固定为 6 个 scheme (`apps/ezagent_core/lib/ezagent/uri/scheme_registry.ex:16-18`):

```
entity, workspace, session, template, resource, system
```

**没有 `cap://` scheme。** (r1 codex 将此标记为 LOW — r2 验证为假阳性;r1 SPEC 文本未引用 `cap://`。r2 为 r2 codex 审阅者留下此明确注释。)

外部 URI 经普通 stdlib `URI.new/1` 路由:

```elixir
def load(s) when is_binary(s) do
  try do
    {:ok, Ezagent.URI.parse!(s)}
  rescue
    ArgumentError -> URI.new(s)  # 外部 scheme — 严格但无 allowlist
  end
end
```

### 3.8 什么保持原始 `URI.parse/1`

**仅**文档/注释/inspect/模块级 docstring 中为教学目的说明 deprecated 形式的。不变量测试 (§5) 排除 `.md` 文件和注释 / `@moduledoc` 字符串中的行。

---

## 4. 迁移计划

### 4.1 阶段顺序 (r2 穷尽调用点清单)

PR-1 (本 SPEC): 无代码。SPEC 合并供 codex adversarial-review。

PR-2: 删除-并-扫除,一次一个生产 app。r2 清单来自 `rg -n "URI\.(parse|new!?)\(" apps/*/lib`:

| App | 计数 | 备注 |
|---|---|---|
| `apps/ezagent_core/` | 28 | 包含 `uri.ex` (allowlisted)、`ecto/uri_type.ex` (§3.7 双 fallback)、`kind/snapshot.ex` (§9.2)、`system_principal/*`、`capability.ex`、`capability_registry.ex`、`presence.ex`、`audit.ex`、`notifications.ex`、`notification_subscriptions.ex`、`persistence.ex`、`agent_lineage.ex`、`entity/system.ex`、`capability/parser.ex`、`runtime/pid_file.ex`、`routing/resolver.ex`、`workspace_registry.ex`。 |
| `apps/ezagent_domain_identity/` | 15 | `entity/user.ex:29,30` (§3.5 常量)、`identity.ex:45,105,152,161,188,265`、`entity_presenter.ex:61`。 |
| `apps/ezagent_domain_chat/` | 78 | 重站点。`entity/session.ex` (删除 303-307 手写)、`behavior/chat.ex`、`behavior/template.ex`、`orchestrator/{tools,mcp_registry,mcp_socket,health}.ex`、`chat/read_marker.ex`、`template/generic_session.ex`、`entity/{agent,agent_template,session_template}.ex`。 |
| `apps/ezagent_domain_workspace/` | 18 | `workspace.ex:261,299,358,446,482,696,744,789,820`、`workspace/loader.ex:262,321`、**`workspace/store.ex:203,212`** (r2 新增)、`entity/workspace.ex:83`、`behavior/workspace.ex:888,930,1225`、加 mix task `agent.create.ex:231` (r2 操作员面对生产)。 |
| `apps/ezagent_domain_external_mirror/` | 11 | **r2 拒绝 r1 "0 生产更改"**。命中:`adapter_install.ex:197`、`worker_spawn.ex:230`、`external_mirror.ex:209,250,391,550`、`behavior/external_mirror.ex:821`、`behavior/external_mirror_worker.ex:640,676`,加 mix task `ezagent_external_mirror_cli.ex:161,220`。 |
| `apps/ezagent_domain_agent_bridge/` | 7 | `registry.ex:98,111`、`token_store.ex:55,69`、`socket.ex:21`、`channel.ex:34,80`。 |
| `apps/ezagent_domain_ui/` | 5 | `primitives.ex:103` + 4 其他。 |
| `apps/ezagent_web/` | 14 | `live_auth.ex:341` (已 parse!)、`home_live.ex:170,197`、`api_v1_controller.ex:117,201`、`workspace_switch_controller.ex:65`、`uploads_controller.ex:236`。 |
| `apps/ezagent_cli/` | 7 | `dispatch.ex:125,128,136,264`、`exec.ex:151`、`tree_builder.ex:216`、`coercion.ex:53`。 |
| `apps/ezagent_plugin_liveview/` | 70 | 重站点。16 个 LV 文件;所有 `case URI.new(uri_str)` 模式经 `parse!/1` rescue 路由。 |
| `apps/ezagent_plugin_cc/` | 10 | `channel.ex:102,109`、`socket.ex:24`、`template/cc_agent.ex:254`,加 mix tasks `seed_cc_agent.ex:62,63,142` + `seed_cc_sandbox.ex:201,243` (r2 操作员面对生产)。 |
| `apps/ezagent_plugin_feishu/` | 8 | `binding_policy.ex:241,267`、`mention_parser.ex:77`、`behavior/user_binding.ex:482`,加 mix task `ezagent_external_mirror_migrate_feishu_bindings.ex:153` (r2 操作员面对生产)。 |
| `apps/ezagent_plugin_curl_agent/` | 4 | `behavior/curl_agent.ex:293,315`、`template/curl_agent.ex:73`。 |
| `apps/ezagent_plugin_echo/` | 5 | `behavior/echo.ex:142,213`、`template/echo_agent.ex:117,159`。 |
| `apps/ezagent_plugin_np/` | 4 | `behavior/np_agent.ex:277,299`、`template/np_agent.ex:79,128`。 |
| **总计** | **284** | r2 穷尽 (165 `URI.parse`、72 `URI.new!`、47 `URI.new`)。 |

PR-3: 不变量测试 (§5)。

PR-4: 追加 `docs/notes/uri-design.md` §5.15。

**无 DB 迁移。** 持久化字符串无论构造器都按字节相同往返 `URI.to_string/1`。Bug 仅在内存中。(r2 §9.2 新增内存中的 snapshot load-path 规范化 — 仍无在盘迁移。)

### 4.2 删除-不-保留契约 (r2 扩展目标)

按 `feedback_let_it_crash_no_workarounds`:每个生产 `URI.parse/1`、`URI.new!/1` (carve-out 外) 和 `URI.new/1` (allowlist 外) 调用站点被**替换**,不保留共存。无过渡 shim。

**r2 扫除目标 (从 r1 扩展)** — 操作员面对产物本 SPEC 视为生产,因为它们构造 URI 结构体后被持久化或 dispatch:

- `apps/*/lib/` — 每个生产 `.ex` 文件 (原 r1 范围)。
- **`apps/*/lib/mix/tasks/` — 每个 mix task (r2 新增)。** 操作员驱动的种子/迁移/修复流程,写回非规范结构体到系统,会从维护路径重新创建原始 bug。枚举站点:
  - `apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex:161,220`
  - `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent_external_mirror_migrate_feishu_bindings.ex:153`
  - `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex:201,243`
  - `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex:62,63,142`
  - `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex:231`
  - `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.token.ex:75`
  - `apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex:504` (测试 harness — 实现 PR 决定)。
- **`scripts/` — 操作员 shell 脚本 (r2 新增)。** 将字符串管道到 mix tasks 的 shell 脚本无需单独扫除目标。**r3 例外:** 任何嵌入 `elixir -e '...'` 或 `iex --eval '...'` body 构造 `%URI{}` 的 `*.sh` 在范围内 — body 是对生产 BEAM 运行的活 Elixir。扫除 grep:`rg -n "URI\.(parse|new!?)\(" scripts -g '*.sh'`。
- **`docs/notes/evidence/` — 固定的 demo/repro 脚本 (r2 新增)。** 同 `scripts/`。**r3 例外:** codex r2 发现 `docs/notes/evidence/pr49-demo-rpc-script.sh` 在第 33、43、53 行嵌入活的 `elixir -e` 块构造 `URI.parse/1`。扫除 grep:`rg -n "URI\.(parse|new!?)\(" docs/notes/evidence -g '*.sh' -g '*.exs'`。

### 4.3 编译时常量迁移

具体更改:

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` — `@admin_uri URI.parse("entity://user/system/admin")` → `@admin_uri URI.new!("entity://user/system/admin")`。
- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:30` — `@system_bootstrap_uri URI.parse(...)` → `URI.new!(...)`。
- `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:98` — `@bootstrap_granted_by URI.parse(...)` → `URI.new!(...)`。
- `apps/ezagent_core/lib/ezagent/entity/system.ex:47` — `URI.parse("system://routing/default")` → `URI.new!(...)`。

### 4.4 测试 fixture 迁移

测试文件 (`test/**/*.exs`) **可以**自由使用 `URI.parse/1`、`URI.new!/1` 或 `URI.new/1`。不变量测试 (§5) **仅**扫描 `apps/*/lib/`,不扫描 `test/`。

### 4.5 已经正确的站点 (无更改)

- `apps/ezagent_core/lib/ezagent/uri.ex` — 规范化助手本身。
- `apps/ezagent_core/lib/ezagent/routing/resolver.ex:353, 388` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_python/lib/ezagent/domain/python.ex:56` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex:45` — 注释引用规范形式,代码已对齐。
- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.{user,agent,workspace}.*.ex` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_user_admin.ex:204` — 已用 `Ezagent.URI.parse!/1`。
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex:246` — 已用 `Ezagent.URI.parse!/1`。

---

## 5. 不变量测试 (r2 — 也覆盖 `URI.new/1`)

**文件:** `apps/ezagent_core/test/invariants/uri_canonicalization_test.exs` (新)。

**目的:** 捕获未来贡献者在 Ezagent-scheme 边界生产代码中引入 `URI.parse/1`、stdlib `URI.new!/1` 或 stdlib `URI.new/1`。不变量测试是 SchemeRegistry chokepoint 强制器;规范模块外的任何裸 stdlib URI 构造器都是回归。

**结构** — 五个正交断言 (r2 新增 §5.2.1 用于 `URI.new/1`):

### 5.1 生产 lib/ 无 `URI.parse/1` (含 mix tasks)

正则 `~r/\bURI\.parse\(/`。注释检测启发式。Glob `apps/*/lib/**/*.ex` 覆盖 `apps/*/lib/ezagent/**` (原 r1 范围) **和** `apps/*/lib/mix/tasks/**` (r2 新增范围,按 §4.2)。

唯一允许列表文件:`apps/ezagent_core/lib/ezagent/uri.ex`。

### 5.2 生产 lib/ 无 stdlib `URI.new!/1` 除 §3.4/§3.5 carve-out

`is_query_target_idiom?/1`: 行同时包含 `URI.new!(` 和 `?action=`。`is_module_attribute?/1`: `~r/^\s*@\w+\s+URI\.new!\(/`。

### 5.2.1 (r2 — 新) 生产 lib/ 无 stdlib `URI.new/1` 除外部 URI fallback 允许列表

非 bang `URI.new/1` 返回 `{:ok, uri} | {:error, _}`,被 `case URI.new(s) do` 模式广泛使用。它和 bang 变体一样绕过 SchemeRegistry 验证。r2 新增此检查。

```elixir
test "no stdlib URI.new/1 in apps outside the external-URI fallback allowlist" do
  violations =
    for path <- lib_files,
        {line, lineno} <- Enum.with_index(File.stream!(path), 1),
        matches_uri_new_no_bang?(line),
        path not in @uri_new_allowlist,
        not in_comment_or_docstring?(line) do
      {path, lineno, String.trim(line)}
    end
  assert violations == [], ...
end
```

**`matches_uri_new_no_bang?/1`** 必须区分 `URI.new(` 和 `URI.new!(` 即使**两者出现在同一行** (codex r2 HIGH;codex r3 发现 r3 的计数公式也是错的)。

修复是**单个 PCRE 负向前瞻正则**:`~r/\bURI\.new(?!!)\(/`。前瞻 `(?!!)` 拒绝 `new` 紧跟 `!` 的匹配。Elixir 的正则**是** PCRE,所以这直接工作。

```elixir
defp matches_uri_new_no_bang?(line) do
  # 负向前瞻:匹配 URI.new( 其中 `new` **不**紧跟 `!`。
  # 捕获 `URI.new(s)` 和 `URI.new(s); URI.new!(t)` 等混合。
  Regex.match?(~r/\bURI\.new(?!!)\(/, line)
end
```

通过 `elixir /tmp/test.exs` 实际验证以下输入:

| 行 | `matches_uri_new_no_bang?/1` |
|---|---|
| `foo = URI.new(s)` | `true` (捕获) |
| `foo = URI.new!(s)` | `false` (正确 — §5.2 领域) |
| `foo = URI.new(s); bar = URI.new!(t)` | `true` (捕获 — codex r2 HIGH 对抗性案例) |
| `foo = URI.new!(s); bar = URI.new(t)` | `true` (捕获 — 反向顺序) |
| `foo = URI.new!(s); bar = URI.new!(t)` | `false` |
| `# URI.new(s)` | 原始 `true`,但 `in_comment?/1` 先剥离 |

impl PR 在不变量测试模块中为上面每一行添加单元测试 (见 §5.5 / Appendix B)。

**允许列表** — 合法调用裸 `URI.new/1` 的文件:

| 文件 | 理由 |
|---|---|
| `apps/ezagent_core/lib/ezagent/uri.ex` | 规范模块本身 — `parse!/1` 内部包装 `URI.new/1`。这是 stdlib `URI.new/1` 可以存在的**唯一**位置。 |
| `apps/ezagent_core/lib/ezagent/ecto/uri_type.ex` | 按 §3.7 双 fallback 契约的外部 URI fallback — `Ezagent.URI.parse!/1` rescue 子句对非 Ezagent scheme fall-through 到 `URI.new/1`。 |

所有**其他** `URI.new/1` 站点 (代码库 45 个生产命中,按 r2 grep) **必须**迁移到 `Ezagent.URI.parse!/1` 包在 try/rescue 在适当边界。示例:

- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:160` — 当前 `case URI.new(uri_str)` → 迁移到 `Ezagent.URI.parse!/1`。
- `apps/ezagent_core/lib/ezagent/runtime/pid_file.ex:274` — 当前 `URI.new("entity://...")` → 迁移到 `parse!/1`。
- `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex:77` — 当前 `case URI.new(uri_str) do` → 迁移到 `parse!/1` rescue (Invariant #9 — 入站表面优雅错误)。
- `apps/ezagent_core/lib/ezagent/capability/parser.ex:117` — 当前 `case URI.new(instance_str) do` → 迁移到 `parse!/1`。
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/*.ex` (多个站点) — 当前 `case URI.new(decoded) do` → 迁移到 `parse!/1` rescue。

允许列表**小且每个条目有理由**。任何未来贡献者需要新条目必须同时更新本 SPEC + 不变量测试允许列表常量。

### 5.3 规范 URI 往返

```elixir
for s <- [
  "entity://user/system/admin",
  "entity://agent/team-alpha/cc_demo",
  "session://default/system/main",
  "workspace://team-alpha",
  "system://bootstrap/default"
] do
  a = Ezagent.URI.parse!(s)
  b = Ezagent.URI.parse!(URI.to_string(a))
  assert a == b
  assert a.authority == nil
  assert URI.to_string(a) == s
end
```

### 5.4 Bug 2 特定表面的 parity 测试

```elixir
test "admin_uri canonical-equal across constructors" do
  from_const = Ezagent.Entity.User.admin_uri()
  from_parse = Ezagent.URI.parse!("entity://user/system/admin")
  {:ok, from_load} = Ezagent.Ecto.URI.load("entity://user/system/admin")
  assert from_const == from_parse
  assert from_const == from_load
  assert from_const.authority == nil
end
```

这是会**捕获** Bug 2 的测试 (在 wizard 测试重现之前)。

### 5.5 (r2 — 新) Snapshot load-path 规范化往返

```elixir
test "snapshot decode_state canonicalizes embedded %URI{} structs" do
  pre_migration_state = %{
    chat: %{owner: URI.parse("entity://user/system/admin"), members: [URI.parse("entity://user/team-alpha/alice")]}
  }
  binary = :erlang.term_to_binary(pre_migration_state)
  decoded = :erlang.binary_to_term(binary, [:safe])
  canonicalized = Ezagent.Kind.Snapshot.canonicalize_uris(decoded)

  assert canonicalized.chat.owner.authority == nil
  assert Enum.all?(canonicalized.chat.members, &(&1.authority == nil))
  assert canonicalized.chat.owner == Ezagent.URI.parse!("entity://user/system/admin")
end
```

这是锁定 r2 §9.2 强制 snapshot 规范化的测试。

### 5.6 为什么这五个一起通过 `feedback_completion_requires_invariant_test` 门

§5.1 + §5.2 + §5.2.1 + §5.3 + §5.4 + §5.5 各捕获不同的重新引入形态:

- §5.1 捕获贡献者从旧代码或 stdlib docs 复制粘贴 `URI.parse(...)`。
- §5.2 捕获贡献者在 carve-out 外使用 `URI.new!/1`。
- **§5.2.1 (r2 新) 捕获贡献者在小允许列表外使用裸 `URI.new/1` (r1 未捕获的情况)。**
- §5.3 捕获贡献者破坏 `parse!/1` 的往返不变量。
- §5.4 捕获 Bug-2 admin_uri parity 特定表面。
- **§5.5 (r2 新) 捕获贡献者删除 load-path 规范化助手,这会静默回归跨版本 snapshot。**

部分迁移 (95% 站点用规范但 1 个边界跳过) 被 §5.1 或 §5.2 或 §5.2.1 捕获。不变量测试基于 grep,对 `apps/*/lib/**/*.ex` (含 mix tasks 按 r2 §4.2) 穷尽。

---

## 6. Plugin 隔离分析

### 6.1 Plugin 作者今天看到什么

Plugin 作者在三个上下文构造 URI:slice 初始化、dispatch target 构造、外部 payload 反序列化。

SPEC 下:Plugin 作者**不**需要知道 `URI.parse/1` 存在、产生不同结构、`URI.new/1` 在允许列表外也被禁止 (不变量测试强制;作者只是不用它)、`:authority` 是字段。

skill `ezagent-developer/anti-patterns.md` 获得新条目:"不要在 lib/ 中使用 stdlib `URI.parse/1`、`URI.new!/1` 或 `URI.new/1`。对所有 Ezagent-scheme URI 使用 `Ezagent.URI.parse!/1`。不变量测试强制执行。"

### 6.2 Chokepoint 留在 core

`Ezagent.URI.parse!/1` 在 `apps/ezagent_core/` (core 层)。无 plugin 拥有规范化逻辑。

### 6.3 新 scheme 的前向兼容

当 plugin 通过 `Ezagent.SpawnRegistry.register/2` 注册新 scheme 时,`Ezagent.URI.parse!/1` 自动接受 — 无需 `parse!/1` 更改。

---

## 7. 权衡 / 替代考虑

### 7.1 选项 A — 全部迁移到 `URI.new!/1`

**优:** 简单。纯 stdlib。
**劣:** 无 SchemeRegistry chokepoint。一个站点回退,bug 回归。
**拒绝。**

### 7.2 选项 B — 全部迁移到 `URI.parse/1`

**优:** 处处保留现有 `:authority == "user"` 形式。
**劣:** `URI.parse/1` 自 1.13 deprecated。锁定到 deprecated API。违反 RFC 3986。
**拒绝。**

### 7.3 选项 C — 通过 `URI.to_string/1` 比较

**优:** 局部修复。
**劣:** 违反 `feedback_let_it_crash_no_workarounds`。
**拒绝。**

### 7.4 选项 D — 规范化助手 (选定)

**优:** 单一 chokepoint。Plugin 隔离。RFC 3986 对齐。通过 §5 测试强制。
**劣:** 迁移触及约 284 个生产站点 (r2 校正计数)。§3.4 / §3.5 的 `URI.new!/1` carve-out 在生产引入两种"ok"形式。
**净:** 优大于劣。Carve-out 在 §5.2 + §5.2.1 精确形式化。

### 7.5 子选项 D' — 引入 `Ezagent.URI.canonical/1`

normalize-from-struct 变体。

r2 备注:`Ezagent.Kind.Snapshot.canonicalize_uris/1` (§9.2 (b) 中的递归 walker) 实际上是此的 struct-walking 版本 — 但限定于单一热路径 (snapshot decode)。出 §10 OQ-1。

---

## 8. 与并发 SPEC 的交互

### 8.1 `2026-05-27-capability-action-axis.md` (#410)

独立。`identity_key/1` 已经通过 `URI.to_string/1` 路由。无代码级交互。

### 8.2 `2026-05-27-workspace-cap-based-visibility.md` (#423)

本 SPEC 下两者规范。`Workspace.Store.list_all/0` 自身在 `store.ex:203,212` 使用 `URI.parse(row.uri)` — r2 清单将这些添加到扫除目标。

### 8.3 前向兼容

任何引入新 URI-shape 约束的未来 SPEC 都在规范形式之上分层。

---

## 9. 向后兼容 / 外部 API

### 9.1 持久化数据

DB 行 (`kind_snapshots`, `users.caps_json`, `messages.sender`, `routing_rules`, `template_tags`, `workspaces.member_uris`) 都存储 URI 字符串。无论内存结构是 `URI.parse`-built 还是 `URI.new!`-built,字符串形式字节相同。**无需 DB 迁移。** Snapshot reload 路径产生规范结构体因为 encode 侧写入规范结构体 — **迁移后**。r2 §9.2 处理迁移前情况。

### 9.2 `:erlang.binary_to_term/2` 在旧序列化 %URI{} — r2 强制 load-path 规范化

**r2 将此从可选 (OQ-4) 提升为强制。**

如果 `kind_snapshots` 行在本 SPEC 迁移之前以 `URI.parse`-built `%URI{}` 烘焙到 snapshot 二进制中写入 (通过 `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:312` 的 `:erlang.term_to_binary(state)`),SPEC 后回放该行重现旧结构 (`:authority == "user"`)。

`apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex:168-170` 使用 `:erlang.binary_to_term(binary, [:safe])`。`:safe` 标志拒绝未知 atom 但**不**规范化 URI 结构体。

**这意味着:即使代码迁移后,从迁移前 snapshot 重新水合的运行 Kind 内存中仍有非规范 URI,直到下次重载。dispatch 边界的严格 `==` 比较会静默失败。**

#### 9.2.1 缓解选择 — 选项 (b) load-path 规范化 (选定)

SPEC 强制 **load-path 规范化** 作为结构化修复:

1. 添加 `Ezagent.Kind.Snapshot.canonicalize_uris/1` — 解码 `state` map 上的递归 walker。
2. 对发现的每个 `%URI{}` 字段 (任何嵌套深度 — map 值、list 元素、tuple 元素、嵌套 struct 字段),通过 `Ezagent.URI.parse!/1` 重新解析以产生规范形式。对非 Ezagent scheme,URI 通过 §3.7 fallback 不变通过。
3. 在 `kind/snapshot.ex:96` 的 `Map.merge` 步骤**之前**在 snapshot decode 路径调用 `canonicalize_uris/1`。

```elixir
# 伪代码 — 在 Ezagent.Kind.Snapshot
#
# 子句顺序是承载性的 (codex r2 HIGH 修复):
#   1. %URI{} 子句必须在通用 struct/map 子句之前,否则 %URI{} 本身
#      是 struct 会先命中错误子句。
#   2. 自定义 struct 解构到 map、遍历、然后重新 struct (struct/2)
#      以保留 struct 形状。
#   3. map key AND value 都被遍历 (罕见但有效:%{%URI{} => v})。
#   4. tuple 按元素遍历 (Tuple → list → walk → Tuple)。
#   5. %URI{} 子句调用 Ezagent.URI.parse!/1 — 规范 chokepoint
#      — 不是裸 URI.new/1。非 Ezagent scheme (§3.7 外部 URI fallback)
#      被捕获并不变通过。

def canonicalize_uris(%URI{} = uri) do
  s = URI.to_string(uri)

  try do
    Ezagent.URI.parse!(s)
  rescue
    # 外部 (非 Ezagent) scheme — §3.7 fallback。
    ArgumentError ->
      case URI.new(s) do
        {:ok, canonical} -> canonical
        _ -> uri
      end
  end
end

def canonicalize_uris(%_{} = struct_) do
  # 自定义 struct — 解构到 map (丢弃 :__struct__)、遍历、重新 struct。
  mod = struct_.__struct__

  struct_
  |> Map.from_struct()
  |> canonicalize_uris()
  |> then(&struct(mod, &1))
end

def canonicalize_uris(state) when is_map(state) do
  Map.new(state, fn {k, v} -> {canonicalize_uris(k), canonicalize_uris(v)} end)
end

def canonicalize_uris(state) when is_list(state) do
  Enum.map(state, &canonicalize_uris/1)
end

def canonicalize_uris(state) when is_tuple(state) do
  state
  |> Tuple.to_list()
  |> Enum.map(&canonicalize_uris/1)
  |> List.to_tuple()
end

def canonicalize_uris(other), do: other
```

上面的子句顺序规则本身是 impl PR 必须保留的不变量。§5.5 不变量测试演练每种形态 (URI / 自定义 struct / 嵌套 map / map-as-key / list / tuple) 以锁定契约。

**为什么选项 (b) 而非 (a) 操作员删除:**

- (a) `mix ezagent.snapshot.purge_pre_canonical` 删除所有 `kind_snapshots` 行 + 要求操作员重启 `phx.server`。代价:每个 Kind 的在飞状态在部署时丢失。运营负担。易忘。
- (b) Load-path 规范化自动处理所有 snapshot,零操作员负担。代价是 load 时的单遍递归遍历,在 Kind 生命周期内分摊。按 `feedback_let_it_crash_no_workarounds`,这是结构化修复。

选项 (a) 文档化为 (b) 在实现期不可行时的**后备**。impl PR 的第一个 commit **必须**落地 (b);仅当 codex impl-review 识别 blocker 时 impl PR 才可枢转到 (a)。

#### 9.2.2 边缘情况 (r3 — 由 §9.2.1 伪代码子句处理)

- **嵌套 map/list 字段内的嵌套 `%URI{}`。** 递归 walker 处理任意深度 (Map → Map → URI、Map → List → URI、List → Tuple → URI)。由 §5.5 不变量测试案例 `deep: %{nested: %{list: [...]}}` 锁定。
- **自定义 struct (`%MyBinding{uri: %URI{}}`) 内的 `%URI{}`。** `%_{} = struct_` 子句 (因子句顺序原因放在 `is_map(state)` 子句**之前**) 通过 `Map.from_struct/1` 解构、遍历 map、通过 `struct(mod, ...)` 重新 struct。`%URI{}` 子句必须在 `%_{} = struct_` **之前**,使 URI 结构体本身 (它**是** struct) 先被 URI 子句捕获。由 §5.5 测试案例 `binding: %MyBinding{uri: ...}` 锁定。
- **`%URI{}` 作为 map key。** 罕见但可能 (`%{%URI{} => value}`)。Map 子句的 `Map.new(state, fn {k, v} -> {canonicalize_uris(k), canonicalize_uris(v)} end)` 遍历**两者** key 和 value (codex r2 HIGH 发现先前伪代码与此声明不匹配;r3 修复)。由 §5.5 测试案例 `per_member: %{... => :online}` 锁定。
- **`%URI{}` 作为 tuple 元素。** `is_tuple(state)` 子句转为 list、遍历、转回。由 §5.5 测试案例 `last_event: {:joined, %URI{}, ts}` 锁定。
- **跨 OTP `binary_to_term` 兼容。** `:erlang.binary_to_term` 保留编码的 struct 形状。无论 OTP 版本都修正。
- **snapshot state 内的非 Ezagent-scheme URI。** 外部 URI (如 Feishu `chat_id` 作为 `URI.parse("https://...")` 存储) 流经 `%URI{}` 分支中的 §3.7 fallback rescue 子句:`Ezagent.URI.parse!/1` 在非允许列表 scheme 上 raise,rescue 捕获并通过 strict `URI.new/1` 重新规范化。即使绕过 SchemeRegistry 检查,URI 最终也有 `:authority == nil` (RFC 3986)。

### 9.3 操作员面对的 URI (r2 — 扩展范围;r3 — 固定脚本也在范围内)

脚本 (`scripts/*.sh`)、文档 (`docs/**/*.md`)、scenario (`scenarios/*.yaml`)、mix-task 帮助文本 — **大部分**引用 URI **字符串**,不引用 struct 形式。这些产物**无更改**。

**例外 — 嵌入活 Elixir 的固定 evidence/repro 脚本 (r3 新增)。** Codex r2 发现 `docs/notes/evidence/pr49-demo-rpc-script.sh` 在第 33、43、53 行包含 `elixir -e '...'` 块通过 `URI.parse/1` 构建活的 `%URI{}` 并 RPC 到运行中的 BEAM。任何嵌入活 Elixir 的固定 repro 脚本本 SPEC 视为生产代码 — 它构造的 URI 结构体流经相同的 dispatch/比较路径。

r3 扩展扫除 grep 包括 `docs/notes/evidence/*.sh` 和任何承载 `elixir -e` / `iex --eval` body 的其他 `*.sh`:

```bash
rg -n "URI\.(parse|new!?)\(" docs/notes/evidence scripts -g '*.sh' -g '*.exs'
```

impl PR 处理每个命中通过:
- 重写嵌入的 Elixir 使用 `Ezagent.URI.parse!/1`,或
- 删除固定脚本如果它是一次性取证产物 (通过 `git log` 验证脚本捕获日期后从未再次运行)。

**操作员面对的 mix tasks** 在 `apps/*/lib/mix/tasks/` 下**构造** URI **结构体**,后被持久化或 dispatch。r2 将这些添加到扫除目标 (按 §4.2 扩展枚举)。枚举命中:

- `apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex:161, 220`
- `apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent_external_mirror_migrate_feishu_bindings.ex:153`
- `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_sandbox.ex:201, 243`
- `apps/ezagent_plugin_cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex:62, 63, 142`
- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex:231`
- `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.token.ex:75`
- `apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex:504` (测试 harness — 实现 PR 决定)

操作员驱动的种子/迁移/修复流程写回非规范结构体到系统会从维护路径重新创建原始 bug。

CLI 命令接受 URI 字符串 — `Ezagent.URI.parse!/1` 是边界。已对齐。

### 9.4 外部 plugin payload (Feishu, MCP)

Feishu webhook 事件交付裸字符串,在 plugin 中转为 URI。已经在 case/rescue 中优雅降级 (Invariant #9)。迁移到 `parse!/1` 保留包装。

### 9.5 API v1 controller

`api_v1_controller.ex:201` query-target 形式。保持 `URI.new!/1`。

---

## 10. 给 Allen 的开放问题

**OQ-1.** §7.5 — 是否将 `Ezagent.Kind.Snapshot.canonicalize_uris/1` (§9.2 递归 walker) 提升为通用 `Ezagent.URI.canonical/1` 助手?当前选择:**否** (推迟直到出现第二个使用站点)。Walker 对 r2 是 snapshot 私有的。

**OQ-2.** §3.4 — 现在引入 `Ezagent.URI.with_action(uri, behavior, action)` 完全消除 `URI.new!/1` carve-out?当前选择:推迟。

**OQ-3.** §5.1 — 不变量测试依赖正则。注释检测启发式是否够稳健?当前选择:正则 + `# uri-canonical-allow` 抑制注释。

**OQ-4.** ~~§9.2 — reconcile-on-load 还是强制 snapshot 重写?~~ **r2:已解决 — 选项 (b) load-path 规范化强制。见 §9.2.1。**

**OQ-5.** §4.4 — 测试 fixture 扫除是否在范围内?当前选择:**不** (单独跟进)。

---

## 11. Codex adversarial review 问题 (r2)

调度 `codex:codex-rescue` adversarial review r2 时明确问:

**Q1 (根因).** 选项 D 是否真正解决根因,还是转移它?具体:`URI.new!/1` 在两个 carve-out (§3.4 query-target, §3.5 编译时常量) **加上** `URI.new/1` 在 2 文件允许列表 (§5.2.1) 中允许,是否保留一个更小但相似的 bug 类?(预期:§5.2 + §5.2.1 通过正则捕获任何违规。)

**Q2 (枚举完整性 — r2 焦点).** §4.1 清单现在是否真正穷尽?Codex 应:
  1. 独立运行 `rg -n "URI\.(parse|new!?)\(" apps/*/lib --type elixir`。
  2. 逐行交叉检查输出与 §4.1 的每 app 计数 (28+15+78+18+11+7+5+14+7+70+10+8+4+5+4 = 284)。
  3. 标记任何未分类为"迁移"或"允许列表"的命中。

**Q3 (URI.new/1 不变量 — r2 焦点).** §5.2.1 不变量是否正确区分"外部 URI fallback 允许列表"与"内部 URI 必须规范化"?具体:
  - 若贡献者向 `apps/ezagent_plugin_feishu/lib/foo.ex` 添加 `URI.new("entity://...")`,§5.2.1 是否捕获?(预期是 — `foo.ex` 不在允许列表。)
  - 若贡献者向 `apps/ezagent_plugin_liveview/lib/bar_live.ex` 添加 `case URI.new(decoded) do`,§5.2.1 是否捕获?(预期是。)
  - `apps/ezagent_core/lib/ezagent/ecto/uri_type.ex` 是否合法在允许列表?(预期是 — §3.7 双 fallback。)

**Q4 (snapshot 规范化 — r2 焦点).** §9.2 将 OQ-4 提升为强制并选择选项 (b)。验证:
  1. 递归 walker 是否处理嵌套 URI (Map → List → Map → URI)?
  2. Walker 是否处理 URI 作为 map key?
  3. Walker 是否处理自定义 struct (`is_struct/1`) 内的 URI?
  4. Load-path 放置 (在 `kind/snapshot.ex:96` 的 `Map.merge` **之前**) 是否正确?
  5. 跨 OTP 风险:`:erlang.binary_to_term` 在 Elixir 1.13 前 `%URI{}` 上是否正确保留 `:authority` 字段?(预期是 — struct 形状以字段名 + 值编码。)

**Q5 (`URI.to_string` 字节 parity).** §9.1 断言 `URI.to_string/1` 对相同规范字符串的 `URI.parse`-built 和 `URI.new!`-built 产生字节相同输出。验证:
  - 对 `entity://user/system/admin`:两种形式 `to_string` 到 `"entity://user/system/admin"`。
  - 边缘:嵌入 `?action=...` 查询的 URI。验证字节相同。
  - 边缘:`%` 编码路径段。验证字节相同。

**Q6 (并发 SPEC).** §8 断言独立。验证:三个 SPEC 是否有共享代码路径且合并顺序要紧?

**Q7 (plugin 契约).** §6 声称 plugin 作者无需知道 URI quirk。验证:跟随"添加新 Behavior" recipe 的贡献者是否自然写出规范代码?

**Q8 (let-it-crash 合规).** §3.3 B5 外部 payload 解析将 `Ezagent.URI.parse!/1` 包在 try/rescue 中。是 let-it-crash 违规吗?(辩护:按 Invariant #9,入站传输**必须**转换为用户可见的错误反应。)

**Q9 (mix-task 扩展 — r2 焦点).** §4.2 扩展扫除目标包括 `apps/*/lib/mix/tasks/`。是否漏掉操作员面对产物?特别检查 `scripts/` 中的原始 `URI.parse` shell 调用 (不太可能但值得验证)。

**Q10 (zh_cn 内容对齐 — r2 焦点).** zh_cn 伴侣现在内容对齐 (相同章节计数、相同表行、相同不变量编号)?具体:§Appendix A 枚举 + §Appendix B 测试伪代码 — zh_cn 完整携带这些还是仍 defer 到 EN 版本?

**Q11 (cap:// scheme — r2 验证).** Codex r1 LOW 标记 `cap://` 引用。r2 grep 找不到。确认 LOW 是假阳性 (SPEC 文本未引用 `cap://`;SchemeRegistry 有 6 个 scheme:entity、workspace、session、template、resource、system)。

原文子代理约束:**"Do NOT run mix test, mix compile, mix deps.get, or any mix command. Static analysis only."**

---

## 12. 回滚计划

若 impl PR 落地并引起生产回归:

**步骤 1.** 还原 impl PR。持久化数据字节相同 (§9.1)。

**步骤 2.** 恢复 `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` 的手写往返。Bug 2 回归。

**步骤 3.** 临时删除不变量测试。

**步骤 4.** 重新加载任何进程内 snapshot — load-path 规范化助手 (§9.2) 随 impl PR 还原;后续 Kind 重载再次产生非规范结构。这是 SPEC 前行为 (回滚明确恢复)。

**步骤 5.** 提交带回归重现的跟进 issue。重新规范。

**验收:** 还原是机械的 (单次 git revert + 删除不变量测试文件)。

---

## 附录 A — 调用站点枚举 (生产 lib/,r2 穷尽总计 284)

(Codex Q2 挑战目标 — 验证穷尽性,对照 `rg -n "URI\.(parse|new!?)\(" apps/*/lib`。)

### `apps/ezagent_core/lib/` (28 个站点)

- `ezagent/uri.ex:126, 134, 305` — `URI.new/1` 在 `parse!/1` 内 (允许列表)、`URI.new!/1` 在 `entity_workspace_uri` 内 (按构造规范,OK)。
- `ezagent/system_principal.ex:110, 169` — `URI.parse("system://..." <> _)` → 迁移到 `parse!/1`。
- `ezagent/workspace_registry.ex:108` — `URI.parse(w)` → 迁移到 `parse!/1`。
- `ezagent/capability_registry.ex:429` — `URI.parse("system://bootstrap/pr-own-1")` → 迁移到 `parse!/1` (或 `URI.new!/1` 按 §3.5 如果编译时常量)。
- `ezagent/presence.ex:135` — `URI.parse(s)` → 迁移到 `parse!/1`。
- `ezagent/audit.ex:393` — `URI.parse(s)` → 迁移到 `parse!/1`。
- `ezagent/notification_subscriptions.ex:488` — `URI.parse(s)` → 迁移到 `parse!/1`。
- `ezagent/persistence.ex:101` — `URI.parse(uri)` → 迁移到 `parse!/1`。
- `ezagent/capability.ex:809, 877, 955` — 迁移到 `parse!/1`。
- `ezagent/agent_lineage.ex:77` — `URI.parse(s)` → 迁移到 `parse!/1`。
- `ezagent/notifications.ex:180` — `URI.parse(s)` → 迁移到 `parse!/1`。
- `ezagent/entity/system.ex:47` — `URI.parse("system://routing/default")` → `URI.new!` (§3.5)。
- `ezagent/kind/snapshot.ex:160, 361` — 迁移到 `parse!/1`。r2:snapshot.ex 还获得 `canonicalize_uris/1` 助手 (§9.2)。
- `ezagent/system_principal/catalog.ex:98` — `@bootstrap_granted_by URI.parse(...)` → `URI.new!` (§3.5)。
- `ezagent/ecto/uri_type.ex:33, 44` — `URI.new(s)` 在 `cast`/`load` → §3.7 双 fallback (在 §5.2.1 允许列表)。
- `ezagent/capability/parser.ex:117` — `URI.new(instance_str)` → 迁移到 `parse!/1`。
- `ezagent/runtime/pid_file.ex:274` — `URI.new("entity://...")` → 迁移到 `parse!/1`。
- `ezagent/routing/resolver.ex` — 已用 `parse!/1` 在 353, 388。行 277 用 `URI.new!(receiver)` — query-target 邻接,验证。
- `mix/tasks/ezagent.stress.ex:504` — `URI.new!(s)` 测试/mix 助手 — r2 §4.2:操作员面对生产 (impl PR 决定)。

### `apps/ezagent_domain_identity/lib/` (15 个站点)

- `ezagent/entity/user.ex:29, 30` — `@admin_uri`、`@system_bootstrap_uri` → `URI.new!` (§3.5)。
- `ezagent/identity.ex:45, 105, 152, 161, 188, 265` — 混合 → 迁移到 `parse!/1`。
- `ezagent/entity_presenter.ex:61` — `case URI.new(uri_str)` → 迁移到 `parse!/1` rescue。
- `mix/tasks/ezagent.user.token.ex:75` — `URI.parse(uri_str)` → 迁移到 `parse!/1` (r2 §4.2 操作员面对生产)。

### `apps/ezagent_domain_chat/lib/` (78 个站点)

- `ezagent_domain_chat.ex:116, 156, 494, 578, 631` — 混合 → 迁移。
- `ezagent/entity/session.ex` (多个站点,303-307 手写删除)。
- `ezagent/entity/session_template.ex`、`agent_template.ex`、`agent.ex`、`behavior/chat.ex`、`behavior/template.ex`、`chat/read_marker.ex`、`orchestrator/{tools,mcp_registry,mcp_socket,health}.ex`、`template/generic_session.ex`、`application.ex` — 详见 EN Appendix A。

### `apps/ezagent_domain_workspace/lib/` (18 个站点 — r2 扩展)

- `ezagent/workspace.ex:261, 299, 358, 446, 482, 696, 744, 789, 820` — 混合 → 迁移。
- `ezagent/workspace/loader.ex:262, 321` — `URI.parse` → 迁移。
- **`ezagent/workspace/store.ex:203, 212` — r2 新增**:`URI.parse(row.uri)` 和 `parse_uri_or_nil` → 迁移到 `parse!/1`。
- `ezagent/entity/workspace.ex:83` — 迁移。
- `ezagent/behavior/workspace.ex:888, 930, 1225` — 混合;扫除。
- `mix/tasks/ezagent.agent.create.ex:231` — 已按构造规范,r2 §4.2 扩展到 mix tasks。

### `apps/ezagent_domain_external_mirror/lib/` (11 个站点 — r2 拒绝 r1 "0 生产更改")

- **`ezagent/external_mirror/adapter_install.ex:197`** — `session_uri = URI.parse(row.session_uri)` → 迁移到 `parse!/1`。
- **`ezagent/external_mirror/worker_spawn.ex:230`** — `URI.parse("entity://worker/...")` → 迁移。
- **`ezagent/external_mirror.ex:209, 250, 391, 550`** — 多个 `URI.parse("#{...}?action=...")` → 迁移。
- **`ezagent/behavior/external_mirror.ex:821`** — `bound_by: URI.parse(row.bound_by)` → 迁移。
- **`ezagent/behavior/external_mirror_worker.ex:640, 676`** — 迁移。
- `mix/tasks/ezagent_external_mirror_cli.ex:161, 220` — 迁移 (r2 §4.2)。

### `apps/ezagent_domain_agent_bridge/lib/` (7 个站点)

- `ezagent/agent_bridge/registry.ex:98, 111` — 迁移到 `parse!/1`。
- `ezagent/agent_bridge/token_store.ex:55, 69` — 迁移到 `parse!/1`。
- `ezagent/agent_bridge/socket.ex:21` — 迁移。
- `ezagent/agent_bridge/channel.ex:34, 80` — 迁移。

### `apps/ezagent_domain_python/lib/`

- 已用 `Ezagent.URI.parse!/1`。无更改。

### `apps/ezagent_domain_ui/lib/` (5 个站点)

- `ezagent_domain_ui/primitives.ex:103` — `URI.new(str)` → 迁移到 `parse!/1`。
- 4 其他;扫除。

### `apps/ezagent_web/lib/` (14 个站点)

- `live_auth.ex:341` — 已规范。OK。
- `live/home_live.ex:170, 197`、`api_v1_controller.ex:117, 201`、`workspace_switch_controller.ex:65`、`uploads_controller.ex:236` — 混合;扫除。

### `apps/ezagent_cli/lib/` (7 个站点)

- `dispatch.ex:125, 128, 136, 264`、`exec.ex:151`、`tree_builder.ex:216`、`coercion.ex:53` — 迁移到 `parse!/1`。

### `apps/ezagent_plugin_*/lib/`

- 详见 EN Appendix A。包括 plugin_cc、plugin_curl_agent、plugin_echo、plugin_feishu、plugin_liveview (16 个 LV 文件)、plugin_np,及对应 mix tasks。

**总计 284 个生产站点。** Codex Q2 挑战目标。

### Appendix A.1 — r2 允许列表 (URI 合法保留 stdlib)

§5.2.1 `URI.new/1` 允许列表 (允许调用裸 `URI.new/1` 的唯一文件):

| 文件 | 理由 |
|---|---|
| `apps/ezagent_core/lib/ezagent/uri.ex` | 规范模块本身 — `parse!/1` 内部包装 `URI.new/1`。这是 chokepoint。 |
| `apps/ezagent_core/lib/ezagent/ecto/uri_type.ex` | 按 §3.7 双 fallback 契约的外部 URI fallback。 |

§3.4 `URI.new!/1` carve-out (合法调用 `URI.new!/1` 的生产行):

| 模式 | 理由 |
|---|---|
| `URI.new!("...?action=...")` | Query-target 语法 (§3.4) — 输入按构造规范。 |
| `@constant URI.new!(...)` | 编译时模块属性初始化 (§3.5) — ETS 编译时不可用。 |
| `URI.new!("workspace://" <> name)` | 结构化 URI 派生 (§3.6 `Capability.workspace_of/1`、`Ezagent.URI.entity_workspace_uri/1`)。 |

---

## 附录 B — 不变量测试伪代码 (§5 的完整草稿,r2)

```elixir
defmodule Ezagent.URICanonicalizationTest do
  use ExUnit.Case, async: true

  @uri_new_allowlist [
    "apps/ezagent_core/lib/ezagent/uri.ex",
    "apps/ezagent_core/lib/ezagent/ecto/uri_type.ex"
  ]

  @uri_parse_allowlist [
    "apps/ezagent_core/lib/ezagent/uri.ex"
  ]

  @lib_glob "apps/*/lib/**/*.ex"

  test "no stdlib URI.parse/1 in production lib/" do
    violations = scan_for(~r/\bURI\.parse\(/, fn _line -> false end, @uri_parse_allowlist)
    assert violations == [], format(violations)
  end

  test "no stdlib URI.new!/1 in production lib/ outside the §3.4/§3.5 carve-outs" do
    violations =
      scan_for(~r/\bURI\.new!\(/, fn line ->
        is_query_target_idiom?(line) or is_module_attribute?(line)
      end, [])
    assert violations == [], format(violations)
  end

  # r2 NEW
  test "no stdlib URI.new/1 in production lib/ outside the external-URI fallback allowlist" do
    violations =
      for path <- Path.wildcard(@lib_glob),
          path not in @uri_new_allowlist,
          {line, lineno} <- Enum.with_index(File.stream!(path), 1),
          matches_uri_new_no_bang?(line),
          not String.contains?(line, "# uri-canonical-allow"),
          not in_comment?(line) do
        {path, lineno, String.trim(line)}
      end

    assert violations == [], format(violations)
  end

  test "canonical URI round-trip" do
    for s <- [
      "entity://user/system/admin",
      "entity://agent/team-alpha/cc_demo",
      "session://default/system/main",
      "workspace://team-alpha",
      "system://bootstrap/default"
    ] do
      a = Ezagent.URI.parse!(s)
      b = Ezagent.URI.parse!(URI.to_string(a))
      assert a == b
      assert a.authority == nil
      assert URI.to_string(a) == s
    end
  end

  test "admin_uri canonical-equal across constructors" do
    from_const = Ezagent.Entity.User.admin_uri()
    from_parse = Ezagent.URI.parse!("entity://user/system/admin")
    {:ok, from_load} = Ezagent.Ecto.URI.load("entity://user/system/admin")
    assert from_const == from_parse
    assert from_const == from_load
    assert from_const.authority == nil
  end

  # r2 NEW (r3 扩展 per codex r2 HIGH-snapshot 发现 — 演练
  # canonicalize_uris/1 契约性要求遍历的每个形态:map value、
  # list element、深度嵌套、map key、tuple element、自定义 struct。)
  test "snapshot canonicalize_uris/1 covers every required shape" do
    parse = &URI.parse/1  # 迁移前形式

    defmodule MyBinding do
      defstruct [:uri, :meta]
    end

    pre_migration_state = %{
      chat: %{
        owner: parse.("entity://user/system/admin"),
        members: [parse.("entity://user/team-alpha/alice")],
        deep: %{nested: %{list: [parse.("entity://user/team-alpha/bob")]}},
        per_member: %{parse.("entity://user/team-alpha/carol") => :online},
        last_event: {:joined, parse.("entity://user/team-alpha/dave"), 1700000000},
        binding: %MyBinding{uri: parse.("entity://user/team-alpha/eve"), meta: %{}}
      }
    }

    binary = :erlang.term_to_binary(pre_migration_state)
    decoded = :erlang.binary_to_term(binary, [:safe])
    canonicalized = Ezagent.Kind.Snapshot.canonicalize_uris(decoded)

    assert canonicalized.chat.owner.authority == nil
    assert hd(canonicalized.chat.members).authority == nil
    assert hd(canonicalized.chat.deep.nested.list).authority == nil
    {tag, dave_uri, ts} = canonicalized.chat.last_event
    assert tag == :joined and ts == 1700000000
    assert dave_uri.authority == nil

    [{carol_uri, status}] = Enum.to_list(canonicalized.chat.per_member)
    assert carol_uri.authority == nil and status == :online

    assert canonicalized.chat.binding.__struct__ == MyBinding
    assert canonicalized.chat.binding.uri.authority == nil

    assert canonicalized.chat.owner == Ezagent.URI.parse!("entity://user/system/admin")
  end

  # r3 NEW (regex 在 r4 修复) — codex r2 HIGH-2 对抗性回归:
  # 单行同时携带 URI.new(...) 和 URI.new!(...) 不得漏过,
  # 不论顺序。通过 elixir REPL 实际验证 — 见 §5.2.1 表格完整输入矩阵。
  test "URI.new/1 invariant catches same-line URI.new + URI.new! mix" do
    assert matches_uri_new_no_bang?("foo = URI.new(s)")
    refute matches_uri_new_no_bang?("foo = URI.new!(s)")
    assert matches_uri_new_no_bang?("foo = URI.new(s); bar = URI.new!(t)")
    assert matches_uri_new_no_bang?("foo = URI.new!(s); bar = URI.new(t)")
    refute matches_uri_new_no_bang?("foo = URI.new!(s); bar = URI.new!(t)")
  end

  defp scan_for(regex, exclude?, allowlist) do
    for path <- Path.wildcard(@lib_glob),
        path not in allowlist,
        {line, lineno} <- Enum.with_index(File.stream!(path), 1),
        Regex.match?(regex, line),
        not String.contains?(line, "# uri-canonical-allow"),
        not in_comment?(line),
        not exclude?.(line) do
      {path, lineno, String.trim(line)}
    end
  end

  defp matches_uri_new_no_bang?(line) do
    # PCRE 负向前瞻:匹配 URI.new( 其中 `new` **不**紧跟 `!`。
    # Codex r4 修复 — r3 基于计数的公式假设 `\bURI.new\(` 匹配
    # `URI.new!(` 的前导部分,但它不匹配 (`(` 必须紧跟 `new`,而
    # `URI.new!(` 在两者之间有 `!`)。
    Regex.match?(~r/\bURI\.new(?!!)\(/, line)
  end

  defp is_query_target_idiom?(line),
    do: String.contains?(line, "URI.new!(") and String.contains?(line, "?action=")

  defp is_module_attribute?(line),
    do: Regex.match?(~r/^\s*@\w+\s+URI\.new!\(/, line)

  defp in_comment?(line), do: Regex.match?(~r/^\s*#/, line)
end
```

(完整实现级版本在 impl PR;本是 SPEC 级参考。)
