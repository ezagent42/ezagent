defmodule Ezagent.Identity.CascadeHookTest do
  @moduledoc """
  Membership-cap unification Phase B.3 (spec §10 / K3, tests 18-19) — the cascade
  hook at the single emit chokepoint + content-free notify.

  Drives a REAL cap grant to an entity X (mutating X's `:identity` slice), then
  asserts X's manager Y is notified content-free on the post-commit
  `DeferredDispatch` turn. Also pins the payload shape (test 18), the off-critical
  -path / non-fatal contract (test 19), and the guard clauses (§13).
  """

  use EzagentCore.DataCase, async: false

  import EzagentDomainIdentity.CapSigningTestHelpers

  alias Ezagent.Capability
  alias Ezagent.Identity.Cascade

  defp uniq, do: System.unique_integer([:positive])

  # X is a spawned USER (the identity-domain test env has no Agent persistence).
  # Using a User for X also exercises skip-self: X is itself in the workspace's
  # user list, and `managers_of/1` must exclude it (deadlock + semantics).
  defp user_with_caps(ws_name, caps) do
    uri = URI.new!("entity://#{ws_name}/user/u-#{uniq()}")
    {:ok, _row} =
      Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", issue_all!(uri, caps))

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp manage_cap_over(x, granter) do
    Ezagent.CreatorGrant.manage_cap(:user, x, Capability.workspace_of(x), granter)
  end

  # Grant an arbitrary (member-cap-shaped) cap to X as admin — mutates X's
  # `:identity` slice, which is the allowlisted `{entity, :identity}` change.
  defp grant_arbitrary_cap_to(x) do
    ws = Capability.workspace_of(x)

    cap = %Capability{
      Capability.cap(:session, Ezagent.ActionSet.Session, :receive, x, ws)
      | granted_by: Ezagent.Entity.User.admin_uri(),
        granted_at: DateTime.utc_now()
    }

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(x)}?action=identity.grant_cap"),
      mode: :call,
      args: %{cap: cap},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    })
  end

  test "grant to X notifies X's manager Y content-free; payload is exactly {uri, slice_key, cursor, event_at} (18)" do
    x = user_with_caps("team-alpha", [])
    manager = user_with_caps("team-alpha", [manage_cap_over(x, URI.new!("entity://team-alpha/user/root"))])
    unrelated = user_with_caps("team-alpha", [])

    :ok = Ezagent.Notifications.subscribe(manager)
    :ok = Ezagent.Notifications.subscribe(unrelated)

    grant_arbitrary_cap_to(x)

    assert_receive {:notification, ^manager, notif}, 2_000

    # Content-free envelope (spec §10): body has EXACTLY these four keys — NO cap
    # values, NO caller, NO member list.
    assert notif.type == :entity_slice_changed
    assert notif.source == Ezagent.Identity.Cascade
    assert Enum.sort(Map.keys(notif.body)) == Enum.sort([:uri, :slice_key, :cursor, :event_at])
    assert notif.body.uri == URI.to_string(x)
    # A cap grant mutates the `:identity` slice (the emitted slice_key) — the
    # allowlisted `{entity, :identity}` change (spec §10's "{entity, :caps}" names
    # the caps CONTAINER; the state_slice/emit key is `:identity`).
    assert notif.body.slice_key == :identity
    assert is_integer(notif.body.cursor)
    assert match?(%DateTime{}, notif.body.event_at)

    # Users-only sink: a non-manager workspace user is NOT notified.
    refute_receive {:notification, ^unrelated, _}, 300
  end

  test "cascade is off the mutating dispatch's critical path — the grant commits regardless (19)" do
    x = user_with_caps("team-alpha", [])
    _manager = user_with_caps("team-alpha", [manage_cap_over(x, URI.new!("entity://team-alpha/user/root"))])

    grant_arbitrary_cap_to(x)

    # The mutation is durably committed the moment the grant returns — the
    # cascade runs on a LATER DeferredDispatch turn and can never roll it back.
    held? =
      x
      |> Ezagent.Identity.read_entity_caps()
      |> Enum.any?(fn
        %Capability{kind: :session} = c -> Capability.action_of(c) == :receive and c.instance == x
        _ -> false
      end)

    assert held?, "the cap grant must have committed (cascade is post-commit, non-fatal)"
  end

  # #161 Phase B codex MED (B-blocking): `:cascade_notify_managers` is cap-exempt
  # and production-reachable via `POST /api/v1/:kind/:action`. Without the
  # in-handler provenance gate, an authenticated SAME-WORKSPACE caller could invoke
  # it directly to trigger a managers-scan + content-free "caps changed" notify
  # (notify-spam / false-signal vector). The gate: the handler proceeds ONLY when
  # `ctx.caller == :vm_internal` (the trusted in-VM marker, #154), which ONLY the
  # internal `Kind.CascadeHook` self-dispatch carries. An external `/api/v1`
  # caller's `ctx.caller` is the AUTHENTICATED entity URI (a `%URI{}` resolved from
  # the bearer token by the controller, transport-set — NOT user args), so it can
  # never be forged to `:vm_internal`.
  test "SECURITY (#161 B MED): an external same-workspace dispatch of :cascade_notify_managers is REJECTED — no managers-scan, no notify" do
    # X and the attacker share ONE workspace, so `workspace_isolation_check`
    # cannot be what rejects — the provenance gate is the only thing that can.
    x = user_with_caps("team-secure", [])
    manager = user_with_caps("team-secure", [manage_cap_over(x, URI.new!("entity://team-secure/user/root"))])
    attacker = user_with_caps("team-secure", [])

    :ok = Ezagent.Notifications.subscribe(manager)

    # Simulate the `POST /api/v1/:kind/:action` path: `ctx.caller` is the
    # authenticated caller entity (a `%URI{}`), NOT `:vm_internal`. The controller
    # honors a requested `"mode": "call"`, so use `:call` to observe the reject
    # return synchronously. Args mirror the real CascadeHook payload so this
    # genuinely exercises the reachable action, not a validation short-circuit.
    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: URI.new!("#{URI.to_string(x)}?action=identity.cascade_notify_managers"),
        mode: :call,
        args: %{slice_key: :identity, cursor: 1, event_at: DateTime.utc_now()},
        ctx: %{caller: attacker, caps: MapSet.new(), reply: :sync}
      })

    assert result == {:error, :unauthorized}

    # The security property: the managers-scan + content-free notify NEVER ran.
    refute_receive {:notification, ^manager, _}, 500
  end

  test "guard clauses (§13): notify_managers ignores bad envelopes, never raises" do
    # non-map args → guard clause → :ok
    assert Cascade.notify_managers(URI.new!("entity://team-alpha/agent/z"), :not_a_map) == :ok
    # unparseable subject → :ok (no notify)
    assert Cascade.notify_managers(nil, %{slice_key: :identity}) == :ok
    # a well-formed call whose subject has no managers → :ok, no crash
    x = URI.new!("entity://team-alpha/agent/lonely-#{uniq()}")
    assert Cascade.notify_managers(x, %{slice_key: :identity, cursor: 1, event_at: DateTime.utc_now()}) == :ok
  end
end
