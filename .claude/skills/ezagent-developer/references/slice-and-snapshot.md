# Slice and Snapshot

Two of the most-load-bearing yet least-intuitive concepts in Ezagent. This file is the canonical explainer; if you're reading it, you've probably hit one of the recurring bug classes from the boundary between these two and the underlying DB tables.

Allen 2026-05-26 (after 6 PRs in a row touching slice/snapshot edges): "这是 ezagent 中实现最为复杂、意义最不清晰的一部分".

## TL;DR

| Concept | Lives where | What | When persisted |
|---|---|---|---|
| **Slice** | In-memory map inside a `Kind.Server` GenServer | One Behavior's private working memory on one Kind instance | Never directly — written via `:on_change` snapshot when mutated |
| **Snapshot** | One row in `kind_snapshots` table; `state_binary` is the serialized state map | Disk image of the **whole Kind's state** (every Behavior's slice combined) | Per the Kind's `persistence/0` strategy (5 options) |
| **DB tables** (`messages`, `external_mirror_bindings`, `users.caps_json`, …) | SQLite rows | Source of truth for queryable data (history, audit, projections) | Direct ORM writes (Ecto) |

**Slice is the actor's private state. Snapshot is the actor's state image on disk. DB tables are SSOT for queryable history.** The three must stay aligned; today's bug class is misalignment.

## The mental model

A Kind URI like `entity://user/system/linyilun` corresponds to ONE `Kind.Server` GenServer process. That process holds an in-memory state map:

```elixir
%{
  identity:        %{caps: MapSet<...>, display_name: "Linyilun"},  ← Identity Behavior's slice
  api_keys:        %{providers: %{...}, creator_uri: ...},          ← ApiKeys Behavior's slice
  inbox:           %{messages: [...], unread_count: 3},             ← Inbox Behavior's slice
  notifications:   %{queued: [...], delivered: [...]},
}
```

The state map is **`%{slice_key => slice_value}`**. Each Behavior owns one key (declared via `Behavior.state_slice/0 :: atom()`), and ONLY reads/writes that key in its `invoke/4` callback. Two Behaviors can't see each other's slice by default (see "sibling-slice reads" below).

When the BEAM crashes / phx restarts, that in-memory map is gone. On next demand-spawn of the URI, `Kind.Server.init/1` calls `Ezagent.Kind.Snapshot.load_or_init/3`:

1. **`init_fresh`** — for each declared Behavior, call its `init_slice/1` to get a fresh empty slice (`%{}` or `%{caps: MapSet.new()}`, etc.)
2. **`fetch_snapshot`** — look up the URI in `kind_snapshots` table; if present, `:erlang.binary_to_term/1` the BLOB to recover the saved state map
3. **`Map.merge(fresh, loaded)`** — snapshot WINS; loaded state overwrites fresh. (Why: snapshot captured stable runtime values like Workers' `subscription_state`, `publisher_cursor`; we want those back. New Behaviors added since snapshot get fresh values.)
4. **`prune_orphan_slices`** — drop slice keys from snapshot that no current Behavior owns (e.g. `:api_keys` left over on a User Kind after PR #389 flipped that Behavior to Agent Kind — PR #389 itself).
5. **`reconcile_after_load_behaviors`** (PR #403) — for each Behavior that declares the optional `reconcile_after_load/2` callback, give it the merged slice and let it union DB-projection rows it manages. ExternalMirror uses this to pick up `external_mirror_bindings` rows inserted between the last snapshot and now.

Then `Kind.Server.init/1` continues: register in `KindRegistry`, set ReadyGate to `:not_ready`, persist the initial snapshot if needed, return `{:ok, state, {:continue, :announce_ready}}`. After `:announce_ready` the URI is `:ready` and dispatch can target it.

## Why this complexity

Three ezagent constraints force this design:

1. **Behaviors are plugins, not core** (Decision Log #21-22). Core can't know which Behaviors exist or what state they hold — the state map MUST be schema-free per-key. → Slice key registry rather than typed struct.
2. **BEAM crash / phx restart must not lose state** (production resilience). → Disk persistence required.
3. **N Behaviors × N migrations is unmanageable**. Per-Behavior SQL tables would mean every plugin coordinates migration; impractical for plugin isolation. → Single schema-free BLOB column on `kind_snapshots`.

The combination — schema-free state + plugin model + restart-resilient — is why we DON'T use:

- **`commanded` + event sourcing**: requires compile-time aggregate schema. Wrong for runtime plugin registration. Also: per-Behavior replay logic burden.
- **`:dets` / `:ets` raw KV**: no SQL queryability. Plus we already have SQLite for other tables.
- **Ecto schema per Behavior**: schema migration coordination nightmare.
- **Smart-pointer in shared Redis**: single point of failure + no actor isolation.

Closest commercial analog: **Akka Persistent Actor** (snapshot + journal) or **Microsoft Orleans Grain state** (single state object per grain). Ezagent's slice is essentially the Smalltalk instance-variable view, with explicit per-Behavior namespacing.

## Five persistence strategies

`Kind.persistence/0` returns one of:

| Strategy | When written | Used by |
|---|---|---|
| `:ephemeral` | Never | Session Kind (task ends → terminate) |
| `{:snapshot, :on_change}` | Sync, every slice mutation | User Kind, Agent Kind (most common) |
| `{:snapshot, :periodic, ms}` | Async every `ms`, via Snapshot.Writer | Workers under heavy load |
| `:on_terminate` | GenServer.terminate hook | Things that need normal-shutdown checkpoint |
| `:external` | Never (Kind's `init_slice/1` reads from foreign system on every spawn) | Workspace Kind (`workspaces` table is SSOT) |

## Slice isolation rule + the sibling-slice opt-in escape

Default: **a Behavior's `invoke/4` receives ONLY its own slice** (the `slice` arg). Reading another Behavior's slice on the same Kind requires explicit opt-in via the `reads_sibling_slices/0 :: [atom()]` callback (PR #389 / invariant #18):

```elixir
defmodule Ezagent.Behavior.CurlAgent do
  @impl Ezagent.Behavior
  def reads_sibling_slices, do: [:api_keys]  # explicit declaration

  @impl Ezagent.Behavior
  def invoke(:receive, slice, args, ctx) do
    api_key = ctx[:sibling_slices][:api_keys][:providers]["deepseek"]
    # ... use api_key ...
  end
end
```

`Ezagent.Kind.Runtime.handle_dispatch/4` reads the declaration + injects ONLY the requested slice keys into `ctx[:sibling_slices]`. Without the declaration, `ctx[:sibling_slices]` is `nil`. This was the structural fix for the ApiKeys flip (PR #389) — pre-fix, CurlAgent dispatched `identity.get_api_key` back to `ctx.self_uri`, which after the flip became `GenServer.call(self)` → `:calling_self` deadlock.

**Rule of thumb**: if you find yourself wanting all slices, refactor the slice boundaries instead. `:all_slices` was a generic escape hatch in an early PR-389 draft; codex flagged it CRIT and we replaced with the opt-in scheme above.

## Snapshot vs. DB SSOT — the bug class

Some Behaviors' slices are projections of an SSOT DB table:

| Behavior | Slice key | DB SSOT |
|---|---|---|
| `Ezagent.Behavior.Chat` | `:chat.recent_messages` | `messages` table |
| `Ezagent.Behavior.ExternalMirror` | `:external_mirror.bindings` | `external_mirror_bindings` table |
| `Ezagent.Behavior.Identity` | `:identity.caps` | `users.caps_json` column |

The snapshot is a CACHE of these tables. Three things can go wrong:

### Bug A — snapshot captures stale data, DB has fresh

Scenario: a `external_mirror_bindings` row gets INSERTED outside the dispatch path (SQL hand-fix, race condition, plugin author bypassing the canonical bind API). The session's snapshot was written before the insert. On next Kind restart, `Map.merge(fresh, loaded)` makes snapshot win — the new row is lost from the live slice.

**Fix shape** (PR #403, invariant #20): Behavior implements `reconcile_after_load/2 :: (uri, slice) -> slice` to union DB rows into the merged slice. ExternalMirror unions by `binding_id`, idempotent.

### Bug B — Behavior is removed, snapshot retains its slice key

Scenario: PR #389 moved `ApiKeys` Behavior from User Kind to Agent Kind. User Kinds still have OLD `:api_keys` slice content in their `state_binary` BLOB. AutoDerive LV walks the raw slice map and would render the orphan content (plaintext API keys leaked).

**Fix shape** (PR #389): `prune_orphan_slices/2` drops slice keys not declared by the Kind's current `behaviors/0`. Runs at load, after merge.

### Bug C — slice serializes the wrong shape

Scenario: `grant_cap` CLI accepts a JSON cap map (string keys: `%{"kind" => "session", ...}`); the dispatch action body writes the bare map into `slice.caps`. Next time anyone reads — `Capability.matches?/2` expects `%Capability{}` struct atoms — BadMap.

**Fix shape** (PR #400, invariant #19): single normalization chokepoint `Ezagent.Capability.normalize!/2` converts struct / atom-keyed / string-keyed input → canonical `%Capability{}`. ALL grant paths must go through it. Symmetric: `Capability.revoke/2` + `identity_key/1` for revoke matching (ignore provenance fields).

## Worked example: `entity.send`

Concrete walk-through to make slice/snapshot tangible.

### The Behavior

```elixir
defmodule Ezagent.Behavior.EntitySend do
  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def state_slice, do: :outbox

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{
    pending: [],        # retry queue
    sends_in_60s: [],   # rate-limit window
    last_sent_at: nil,
    total_sent: 0
  }

  @impl Ezagent.Behavior
  def invoke(:send, slice, %{recipient_uri: r, body: b}, ctx) do
    cond do
      length(slice.sends_in_60s) > 10 ->
        {:error, :rate_limit}

      true ->
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: URI.parse("#{r}?action=inbox.receive"),
          args: %{from: ctx.caller, body: b},
          mode: :cast
        })

        now = System.os_time(:second)
        new_slice = %{slice |
          sends_in_60s: [now | Enum.filter(slice.sends_in_60s, &(&1 > now - 60))],
          last_sent_at: DateTime.utc_now(),
          total_sent: slice.total_sent + 1
        }
        {:ok, new_slice, %{ok: true}}
    end
  end
end
```

### What's in slice vs. what's transient

- **Slice (Alice's EntitySend outbox)**: `pending`, `sends_in_60s`, `last_sent_at`, `total_sent`. State Alice's Send Behavior remembers ACROSS calls.
- **Args (transient, per-call)**: `recipient_uri`, `body`. Flow through one call; not stored in slice.
- **Return value (transient)**: `%{ok: true}`. Tells caller "yes the send dispatch happened"; not in slice.

### What's in the recipient (Bob)

Bob's Kind has an `Inbox` Behavior with its own slice:

```elixir
def invoke(:receive, slice, %{from: f, body: b}, _ctx) do
  msg = %{from: f, body: b, at: DateTime.utc_now()}
  new_slice = %{slice |
    messages: [msg | slice.messages],
    unread_count: slice.unread_count + 1
  }
  {:ok, new_slice}
end
```

Bob's inbox slice is where the actual message persists in memory.

### What's in the snapshot

Bob's Kind URI has ONE row in `kind_snapshots`:

```
uri = "entity://user/system/bob"
kind_type = "user"
state_binary = :erlang.term_to_binary(%{
  identity: %{caps: ...},
  inbox: %{messages: [the recent msgs], unread_count: ...},
  api_keys: %{...},
})
```

On Bob's BEAM-crash recovery: read row → deserialize BLOB → THAT IS the state. No replay.

### What's in DB tables

A `messages` table row records every message persistently (queryable history; UI list view; cross-session search). Bob's `inbox.messages` slice is a CACHE of the recent N messages from that table. `reconcile_after_load/2` could pull recent rows on restart if the cache is stale.

## Quick reference: which file changes for slice/snapshot bugs

| Symptom | First look at |
|---|---|
| Slice not picking up DB-projection rows | `reconcile_after_load/2` on the Behavior; was PR #403 merged? |
| Snapshot has orphan slice key (Behavior removed) | `Snapshot.prune_orphan_slices/2`; current `Kind.behaviors/0` correct? |
| Slice has wrong-shape map crashing downstream | Normalization chokepoint — `Capability.normalize!/2` for caps; consider similar pattern for other Behaviors |
| Sibling slice access blowing up GenServer.call(self) | `reads_sibling_slices/0` on the calling Behavior; use `ctx[:sibling_slices]` not dispatch |
| Snapshot write failing under load | `persistence/0` strategy — `:on_change` synchronous is the most expensive; consider `{:periodic, ms}` or `:on_terminate` |
| State lost across restart | Confirm `:ephemeral` isn't the strategy (Session Kind is `:ephemeral` BY DESIGN — task-ending) |

## Where to read the actual code

- `apps/ezagent_core/lib/ezagent/behavior.ex` — Behavior contract + optional callbacks (including `reads_sibling_slices/0`, `reconcile_after_load/2`)
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — `load_or_init/3` + `load_with_fallback/3` + `prune_orphan_slices/2` + `reconcile_after_load_behaviors/3`
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — `init/1` calling all of the above
- `apps/ezagent_core/lib/ezagent/capability.ex` — `normalize!/2` cap normalization chokepoint
- `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` — reference impl of `reconcile_after_load/2`

## See also

- GLOSSARY.md Decision Log #27, #115 (persistence strategies + Snapshot per-Kind r/w)
- GLOSSARY.md Decision Log #123-#129 (the 2026-05-26 batch around ApiKeys flip and reconcile)
- `architecture-invariants.md` invariants #18, #19, #20
- Decision Log §17.2 (why not Event Sourcing)
