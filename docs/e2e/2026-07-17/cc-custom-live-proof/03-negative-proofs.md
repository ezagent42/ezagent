# T7 Step 3 — negative proofs

All three negative proofs ran against the same locally booted node from this
worktree (same env discipline as `02-product-path-proof.md`).

## 3a — `provider: "bogus"` rejected at create with `{:unknown_backend_profile, _}`

Same create lane as the positive proof (template content seam):

```bash
mix ezagent agent_template fork --agent-template template://system/agent/cc-orchestrator \
    --new-name t7-bogus --owner entity://system/user/admin
# => {"template_uri": "template://system/agent/t7-bogus"}

mix ezagent agent_template write --agent-template template://system/agent/t7-bogus \
    --content '{"name":"t7-bogus","flavor":"cc-custom","provider":"bogus","project_cwd":"/tmp/t7-bogus-cwd",...}'
# => content stored (validation is structural at instantiate, not at write)

mix ezagent agent_template instantiate --agent-template template://system/agent/t7-bogus \
    --instance-name t7-bogus-1 --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin
# => error: {:invalid_template_data, {:unknown_backend_profile, "bogus"}}
```

The `to_template_data/2` fail-closed gate (`validate_for_flavor`, spec §4.5
link 2) rejects before any spawn. Verified no agent exists afterwards:

```bash
mix ezagent agent read --agent entity://system/agent/t7-bogus-1
# => error: no such actor (did you spawn the instance?)
```

## 3b — keyless env (server restarted WITHOUT `DEEPSEEK_API_KEY`)

Restart: same scrub as the proof run, plus `unset DEEPSEEK_API_KEY
MOONSHOT_API_KEY` — the profile key is absent from the server env.

### 3b-i — create fails FAST with `{:backend_api_key_missing, "deepseek", _}`

```bash
mix ezagent agent_template instantiate --agent-template template://system/agent/t7-ds-pty \
    --instance-name t7-ds-keyless --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin
# => error: {:backend_api_key_missing, "deepseek",
#            %URI{scheme: "entity", host: "system", path: "/agent/t7-ds-keyless", ...}}
```

The exact 3-tuple from `Provider.ensure_api_key/2`, returned by
`CcCustomAgent.instantiate/3` BEFORE any Kind spawn / PTY start (the launchability
gate, spec §4.3 contract delta 2). The error names the profile — never the
missing env var's value, never a stack of opaque bridge timeouts.

### 3b-ii — the orchestrator socialware slot SKIPS (never halts)

Through the world UI (product surface): new session `t7-keyless-orch` with the
built-in **Orchestrator** socialware app (its role slot is `flavor:
"cc-custom", provider: "deepseek"` — visible in the create params at
`server-run3-keyless-excerpts.txt`). Session created:
`/Socialware-Install-Orchestrator/T7-Keyless-Orch` — **1 member (the operator
only), 0 turns** (`shots/keyless-orchestrator-skip.png`). The install
COMPLETED; the orchestrator role slot SKIPPED. Server log verbatim:

```
[error] socialware role slot "orchestrator" SKIPPED on
  session://system/socialware-install-orchestrator/t7-keyless-orch:
  {:credential_unavailable, "cc-custom"} — the agent would boot without
  credentials, never join its transport bridge, and hang at :not_ready.
  The session is alive without this role.
[error] session socialware install completed with SKIPPED roles for
  session://system/socialware-install-orchestrator/t7-keyless-orch:
  [%{reason: {:credential_unavailable, "cc-custom"}, role_name: "orchestrator"}]
  — the session is alive and usable, but those roles have no agent.
```

This is the chain-C contract exactly: the automatic lane pre-flight
(`CredentialPrecondition.check_source/3` with `backend_profile: "deepseek"`,
T4) reports the credential as unavailable, the role slot is SKIPPED, and the
rest of the install batch completes — never a hard `{:agent_spawn_failed, _}`
halt.
