# PTY Credential Admission Bootstrap Design

## Goal

Allow a newly created session to connect a CLI-authenticated agent such as
Codex or Claude Code through that agent's own PTY, while preserving per-session
agent and credential isolation.

The user-facing flow remains:

1. Click `Connect Codex` or `Connect Claude` for a pending session role.
2. Ezagent creates one provisional agent with an isolated, secret-free config
   home and automatically opens that agent's PTY.
3. The user runs the flavor's normal CLI login inside the PTY.
4. The user clicks the existing completion action.
5. Ezagent validates the credential in that provisional agent's isolated home,
   then completes admission and joins the agent to the session.

## Security Boundary

Grantless bootstrap is allowed only when all of these conditions hold:

- the role is declared `credential_admission: :before_session_join`;
- the resolved credential connection is PTY-backed;
- the recipe content is `credential_optional: true`;
- credential source policy is `:session_local`;
- cascade resolution selected no credential source and carries no pending grant;
- the spawn receipt proves this process is the newly created winner.

This path creates only configuration layers and the completion marker. It does
not copy secret paths, mint a temporary or fake grant, reuse operator credentials,
or inherit credentials from another session or agent.

Any cascade carrying a credential source or pending grant continues through the
existing `materialize_with_grant/1` path, including grant minting, source reads,
version revalidation, and compensation. Missing or inconsistent authorization
outside the explicit bootstrap conditions remains fail-closed.

## Architecture and Data Flow

`AgentAdmission.begin/4` remains the owner-authorized entry point. It creates the
provisional agent and the existing World action switches the UI to its PTY.

The cascade resolver must preserve an explicit, non-secret indication that the
resolved content is eligible for grantless session-local bootstrap. The file
credential home runtime uses that indication to choose between two paths:

- **credentialed materialization:** unchanged grant-backed secret copy and
  atomic commit;
- **PTY bootstrap materialization:** atomic commit of the already-built,
  secret-free staging directory, returning an explicit grantless launch marker.

The launch layer accepts the grantless marker only for this provisional
bootstrap path. It must not invoke grant version revalidation for a marker that
contains no grant. All ordinary credentialed launches retain both existing
revalidation boundaries.

The agent remains provisional and outside the session membership until
`AgentAdmission.complete/4` reads the credential status and receives
`:authenticated`. Failed validation retains the existing failure and cleanup
behavior.

## Error Handling

- Failure to build or atomically install the secret-free config home aborts the
  provisional spawn and surfaces the existing tagged materialization error.
- Existence of a source without a valid grant never falls back to bootstrap.
- Exiting the PTY without logging in does not admit the agent; completion returns
  the existing authentication failure.
- Cancellation and timeout retire the provisional agent and remove its isolated
  home through the existing admission cleanup path.
- No automatic polling or new timeout is introduced; completion remains an
  explicit user action.

## Testing

Add regression coverage at three levels:

1. A file-credential materialization unit test proves an eligible session-local
   grantless cascade commits no secret files and returns the grantless marker.
2. Codex and Claude Code admission integration tests prove `begin` creates a
   provisional agent and exposes its PTY without a credential grant.
3. Negative tests prove a sourced cascade without a valid grant, a non-session-
   local policy, or a non-optional credential cannot use the bootstrap path.

Existing tests must continue to prove that the agent is not a session member
before authenticated completion and that grant-backed starts retain strict
grant revalidation and compensation.

Run focused tests, affected architecture gates, and `mix ci.fast`. Per the
worktree instruction, do not run `mix precommit`.
