defmodule Ezagent.Invariants.CapHasWorkspaceTest do
  @moduledoc """
  Phase 9 PR-3 (SPEC v3 §4) invariant — every `Ezagent.Capability`
  carries a `workspace_uri` field, and the field is enforced at
  construction time via `@enforce_keys`.

  Why this test exists: the workspace dimension is what prevents
  cross-tenant cap leakage. A regression that drops the field (or
  reverts `@enforce_keys`) would silently re-introduce the leak —
  every kind/behavior/instance match would succeed regardless of
  workspace, and PR-4's enforcement step would become a no-op.

  ## Pinned invariants

  1. Constructing a `Ezagent.Capability` without `workspace_uri`
     raises `ArgumentError` (compile-time guarantee via
     `@enforce_keys`; runtime check via `struct!/2` here).
  2. Admin's bootstrap cap has `workspace_uri: :any` — the only
     structural cross-workspace cap.
  3. A freshly-provisioned User's default caps have
     `workspace_uri` equal to that user's workspace URI
     (`Ezagent.URI.entity_workspace_uri/1` derived).

  ## What this test does NOT cover

  - Cross-workspace dispatch ENFORCEMENT (Phase 9 PR-4 scope) —
    `cap_for_action/3` derives the needed workspace and
    `matches?/2` checks it; PR-4 wires the runtime denial path
    + telemetry. This invariant test pins the structural fields
    only.
  - Cross-workspace grant authorization (Phase 9 PR-4 scope) —
    `Ezagent.Identity.grant_cap/3` defaults workspace from grantee
    in PR-3; PR-4 enforces that explicit `:any` requests require
    the granter to hold `cross-workspace:dispatch`.
  """

  use ExUnit.Case, async: true

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Capability

  describe "@enforce_keys workspace_uri" do
    test "struct/1 without workspace_uri raises ArgumentError" do
      # `struct!/2` is the runtime equivalent of `%Capability{...}`
      # with `@enforce_keys` — calling it without the required key
      # raises. The compile-time form (`%Capability{kind: ...}`)
      # would raise at compile time with the same root cause.
      assert_raise ArgumentError, ~r/workspace_uri/, fn ->
        struct!(Capability, %{
          kind: :session,
          behavior: :any,
          instance: :any,
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: ~U[2026-05-21 00:00:00Z]
        })
      end
    end

    test "struct/1 WITH workspace_uri succeeds" do
      cap =
        struct!(Capability, %{
          kind: :session,
          behavior: :any,
          instance: :any,
          workspace_uri: URI.new!("workspace://team-alpha"),
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: ~U[2026-05-21 00:00:00Z]
        })

      assert URI.to_string(cap.workspace_uri) == "workspace://team-alpha"
    end
  end

  describe "admin bootstrap cap" do
    test "carries workspace_uri: :any (SPEC v3 §4.4 — structural cross-workspace)" do
      [admin_cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))

      assert admin_cap.workspace_uri == :any,
             "admin's bootstrap cap MUST have workspace_uri: :any so it is " <>
               "cross-workspace by design (the only structural cross-workspace " <>
               "cap — SPEC v3 §4.4 + Decision #81)"
    end

    test "admin_invariant?/1 requires the workspace_uri: :any field" do
      [admin_cap] = MapSet.to_list(Ezagent.SystemPrincipal.caps("system://bootstrap"))
      assert Capability.admin_invariant?(admin_cap)

      # A bootstrap-granted cap with a CONCRETE workspace is NOT the
      # admin structural invariant — it's a workspace-admin cap that
      # would be revokable. The matcher is strict on workspace_uri.
      workspace_admin = %{admin_cap | workspace_uri: URI.new!("workspace://team-alpha")}

      refute Capability.admin_invariant?(workspace_admin),
             "admin_invariant? must require workspace_uri: :any in addition to " <>
               "the triple-:any pattern — a workspace-scoped triple-:any cap is " <>
               "a workspace-admin grant, not the cross-workspace bootstrap"
    end
  end

  describe "User.default_caps/1 scopes to user workspace" do
    test "user provisioned in workspace://team-alpha → default cap carries it" do
      caps = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-alpha"))

      for c <- caps do
        assert %URI{} = c.workspace_uri
        assert URI.to_string(c.workspace_uri) == "workspace://team-alpha"
      end
    end

    test "user provisioned in workspace://team-beta → default cap carries it" do
      caps = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-beta"))

      for c <- caps do
        assert URI.to_string(c.workspace_uri) == "workspace://team-beta",
               "default_caps/1 must use the workspace_uri passed in, not a " <>
                 "hardcoded default — otherwise users in team-beta would " <>
                 "lose their session-participation cap"
      end
    end

    test "default_caps/1 does NOT mint a workspace_uri: :any cap (only admin gets cross-workspace)" do
      caps = Ezagent.Entity.User.default_caps(URI.new!("workspace://team-alpha"))

      refute Enum.any?(caps, fn c -> c.workspace_uri == :any end),
             "default_caps/1 must NEVER mint a :any-workspace cap — that's the " <>
               "admin escape hatch. Ordinary users get workspace-scoped caps so " <>
               "they cannot dispatch into other tenants by structural default."
    end
  end

  describe "to_map/1 + from_map/1 round-trip" do
    test "workspace_uri survives serialize → deserialize" do
      cap = %Capability{
        kind: :session,
        behavior: :any,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-05-21 00:00:00Z]
      }

      m = Capability.to_map(cap)
      assert m["workspace_uri"] == "workspace://team-alpha"

      back = Capability.from_map(m)
      assert URI.to_string(back.workspace_uri) == "workspace://team-alpha"
    end

    test ":any workspace_uri survives round-trip" do
      cap = %Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("system://bootstrap/default"),
        granted_at: ~U[2026-05-21 00:00:00Z]
      }

      m = Capability.to_map(cap)
      assert m["workspace_uri"] == "any"

      back = Capability.from_map(m)
      assert back.workspace_uri == :any
    end
  end
end
