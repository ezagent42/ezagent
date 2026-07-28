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

## Tests

- A frontend component test verifies that Hello defaults to `curl`, exposes
  the completion-flavor selector, and emits no curl configuration for a
  non-curl choice.
- A generator-level regression test verifies that a missing API key becomes a
  `no_api_key` error signal instead of a `generation_failed` wrapper.
- Existing World error-card tests remain the authority that the preserved
  signal renders the credential-configuration card.

## Scope boundary

This change is confined to the World template-authoring surface and the Hello
generator's error-normalization boundary. It does not alter session-template
agent materialization, credential cascade policy, agent readiness, or rollback.
