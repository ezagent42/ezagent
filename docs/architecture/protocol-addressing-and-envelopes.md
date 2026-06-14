# Protocol — Addressing & Envelopes

> **Durable architecture reference.** The thin formalization of ezagent's wire
> protocol: how things are *addressed* (URIs) and how a request is *wrapped*
> (the Invocation envelope and the Message payload it carries). This is the
> authoritative cross-reference; the exhaustive field-level detail lives in the
> module `@moduledoc`s cited inline. For the message *flow* (IM → session →
> agent fan-out), see [`communication-overview.md`](./communication-overview.md).
>
> Bilingual mirror: [`protocol-addressing-and-envelopes.zh_cn.md`](./protocol-addressing-and-envelopes.zh_cn.md).
> `file`/module citations are point-in-time — verify against current code.

## 1. Addressing — the URI

Every addressable thing in the system is named by a URI. Source of truth:
`Ezagent.URI` (`apps/ezagent_core/lib/ezagent/uri.ex`) — the *only* sanctioned
home for URI parsing/construction (a CI invariant forbids raw stdlib `URI.*`
in product `lib/`).

### 1.1 Grammar

```
address       = scheme "://" authority [ "?" "action=" verb ]
verb          = behavior "." action          ; e.g. session.send
```

Per-tenant schemes carry the workspace as the first authority segment, so
workspace identity is O(1)-extractable from the path (SPEC v3 §3.6):

```
<scheme>://<workspace>/<type>/<name>[?action=<behavior>.<action>]
```

| scheme       | shape                                      | `<type>` axis                |
|--------------|--------------------------------------------|------------------------------|
| `entity://`  | `entity://<ws>/<type>/<name>`              | `user` \| `agent`            |
| `session://` | `session://<ws>/<template>/<name>`         | the template the session was instantiated from |
| `template://`| `template://<ws>/<type>/<name>`            | `agent` \| `session`         |
| `resource://`| `resource://<ws>/<type>/<name>`            | resource kind (`uploads`, …) |
| `workspace://`| `workspace://<name>`                      | — (tenant root)              |
| `system://`  | `system://<type>/<name>`                   | cross-workspace              |

### 1.2 Two load-bearing principles

1. **Path is identity; the query carries the verb.** The path uniquely
   identifies *what* is addressed; `?action=<behavior>.<action>` selects *which
   Behavior + action* to invoke against it (`Ezagent.URI.behavior_action/1`,
   `with_action/3`). A bare path (no `?action=`) is an identity reference; a
   path + `?action=` is a dispatch target.

2. **Canonical form is an invariant, not a convenience.** The same logical URI
   must have exactly one `%URI{}` representation. `URI.parse/1` (stdlib,
   RFC-2396) yields `authority: "<ws>"`; the canonical constructor yields
   `authority: nil` (RFC-3986). They `to_string/1` to identical bytes but are
   not struct-`==`, so a map/ETS/MapSet keyed with one and looked up with the
   other **silently misses** — "the single most expensive URI bug class"
   (Allen 2026-05-30, *"地址静默错误是不可接受的"*). Defenses, strongest first:
   `new!/1` (canonical constructor, scheme + shape validated, `canonical!`
   post-condition) · `parse/1` (non-raising inbound boundary, same canonical
   form) · `canonical?/1` (predicate) · `canonical!/1` (loud structural guard)
   · `with_action/3` (canonical dispatch-target builder). See the
   `Ezagent.URI` `@moduledoc` for the full ladder + the
   `UriCanonicalizationInvariantTest` CI gate.

### 1.3 Scheme registry (runtime, not compile-time)

Accepted schemes are the live `Ezagent.URI.SchemeRegistry` ETS allowlist, seeded
at boot with `entity`, `workspace`, `session`, `template`, `resource`, `system`
(SPEC §5.6). Plugins extend it only via `Ezagent.SpawnRegistry.register/2` — so
a new Kind's scheme is co-registered with its spawn wiring, never hard-coded.

## 2. Envelopes — Invocation & Message

There are two nested envelopes. The **Invocation** is the universal request
wrapper for *any* dispatch; the **Message** is the identity-invariant *payload*
for entity↔entity (chat/session) communication.

### 2.1 Invocation — the universal request shape

`Ezagent.Invocation` (`apps/ezagent_core/lib/ezagent/invocation.ex`). Every
adapter (Feishu webhook, CLI, LiveView, MCP, …) builds the same struct and calls
`dispatch/1`; the 12-step dispatch path is adapter-independent.

```elixir
%Ezagent.Invocation{
  target: %URI{},   # the address (§1) incl. ?action= verb
  mode:   :call | :cast | :call_stream | :subscribe | :introspect,
  args:   %{},      # action arguments (for messaging: %{message: %Message{}})
  ctx:    %{caller: %URI{}, caps: MapSet.t(Capability), reply: reply_target, ...}
}
```

- **`target`** — *where + what*: the addressed URI plus the `?action=` verb.
- **`mode`** — interaction shape. `:call` blocks for a reply (so cap-denial
  bubbles back to a human, Decision #134); `:cast` is fire-and-forget.
- **`ctx`** — *who + how to answer*: `caller` (a URI), `caps` (the
  capability set checked at the CapBAC chokepoint, step 5.5), and `reply` (one
  of 7 reply targets — `:caller_inbox` / `:phoenix_pubsub` / `:ignore` /
  protocol-bound `:plug_conn` / `:phoenix_channel` / `:stdio_pipe` /
  `:mcp_response`). Optional: `trace_id`, `deadline_ms`, `idempotency_key`.

Dispatch is split: `Invocation` owns steps 1-4 + 11-12 (build, route, reply);
`Ezagent.Kind.Runtime` owns 5-10 inside the target Kind's GenServer — including
step 5.5 (CapBAC `matches?`) and step 5.6 (workspace isolation →
`{:error, :cross_workspace_denied}`, distinct from `:unauthorized`).

### 2.2 Message — the identity-invariant payload

`Ezagent.Message` (`apps/ezagent_core/lib/ezagent/message.ex`) is a
*specialization of an Invocation's `args` shape* (Decision #39/#40), carried as
`args.message` on a `session.send` / `*.receive` invocation.

```elixir
%Ezagent.Message{
  id:          "<uuid hex>",     # plain UUID — NOT a `message://` URI (retired PR #149)
  sender:      %URI{},           # entity://user|agent that authored it
  mentions:    [%URI{}],         # @-targets
  body:        %{text: String.t(), attachments: [%URI{}]},
  ref_id:      String.t() | nil, # reply-to another message id
  inserted_at: %DateTime{},
  visibility:  :customer_visible | :operator_only,
  # session_uri / workspace_uri stamped on persist; legend_triggers is a
  # VIRTUAL, non-wire routing hint (never serialized).
}
```

**The identity invariant (the load-bearing rule).** A Message's identity —
`sender`, `mentions`, `body`, `ref_id`, `inserted_at` — is **immutable across
any number of routing / forwarding hops**. A relayer (the routing fan-out,
cross-session re-entry, an external mirror) creates a **new Invocation** that
*carries* the Message to the next recipient; it **never mutates the Message**.
This is what makes "who said what" stable no matter how many sessions or
adapters a message traverses. See `communication-overview.md` §2-3 for the
concrete fan-out (`session.send` → per-recipient `*.receive`).

Message is session-internal data, not a dispatchable Kind — there is no
`message://` scheme. Its `id` lives only in the messages table + the LiveView
stream `dom_id`.

## 3. How the two layers compose

```
adapter event ─▶ build %Invocation{ target: session://ws/tmpl/name?action=session.send,
                                     args:  %{message: %Message{…}},      ◀── payload (identity-invariant)
                                     ctx:   %{caller, caps, reply} }       ◀── envelope (who/how)
              ─▶ dispatch/1 ─▶ routing resolves recipients ─▶ for each:
                 build a NEW %Invocation{ target: <recipient>?action=<kind>.receive,
                                          args: %{message: SAME %Message{}} }   ◀── wrap, never mutate
```

- **URI** answers *where + what* (§1).
- **Invocation** answers *who is asking, how to reply, what mode* (§2.1).
- **Message** answers *what was said* and guarantees it stays unchanged in
  transit (§2.2).

## 4. Open / deferred

- **Message schema versioning** (the code half of this task) is deferred until
  after the im→session→agent physical split (`Entity.Session` / `Message` are
  mid-relocation). When added, a `schema_version` field on the Message envelope
  lets the wire format evolve without breaking persisted rows or in-flight
  relays — to be specced alongside the first backward-incompatible body change.

## 5. Cross-references

- [`communication-overview.md`](./communication-overview.md) — the message flow + fan-out.
- `Ezagent.URI` `@moduledoc` — exhaustive URI rules, canonical-form ladder, parser layering.
- `Ezagent.Invocation` / `Ezagent.Message` `@moduledoc`s — full field semantics.
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — the canonical-form hardening.
- `docs/superpowers/specs/2026-06-05-unify-uri-query-design.md` — URI-as-opaque-id query model.
