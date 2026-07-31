# Agent Credential Fix Link Target

## Problem

The World error-card renderer maps `:agent_keys_page` to the static path
`/identities/agents/api-keys`. That route has no agent URI, so the destination
cannot load the agent that needs credentials.

In a Hello session, the error signal can be posted by the `front-desk` member
even though the missing provider credential belongs to the member occupying the
`llm` role. The message sender therefore must not determine the repair target.

## Design

The `agent_credential_missing` error-code declaration identifies `llm` as its
repair role. While shaping conversation messages, World resolves that role
against the current session's authorized member map and passes the resulting
agent URI into the shared error renderer.

For `:agent_keys_page`, the renderer produces:

```text
/identities/agents/<URI.encode_www_form(actual-agent-uri)>/api-keys
```

For example:

```text
/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2F17ef3de3-768e-4a1d-819f-3d836f070ab0/api-keys
```

The renderer never uses the error-message sender as the credential target. If
the declared repair role has no unique current agent member, World omits the
direct repair link instead of emitting a generic or invalid agent route.

## Scope

- Extend the backend error-code metadata with an optional repair role.
- Resolve that role from the current session member map on initial history and
  older-message pagination.
- Build the agent-specific API Keys URL in the shared backend error renderer.
- Keep unrelated error codes and notification behavior unchanged.
- Do not change the agent error-signal wire format.

## Tests

- A credential error authored by `front-desk` links to the distinct member whose
  role is `llm`.
- The generated path contains the URL-encoded actual LLM agent URI.
- An unresolved repair role produces no misleading direct link.
- Existing Layer 2 and Layer 3 behavior remains unchanged.
