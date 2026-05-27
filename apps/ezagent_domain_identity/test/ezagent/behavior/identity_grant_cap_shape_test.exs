defmodule Ezagent.Behavior.IdentityGrantCapShapeTest do
  @moduledoc """
  Bug 2 regression (Allen 2026-05-26) — `IdentityAdmin.invoke(:grant_cap, ...)`
  used to store the input `cap` arg as-is into the slice MapSet. Three
  caller-shaped inputs reach this entry point:

    1. `%Ezagent.Capability{}` struct (Elixir caller built the struct)
    2. atom-keyed map (Elixir caller passed params)
    3. **string-keyed map** (CLI's Optimus `:map` arg → `Jason.decode/1`)

  Before the fix, shape (3) sat in the slice as a bare string-keyed
  map. `Capability.matches?/2` pattern-matches on `%__MODULE__{}` and
  silently rejected the held map → CLI grants authorized nothing.

  This test pins the contract: all three input shapes produce the
  same canonical `%Capability{}` representation in the slice, and the
  result `matches?/2` the corresponding needed-cap map.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.IdentityAdmin
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://system")
  @session_uri URI.new!("session://default/system/main")
  @granter URI.parse("entity://user/system/admin")

  # All three input shapes encode the same logical capability:
  #
  #   kind:           :session
  #   behavior:       Ezagent.Behavior.ExternalMirror
  #   instance:       session://default/system/main
  #   workspace_uri:  workspace://system
  defp shape_struct do
    %Capability{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: @session_uri,
      workspace_uri: @workspace_uri,
      granted_by: @granter,
      granted_at: DateTime.utc_now()
    }
  end

  defp shape_atom_keyed_map do
    %{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: @session_uri,
      workspace_uri: @workspace_uri
    }
  end

  # The CLI shape — string keys, atom/module/URI values as their
  # serialized string forms (same shape `Jason.decode/1` produces from
  # `mix ezagent user grant_cap --cap '{"kind":"session", ...}'`).
  defp shape_string_keyed_map do
    %{
      "kind" => "session",
      "behavior" => "Ezagent.Behavior.ExternalMirror",
      "instance" => "session://default/system/main",
      "workspace_uri" => "workspace://system"
    }
  end

  # Granter ctx — wildcard `behavior: :any`-on-workspace caps require
  # workspace admin OR bootstrap admin per check_grant_authorized.
  # Concrete kind+behavior caps fall through to the data_owner check;
  # admin caps satisfy both paths.
  defp admin_ctx do
    %{
      caller: @granter,
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  describe "all three input shapes produce the same in-slice representation" do
    test "struct input — passes through unchanged" do
      cap = shape_struct()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: cap}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1
      assert is_struct(stored, Capability)
      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "atom-keyed map input — normalized to struct" do
      params = shape_atom_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1
      assert is_struct(stored, Capability),
             "expected a %Ezagent.Capability{} struct in the slice, got #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "string-keyed (CLI / JSON) map input — normalized to struct" do
      json_map = shape_string_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1

      assert is_struct(stored, Capability),
             "CLI / JSON-decoded cap MUST be normalized to a %Capability{} struct " <>
               "before going into the slice (Bug 2 regression — bare string-keyed " <>
               "map sat here previously, silently denying every cap match). " <>
               "Got: #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
      assert URI.to_string(stored.instance) == "session://default/system/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "all three shapes collapse to ONE row in the slice (identity-tuple dedup)" do
      # Codex review HIGH-1 follow-on: granting the same logical cap
      # via three different input shapes must result in EXACTLY ONE
      # row in the slice — `granted_at` differs across normalizations
      # but the identity tuple (kind+behavior+instance+workspace_uri)
      # is the same. Pre-fix, the slice kept three distinct rows
      # because plain `MapSet.put` distinguishes them by `granted_at`.
      ctx = admin_ctx()

      {:ok, slice_1, _} =
        IdentityAdmin.invoke(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      {:ok, slice_2, _} =
        IdentityAdmin.invoke(:grant_cap, slice_1, %{cap: shape_atom_keyed_map()}, ctx)

      {:ok, slice_3, %{caps: caps}} =
        IdentityAdmin.invoke(:grant_cap, slice_2, %{cap: shape_string_keyed_map()}, ctx)

      assert MapSet.size(slice_3.caps) == 1,
             "three grants of the same identity tuple must collapse to ONE row in " <>
               "the slice — pre-fix, distinct `granted_at` stamps caused MapSet to " <>
               "keep duplicates. Got: #{inspect(slice_3.caps)}"

      [stored] = caps
      assert is_struct(stored, Capability)
      assert stored.kind == :session
      assert stored.behavior == Ezagent.Behavior.ExternalMirror
    end
  end

  describe "revoke_cap correctly removes a cap supplied as CLI / JSON (codex HIGH-1)" do
    test "string-keyed revoke removes the original-timestamp cap" do
      # The HIGH-1 regression: cap granted at T1, revoked from JSON at
      # T2. Pre-fix, `MapSet.delete/2` saw two structurally-distinct
      # caps (different `granted_at`) and silently no-op'd — the cap
      # stayed in force. Post-fix, identity-tuple match removes the
      # original entry.
      ctx = admin_ctx()

      {:ok, slice_after_grant, _} =
        IdentityAdmin.invoke(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      assert MapSet.size(slice_after_grant.caps) == 1

      # Wait one ms so revoke's normalize! stamps a definitely-different
      # granted_at than the original grant.
      Process.sleep(1)

      {:ok, slice_after_revoke, %{caps: caps}} =
        IdentityAdmin.invoke(
          :revoke_cap,
          slice_after_grant,
          %{cap: shape_string_keyed_map()},
          ctx
        )

      assert MapSet.size(slice_after_revoke.caps) == 0,
             "CLI-shaped revoke must remove the original-timestamp cap (codex " <>
               "review HIGH-1). Got: #{inspect(slice_after_revoke.caps)}"

      assert caps == []
    end

    test "atom-keyed revoke removes the original-timestamp cap" do
      ctx = admin_ctx()

      {:ok, slice_after_grant, _} =
        IdentityAdmin.invoke(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      Process.sleep(1)

      {:ok, slice_after_revoke, _} =
        IdentityAdmin.invoke(
          :revoke_cap,
          slice_after_grant,
          %{cap: shape_atom_keyed_map()},
          ctx
        )

      assert MapSet.size(slice_after_revoke.caps) == 0
    end
  end

  describe "revoke_cap refuses the bootstrap-admin invariant cap (codex HIGH-3)" do
    test "direct revoke of the all-axes-:any bootstrap cap is refused" do
      # Codex review HIGH-3: previously `MapSet.delete/2` ran
      # unconditionally; bootstrap admin's structural cap could be
      # removed. Post-fix, `Capability.revoke/2` guards via
      # `admin_invariant?/1`.
      bootstrap_cap = %Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap/default"),
        granted_at: DateTime.utc_now()
      }

      slice = %{caps: MapSet.new([bootstrap_cap])}

      assert {:error, :cannot_revoke_admin} =
               IdentityAdmin.invoke(:revoke_cap, slice, %{cap: bootstrap_cap}, admin_ctx())
    end
  end

  describe "downstream Capability.matches?/2 sees the granted cap" do
    test "string-keyed CLI grant authorizes a matching dispatch (the regression)" do
      # The end-to-end check: a grant via the CLI path (string-keyed
      # map) MUST authorize a dispatch needing the same logical cap.
      # Before the fix, `matches?/2` rejected the bare map → grant was
      # effectively a no-op.
      json_map = shape_string_keyed_map()

      {:ok, slice, _} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      assert Enum.any?(slice.caps, &Capability.matches?(&1, needed)),
             "string-keyed CLI-supplied cap MUST match a matching needed-cap shape " <>
               "via Capability.matches?/2 after normalization. Slice contents: " <>
               inspect(slice.caps)
    end

    test "atom-keyed Elixir grant authorizes a matching dispatch" do
      params = shape_atom_keyed_map()

      {:ok, slice, _} =
        IdentityAdmin.invoke(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      assert Enum.any?(slice.caps, &Capability.matches?(&1, needed))
    end
  end

  describe "Capability.normalize!/2 input validation" do
    test "passes a %Capability{} struct through unchanged" do
      cap = shape_struct()
      assert Capability.normalize!(cap, @granter) == cap
    end

    test "rejects atom-keyed map missing :workspace_uri (no silent default)" do
      bad_input = %{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: :any}

      assert_raise ArgumentError, ~r/missing required `:workspace_uri`/, fn ->
        Capability.normalize!(bad_input, @granter)
      end
    end

    test "rejects garbage shapes" do
      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!("not-a-cap", @granter)
      end

      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!(42, @granter)
      end

      assert_raise ArgumentError, ~r/unrecognized cap shape/, fn ->
        Capability.normalize!(%{unrelated: :map}, @granter)
      end
    end

    test "string-keyed map stamps granted_by from the supplied granter" do
      cap = Capability.normalize!(shape_string_keyed_map(), @granter)

      assert is_struct(cap, Capability)
      assert URI.to_string(cap.granted_by) == URI.to_string(@granter)
      assert match?(%DateTime{}, cap.granted_at)
    end

    test "string-keyed map missing \"workspace_uri\" raises (codex HIGH-2)" do
      # Pre-fix, missing `"workspace_uri"` flowed through `from_map/1`
      # which silently defaulted to `:any` — a CLI typo would have
      # silently widened the cap to cross-workspace authority. Post-fix,
      # the grant chokepoint raises.
      bad = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "instance" => "session://default/system/main"
      }

      assert_raise ArgumentError, ~r/missing required `"workspace_uri"`/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "string-keyed map missing \"instance\" raises (codex HIGH-2)" do
      bad = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "workspace_uri" => "workspace://system"
      }

      assert_raise ArgumentError, ~r/missing required `"instance"`/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "string-keyed map with unknown atom \"kind\" raises — no silent rescue to :any (codex HIGH-2)" do
      # Pre-fix, `string_to_atom_or_module/1` rescued `String.to_existing_atom/1`
      # failures to `:any` — a typoed kind silently became a wildcard cap.
      bad = %{
        "kind" => "totally_made_up_kind_that_no_module_uses_99999",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "instance" => "session://default/system/main",
        "workspace_uri" => "workspace://system"
      }

      assert_raise ArgumentError, ~r/unknown atom or module/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "string-keyed map with unknown module \"behavior\" raises (codex HIGH-2)" do
      bad = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.TotallyMadeUpBehavior999",
        "instance" => "session://default/system/main",
        "workspace_uri" => "workspace://system"
      }

      assert_raise ArgumentError, ~r/unknown atom or module/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "\"any\" string round-trips to :any atom on every axis" do
      # Sanity check — `"any"` is the explicit wildcard, NOT a silent
      # default. Operators who actually want cross-workspace authority
      # must type `"any"` (not omit the field).
      input = %{
        "kind" => "any",
        "behavior" => "any",
        "instance" => "any",
        "workspace_uri" => "any"
      }

      cap = Capability.normalize!(input, @granter)
      assert cap.kind == :any
      assert cap.behavior == :any
      assert cap.instance == :any
      assert cap.workspace_uri == :any
    end

    # SPEC 2026-05-27 capability-action-axis (codex impl PR review CRIT):
    # `normalize!/2` previously DROPPED the input `:action`/`"action"`
    # key, silently defaulting every grant to `action: :any` (behavior-
    # wildcard). The fix below ensures the action axis flows through
    # both grant input shapes.
    test "atom-keyed map propagates :action into the canonical struct" do
      input = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        action: :bind,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      cap = Capability.normalize!(input, @granter)
      assert Capability.action_of(cap) == :bind,
             "atom-keyed grant input MUST propagate `:action` into the canonical struct"
    end

    test "atom-keyed map without :action defaults to :any (declarative wildcard)" do
      cap = Capability.normalize!(shape_atom_keyed_map(), @granter)

      assert Capability.action_of(cap) == :any,
             "atom-keyed shape without `:action` defaults to `:any` (matches `cap/3` constructor's declarative shape; the runtime grant-boundary at `Identity.invoke(:grant_cap)` is the enforcement layer for wildcard grants from non-admin)"
    end

    test "string-keyed map propagates \"action\" into the canonical struct" do
      input = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "action" => "bind",
        "instance" => "session://default/system/main",
        "workspace_uri" => "workspace://system"
      }

      cap = Capability.normalize!(input, @granter)
      assert Capability.action_of(cap) == :bind,
             "string-keyed (CLI) grant input MUST propagate `\"action\"` into the canonical struct — pre-fix, the CLI's narrow `:bind` grant became a silent behavior-wildcard"
    end

    test "string-keyed map with \"action\" => \"any\" stays as :any wildcard" do
      input = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "action" => "any",
        "instance" => "session://default/system/main",
        "workspace_uri" => "workspace://system"
      }

      cap = Capability.normalize!(input, @granter)
      assert Capability.action_of(cap) == :any
    end

    test "string-keyed map without \"action\" defaults to :any (back-compat with pre-SPEC CLI)" do
      cap = Capability.normalize!(shape_string_keyed_map(), @granter)
      assert Capability.action_of(cap) == :any,
             "pre-SPEC CLI payloads lacked `\"action\"`; the default is `:any` so old CLI grants behave like the pre-SPEC behavior-wildcard. New CLI grants narrow by passing an explicit `\"action\"` field."
    end

    test "narrow-action grant produces a cap that does NOT match a different action" do
      # End-to-end version of the CRIT — the matched cap shape MUST
      # reflect the input action.
      input = %{
        "kind" => "session",
        "behavior" => "Ezagent.Behavior.ExternalMirror",
        "action" => "bind",
        "instance" => "session://default/system/main",
        "workspace_uri" => "workspace://system"
      }

      cap = Capability.normalize!(input, @granter)

      needed_unbind = %{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        action: :unbind,
        instance: @session_uri,
        workspace_uri: @workspace_uri
      }

      refute Capability.matches?(cap, needed_unbind),
             "a `\"action\" => \"bind\"` grant MUST NOT authorize `:unbind` dispatch — the action axis must be load-bearing through the CLI normalize path"
    end
  end

  describe "Capability.identity_key/1 + Capability.revoke/2 — provenance-stripped match" do
    test "identity_key/1 ignores granted_by + granted_at" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 100, :second)

      cap_at_t1 = %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: now
      }

      cap_at_t2 = %{
        cap_at_t1
        | granted_by: URI.parse("entity://user/system/other-admin"),
          granted_at: later
      }

      assert Capability.identity_key(cap_at_t1) == Capability.identity_key(cap_at_t2),
             "identity_key/1 MUST ignore provenance metadata (granted_by / granted_at) — " <>
               "otherwise grant-then-revoke via different code paths silently drops " <>
               "the revoke (codex HIGH-1)."
    end

    test "revoke/2 removes a cap with matching identity-tuple but different timestamp" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 100, :second)

      held_cap = %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: now
      }

      revoke_target = %{held_cap | granted_at: later}

      caps = MapSet.new([held_cap])
      assert {:ok, new_caps} = Capability.revoke(caps, revoke_target)
      assert MapSet.size(new_caps) == 0
    end

    test "revoke/2 refuses the bootstrap-admin invariant cap (codex HIGH-3)" do
      bootstrap_cap = %Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: URI.parse("system://bootstrap/default"),
        granted_at: DateTime.utc_now()
      }

      caps = MapSet.new([bootstrap_cap])
      assert {:error, :cannot_revoke_admin} = Capability.revoke(caps, bootstrap_cap)
    end

    # SPEC 2026-05-27 capability-action-axis (codex impl PR review HIGH-1):
    # `identity_key/1` now includes the action axis. Two caps with the
    # same kind/behavior/instance/workspace but different actions are
    # DISTINCT logical identities — granting one MUST NOT dedupe the
    # other, and revoking one MUST NOT remove the other.
    test "identity_key/1 distinguishes per-action grants on the same target" do
      now = DateTime.utc_now()

      cap_bind = %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        action: :bind,
        instance: @session_uri,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: now
      }

      cap_unbind = %{cap_bind | action: :unbind}

      refute Capability.identity_key(cap_bind) == Capability.identity_key(cap_unbind),
             "identity_key/1 MUST distinguish caps that differ only in action axis — pre-fix the key was 4-axis (action ignored), so a `:bind` grant and a `:unbind` grant collapsed onto the same MapSet identity. SPEC 2026-05-27 HIGH-1."
    end

    test "revoke/2 with a :bind-action target leaves a :unbind-action cap intact" do
      cap_bind = %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        action: :bind,
        instance: @session_uri,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: DateTime.utc_now()
      }

      cap_unbind = %{cap_bind | action: :unbind, granted_at: DateTime.utc_now()}

      caps = MapSet.new([cap_bind, cap_unbind])

      # Revoke just the :bind cap. The :unbind cap MUST survive.
      assert {:ok, new_caps} = Capability.revoke(caps, cap_bind)
      assert MapSet.size(new_caps) == 1

      [survivor] = MapSet.to_list(new_caps)
      assert Capability.action_of(survivor) == :unbind,
             "revoking the `:bind` cap MUST leave the `:unbind` cap untouched — pre-fix, identity_key/1 ignored action axis so both caps had the same key and both got removed. SPEC 2026-05-27 HIGH-1."
    end
  end

  describe "codex r2 forgeable-legacy regression — Map.delete(cap, :action) must not bypass narrow check" do
    # codex r2 new HIGH (post-r1-fixes): the workspace-admin
    # predicates' "legacy snapshot" branches used `action_of(cap) == :any`
    # which is forgeable — a caller controlling `ctx.caps` could
    # `Map.delete(cap, :action)` to fall through the narrow check
    # because `Map.get(cap, :action, :any)` defaults to `:any`. Real
    # legacy caps come from `binary_to_term` of pre-SPEC structs
    # (action literally absent). The fix uses `Map.has_key?` — true
    # absent-field check, no defaulting.
    #
    # This test pins the forged-cap rejection at the matcher boundary
    # (the predicate is `defp` in Behavior.Identity; the structural
    # property — narrow cap with forged-absent action must not satisfy
    # an action-specific check — is what this test asserts).

    test "Map.delete(cap, :action) on narrow Workspace :create_session cap does NOT match :add_member" do
      ws_uri = URI.parse("workspace://system")

      narrow_cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :create_session,
        instance: ws_uri,
        workspace_uri: ws_uri,
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: DateTime.utc_now()
      }

      forged = Map.delete(narrow_cap, :action)

      assert not Map.has_key?(forged, :action),
             "pre-condition: forged cap MUST literally lack :action key"

      # matches?/2 must NOT confuse forged-absent with explicit :any.
      # `action_of(forged)` returns :any via Map.get default, but the
      # MATCH must still narrow on the original action: :create_session
      # intent — which is gone after Map.delete. The needed-cap for
      # :add_member must therefore NOT match this forged shape.
      refute Capability.matches?(forged, %{
               kind: :workspace,
               behavior: Ezagent.Behavior.Workspace,
               action: :add_member,
               instance: ws_uri,
               workspace_uri: ws_uri
             }),
             "matcher tolerance only protects deserialized old structs; a forged-absent action must still be rejected at admin-predicate boundary"
    end

    test "real legacy cap (action: :any, key present) still matches any action — backward-compat OK" do
      # Sanity that the fix doesn't break legitimate wildcard caps.
      ws_uri = URI.parse("workspace://system")

      wildcard_cap = %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: ws_uri,
        workspace_uri: ws_uri,
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: DateTime.utc_now()
      }

      assert Capability.matches?(wildcard_cap, %{
               kind: :workspace,
               behavior: Ezagent.Behavior.Workspace,
               action: :add_member,
               instance: ws_uri,
               workspace_uri: ws_uri
             }),
             "action: :any explicit wildcard MUST match every action — preserves catalog/admin semantic"
    end
  end
end
