# Socialware Concepts

This guide defines the socialware model used by ezagent. It is the standalone
authoring guide for the base / socialware / fixture taxonomy.

## Why "socialware", Not "App"

A socialware is a human+program hybrid flow, not a pure software app. It is
operated: a responsible human and one or more agents collaborate inside an
observed turn surface where the human can hold, settle, approve, and take over
program output before it reaches an external audience.

A pure app hides internals and runs unattended. A socialware exposes its
internals to a responsible human and makes human gating first-class.

Concretely, a socialware composes capability substrates, called bases, with a
flow-specific shape. The socialware is the thing an operator opens and uses. A
base is not directly user-operable.

## The Three Layers

```text
FIXTURE
  A seeded instance or use of a socialware for a specific business.
  Example: autoservice = chat used for customer service.

SOCIALWARE
  A human+program hybrid flow that composes one or more bases plus a shape.
  It is directly user-operable.
  Examples: chat, kanban.

BASE
  A capability substrate composed into socialwares.
  A base provides capability, not a product.
  Examples: orchestrator, surface, pty, sandbox, cc-headless-agent.
```

### Base

A base is a reusable capability substrate. In code, most bases are Behaviors
that own persistent state slices and dispatchable actions. A base is composed
into one or more socialwares.

Verified bases:

| Base | Code | Role |
| --- | --- | --- |
| orchestrator | `Ezagent.ActionSet.Template` recipe content + `Orchestrator.Tools` + `SessionManager` | The existing orchestration combo. No new `Behavior.Orchestrator`, and no `Behavior.Template` refit. |
| surface | `Ezagent.ActionSet.Surface` | Render/external-surface substrate, immutable page versions, approved pointer, settlement commit. |
| pty | `Ezagent.ActionSet.Pty` | Terminal/PTY substrate. |
| sandbox | `Ezagent.ActionSet.Sandbox` | Per-agent config directory and plugin-extension substrate. |
| cc-headless-agent | `Ezagent.ActionSet.CcHeadlessAgent` | Claude Code SDK/headless-agent substrate. |

The orchestrator base is conceptual shorthand for the existing recipe + tools +
executor combo. `Behavior.Template` remains template-content storage on
AgentTemplate and SessionTemplate Kinds; it is not a session-mounted runtime
base.

### Socialware

A socialware is a directly operable flow composed from bases plus a shape.

`chat` is the world Conversation surface. It is generic and has no customer
service, autoservice, or other business semantics. In the target model, chat
composes the orchestration base, the surface base, and the conversation shape.
Current `main` still has a split: plain chat sessions do not mount Turn/Surface,
while the socialware/hello path does. P3 closes that by moving composition into
the `installs` data field.

`kanban` is a board/task socialware. It has definite task semantics and a
board/task shape. Current `main` has kanban as a role recipe only; it does not
yet use `role_name`, `{:role, name}` routing, or routing rules. The target model
expresses those semantics through recipe, responsibility, and routing.

### Fixture

A fixture is a configured instance or seeded use of a socialware for a business.
It is not a concept-layer object.

`autoservice` is a fixture: chat configured for a customer-service business. It
adds team, persona, and adapter configuration, but it does not add a new layer to
the model and must not enter the core taxonomy or schema as a concept.

## Shape

A shape is the flow-specific behavior and recipe that make bases into a
particular flow.

For chat, the shape is the conversation turn protocol,
`Ezagent.ActionSet.Turn`. Turn owns the `:turns` slice and is specific to
conversation flows, so it is a shape, not a base.

For kanban, the shape is the board/task protocol,
`Ezagent.ActionSet.Kanban`: nodes, stages, claims, statuses, artifacts, metrics,
Miro sync, and board configuration.

Surface is different: a rendered external surface can be reused by unrelated
flows, so `Ezagent.ActionSet.Surface` is a base.

## How Bases Compose Into Socialware

A socialware installs its session-mounted bases and shape onto a session host
through the existing declaration-free mount path. The session's active behavior
set is the union of the installed socialwares' bases and shapes.

The socialware definition is config-as-data. It names:

- bases and shape behaviors to mount on the session host;
- members and B1 responsibilities;
- routing rules;
- prompt templates, legends, and orchestrator template URI;
- external adapters, such as web feed, Feishu, or Slack;
- visibility policy, including anonymous web access and publish policy.

The definition lives under a structured, non-URI ConfigStore subject:

```text
socialware:<name>
```

The subject is an opaque identifier, not a `<scheme>://` URI. The workspace is
a separate ConfigStore field, so it is not embedded in the subject (T1 project
B); the ConfigObject key is `"socialware"`. There is no `socialware://` scheme,
and socialware is not a new Kind.

## How To Author A Socialware

This is the target authoring model after P3-P7. Until P9, author only B1
responsibilities such as `bot`, `reviewer`, and `orchestrator`. The named
`supervisor` B2 pool is introduced only in P9.

1. Pick the bases the flow needs: orchestration, surface, pty, sandbox,
   cc-headless-agent, or another real base.
2. Define the flow shape: conversation Turn, Kanban, or a new flow-specific
   Behavior.
3. Declare B1 responsibilities and routing: assign `role_name` per member and
   route to `{:role, name}`.
4. Add adapters if the socialware has an external surface: web feed, Feishu,
   Slack, or another `ExternalMirror.Adapter`.
5. Author the socialware definition as config-as-data and install it through the
   SessionTemplate `installs` composition field.

Developers do not add a new host Kind, do not make `domain_session` declare
every base, and do not add new spawn call sites for each socialware. The host is
a generic session; installation is data plus the existing mount mechanism.

## Anti-Patterns

- A pure unattended app is not a socialware.
- A fixture such as autoservice is not a concept-layer socialware type.
- The hello plugin is the surface/page-builder base code, not a separate
  socialware vertical.
- The orchestrator is one base among several, not the base.
- Do not add `socialware://`.
- Do not create a new `Behavior.Orchestrator`.
- Do not refit `Behavior.Template` into a session-mounted runtime base.
- Do not introduce a named `operator` or `supervisor` role before P9.

