# 全新数据库下的逐授权持久撤销设计

**状态：** 已完成三轮对抗性评审与 target branch 实现；交付 return 已记录，最终 PR
保持开放并等待 coordinator 评审

**决策日期：** 2026-08-01

**覆盖范围：** 本文覆盖 `/Users/h2oslabs/P2_KIMI_HANDOFF.md` 中的协议版本和维护期
cutover 设计；逐授权撤销内核继续保留。

## 1. 背景与决策

应用尚未进入生产环境，不存在必须保留的客户数据库。使用本分支前，开发数据库会
被完整删除并重新初始化。

因此系统不发布旧/新权限协议的过渡机制。未来只有一种 capability grant 机制：

- 每个已签发 grant artifact 都具有全新的 `grant_id`；
- `grant_id` 被 authority 签名覆盖；
- revoke 按 `grant_id` 写入不可变标记；
- authorize、持久化写入和 delivery 都拒绝已撤销 artifact；
- 对同一逻辑 capability 再次 grant 时生成新的 `grant_id`。

最终运行模型中不存在 `v1`、`v2`、`signing_version`、revocation epoch、cutover、
remint 或 legacy compatibility 等概念。

这里删除的仅是 capability **协议**版本。authority key generation 以及 `key_id` 中
用于 key rotation 和 current-authority verification 的密钥版本继续保留；本任务不得
删除或改名这些语义。

## 2. 范围

### 包含

1. 删除 P2 协议版本字段和所有按版本分支。
2. 删除 P2 revocation epoch、激活转换和持久 epoch 表。
3. 删除 P2 维护期 cutover/remint 命令、release 入口、语义 diff、manifest、破坏性
   rebuild 事务以及对应 runbook/test。
4. 对所有已签发 grant artifact 无条件执行带签名 `grant_id` 契约。
5. 保留独立 revocation ledger，并在所有 grant-artifact 边界执行校验。
6. 保留 exact-artifact revoke、新 ID re-grant、outbox enforcement、cold restart
   enforcement，以及 `EntityCaps` 到 `IdentityCaps` 的命名收敛。
7. 用空数据库初始化验收替代 activation/cutover 验收。
8. 同时删除旧 Identity Store cutover compatibility plane：不存在
   `Identity.Cutover`、cutover release/Mix 入口、legacy-authoritative 或 dual-write
   mode，也不再把 capability 持久化到 `users.caps_json`。
9. 空数据库第一次启动起，`IdentityCaps.Store` 就是 held capability 的唯一持久来源。

### 不包含

- 保留任何现有开发数据。
- 导入或 remint 已存在的 capability artifact。
- 从 membership、recipe、snapshot 或 user 数据反推历史直接授权。
- 让应用启动过程自动删除数据库。
- 删除 authority generation 或 key-version rotation 语义。
- 重写与 P2 无关的仓库 migration 历史。创建 ledger 和 `grant_id` 列所需的 schema
  migration 仍然保留。
- 删除 Kind snapshot 本身。snapshot `:identity` 数据可以继续作为 runtime cache，
  但不能成为独立持久 authority，并且 load 时必须与 `IdentityCaps.Store` reconcile
  和 filter。

## 3. 核心模型

### 3.1 Capability request 与 grant artifact

现有 `%Ezagent.Capability{}` 同时表达未签发 capability request 和已签发 artifact，
两种状态的约束不同：

- 未签名 request 或 required-cap shape 可以暂时为 `grant_id: nil`；
- 唯一签发 chokepoint 会忽略调用方提供的值并写入新的 UUID；
- 已签名 grant artifact 必须具有语法有效且非空的 `grant_id`；
- 任何 held、persisted、restored、delivered 或参与 authorize 的 artifact 如果没有
  有效 `grant_id`，都作为 malformed artifact 拒绝。

`grant_id` 不进入 `Capability.identity_key/1`。逻辑 revoke 先按 capability identity
查找，再记录已存储签名 artifact 的精确 `grant_id`。

### 3.2 签名契约

canonical signed payload 始终包含 `grant_id`，不存在备用 payload shape 或 fallback
verify 路径。`grant_id` 缺失、格式非法、被修改，或 artifact 不是由当前 authority
签名时，验证失败。

绕过普通 Grant issue 函数的 authority anchor 也必须在签名前写入新的 `grant_id`。

### 3.3 持久撤销台账

`cap_revocations` 继续由 core 持有并只允许插入。主键为 `grant_id`；审计字段保留
workspace、holder、capability identity digest、target、key 和 revoke 时间。

snapshot 清理、holder 删除、Store 替换或 delivery 清理都不能删除 marker。marker
GC 继续延后。

### 3.4 Canonical issued-artifact API

request normalize 与 issued-artifact validation 使用不同 API。新增 core-owned
`Ezagent.Cap.GrantArtifact` 契约：

```elixir
@spec from_map(map()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec from_term(binary()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec validate(Capability.t()) :: {:ok, Capability.t()} | {:error, validation_error()}
@spec valid_grant_id?(term()) :: boolean()

@type validation_error ::
        :not_capability
        | :missing_grant_id
        | :invalid_grant_id
        | :missing_signature
        | :missing_key_id
        | :missing_grantee_uri
        | :invalid_term
        | {:invalid_field, atom()}
        | {:invalid_uri, atom()}
```

`Capability.Normalize` 继续作为 request/declaration normalizer，可以生成
`grant_id: nil` 的 request；它不再生成协议版本，也不把缺少 grant ID 解释成 legacy
artifact。任何 artifact carrier 在其数据成为 held、persisted、restored、delivered
或参与 authorize 前，都必须经过 `GrantArtifact.from_map/1` 或
`GrantArtifact.validate/1`。carrier 包括 Store JSON、live/snapshot identity set、
delivery envelope、recipe-binding artifact，以及任何 rehydrate signed grant 的
serializer。

有限 carrier 清单为：

1. `identity_caps.caps_json` Store set；
2. live 与 snapshot `:identity` cap set；
3. delivery-outbox payload 和 `DeliveryOutbox.Envelope`；
4. provider callback ingress 与持久 callback-attempt artifact；
5. `RecipeCapBinding.artifacts`；
6. `kind_cap_authorities.anchor`，即以 Erlang term 保存的单一 artifact；
7. capability Jason/EventLog decode path；
8. provisioning-receipt 或 provider-callback serializer field（仅当它包含可 rehydrate
   artifact；只有 digest 的 field 不是 artifact carrier）；
9. absent-from-Store revoke 接受的 exact artifact。

`GrantArtifact` 还提供全有或全无的 set validator：

```elixir
@spec validate_set(Enumerable.t(), term()) ::
        {:ok, MapSet.t(Capability.t())}
        | {:error, {:invalid_grant_artifact, term(), non_neg_integer(), validation_error()}}
```

任一元素非法都会拒绝整个 carrier set；reader 不得只丢弃 malformed element 后继续。
空 `grant_id`、signature 或 `key_id` 作为 missing；field type 错误返回
`{:invalid_field, field}`，URI field 非法返回 `{:invalid_uri, field}`，两种 tuple 都属于
`validation_error()`。每个 carrier 都有 focused test，证明 malformed input 使整个读取
fail-closed。

canonical `grant_id` 是 `Ecto.UUID.generate/0` 返回的小写、带连字符 UUID 文本。
验证要求 `Ecto.UUID.cast/1` 成功，并且 cast 后的 canonical 结果与输入完全相同。

`GrantArtifact.from_term/1` 使用 `:erlang.binary_to_term(binary, [:safe])`，只接受
`%Capability{}`，随后调用 `validate/1`；任何 decode exception 或 unexpected term 都返回
`{:error, :invalid_term}`。`Ezagent.Cap.Authority` 只有在完成 safe decode、row/key/target/
current-authority signature verification 和 revocation-ledger check 后才返回 anchor。
corrupt、missing-ID、noncanonical-ID、stale 或 revoked anchor 全部 fail-closed，不能进入
admin 或 carried authorization caps。

## 4. 强制执行边界

clean database 初始化不会削弱 no-resurrection 保证，以下边界必须全部保留：

1. **Issue：** 每个新 artifact 在签名前获得 framework 生成的 `grant_id`。
2. **Authorize：** artifact match 前执行签名/当前 authority 校验，以及一次 workspace
   scoped ledger 查询；ledger 读取失败即 deny。
3. **Store：** 所有 Store 写路径共用事务内 artifact-shape 与 revoked-artifact
   guard。`grant_id` 缺失或非法、signed-artifact field 缺失、ID 已撤销或 ledger
   读取失败时，在持久化和 reindex 前拒绝写入。
4. **Effective load：** Store/snapshot/recipe 恢复出的 artifact 必须先经过同一套已签发
   artifact 有效性和 revoke 语义，才能成为 held cap。
5. **Delivery：** enqueue 和 drain 都拒绝已撤销 `grant_id`；envelope semantic
   identity 包含 `grant_id`。
6. **Revoke：** 单一事务锁定 holder row，解析精确 artifact，插入 marker，从 Store
   删除，取消匹配 pending delivery，并重建 grantee index。

这些检查不再受 epoch 条件包裹，而是始终开启。

新增的 per-grant Store guard 刻意不作为第二套 current-authority verifier；它不得
删除或削弱 Store 已有的 authority lock，该 lock 原子保护 active-row/current-self-license
lifecycle invariant。密码学签名/current
generation 验证继续在 authorize、effective load、delivery consumption 和 exact
revoke trust boundary fail-closed。这样保留 P2 no-resurrection 范围，同时避免把
authority-row locking 引入所有 Store writer。Store 可以包含结构有效但密码学上已
过期的 artifact，但该 artifact 无法成为 effective authority。现有 self-license
regenesis-race coverage 继续 mandatory；只有为新 per-grant guard 增加额外 per-target
authority lock 才不在范围内。

### 4.1 Store-first mutation 与 bootstrap protocol

`IdentityCaps.Store` authoritative 是写入顺序 invariant，不只是 read preference。
held identity cap set 的每次 mutation 都遵循：

1. issue/normalize proposed artifact；
2. 同步进入 Store transaction，锁 holder row，执行 artifact-shape 与 revocation
   guard，按需更新 Store、cancel/reindex，并 commit；
3. 只有 Store commit 后，才用精确 committed Store result 替换 live `:identity` cap
   set，并写 snapshot projection；
4. 只有 checked Store commit 后才 acknowledge mutation。snapshot projection failure
   不得推翻 Store authority；应使 actor crash 或 not-ready，再通过 cold load 从 Store
   rebuild。

删除 identity cap 的现有 snapshot-first `commit_and_notify` Store mirror。snapshot
callback 不再执行 best-effort Store write。grant/revoke/replace 入口必须先调用
Store-owned mutation API；source invariant 禁止直接修改 live slice。

creation 也必须 Store-first。user row 与 initial Store row 在同一 Repo transaction
插入。其他 cap-bearing entity 在 Kind 可见或 ready 前完成 Store genesis/provisioning
transaction。不存在“可见的 existing entity 合法缺少 Store row”的窗口。

cold load 精确状态：

- active Store row：validated cap set 替换 snapshot 数据，绝不 union；
- tombstoned/revoked-unprovisioned Store row：effective held cap 为空；
- Store read error：fail-closed 并拒绝 ready；
- existing entity 缺少 Store row：invariant violation，fail-closed 并拒绝 ready；
- missing row 只允许出现在未 commit 的 new-entity genesis transaction 内，且此时
  entity 尚不可见、不可 spawn。

`ctx.caps` 携带的 delegation 仍是独立 authorization input，不是 held-cap Store row。
本节仅约束 durable held capability。

## 5. Revoke 与 re-grant 语义

Store 中存在逻辑匹配时，revoke 忽略调用方携带的 grant metadata，使用已存储签名
artifact 的 `grant_id`。

Store 中没有匹配时，只接受 authority、holder/grantee、target 和当前 generation
全部验证通过的精确签名 artifact。随机 ID、未签名 request、旧 authority artifact
和错误 holder artifact 都被拒绝。

对同一逻辑 capability 再次 grant 会生成新的 `grant_id`；旧 marker 不阻止新
artifact。复用已撤销 `grant_id` 会被 Store 和 delivery guard 拒绝。

## 6. 全新数据库初始化

删除数据库是显式开发/部署前置步骤，不是运行时副作用：

1. 停止所有使用开发数据库的应用进程；
2. 使用仓库支持的 reset 流程删除并重建整个开发数据库；
3. 从空数据库运行全部 migrations；
4. 运行 seeds/bootstrap；
5. 启动应用；
6. 通过正常应用流程创建 user、workspace、session 和 grant。

reset 会删除 user、workspace、snapshot、direct grant、pending delivery、revoke marker
和其他全部开发数据。应用启动前不会读取 reset 前数据，也不会运行权限迁移任务。

最终 runtime 只有一条持久 authority path：

- `IdentityCaps.Store` 无条件 authoritative；不存在 persisted cutover flag 或 mode
  switch。
- 通过普通 schema-cleanup migration 从 runtime schema 删除 `users.caps_json`，并从
  所有 schema、create/update function 和 fallback 中删除它。
- 删除旧 Identity cutover schema/table、release/Mix command、runbook、仅迁移使用的
  backfill/remint helper、dual-write code 和 legacy fallback read。
- snapshot `:identity` 只是 cache，cold load 时不能覆盖 Store 内容。

## 7. 删除清单

实现将删除或重写以下 P2 surface：

- `Ezagent.Cap.RevocationEpoch` 及其 Ecto schema/migration/test；
- `Ezagent.Identity.CapRevocationCutover` 及其 test；
- `EzagentCore.Release.cap_revocation_cutover/1`；
- `Ezagent.Identity.Cutover` 及其 Ecto schema/table、release/Mix 入口、runbook、
  migration-only remint/backfill helper 和 compatibility test；
- `users.caps_json` column 以及所有 legacy-authoritative、fallback 或 dual-write
  capability path；
- 协议版本字段、encoder、digest、default 和 conditional；
- cutover 专用 invariant allowlist、ratchet count、文档和 acceptance test；
- dry-run report、semantic diff、approved manifest、table/advisory lock、remint API，
  以及仅为 cutover 存在的 pending-row cleanup。

实现继续保留：

- 已签发 capability artifact 和 delivery row 上的 `grant_id`；
- `cap_revocations` 与 `Ezagent.Cap.RevocationLedger`；
- Store 的共享 revoked-artifact guard；
- authorize/effective-load/outbox enforcement；
- atomic revoke 与 exact-artifact validation；
- fresh-ID authority issuance 和 authority-anchor issuance；
- 为唯一机制更新的 serializer 与 digest；
- 最终 `IdentityCaps` 命名。

### 7.1 Storage constraint

已进入 `main` 的 historical migration 保持 version、module 和 DDL semantics。唯一
narrow exception 是其中直接调用被 P2d rename 的 runtime module：该调用更新到当前
`IdentityCaps` module，保证空数据库 replay，不保留旧名字 compatibility module。
branch 上尚未 merge 的 P2 migration 在 merge 前修改，并新增一个有序 cleanup
migration：

1. `20260801000000_create_cap_revocations.exs` 使用 PostgreSQL UUID primary key
   创建 ledger。
2. 删除尚未 merge 的 `20260801000100_create_cap_revocation_epoch.exs`；空数据库从不
   创建该表。
3. `20260801000200_add_grant_id_to_cap_delivery_outbox.exs` 添加 PostgreSQL UUID
   `NOT NULL` column 和 workspace/grant/status index。它在非空 incompatible database
   上故意失败；唯一支持路径是 clean reset。
4. `20260801000300_remove_identity_cap_compatibility.exs` drop historical
   `identity_cutover` table 并删除 `users.caps_json`。原来创建这些对象的旧 migration
   保持不变，使完整 migration chain 仍可 replay。

clean-start gate 在 migration 后查询 PostgreSQL catalog，断言最终 column、UUID type、
nullability、index，以及两个 compatibility surface 都不存在。

每个直接标识 issued grant 的 relational column 使用 PostgreSQL UUID 语义，不使用
无限制 text：

- `cap_revocations.grant_id`：UUID primary key，定义上即为 `NOT NULL`；
- `cap_delivery_outbox.grant_id`：UUID `NOT NULL`，Ecto changeset 必填，并保留
  workspace/grant/status index。

ledger 和 outbox Ecto schema 使用 `Ecto.UUID`；public API 继续暴露 canonical UUID
string。JSON/term carrier 无法使用 database column constraint，因此 decode 和 write
boundary 必须执行 `GrantArtifact` validation。

## 8. 失败语义

- 已签发 artifact 缺少或带非法 `grant_id`：拒绝，不做兼容转换。
- effective-authority trust boundary 上签名无效或过期：deny/reject。单独的 Store
  persistence 不表示 artifact 在密码学上 current。
- ledger 读取失败：authorize deny，durable write/delivery 拒绝。
- `grant_id` 已撤销：deny 并拒绝持久化/delivery。
- revoke 无法解析可信精确 artifact：返回错误且不写入任何数据。
- 事务失败：marker、Store mutation、outbox cancellation 和 index mutation 一起回滚。
- database reset/bootstrap 失败：应用保持未启动，不回退到旧数据。

## 9. 验收契约

### 协议与签发

- runtime capability source 和 ordinary test 不再命名 capability protocol version 或
  revocation epoch。
- 每个已签发 grant 和 authority anchor 都具有非空新 `grant_id`，并被签名覆盖。
- 调用方提供的 `grant_id` 在签发时被覆盖。
- 修改或删除 `grant_id` 会使 artifact 无效。
- corrupt-term、missing-ID、noncanonical-ID、stale-signature 和 revoked
  `kind_cap_authorities.anchor` fixture 全部在进入 authorization 前 fail-closed。

### 持久撤销

- 撤销一个 grant 会立即 deny 它，但不撤销逻辑上不同的 grant。
- 对同一逻辑 capability re-grant 使用新的 `grant_id` 并成功。
- Store write 以及 outbox enqueue/drain 拒绝已撤销 `grant_id`。
- live slice、snapshot、recipe binding、provider callback 和 pending delivery 在 cold
  restart 后都不能复活已撤销 artifact。
- absent-from-Store exact revoke 只对绑定预期 holder 和 target 的有效签名 artifact
  成功。

### Clean start

- 空数据库可完成全部 schema migrations，无需 activation 或 cutover 命令。
- 最终 schema 不包含 identity/revocation cutover table，也不包含
  `users.caps_json`；Store 立即 authoritative。
- seeds/bootstrap 只创建满足唯一机制的 grant。
- 应用启动后直接无条件执行 grant-ID enforcement。
- source ratchet 证明 epoch/cutover/version compatibility surface 不能被静默重新引入。
  ratchet 只约束 capability 协议兼容面，必须继续允许 authority key generation/version
  代码。

可执行 gate 是 Mix task
`apps/ezagent_core/lib/mix/tasks/ezagent.cap_revocation.verify_clean_start.ex`，通过且只
通过一个 alias entry 调用：

```elixir
"ci.clean_per_grant": ["ezagent.cap_revocation.verify_clean_start"]
```

`mix precommit` 恰好一次包含 `ci.clean_per_grant`。CI 和最终交付验证运行
`MIX_TEST_PARTITION=<unique> mix precommit`；不存在 optional equivalent gate。

`config/test.exs` 接受 `EZAGENT_TEST_DATABASE` 作为 exact database-name override；
未设置时继续使用 ordinary partition database formula。外层 verification task 不启动
`:ezagent_core` 或任何 umbrella application。它通过 direct admin connection 创建
disposable database，然后以相同显式 environment 启动 migration/seed/scenario 的每个
OS child process：

```text
MIX_ENV=test
MIX_TEST_PARTITION=<the gate's unique partition>
EZAGENT_TEST_DATABASE=<the generated prefixed database>
```

每个 child 都必须确认 resolved `EzagentCore.Repo.config()[:database]` 等于
`EZAGENT_TEST_DATABASE`，否则拒绝运行。migration、seed/bootstrap、first application
scenario 与 cold-restart verification 使用独立 child process，因此第二次 application
start 是真实 cold start。启动任何 child 前，task 断言 generated database 与普通配置的
test database 不同；任何 child command 都不得缺少 override。

task 必须：

1. 从 monotonic integer 与 random suffix 派生匹配
   `~r/\Aezagent_pg_compat_test_clean_[a-z0-9_]+\z/` 的唯一数据库名；公开 Mix-task
   interface 不接受调用方传入 database name 作为 drop target；
2. 每次 create/drop 前 parse 并重新验证 resolved name，只连接同一个 configured
   PostgreSQL server，并使用 `try/after` cleanup 在所有退出路径只 drop 该精确名称；
3. 外层 task 通过 direct admin connection 创建数据库，再为 migration、seeds/bootstrap、
   first boot 和 cold boot 启动隔离 child，全部携带上述 exact override；
4. 启动第一个正常应用 child，并断言 authority-anchor 与 bootstrap grant 通过
   `GrantArtifact` 和 current-authority validation；
5. 执行 issue、authorize、revoke、deny、使用新 ID re-grant，并 authorize 新 grant；
6. 结束第一个 child，再针对同一 generated database 启动第二个正常应用 child，
   证明旧 grant 仍 deny、新 grant 仍 authorize；
7. 检查 Store、authority anchor、ledger 与 outbox schema，断言 canonical signed grant
   ID、UUID/NOT NULL constraint、Store-only authority，以及不存在任何 P2 或 Identity
   activation/cutover/remint step；
8. 无论成功或失败都 drop disposable database。

强制执行的 `Ezagent.IdentityCapsTest` suite 用 fault injection 补充 process-level gate：
覆盖 Store-before-projection 顺序、Store commit 后 snapshot failure、cold-load 从 Store
replace，以及 Store missing/corrupt 时拒绝 ready。carrier owner suites 覆盖 outbox、
recipe、provider、snapshot 和 event-log 边界。这些测试进入 `ci.fast`/`precommit`；
clean-start task 负责空 schema 与真实跨进程持久性证明。

针对已迁移 test database 的 unit test 不能作为充分证据。

### Source ratchet

`apps/ezagent_core/test/invariants/clean_slate_grant_protocol_test.exs` 扫描 runtime library
source、configuration 和 umbrella Mix project，拒绝：

- `signing_version`；
- `RevocationEpoch`、`CapRevocationEpoch` 和 `cap_revocation_epoch`；
- `CapRevocationCutover`、`cap_revocation_cutover` 和已删除的 cap-revocation
  cutover Mix/release 入口；
- runtime 对 `Identity.Cutover`、`IdentityCutover`、`identity_cutover`、
  `PreEpochRemint` 或其 Mix/release 入口的引用；
- `users.caps_json` 的读写，同时允许 `identity_caps.caps_json`。

narrow exception 只有 ratchet source 自身、最初创建 retired column/table 的 immutable
historical migration，以及 cleanup migration
`20260801000300_remove_identity_cap_compatibility.exs`。authority `key_id` version、
authority generation 与 rotation code 继续允许。每个 exception 都是 exact file path。
clean-start verification task 也是 exact-path exception，因为它必须命名 retired schema
object 才能断言其不存在；它不能提供 runtime compatibility behavior。

### Gates

- touched application test suites；
- authorize-chokepoint 与 capability-issue ratchet；
- touched files 的 `mix format --check-formatted`；
- `mix ci.fast`；
- `mix precommit`。

### 实现证据映射

- artifact identity、canonical UUID、签发覆盖调用方 ID 与签名绑定：
  `grant_artifact_test.exs`、`capability_protocol_test.exs` 和
  `authority_verify_against_current_test.exs`。
- authority-anchor fail-closed：`authority_anchor_validation_test.exs`。
- atomic exact revoke、新 ID re-grant、Store write rejection 与 absent-Store exact
  validation：`identity_caps/store_test.exs`。
- Store-first projection、cold repair 与 readiness denial：`identity_caps_test.exs`。
- durable delivery 与 restart enforcement：`delivery_outbox_hardening_test.exs` 及
  recipe/provider carrier suites。
- compatibility removal 与最终 PostgreSQL schema：
  `clean_slate_grant_protocol_test.exs` 和
  `20260801000300_remove_identity_cap_compatibility.exs`。
- 空数据库/重启验收：`mix ezagent.cap_revocation.verify_clean_start`，并通过
  `ci.clean_per_grant` 恰好一次接入 `precommit`。

## 10. Branch 与 PR 交付

- integration target 仍为 `feat/p2-per-cap-revocation`。
- 后续 implementation sub-phase 可以使用子分支，并创建指向 integration target 的
  PR。该 sub-phase 所需测试通过后，实现 agent 有权自行把 sub-phase PR 合入
  integration target。
- 已经直接提交到 integration target 的 commit 不需要倒退补造 sub-phase PR。
- 完成条件包括 push integration target，并创建一个
  `feat/p2-per-cap-revocation` 指向 `main` 的最终 PR。
- 最终 PR 必须保持 open，交由 coordinator review。实现 agent 不得合并最终 PR，
  也不得以其他方式把 integration target 合入 `main`。

## 11. 文档权威性

本文记录用户在 2026-08-01 作出的 clean-slate 决策。在 P2 handoff 要求
inactive/active epoch、协议版本、向后兼容 decode、维护期 remint、语义迁移 diff 或
production cutover 的部分，本文优先。handoff 对逐授权 ledger 内核、atomic revoke、
enforcement boundary、测试纪律和 branch identity 仍然有效。本文第 10 节覆盖 handoff
中禁止最终 PR 的要求，并定义当前交付契约。
