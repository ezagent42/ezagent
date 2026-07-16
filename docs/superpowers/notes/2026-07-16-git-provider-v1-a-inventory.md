# Git Provider V1-A — current primitive inventory

**Date:** 2026-07-16

**Repository baseline:** `ea529a89b2876cf292679e30803652e66e6971c3`

**Purpose:** evidence-only inventory for Plan A. This note does not authorize a production credential path.

## Capability artifact seam

| Item | Current fact | Evidence |
|---|---|---|
| Issue API | `Ezagent.Cap.issue(authorization, grantee_uri, capability)` | `apps/ezagent_core/lib/ezagent/cap.ex:31-39` |
| Authorization forms | `{:held_by, uri}`, `{:admin, uri}`, `{:rule, name, uri}`, `{:genesis, uri}` | `cap.ex:22-27`, `214-230` |
| Artifact | issuer provenance + `grantee_uri` + `key_id` + Ed25519 signature | `cap.ex:147-210`; `capability.ex:47-66` |
| Receiver check | `Ezagent.Cap.verify_for(cap, receiver_uri)` | `cap.ex:86-102` |
| Compatibility | unsigned legacy artifacts remain dual-read unless `require_signature` is enabled | `cap.ex:43-63`, `197-203` |

Plan B must use these current signatures and cannot use the older provenance-only model.

## OS-process boundary

| Property | Current fact | Evidence |
|---|---|---|
| Approved launcher | `Ezagent.Runtime.OsProcess.spawn/2` | `apps/ezagent_core/lib/ezagent/runtime/os_process.ex` |
| Command safety | list command uses argv/execve; binary command is legacy shell mode | `os_process.ex:48-83`, `137-139` |
| Lifecycle | erlexec `run_link`, process group + `kill_group`, explicit stop | `os_process.ex:84-123`, `126-135` |
| Runtime identity | current worker runs as `uid=1000(huangjiajia)` | `id` on 2026-07-16 |
| Host | Linux 6.8.0-71-generic x86_64 | `uname -a` on 2026-07-16 |
| OS-user isolation | not provided by `OsProcess` | no uid/gid/user namespace option in `spawn_opts` or `build_exec_opts/3` |
| Mount/filesystem isolation | not provided by `OsProcess` | no mount namespace/container option in the module |

Conclusion: `OsProcess` is the correct lifecycle primitive, but it is not by itself a credential-isolation boundary. Task 2 must reproduce the same-UID exposure with sentinel data.

## Secret storage

Repository search found no `SecretStore`, Vault, KMS, Cloak, or equivalent encrypted-at-rest abstraction.

Load-bearing evidence:

```text
apps/ezagent_core/priv/repo/migrations/20260530000000_app_settings.exs:7-8
stored as-is — Ezagent has no at-rest encryption today ...
```

Existing credential facilities are file/config-home materialization or plaintext application storage, not an approved Entity SSH private-key backend. Cookie encryption in `runtime.exs` is web-session infrastructure and is not a general secret store.

**Inventory result:** encrypted Secret Store = absent / NO-GO pending a separate approved primitive.

## SSH private-key parsing

Searches for OpenSSH/PEM/private-key parsing and the dependency graph found no repository-owned OpenSSH Ed25519/RSA private-key importer. OTP `:public_key` is currently used for TLS CA/hostname work, while capability signing uses raw derived Ed25519 bytes through `:crypto`; neither is evidence of OpenSSH private-key file parsing.

The worktree currently has no materialized `_build`/dependency set: `mix deps` reports locked dependencies as unavailable. This is an environment setup fact. Inspection of `mix.lock` and app dependency declarations still found no dedicated SSH/PEM import library.

**Inventory result:** SSH import parser = absent / NO-GO pending an approved parser decision.

## Plugin/adapter registration

The ExternalMirror path is the reusable structural pattern:

- plugins declare `adapters/0` through `Ezagent.Plugin`;
- plugin boot prevalidates the complete batch;
- registry insert uses `:ets.insert_new/2`;
- same-module re-registration is idempotent;
- duplicate adapter IDs fail loud;
- successful inserts produce receipts;
- boot failure rolls back only rows inserted by that boot attempt;
- Resource type registration happens after other fallible publish steps.

Evidence:

- `apps/ezagent_core/lib/ezagent/plugin.ex:213-232`, `475-530`, `780-930`
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`

Plan B should extend the plugin declaration/boot/receipt rollback model rather than call a Git adapter registry directly from plugin application code.

## Decision table

| Decision | Required property | Current primitive | Inventory result |
|---|---|---|---|
| Capability | signed, receiver-bound, exact instance/action/workspace | `Ezagent.Cap.issue/3`, `verify_for/2` | GO for downstream design |
| Secret backend | encrypted at rest, opaque refs, version create/read/delete | none | NO-GO |
| SSH parser | bounded OpenSSH Ed25519/RSA import with fixed errors | none | NO-GO |
| Git broker lifecycle | argv-safe spawn + crash cleanup | `Ezagent.Runtime.OsProcess` | GO for lifecycle only |
| Git broker isolation | agent cannot observe/reuse credential material | none proven | NO-GO pending Task 2/3 |
| Adapter seam | duplicate-safe declaration, boot rollback | `Ezagent.Plugin` + ExternalMirror registry pattern | GO as pattern |

Inventory complete; no GO decision yet.
