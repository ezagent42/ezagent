# Per-cap revocation v2 cutover

This is a stopped-node maintenance operation. It re-mints the current durable
effective capability plane as signed v2 artifacts, rewrites every durable cap
materialization, and activates the monotone per-cap revocation epoch in one
Postgres transaction.

## Mandatory writer exclusion

During the entire cutover window:

- stop the serving container;
- do not run `bin/ezagent eval`, a Mix task, a remote console, or a restore job
  against the same `DATABASE_URL` other than the single cutover command;
- do not start a second container against that database;
- do not start `/app/bin/ezagent` until the cutover command has completed.

The transaction takes an advisory lock and write-conflicting table locks as a
mechanical backstop. Those locks do not replace the operational exclusion rule.
The cutover is deliberately not an `EzagentWeb.Application` child: the Phoenix
Endpoint would already be serving by then.

## Procedure

1. Stop the serving container and all other writers.
2. Run migrations.
3. Rehearse the exact locked plan:

       /app/bin/ezagent eval 'EzagentCore.Release.cap_revocation_cutover(dry_run: true)'

4. Review both `would_be_lost` and `would_be_added`, including each reported
   holder, logical capability identity, source, and reason. An empty diff needs
   no approval hash. A non-empty diff must be explicitly approved by recording
   the reported `manifest_hash` in the deployment change.
5. Run the one-shot. For an approved non-empty diff:

       /app/bin/ezagent eval 'EzagentCore.Release.cap_revocation_cutover(approved_manifest_hash: "HASH")'

6. Require a successful return. Any raise/refusal stops the deployment; do not
   open the listener. A crash rolls back the wipe, rebuild, anchor rewrite,
   pending-delivery cancellation, and epoch activation together.
7. Only after success, run `/app/bin/ezagent start`.

The canonical admin's structural self-license is intentionally included in the
v2 plane. On databases that follow the prior born-empty admin contract, this is
reported as a `required_admin_self_license` addition and therefore requires the
same reviewed manifest-hash approval as any other semantic addition.
