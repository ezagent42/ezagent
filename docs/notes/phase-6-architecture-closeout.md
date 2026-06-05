# Phase 6 — Architecture closeout

Forensic record of the 24 phase-6 PRs vs. the architecture
documents, written at merge-time (2026-05-18). Companion to the
short rows added to ARCHITECTURE.md Decision Log (#132-#134),
GLOSSARY.md, and IMPLEMENTATION_ROADMAP.md §9.

This file exists because three implementation choices were
trade-offs (not obvious one-best-answers) and the *why* needs to
survive long enough for the next person touching the same area to
find it.

---

## 1. What actually shipped vs. what §9 promised

§9 of IMPLEMENTATION_ROADMAP.md was written before Phase 6 work
started; the actual delivery diverged. Honest accounting:

| §9 deliverable | Status |
| --- | --- |
| 6a CC channel v1 → v2 wire swap | Partial. v2 `EzagentPluginCc` (Phoenix.Socket + BridgeRegistry) shipped in PR 4 and is the binding target the runtime checks first; v1_prototype is still the live transport for `agent://cc-demo` end-to-end. Full v2 cutover deferred to Phase 7. |
| 6b EZAGENT_HOME DB migration | Not done. Still on the to-do list. |
| 6c CLI token-based auth | Not done. CLI still uses admin-all-cap via cookie. |
| 6d Workspace-scoped routing | Not done. Routing remains global. |
| 6e Federation MVP | Not done. Optional per §9. |
| 6f Plugin scaffolder | Not done (intentionally per §9, "Allen 2026-05-17 现在不做"). |

What *did* ship (24 PRs, the actual Phase 6 work):

- **Feishu production hardening**: WS long-connect sidecar
  (PR 15), `UserBinding` + `BindingPolicy` (PR 15), @-mention
  routing (PR 16), react-ack via direct httpc bypass of `Client`
  mailbox (PR 17), `SenderResolver` auto-spawn on inbound (PR 18),
  image/file pass-through (PR 14), inbound delegation + error
  feedback to operator (PR 27).
- **CC bridge / PTY resilience**: per-bridge file logging +
  verbose trace (PR 21), eager-announce + auto-prompts (PR 19),
  SSE-subscriber dedup (PR 20), announce retry-forever with
  backoff (PR 22), `claude-pty-settings.json` override of
  `remoteControlAtStartup` for PtyServer-spawned claude (PR 23).
- **CC channel protocol compliance**: drop list-valued `meta`
  keys, conform to channels-reference `Record<string, string>`
  schema (PR 26).
- **User identity baseline**: `Ezagent.Entity.User.default_caps/0`
  structural default, `Users.create/3` prepends defaults,
  `BindingPolicy` idempotently re-grants for pre-PR-27 users
  (PR 27).

The roadmap should be updated to reflect this divergence: §9 entry
"6f production hardening (Feishu, CC bridge, identity)" is what
actually happened; the original 6a-6e items move to Phase 7.

---

## 2. Three architectural trade-offs that need future-dev attention

### 2.1 `User.default_caps()` uses `behavior: :any` instead of a module reference

`Ezagent.Capability.matches?/2` compares cap's `behavior` field
against the action's *resolved module* (e.g.
`Ezagent.Behavior.Chat`), not against an atom shorthand. A cap
written `behavior: :chat` looks correct but never matches —
silently denied at CapBAC.

The "right" default cap for chat would be:

```elixir
%Capability{
  kind: :session,
  behavior: Ezagent.Behavior.Chat,   # ← module reference
  instance: :any,
  ...
}
```

But `Ezagent.Entity.User` lives in `ezagent_domain_identity`, and
`Ezagent.Behavior.Chat` lives in `ezagent_domain_instance_message`.
`ezagent_domain_instance_message` already depends on `ezagent_domain_identity`
(needs `Ezagent.Entity.User`). Adding the reverse direction
creates a circular dep at compile time.

Three considered options:

1. **Module reference (correct):** requires breaking the
   circular dep. Architecturally cleanest, biggest refactor.
2. **Runtime lookup via `Ezagent.BehaviorRegistry`:** would need
   `BehaviorRegistry` to be populated at user-creation time,
   which is boot-order fragile (Identity domain boots before
   plugin domains).
3. **`behavior: :any` wildcard:** what we did. Matches the
   existing convention (`admin_caps` uses `:any:any:any`;
   `feishu_chat` cap uses `:feishu_chat:any:any`). The narrow
   scope (`kind: :session`) keeps blast radius confined to one
   Kind family.

**Why this is a trade-off, not an idiom:** the existing `:any`
caps (`admin_caps`, `feishu_chat`) are intentionally broad —
admin owns everything; `feishu_chat` Kind is a small family
where the breadth is fine. `User.default_caps` is different:
it's a structural baseline applied to *every* user, and ideally
would scope down to the specific Behavior the user is being
authorized to attempt. The `:any` here is **a workaround for
a circular dep**, not a design statement.

**What future devs should NOT do:** copy this pattern and write
`plugin_x_kind:any:any` thinking "default caps idiomatically use
:any." If a future plugin can express its cap as a module
reference without creating a circular dep, it should.

**When to revisit:** if the dep graph gets reorganized
(`ezagent_domain_instance_message`'s `Ezagent.Behavior.Chat` module moves to
`ezagent_core` or somewhere upstream of `ezagent_domain_identity`),
narrow `User.default_caps` to the specific module reference.

### 2.2 `InboundDispatcher.do_dispatch` dispatch mode `:cast` → `:call`

`Ezagent.Behavior.Chat.@interface[:send]` declares `:send` as a
`:cast` action (fire-and-forget, no result). PR 27 changed the
Feishu inbound transport to dispatch with `mode: :call` so that
authorization failures can return synchronously and be sent
back to the human in Feishu as an error text + THUMBSDOWN
react.

This works because `Ezagent.Invocation.dispatch/1` accepts any mode
the caller passes — the `@interface` declaration is a hint to
*default* transport behavior, not a hard contract that callers
must respect. But the divergence creates a documentation gap:
someone reading `Chat.@interface` will see `:send → :cast` and
might assume all callers fire-and-forget.

**Why we did it:** the alternative is silent drop at the
CapBAC gate — the bound Feishu user types a message,
authorization denies, the user sees nothing happen. Allen's
"silent down 不可接受" feedback (2026-05-18) made this a hard
requirement.

**What future devs should NOT do:** copy `mode: :cast` from
some other call site into Feishu's inbound path "to match the
interface declaration." The transport correctly overrides for
the error-feedback use case.

**Documentation lock:** Decision #134 records the trade-off.
If a future PR formalizes a "transport can request synchronous
result regardless of declared action mode" contract, it should
update both the Decision and `Ezagent.Behavior` moduledoc.

### 2.3 Channel meta schema = `Record<string, string>` (external invariant)

PR 26 fixed a silent-drop bug where PR 14 had added
`meta.attachments` as a list value. The channels-reference spec
declares `meta: Record<string, string>` — any non-string value
causes claude TUI to silently drop the entire notification, no
error to either side.

**This is not an Ezagent design decision** — it's an external
contract Anthropic owns. Ezagent's adapter MUST conform.

**What broke before:** PR 14 author (correctly, from an Ezagent
internal POV) thought structured attachment metadata should be
in `meta` next to other context. The spec says no. The bug
sat undetected for 3 weeks because nothing in Ezagent's test
harness validated the channels-reference schema; the symptom
("messages don't arrive") looked like a transport-layer issue
and was repeatedly mis-diagnosed.

**What future devs should NOT do:** put structured data
(lists, maps, nested objects) into `meta` when emitting
`notifications/claude/channel`. If structured data needs to
reach claude, encode it into `content` text (a breadcrumb or
JSON line the model can parse) or use a `tools/call` round-trip
to fetch it explicitly.

**Documentation lock:** Decision #132 + the invariant test in
`apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs`
("to_claude payload meta values are all strings (no list/map
smuggling)"). The test must fail in CI if anyone re-introduces
a non-string meta value.

---

## 3. What did NOT drift — patterns to lock in as canonical

These were done well and should be the reference implementations
future PRs cite:

1. **`InboundDispatcher` error feedback to operator** (PR 27) —
   wraps the silent-drop anti-pattern with sync result + human
   text. Apply the same pattern to any future inbound transport
   (Slack, Discord, email, etc.).
2. **`SenderResolver` auto-spawn of bound user Kind** (PR 18) —
   respects the Kind lifecycle (register → subscribe →
   announce_ready, Decision #66) instead of trying to short-cut
   into a dead actor.
3. **`BindingPolicy` idempotent re-grant via MapSet semantics**
   (PR 27) — calling `BindingPolicy.apply/2` twice on the same
   user doesn't double-grant. The Identity slice de-dupes
   automatically. Future "ensure user X has cap Y" code paths
   should use the same shape.
4. **Channel meta schema compliance** (PR 26) — strip
   non-string values, move structured data to content. Don't
   try to extend the meta wire format.
5. **CC channel v2 architecture** (PR 4 — Phoenix.Socket +
   BridgeRegistry) — even though the cutover from v1_prototype
   is incomplete, the v2 architecture is sound. Phase 7's wire
   swap should be a transport change, not a redesign.

---

## 4. Pointers (for the next person who reads this)

- **The Decision Log entries that locked these in:** ARCHITECTURE.md
  #132 (meta schema), #133 (User default caps), #134
  (InboundDispatcher mode). Each cross-references this file.
- **Tests that act as CI gates for the invariants:**
  - `apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` —
    meta-string invariant
  - `apps/ezagent_domain_identity/test/esr/entity/user_test.exs` —
    `default_caps/0` shape invariants
- **Live state migration:** pre-PR-27 users get
  `User.default_caps()` topped up at next Feishu bind via
  `BindingPolicy.ensure_user_default_caps/2`. Manual backfill
  for users who don't have a Feishu binding:
  `Ezagent.Behavior.Identity.invoke(:grant_cap, ...)`.

---

*Closeout signed off by Allen 2026-05-18.*
