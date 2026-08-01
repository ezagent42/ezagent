# 全新数据库下的逐授权持久撤销设计

**状态：** 方向已批准，等待对抗性评审

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

### 不包含

- 保留任何现有开发数据。
- 导入或 remint 已存在的 capability artifact。
- 从 membership、recipe、snapshot 或 user 数据反推历史直接授权。
- 让应用启动过程自动删除数据库。
- 删除与 P2 无关的历史迁移机制，例如已有的 Identity Store cutover。
- 重写与 P2 无关的仓库 migration 历史。创建 ledger 和 `grant_id` 列所需的 schema
  migration 仍然保留。

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

## 4. 强制执行边界

clean database 初始化不会削弱 no-resurrection 保证，以下边界必须全部保留：

1. **Issue：** 每个新 artifact 在签名前获得 framework 生成的 `grant_id`。
2. **Authorize：** artifact match 前执行签名/当前 authority 校验，以及一次 workspace
   scoped ledger 查询；ledger 读取失败即 deny。
3. **Store：** 所有 Store 写路径共用事务内 revoked-artifact guard。`grant_id` 缺失或
   非法、签名无效或 ledger 读取失败时，在持久化和 reindex 前拒绝写入。
4. **Effective load：** Store/snapshot/user 恢复出的 artifact 必须先经过同一套已签发
   artifact 有效性和 revoke 语义，才能成为 held cap。
5. **Delivery：** enqueue 和 drain 都拒绝已撤销 `grant_id`；envelope semantic
   identity 包含 `grant_id`。
6. **Revoke：** 单一事务锁定 holder row，解析精确 artifact，插入 marker，从 Store
   删除，取消匹配 pending delivery，并重建 grantee index。

这些检查不再受 epoch 条件包裹，而是始终开启。

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

## 7. 删除清单

实现将删除或重写以下 P2 surface：

- `Ezagent.Cap.RevocationEpoch` 及其 Ecto schema/migration/test；
- `Ezagent.Identity.CapRevocationCutover` 及其 test；
- `EzagentCore.Release.cap_revocation_cutover/1`；
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

## 8. 失败语义

- 已签发 artifact 缺少或带非法 `grant_id`：拒绝，不做兼容转换。
- 签名无效或过期：拒绝。
- ledger 读取失败：authorize deny，durable write/delivery 拒绝。
- `grant_id` 已撤销：deny 并拒绝持久化/delivery。
- revoke 无法解析可信精确 artifact：返回错误且不写入任何数据。
- 事务失败：marker、Store mutation、outbox cancellation 和 index mutation 一起回滚。
- database reset/bootstrap 失败：应用保持未启动，不回退到旧数据。

## 9. 验收契约

### 协议与签发

- production source 和 test 不再命名 capability protocol version 或 revocation epoch。
- 每个已签发 grant 和 authority anchor 都具有非空新 `grant_id`，并被签名覆盖。
- 调用方提供的 `grant_id` 在签发时被覆盖。
- 修改或删除 `grant_id` 会使 artifact 无效。

### 持久撤销

- 撤销一个 grant 会立即 deny 它，但不撤销逻辑上不同的 grant。
- 对同一逻辑 capability re-grant 使用新的 `grant_id` 并成功。
- Store write 以及 outbox enqueue/drain 拒绝已撤销 `grant_id`。
- live slice、snapshot、旧 user JSON 和 pending delivery 在 cold restart 后都不能复活
  已撤销 artifact。
- absent-from-Store exact revoke 只对绑定预期 holder 和 target 的有效签名 artifact
  成功。

### Clean start

- 空数据库可完成全部 schema migrations，无需 activation 或 cutover 命令。
- seeds/bootstrap 只创建满足唯一机制的 grant。
- 应用启动后直接无条件执行 grant-ID enforcement。
- source ratchet 证明 epoch/cutover/version compatibility surface 不能被静默重新引入。

### Gates

- touched application test suites；
- authorize-chokepoint 与 capability-issue ratchet；
- touched files 的 `mix format --check-formatted`；
- `mix ci.fast`；
- `mix precommit`。

## 10. 文档权威性

本文记录用户在 2026-08-01 作出的 clean-slate 决策。在 P2 handoff 要求
inactive/active epoch、协议版本、向后兼容 decode、维护期 remint、语义迁移 diff 或
production cutover 的部分，本文优先。handoff 对逐授权 ledger 内核、atomic revoke、
enforcement boundary、测试纪律、branch 和交付约束仍然有效。
