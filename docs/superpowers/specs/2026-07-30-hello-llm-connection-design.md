# Hello LLM connection-before-membership design

## Decision

A Hello session must admit its `llm` role only after the role's declared
flavor has completed its credential configuration and passed validation.
The session-template declaration remains the source of truth for the recipe
and flavor; users do not choose an arbitrary flavor at session runtime.

The role agent itself is session-scoped and is never reused across sessions.
The verified credential source is reusable at the user/workspace/flavor scope.

## Problem

The current automatic materialization path tries to validate a credential
source before it spawns a file-credential agent. That prevents a first-time
`codex` or `cc` user from reaching the PTY in which they must log in. Relaxing
the gate and joining an unauthenticated agent is not acceptable: it creates a
member that cannot respond.

## User journey

1. A user creates a session from `hello` or a template derived from Hello.
2. The system creates the session, materializes `front-desk`, and navigates to
   the session detail page.
3. If the declared `llm` flavor has a valid reusable credential source, the
   system materializes and joins the session-local llm automatically.
4. Otherwise the message list shows a persistent **Connect LLM** card. Its
   label and action are determined by the template's declared flavor:
   `Connect Codex`, `Connect Claude`, or `Configure API key`, for example.
5. The user clicks the card action. The system creates one provisional,
   session-local llm agent but does not make it a session member. The applicable
   flavor-owned UI opens: a PTY login for interactive flavors, or a secure
   credential form for API-backed flavors.
6. On successful credential validation, the system persists the reusable
   credential source, binds the provisional agent to its declared recipe,
   grants the normal participation capabilities, and joins it to the session.
   The member roster refreshes automatically and the card becomes a short
   success state or disappears.
7. On cancellation, timeout, or validation failure, the provisional agent and
   its temporary state are retired. The session and `front-desk` remain usable;
   the card reports the outcome and offers a retry.

## State model

The llm role has a durable session-scoped provisioning state:

| State | Meaning | User-visible result |
|---|---|---|
| `pending_auth` | No valid credential source is available; no llm member exists. | Connect LLM card. |
| `authenticating` | Exactly one provisional agent/login flow is active. | Progress card; repeat clicks focus or resume the existing flow. |
| `materializing` | Validation succeeded; recipe binding and membership convergence are running. | Non-dismissable progress card. |
| `joined` | The session-local llm is a verified, converged member. | Normal member row; no setup prompt. |
| `failed` | The last attempt failed and its provisional resources were cleaned up. | Reason plus retry action; equivalent to `pending_auth` for admission. |

The state must include the template revision, role name, flavor, and (only
while active) provisional agent URI/attempt ID. This makes retries idempotent
and prevents a stale login completion from admitting an agent after the user
has cancelled or changed template revision.

## Responsibilities

- **Hello Definition/template** declares `llm` recipe, fixed flavor, and that
  the role needs connection-before-membership. It contains no agent creation,
  credential-copy, or direct membership code.
- **Generic socialware/session materialization** owns provisional agent
  lifecycle, recipe binding, validation, membership admission, retry, and
  rollback. This must be reusable by any socialware role that requires setup.
- **Flavor implementation** owns its authentication interaction and validation:
  PTY/browser login for interactive flavors and secure provider configuration
  for API-backed flavors.
- **World** renders the generic role-connection state as the message-list card
  and refreshes the member roster after admission.

## Admission and reuse rules

1. A provisional agent is never visible as a session member and receives no
   session participation capability before validation succeeds.
2. A reusable credential source is keyed by the authenticated user, workspace,
   and template-declared flavor. It may be reused by later Hello sessions.
3. Every successful Hello session still gets a new llm agent URI. Credentials
   are reused; agents are not.
4. Existing valid credentials take the same validation path but skip the card
   and complete admission automatically.
5. If a credential later becomes invalid, the UI returns to `pending_auth`;
   it must not silently create a replacement member or leave an apparently
   healthy but non-responsive llm in the roster.

## Error handling

- A credential source validation error is presented as a connection error, not
  as an unexplained missing member.
- A join or roster-convergence failure after successful authentication retires
  only the provisional agent and retains the reusable credential source.
- Cancellation and timeout retire the provisional agent without deleting a
  previously valid credential source.
- Duplicate connection requests share the active attempt rather than creating
  more agents or PTYs.

## Verification

Automated tests must cover:

1. no credential source: `front-desk` joins, llm does not join, and
   `pending_auth` is persisted/rendered;
2. interactive flavor first login: a provisional non-member agent exists,
   successful validation admits exactly that agent once;
3. API-key flavor: invalid input remains non-member; valid input admits once;
4. retry/cancellation: temporary agents are cleaned up and stale completion
   cannot admit one;
5. reusable credentials: a second session receives a different llm URI and
   joins automatically;
6. a derived Hello template uses its own declared flavor and does not expose a
   runtime flavor picker;
7. World UI: card states, retry action, and roster refresh are covered without
   asserting raw HTML.

## Non-goals

- Letting users switch the llm flavor inside an already-created session.
- Making a Hello role agent reusable across sessions.
- Adding Hello-specific agent-creation or credential-management code.
