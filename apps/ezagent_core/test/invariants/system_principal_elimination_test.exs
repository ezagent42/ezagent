defmodule Ezagent.SystemPrincipalEliminationTest do
  @moduledoc """
  NORTH-STAR ratchet: eliminate `system://` principals entirely (Allen 2026-06-17).

  `system://` principals are an artifact of not having modeled the real authority. The
  goal is to collapse `SystemPrincipal.Catalog` to a SINGLE genesis primitive
  (`system://bootstrap`, itself slated to become `entity://system/user/admin` self-authority
  in the final step); every other authority must trace to a real accountable entity
  (the actor's own held caps, a rule attributed to a real configurer, or the genesis admin).

  This is the broader sibling of `no_unowned_system_principal_grant_test.exs` (which only
  ratchets the GRANT-MINTERS). This gate ratchets the ENTIRE principal set.

  Mechanism (mirrors the no_unowned idiom Allen accepted): `@remaining` is the named set of
  not-yet-eliminated principals; the live Catalog must equal `@remaining ++ [@genesis]`
  exactly. Any Catalog change FORCES an edit here — adding a principal grows `@remaining`
  (a review surface that contradicts the north star → reject), removing one shrinks it
  (the per-class elimination PR's job). The allowlist only shrinks; the terminal state is
  `@remaining == []`, then `@genesis` collapses to the admin entity (the last PR).

  Per-class collapse plan — see `.claude/skills/ezagent-developer/references/capbac.md` §7
  "NORTH STAR".
  """

  use ExUnit.Case, async: true

  alias Ezagent.SystemPrincipal.Catalog

  # The one genesis primitive — eliminated LAST (collapses to entity://system/user/admin).
  @genesis "system://bootstrap"

  # The principals still awaiting elimination. Each per-class PR REMOVES its entries.
  # Shrink-only: the north star is `@remaining == []`.
  @remaining [
    # ELIMINATED 2026-06-20, 甲-4: "system://chat-router" — the last non-genesis
    # wildcard holder. It was borrowed by the Session delivery fan-out for three
    # dispatches, each now re-attributed to a real entity presenting its OWN
    # inline narrow cap (the step-5.5 authorizer `granted_via_ctx_caps?`):
    # (1) the `<entity>.receive` fan-out (`delivery.ex`) presents the RECIPIENT's
    # own `:receive` cap on its own instance (`granted_by: recipient_uri`,
    # member self-consent); (2) the cross-session forward presents `session.send`
    # on the concrete target (`granted_by: source_session`) GUARDED to
    # same-workspace forwards; (3) the agent's `:sync_result` self-dispatch
    # presents an inline self-cap (`granted_by: self_uri`). The per-recipient
    # inline cap is minted at dispatch from the recipient's own URI, so the
    # "open plugin Behavior set cannot be enumerated" rationale for the wildcard
    # is moot. Same play as chat-reply / worker-publish / agent-internal.
    # ELIMINATED 2026-06-20, 甲-3: "system://chat-reply" — it held
    # `bootstrap_wildcard()` and was borrowed by the 5 agent/plugin bridge
    # adapters (curl_agent, plugin_codex, plugin_cc, echo, np_agent) to dispatch
    # `session.send` into the originating session. Each agent is a real entity
    # whose reply dispatch already used `caller: self_uri`/`agent_uri`; each now
    # presents its OWN inline narrow `session.send` cap on the concrete reply
    # session (`granted_by: <agent_uri>` self-authority, least privilege) as the
    # step-5.5 authorizer (`granted_via_ctx_caps?`) instead of borrowing this
    # ambient wildcard. Same play as worker-publish / agent-internal.
    # ELIMINATED: "system://worker-publish" — the ExternalMirrorWorker's two
    # internal self-dispatches now carry their OWN inline authorizer caps
    # (`caller: self_uri` + self-authority publish cap / admin-granted
    # subscribe cap) instead of borrowing this ambient principal.
    "system://template-materialize",
    # ELIMINATED 2026-06-19: "system://orchestrator-tools" — a DEAD caller. The
    # orchestrator's tools run AS the orchestrator agent with ITS OWN caps
    # (`SessionManager.opts` sets caller=orchestrator_uri, caps via in-process
    # `Identity.list_caps_for/1`); the `set_legends` allowlist entry was never
    # reached in production (system path uses session-internal; the orchestrator
    # uses its `{:within_session, self}` delegated cap). Both caps unreachable.
    "system://session-internal",
    # ELIMINATED 2026-06-19: "system://agent-internal" — its only live authority
    # (`cap(:agent, Sandbox, :write_path)`, the freshly-spawned worker writing
    # its OWN `:sandbox` slice) is GENUINE self-authority. The
    # `Agent.TemplateSpawn` dispatch now carries the agent's own instance-scoped
    # `sandbox.write_path` cap inline (`caller: worker_uri`); the
    # `Credential.Resolver` guard that special-cased this principal was
    # generalized to reject any `system://` caller.
    # ELIMINATED 2026-06-19: "system://workspace-loader" — its only authority
    # (`cap(:workspace, Workspace, :any)`, the workspace dispatching its OWN
    # self-maintenance actions on its OWN slice) is GENUINE self-authority. The
    # `Ezagent.Workspace` facade + `Workspace.Loader` dispatches now carry the
    # workspace's own instance-scoped, per-action `cap(:workspace, Workspace,
    # <action>)` inline (`caller: workspace_uri`); same play as worker-publish /
    # agent-internal.
    # ELIMINATED 2026-06-19: "system://mix-task" — it held `bootstrap_wildcard()`
    # and was borrowed by the OPERATOR CLI mix tasks (create_session /
    # agent.create / credential.adopt / stress / cc demo seeders) as an ambient
    # "operator has shell = admin authority" principal (in-VM trust §10.5). The
    # operator's authority now routes through the REAL genesis admin entity
    # `entity://system/user/admin` (`User.admin_uri/0`, seeded with the bootstrap
    # wildcard): each task dispatches with `caller: admin_uri()` carrying an
    # INLINE per-action admin cap in `ctx.caps`. The one GRANT sub-path
    # (`agent.create --caps` → `grant_initial_caps`) routes through the
    # `Ezagent.Identity.Grant` chokepoint as `{:held_by, admin_uri()}`, reading
    # the admin entity's REAL held wildcard. Same play as worker-publish /
    # agent-internal / workspace-loader.
    # ELIMINATED: "system://feishu-binding-policy" (#824 — last grant-minter;
    # redundant re-grant removed) and "system://credential-materializer"
    # (api-key materialization → agent self-authority; per-grant GrantCap remains).
    "system://lv-anon-mount",
    "system://socialware-gc"
  ]

  test "the live Catalog is EXACTLY the genesis primitive + the not-yet-eliminated allowlist" do
    live = MapSet.new(Catalog.uris())
    accounted = MapSet.new([@genesis | @remaining])

    unlisted = MapSet.difference(live, accounted) |> MapSet.to_list()
    stale = MapSet.difference(accounted, live) |> MapSet.to_list()

    assert unlisted == [],
           "New/unaccounted system principal(s): #{inspect(unlisted)} — the north star is to " <>
             "ELIMINATE system principals, not add them. If this is genuinely unavoidable, it is " <>
             "a Decision-#154 review surface; otherwise model the authority as a real entity " <>
             "(self-held caps / a rule with a configurer / the genesis admin). See capbac.md §7."

    assert stale == [],
           "Allowlist entr(ies) no longer in the Catalog: #{inspect(stale)} — an elimination PR " <>
             "removed the principal. Remove it from @remaining too (the allowlist only shrinks)."
  end

  test "the elimination ratchet is monotonic — count never exceeds the allowlist" do
    # A defensive companion to the exact-match test: even if someone swaps (removes one,
    # adds one) the total must not grow beyond the recorded allowlist size.
    assert length(Catalog.uris()) <= length(@remaining) + 1,
           "System-principal count grew. The north star is monotonic elimination; the only " <>
             "permitted Catalog change is REMOVAL (+ a matching @remaining shrink)."
  end

  test "north-star progress is observable" do
    remaining = length(@remaining)
    # Not an assertion on a target (the program lands across PRs) — a visible counter so the
    # ratchet's progress is legible in CI output. Terminal target: 0 remaining (+ genesis,
    # which the final PR collapses to entity://system/user/admin).
    assert remaining >= 0
    IO.puts("\n[north-star] system principals remaining to eliminate: #{remaining} (+ genesis)\n")
  end
end
