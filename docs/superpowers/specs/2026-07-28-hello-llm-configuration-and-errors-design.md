# Hello LLM Configuration and Errors Design

## Goal

Keep `curl` as the default Hello LLM flavor while allowing a template author to
choose any supported completion flavor, and render missing credentials as an
actionable configuration error rather than an internal error.

## Design

The template builder keeps its Hello-specific presentation because the `curl`
flavor has provider, API URL, and model configuration.  It receives the
registered completion-flavor list, renders it as a selector, and initializes
to `curl`.  Selecting a non-`curl` flavor clears the curl-only configuration
from the role-slot payload; selecting `curl` restores the existing default
configuration fields.  Reusing an existing agent remains outside this Hello
LLM configuration surface.

`Generator.generate_simple/4` must preserve known agent failure terms when it
posts its structured error reply.  In particular, `{:no_api_key, provider}`
must reach `ErrorCards` unchanged so the existing `agent_credential_missing`
registration renders its Layer 1 or Layer 2 configuration guidance.  Unknown
generation errors remain wrapped as `{:generation_failed, reason}` and retain
the Layer 3 issue-registration path.

## Error Handling

The fix does not infer that every generation error is a credential error.
Only the explicit `no_api_key` tuple is preserved as an actionable credential
failure.  HTTP, transport, decode, model, and unrecognized failures remain
generic until they have a stable, separately registered user-facing code.

## Session membership before credential validation

Every fresh agent declared by a template role slot is a session member once its
agent process, capability binding, and session join succeed. Credential state
MUST NOT prevent that membership. This applies to every flavor: `curl` agents
need a reachable member surface to configure an API key, and file-backed
interactive flavors need their PTY surface to complete login. Environment-backed
flavors also remain members, but their provider configuration is repaired
outside the PTY.

`CredentialPrecondition` remains a diagnostic helper, but no longer gates
template materialization. The materializer must remove both pre-spawn
credential skips and the post-spawn credential check that terminates a fresh
agent before its session join. It must also tell the credential cascade that a
template-role spawn is allowed to have no source: otherwise a required
slice-backed role is rejected inside the cascade even after the pre-check is
removed. That permission is scoped to session-template role materialization;
it does not relax ordinary explicit-agent creation or unrelated spawn paths.

Host-login adoption is useful only as an optimization for copying an already
available credential. It must not synchronously block or fail a role's create
and join path. A timeout or adoption error is recorded for operators, while
the agent is still created and joined without inherited credentials.

Failed agent creation unrelated to credentials, capability binding, and
session join remain hard materializer failures. An agent with unavailable
credentials is instead a valid member that cannot yet generate. Runtime
failures retain the flavor's existing structured signal where one exists (for
example, `curl` returns `{:no_api_key, provider}`); adding a common PTY-login
signal is deferred until the bridge exposes a stable, flavor-neutral readiness
state. This avoids incorrectly presenting PTY login for environment-backed
flavors such as `cc-custom`, whose remediation is provider configuration.

## Tests

- A frontend component test verifies that Hello defaults to `curl`, exposes
  the completion-flavor selector, and emits no curl configuration for a
  non-curl choice.
- A generator-level regression test verifies that a missing API key becomes a
  `no_api_key` error signal instead of a `generation_failed` wrapper.
- Existing World error-card tests remain the authority that the preserved
  signal renders the credential-configuration card.
- A definition-agent integration regression test proves a credential-less
  template role is materialized and joined instead of being skipped or
  terminated.
- A cascade regression test proves a required slice-backed role also joins
  without a credential source, rather than failing inside the cascade.
- Existing runtime error-card coverage remains the authority for each flavor's
  stable error signal; this change does not invent a misleading common signal.
