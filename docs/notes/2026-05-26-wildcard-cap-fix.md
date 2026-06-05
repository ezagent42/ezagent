# wildcard-cap-fix (2026-05-26)

LV happy-path regression: dispatch step 5.5 denied every action linyilun
(`entity://user/system/linyilun`) tried via the LV admin UI — including
`identity.list_caps`, `workspace.create_agent`, and the external_mirror
`list_bindings` chain — even though his `users.caps_json` row carried an
all-`:any` wildcard cap granted by `entity://user/system/admin`.

Surfaced by Allen 2026-05-26 00:02 after the v1 e2e LV happy-path bar
demanded all four scenarios pass:

1. `agent_new_live` Create button → flavor=echo, name=demo_d → agent
   exists.
2. `session_editor` Invite member → autocomplete echo_default → member
   appears.
3. `mix ezagent.external_mirror.bind <session> feishu <oc> --as linyilun`
   succeeds (or fails with a non-cap error).
4. Feishu conversation roundtrip via the bound session.

## Two independent regressions, one PR

### Regression A — URI struct equality denies narrow caps with concrete instance

`Ezagent.Capability.matches?/2`'s `instance_match?/2` had a catch-all
`defp instance_match?(same, same), do: true` clause that pattern-matched
struct equality on `%URI{}` values. For URIs produced by two different
parsers this pattern silently FAILED:

- `URI.parse/1` (deprecated since Elixir 1.13) sets the legacy
  `authority` field; `URI.new!/1` (used by `Ezagent.URI.new!/1`)
  leaves `authority: nil`. Both stringify identically.

The held self-Identity cap that `Behavior.Identity.add_owner_identity_cap/2`
mints at slice init had its `instance` field populated from the `args[:uri]`
URI struct — that URI flowed through `Capability.from_map/1`'s
`URI.parse(s)` path during snapshot deserialization. The needed cap at
dispatch step 5.5 had its `instance` substituted from
`Ezagent.URI.instance(target)` operating on a `URI.new!/1`-produced
struct. Same canonical string, different struct shape → no match → DENIED.

This regression affected EVERY narrow cap with a concrete URI instance —
the bug had been latent since the early URI deprecation but was masked
pre-PR-CC-2-v2 by the legacy `ctx.caps` path (which sometimes carried
the same URI struct on both sides). PR-CC-2-v2 routed cap reads through
`Kind.holds_cap?/2` → `Kind.get_slice/2`, which made the asymmetry
visible.

**Fix** (`apps/ezagent_core/lib/ezagent/capability.ex`):

```elixir
# was:
#   defp instance_match?(same, same), do: true
#   defp instance_match?(_, _), do: false
defp instance_match?(%URI{} = held, %URI{} = needed),
  do: URI.to_string(held) == URI.to_string(needed)

defp instance_match?(same, same), do: true
defp instance_match?(_, _), do: false
```

Mirrors `workspace_match?/2` (which already used `URI.to_string/1`
equality at the workspace axis).

### Regression B — caps_json wildcard never reaches the User Kind's slice

`mix ezagent.user.create entity://user/system/linyilun --caps '*'` writes
the wildcard cap to `users.caps_json` then calls
`Ezagent.SpawnRegistry.spawn(uri)` to "opportunistically" spawn the User
Kind. The registered spawn fn (in `EzagentDomainIdentity.Application`
and — when chat is loaded — overwritten in `EzagentDomainInstanceMessage.Application`)
hard-coded:

```elixir
initial_caps =
  if uri == User.admin_uri() do
    Ezagent.SystemPrincipal.caps("system://bootstrap")
  else
    MapSet.new()        # <-- empty for every non-admin
  end
```

Result: the User Kind's `:identity` slice was initialized with **no
caps_json content**. The default-session cap added by
`User.default_caps/1` was prepended to caps_json BUT not passed to
`init_slice/1` — and the wildcard never made it into the slice either.

A `:on_change` snapshot wrote shortly afterward, freezing the
default+self-Identity state to `kind_snapshots.state_binary`. On every
subsequent phx restart, `Kind.Snapshot.load_or_init/3` preferred the
snapshot over `args[:initial_caps]` (the `Map.merge(fresh, loaded_state)`
contract). The wildcard never reached dispatch step 5.5's
`Kind.holds_cap?/2` lookup — for the LIFETIME of the broken snapshot.

PR-CC-2-v2's `transition_bridge_wildcard()` masked similar divergences
for `system://` principals; PR #358 removed it. linyilun is NOT a system
principal, so that bridge was irrelevant to his path — Regression B was
ALREADY broken pre-#358 for any non-admin who relied on a caps_json
wildcard. The 2026-05-26 LV happy-path bar is the first acceptance gate
that exercised this code path end-to-end.

**Fix** (single chokepoint in `Ezagent.Entity.User.initial_caps_for_spawn/1`):

```elixir
def initial_caps_for_spawn(%URI{} = uri) do
  if uri == @admin_uri do
    Ezagent.SystemPrincipal.caps("system://bootstrap")
  else
    # Hydrate from users.caps_json — the durable bootstrap manifest.
    case Ezagent.Users.get_by_uri(uri) do
      %{caps: caps_list} when is_list(caps_list) -> MapSet.new(caps_list)
      _ -> MapSet.new()
    end
  end
end
```

Both `entity` SpawnRegistry handlers (identity app + chat plugin) call
this helper, so every spawn entry point (mix tasks, LV
`WorkspaceUserAdmin.create_user`, login-mediated
`Entity.ensure_spawned/1`) lands the same cap set in the slice.

### Repair for already-broken users — Behavior.Identity.post_init/2

The fix above corrects NEW users but does nothing for users with a
stale `kind_snapshots` row (like linyilun). To self-repair on next
spawn, `Behavior.Identity` now exports a `post_init/2` /
`handle_continue/3` pair that reads `users.caps_json` after slice
load and merges any missing caps into `slice.caps` as a UNION.
Pre-decided in `post_init/2` so the Kind stays `:not_ready` only when
there's actual reconciliation work to do (no continue when slice
already reflects caps_json).

### V1 limitation: caps_json revoke is not durable

`:revoke_cap` mutates the in-memory slice only — it does NOT update
`users.caps_json`. With the post_init reconcile in place, a revoked
caps_json cap re-appears on next spawn. In practice the caps_json
baseline is `User.default_caps(workspace) ++ <caller-supplied caps at
create>` — revoking those bootstrap caps is not a V1 use case (admin
revocations target post-create `:grant_cap` additions which live in
the slice alone and survive via snapshot). A future SPEC ("caps SoT
consolidation") will sync `:grant_cap` / `:revoke_cap` writes back to
caps_json, at which point the post_init becomes either redundant or
hardened with a "revoked-since" set.

## Why this isn't a "fix the dispatch chokepoint" change

The prompt's first checklist hypothesis (`Kind.holds_cap?/2` /
`Capability.matches?/2` semantics) IS where Regression A landed —
matches.ex line ~244 — and the invariant test at
`apps/ezagent_core/test/invariants/wildcard_cap_authorizes_concrete_needed_test.exs`
locks it as a regression-watch.

Regression B is OUT of the dispatch chokepoint by design — the slice
content is decided at Kind.spawn / Kind.Server.init time, not at
dispatch. Fixing it in `Capability.matches?/2` would have required a
shim ("if wildcard cap is in caps_json, behave as if it's in slice")
which violates `feedback_let_it_crash_no_workarounds`. Fixing at the
spawn chokepoint keeps the dispatch path's "the slice IS the truth"
contract intact.

## Acceptance gates

1. `EzagentCore.Invariants.WildcardCapAuthorizesConcreteNeededTest`
   passes — 6 assertions covering URI-struct normalization (3 cases),
   wildcard match (3 cases), and self-Identity cap pairing.
2. The existing `Ezagent.Integration.SnapshotRestartTest` continues to
   pass — verifies `post_init/2` doesn't break the snapshot-restart
   roundtrip for URIs without a caps_json row.
3. Post-merge: Allen restarts phx, runs the LV happy-path e2e (4
   scenarios) and verifies via agent-browser screenshots.

## Files

- `apps/ezagent_core/lib/ezagent/capability.ex` — `instance_match?/2`
  URI normalization.
- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` —
  `initial_caps_for_spawn/1` shared helper.
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`
  — entity spawn fn delegates to helper.
- `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex` —
  same.
- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` —
  `post_init/2` + `handle_continue/3` for snapshot-load
  reconciliation.
- `apps/ezagent_core/test/invariants/wildcard_cap_authorizes_concrete_needed_test.exs`
  — new invariant test.
