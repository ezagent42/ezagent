# Versioned HMAC PAT rollout / 版本化 HMAC PAT 上线

This runbook is the executable credential transition for `entity_tokens`.
Bridge credentials in `AgentBridge.TokenStore` are a separate YAML store and
are not changed here.

本手册只迁移 `entity_tokens`。`AgentBridge.TokenStore` 的 YAML bridge token
是独立凭据系统，不在本次迁移范围内。

## Required order / 必须顺序

1. Back up the database and retain the active pepper secrets.
2. Provision `EZAGENT_PAT_DIGEST_VERSION=1` and a durable, random
   `EZAGENT_PAT_PEPPER_V1` of at least 32 bytes on every node.
3. Deploy the new binary and run migrations. Mint and verify are now HMAC-only;
   legacy rows with `token_digest IS NULL` already fail closed.
4. Before deleting anything, mint the first admin PAT on-node with the
   PAT-independent bootstrap entrypoint:

   ```sh
   mix ezagent.user.token entity://system/user/admin --mint --label bootstrap-admin
   ```

5. Delete unrecoverable bcrypt-era rows for hygiene:

   ```sh
   mix ezagent.entity_tokens.invalidate_legacy
   ```

6. Humans sign in again. Password and magic-link login rotate a single
   `interactive-login` row and show the new PAT once.
7. Restart or repair cc role agents. Every role-agent spawn runs
   `SpawnPlan.maybe_put_cli_identity_env/3`, mints `esr_pat_v1_...`, and injects
   only `EZAGENT_USER_TOKEN`. Role-less legacy agents receive no PAT and need none.

中文顺序：先备份并持久化 pepper；部署迁移；先用本机 bootstrap 命令签发管理员
PAT；再清理旧 bcrypt 行；用户重新登录自签；最后滚动重启/repair 服务 agent。
密码登录和 bootstrap mint 都不依赖旧 PAT，因此不会形成“先有 PAT 才能签 PAT”的死锁。

## Rotation / 轮换

Provision `EZAGENT_PAT_PEPPER_V2`, set `EZAGENT_PAT_DIGEST_VERSION=2`, and
deploy. New tokens are `esr_pat_v2_...`; v1 and v2 verify concurrently because
the version selector is inside the token. Repeat steps 4-7 for the rotation,
then delete v1 rows before retiring `EZAGENT_PAT_PEPPER_V1`.

## Recovery and rollback / 恢复与回滚

1. **Forward repair (preferred):** stay on the new binary and repeat bootstrap,
   login, and agent restart minting under the current version.
2. **Data restore on the new binary:** restore the pre-cleanup snapshot and keep
   the peppers. Restored HMAC rows work; restored bcrypt-only rows remain invalid
   and their users re-authenticate.
3. **Old-binary code/schema rollback:** restore the pre-migration schema and data
   snapshot. The old binary cannot verify or mint HMAC PATs, so this is a full
   fleet re-authentication event. Retain all peppers for the next roll-forward.

三种情况不可混为一谈：优先前向修复；新代码下可恢复数据快照；只有同时恢复旧
schema/data 才能回滚旧 bcrypt binary，而且该路径必然要求全量重新认证。
