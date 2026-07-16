# Git Provider V1-A broker isolation options

**Date:** 2026-07-16

**Input evidence:**

- `docs/superpowers/notes/2026-07-16-git-provider-v1-a-inventory.md`
- `docs/superpowers/notes/2026-07-16-git-provider-v1-a-isolation-probe.md`
- `apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs`

## Required property

An SSH broker is acceptable only when an agent cannot read the imported private
key and cannot reuse the broker interface for an operation outside the
Cap-authorized Git request. Process cleanup, mode `0600`, a separate working
directory, or keeping bytes out of argv are necessary hygiene but are not that
boundary.

## Candidate matrix

| Candidate | Provisioning ownership | IPC authentication / Cap enforcement | Host-key policy | Crash cleanup | Deployment support | Agent prevented from reuse? | Result |
|---|---|---|---|---|---|---|---|
| A. Separate OS user | Would require deploy/host owner to create and operate a broker identity plus inaccessible storage | No authenticated broker IPC exists; a new endpoint would need receiver-bound Cap verification and request narrowing | Not implemented; must bind repository host and pinned/approved host key | `OsProcess` can reap a child tree, but it cannot launch under the absent identity | Docs mention separate users as operator advice; no provisioning, runtime uid/gid option, service unit, or CI fixture exists | Not demonstrated | NO-GO for V1-A |
| B. Existing container/sandbox | Current Docker files provision one application container; agents and BEAM-side services share it | No nested agent/broker boundary or authenticated IPC exists | Not implemented | Container lifecycle exists only at whole-app level | `bwrap` is installed on this workstation, but it is neither an ezagent production primitive nor present in committed deployment configuration | Not demonstrated | NO-GO for V1-A |
| C. Remote signer/credential service | No owner, service, client, or deploy contract exists | Would need mutually authenticated structured Git-only requests plus receiver-bound Cap verification | Not implemented | Would belong to the remote service contract | No repository or deployment support found | Not demonstrated | NO-GO for V1-A |
| D. No approved boundary | No new provisioning | No unsafe interface is exposed | Not applicable | Not applicable | Matches current repository and host evidence | Yes, by withholding SSH transport | Selected |

## Evidence

Repository inspection:

```bash
rg -n "user:|read_only|cap_drop|security_opt|secrets:|/secrets|userns|pid:" docker -g '*'
rg -n "separate OS user|remote signer|credential service" apps config docs
```

The committed compose files mount deployment secrets into the application
container. They do not place agents and a Git credential broker in different
security domains. `Ezagent.Runtime.OsProcess.spawn/2` has no uid, gid, user
namespace, mount namespace, or container option.

Host availability inspection found `/usr/bin/bwrap` and `/usr/bin/unshare`, but
binary presence is not an approved production isolation mechanism. There is no
ezagent adapter, lifecycle, deployment configuration, Cap-authenticated IPC, or
test fixture for either. Plan A therefore does not invent a sandbox integration
or treat this workstation as deployment authorization.

The executable Task 2 probe independently establishes that the current shared
UID can read both a known mode-0600 file and another child environment on this
host (`2 tests, 0 failures`).

## Downstream consequence

- SSH private-key import remains a designed extension point, not an enabled V1
  transport.
- Plan D may proceed with a GitHub plugin whose write path uses GitHub Git Data
  API requests and whose checkout prerequisite is public repository access.
- Authenticated checkout and non-GitHub SSH transport remain blocked on a
  separately approved credential boundary.

SSH broker isolation: NO-GO — no approved agent-inaccessible credential boundary exists
