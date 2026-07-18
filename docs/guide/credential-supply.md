# Guide: Supplying agent credentials (operator lanes)

> Operational how-to for the credential supply plane (任务 B, handoff
> `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §4). When a
> socialware install skips a role slot for lack of credentials, this is how an
> operator supplies a source and re-materializes the skipped role.

## Why roles get skipped

Automatic materialization (socialware role slots) refuses to create an agent
that cannot authenticate (`Ezagent.Agent.CredentialPrecondition`, chain C):
the slot is skipped **loudly** — durable row in the session's
`unfilled_agent_role_slots` (rendered by the world UI), `Logger.error`, and
telemetry `[:ezagent, :socialware, :definition_agents, :skipped]`.

The skip `reason` tells you which supply lane fixes it:

| reason | meaning | fix lane |
|---|---|---|
| `:missing_credentials` | file-backed flavor (e.g. `cc` `.credentials.json`) has no resolvable source for this installer | §1 or §2 below |
| `:missing_provider_credential` | env-backed flavor's provider key is unavailable (deepseek today; cc-custom profiles) | set the provider key in the deploy env |
| `:unavailable` | some other failure — NOT fixable by supplying credentials | read the server log / telemetry raw reason |

## 1. User-default source (per owner × workspace × flavor)

Adopt an existing credentialed agent as the installer's default source:

```bash
mix ezagent.credential.adopt <owner-uri> --flavor cc [--source <agent-uri>]
```

Future installs by that user resolve this pointer first
(`Ezagent.Credential.UserDefaultSource`).

## 2. Workspace-shared source (per workspace × flavor)

A workspace admin binds a shared service-account source through the
cap-checked production writer (`Ezagent.ActionSet.WorkspaceSharedCredentialSource`,
registered on the Workspace Kind — reachable through the derived CLI tree):

```bash
mix ezagent workspace set_workspace_shared_credential_source \
  --workspace <workspace-uri> --flavor cc --source-uri <agent-uri>
```

Validation is fail-closed: the source must exist (snapshot), live in the same
workspace, and carry the same flavor. Non-admin installers resolve this layer
when they have no default of their own (`user default → workspace shared → NONE`).

> The host operator's own Claude login NEVER flows to agents a co-tenant caused
> to exist (#161) — that is the point of the skip, not a bug.

## 3. Re-materialize the skipped roles

Supplying a source does **not** retro-fill sessions — the skip rows are an
install-time snapshot. Re-run the (idempotent) install pipeline:

```bash
mix ezagent.session.reinstall_socialware <session-uri>
```

Roles whose credentials now resolve join the session; their skip rows clear
(the rerun rewrites `unfilled_agent_role_slots` from the fresh summary).
Already-joined roles are skipped (no duplicates). Roles still lacking
credentials stay skipped, loudly — reinstall is an explicit operator action,
never an automatic retry loop.

## Verification

Integration coverage:
`apps/ezagent_plugin_cc/test/integration/socialware_credential_rematerialize_test.exs`
(skip → supply → reinstall → member joined + rows cleared → idempotent rerun),
`.../socialware_credential_skip_telemetry_test.exs` (telemetry), and
`apps/ezagent_domain_session/test/.../unfilled_role_slot_reason_test.exs`
(three-way reason classification).
