# Task 1 report — declarative credential admission and connection contracts

## Implementation

- Added `Ezagent.Agent.CredentialConnection`, a flavor-neutral boundary that
  resolves each flavor through `Ezagent.AgentFlavorRegistry`, calls only the
  registered Template Class's optional `credential_connection/1`, and
  normalizes supported declarations:
  - `{:pty, label}` -> `{:pty, %{label: label}}`
  - `{:api_key, provider, label}` ->
    `{:api_key, %{provider: provider, label: label}}`
  - no callback -> `:not_required`
  - unknown or malformed declarations -> `{:error, :unsupported_connection}`
- Added the optional, documented `credential_connection/1` callback to
  `Ezagent.Agent.CredentialAdapter`; its documented default is `:not_required`.
- Added `credential_admission` to normalized agent role declarations. Both atom
  and string inputs are accepted; supported values are `:immediate` and
  `:before_session_join`; omitted values normalize to `:immediate`.
- Kept install-level role slot choices limited to flavor/install data, preserving
  the declaration-level credential-admission policy.

## TDD evidence

1. RED:

   ```sh
   mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs
   ```

   Result: 4 failures, all because
   `Ezagent.Agent.CredentialConnection.for_flavor/1-2` was undefined.

2. GREEN / required focused verification:

   ```sh
   mise exec -- mix test \
     apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs \
     apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs \
     apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs
   ```

   Result: 33 tests, 0 failures (4 agent-domain tests; 29 session-domain tests).

## Changed files

- `apps/ezagent_domain_agent/lib/ezagent/agent/credential_connection.ex`
- `apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex`
- `apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs`
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex`
- `apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs`
- `apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs`

## Commit

`6395a6daf35d7a4fbe963c739f30f1c7dab9d15f` —
`feat(session): declare credential-gated role admission`

## Concerns

- The brief names `apps/ezagent_domain_agent/lib/ezagent/agent/credential_adapter.ex`,
  but the sole existing `Ezagent.Agent.CredentialAdapter` module is owned by
  `apps/ezagent_core`. The callback was therefore added to that authoritative
  module; creating the named domain-agent path would duplicate the module.
- `mix precommit` was started and reached its clean forced compile phase, but was
  stopped at the task owner's direction because Task 6 owns full precommit.
  The Task 1 focused command above is fresh and passing.

---

## Review correction — unavailable template classes and admission serialization

### Root cause

`CredentialConnection.template_connection/2` discarded the result of
`Code.ensure_loaded/1`. An unavailable Template Class therefore had no exported
callback and was incorrectly treated as `:not_required`.

### TDD evidence

1. RED:

   ```sh
   mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs
   ```

   Result: 5 tests, 1 failure. The unavailable registered class returned
   `{:ok, :not_required}` instead of `{:error, :unsupported_connection}`.

2. GREEN:

   ```sh
   mise exec -- mix test \
     apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs \
     apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs \
     apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs \
     apps/ezagent_domain_session/test/ezagent/socialware/role_slot_acceptance_test.exs
   ```

   Result: 38 tests, 0 failures (5 agent-domain tests; 33 session-domain tests).

### Changes

- Unavailable registered Template Classes now return
  `{:error, :unsupported_connection}`.
- `role_slot_acceptance_test` now asserts the serialized default
  `"credential_admission" => "immediate"`.
- Replaced nested test helper modules with one compiled top-level support module.

### Scope

The correction commit excludes this shared report and the pre-existing plan
document; both remain unstaged.
