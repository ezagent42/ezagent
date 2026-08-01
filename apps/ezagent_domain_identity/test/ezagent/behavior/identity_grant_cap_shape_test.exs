defmodule Ezagent.ActionSet.IdentityGrantCapShapeTest do
  @moduledoc """
  Bug 2 regression (Allen 2026-05-26) — `invoke_shim(:grant_cap, ...)`
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

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.Capability

  @workspace_uri URI.new!("workspace://system")
  @session_uri URI.new!("session://system/default/main")
  @granter Ezagent.URI.new!("entity://system/user/admin")

  # Local test helper that calls the new-contract handler directly
  # (`IdentityAdmin.handle_grant_cap/2`, `handle_revoke_cap/2`) and
  # repackages the result into the 3-tuple shape this test file's
  # pre-migration assertions consume. The helper:
  #
  #   1. Injects `ctx[:read]` that exposes `slice[:caps]` so the
  #      handler's `ctx[:read].(:caps, ...)` lookup returns the same
  #      MapSet the slice carries.
  #   2. Runs the new-contract handler.
  #   3. Reconstructs `{:ok, new_slice, result}` by finding the
  #      `:set` effect for `:caps` in the returned effects list and
  #      lifting it into `new_slice.caps`.
  #
  # The handler's other effects (`:emit` audit events) are discarded —
  # the test file's assertions are slice-based and don't inspect
  # auxiliary effects. Dispatch-parity through Kind.Runtime is covered
  # by `identity_migration_parity_test.exs`.
  defp invoke_shim(:grant_cap, slice, args, ctx) do
    cap = Capability.normalize!(args.cap, ctx.caller)
    {:ok, authority} = Ezagent.Cap.Authority.open(cap.instance, cap.kind)
    cap = authority_signed_cap_as!(authority, ctx.caller, ctx.self_uri, cap)

    handler_ctx =
      Map.put(ctx, :read, fn key, default ->
        case key do
          :caps -> Map.get(slice, :caps, default)
          _ -> default
        end
      end)

    {:ok, result, effects} = IdentityAdmin.handle_grant_cap(%{cap: cap}, handler_ctx)

    new_caps =
      case Enum.find(effects, &match?({:set, :caps, _}, &1)) do
        {:set, :caps, set} -> set
        nil -> Map.get(slice, :caps, MapSet.new())
      end

    {:ok, %{slice | caps: new_caps}, result}
  end

  defp invoke_shim(:revoke_cap, slice, args, ctx) do
    handler_ctx =
      Map.put(ctx, :read, fn key, default ->
        case key do
          :caps -> Map.get(slice, :caps, default)
          _ -> default
        end
      end)

    case IdentityAdmin.handle_revoke_cap(args, handler_ctx) do
      {:ok, result, effects} ->
        new_caps =
          case Enum.find(effects, &match?({:set, :caps, _}, &1)) do
            {:set, :caps, set} -> set
            nil -> Map.get(slice, :caps, MapSet.new())
          end

        {:ok, %{slice | caps: new_caps}, result}

      {:error, _} = err ->
        err
    end
  end

  # All three input shapes encode the same logical capability:
  #
  #   kind:           :session
  #   behavior:       Ezagent.ActionSet.ExternalMirror
  #   instance:       session://system/default/main
  #   workspace_uri:  workspace://system
  defp shape_struct do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.ExternalMirror,
      instance: @session_uri,
      workspace_uri: @workspace_uri,
      granted_by: @granter,
      granted_at: DateTime.utc_now()
    }
  end

  defp shape_atom_keyed_map do
    %{
      kind: :session,
      behavior: Ezagent.ActionSet.ExternalMirror,
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
      "behavior" => "Ezagent.ActionSet.ExternalMirror",
      "instance" => "session://system/default/main",
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
      self_uri: @granter,
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }
  end

  describe "all three input shapes produce the same in-slice representation" do
    test "struct input — passes through unchanged" do
      cap = shape_struct()

      {:ok, new_slice, %{caps: caps}} =
        invoke_shim(:grant_cap, %{caps: MapSet.new()}, %{cap: cap}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1
      assert is_struct(stored, Capability)
      assert stored.kind == :session
      assert stored.behavior == Ezagent.ActionSet.ExternalMirror
      assert URI.to_string(stored.instance) == "session://system/default/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "atom-keyed map input — normalized to struct" do
      params = shape_atom_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        invoke_shim(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1

      assert is_struct(stored, Capability),
             "expected a %Ezagent.Capability{} struct in the slice, got #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.ActionSet.ExternalMirror
      assert URI.to_string(stored.instance) == "session://system/default/main"
      assert URI.to_string(stored.workspace_uri) == "workspace://system"
    end

    test "string-keyed (CLI / JSON) map input — normalized to struct" do
      json_map = shape_string_keyed_map()

      {:ok, new_slice, %{caps: caps}} =
        invoke_shim(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      [stored] = caps
      assert MapSet.size(new_slice.caps) == 1

      assert is_struct(stored, Capability),
             "CLI / JSON-decoded cap MUST be normalized to a %Capability{} struct " <>
               "before going into the slice (Bug 2 regression — bare string-keyed " <>
               "map sat here previously, silently denying every cap match). " <>
               "Got: #{inspect(stored)}"

      assert stored.kind == :session
      assert stored.behavior == Ezagent.ActionSet.ExternalMirror
      assert URI.to_string(stored.instance) == "session://system/default/main"
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
        invoke_shim(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      {:ok, slice_2, _} =
        invoke_shim(:grant_cap, slice_1, %{cap: shape_atom_keyed_map()}, ctx)

      {:ok, slice_3, %{caps: caps}} =
        invoke_shim(:grant_cap, slice_2, %{cap: shape_string_keyed_map()}, ctx)

      assert MapSet.size(slice_3.caps) == 1,
             "three grants of the same identity tuple must collapse to ONE row in " <>
               "the slice — pre-fix, distinct `granted_at` stamps caused MapSet to " <>
               "keep duplicates. Got: #{inspect(slice_3.caps)}"

      [stored] = caps
      assert is_struct(stored, Capability)
      assert stored.kind == :session
      assert stored.behavior == Ezagent.ActionSet.ExternalMirror
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
        invoke_shim(
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
        invoke_shim(
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
        invoke_shim(
          :grant_cap,
          %{caps: MapSet.new()},
          %{cap: shape_struct()},
          ctx
        )

      Process.sleep(1)

      {:ok, slice_after_revoke, _} =
        invoke_shim(
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
      # #154 genesis collapse (2026-06-20): the revoke-protected genesis cap is
      # now the admin-entity-granted wildcard (`admin_genesis_cap/0`), recognized
      # by `admin_invariant?/1` via granted_by == entity://system/user/admin.
      bootstrap_cap = Ezagent.Capability.admin_genesis_cap()

      slice = %{caps: MapSet.new([bootstrap_cap])}

      assert {:error, :cannot_revoke_admin} =
               invoke_shim(:revoke_cap, slice, %{cap: bootstrap_cap}, admin_ctx())
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
        invoke_shim(:grant_cap, %{caps: MapSet.new()}, %{cap: json_map}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        action: :any,
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
        invoke_shim(:grant_cap, %{caps: MapSet.new()}, %{cap: params}, admin_ctx())

      needed = %{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
        action: :any,
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
      bad_input = %{kind: :session, behavior: Ezagent.ActionSet.ExternalMirror, instance: :any}

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
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
        "instance" => "session://system/default/main"
      }

      assert_raise ArgumentError, ~r/missing required `"workspace_uri"`/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "string-keyed map missing \"instance\" raises (codex HIGH-2)" do
      bad = %{
        "kind" => "session",
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
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
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
        "instance" => "session://system/default/main",
        "workspace_uri" => "workspace://system"
      }

      assert_raise ArgumentError, ~r/unknown atom or module/, fn ->
        Capability.normalize!(bad, @granter)
      end
    end

    test "string-keyed map with unknown module \"behavior\" raises (codex HIGH-2)" do
      bad = %{
        "kind" => "session",
        "behavior" => "Ezagent.ActionSet.TotallyMadeUpBehavior999",
        "instance" => "session://system/default/main",
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
        behavior: Ezagent.ActionSet.ExternalMirror,
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
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
        "action" => "bind",
        "instance" => "session://system/default/main",
        "workspace_uri" => "workspace://system"
      }

      cap = Capability.normalize!(input, @granter)

      assert Capability.action_of(cap) == :bind,
             "string-keyed (CLI) grant input MUST propagate `\"action\"` into the canonical struct — pre-fix, the CLI's narrow `:bind` grant became a silent behavior-wildcard"
    end

    test "string-keyed map with \"action\" => \"any\" stays as :any wildcard" do
      input = %{
        "kind" => "session",
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
        "action" => "any",
        "instance" => "session://system/default/main",
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
        "behavior" => "Ezagent.ActionSet.ExternalMirror",
        "action" => "bind",
        "instance" => "session://system/default/main",
        "workspace_uri" => "workspace://system"
      }

      cap = Capability.normalize!(input, @granter)

      needed_unbind = %{
        kind: :session,
        behavior: Ezagent.ActionSet.ExternalMirror,
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
        behavior: Ezagent.ActionSet.ExternalMirror,
        instance: @session_uri,
        workspace_uri: @workspace_uri,
        granted_by: @granter,
        granted_at: now
      }

      cap_at_t2 = %{
        cap_at_t1
        | granted_by: Ezagent.URI.new!("entity://system/user/other-admin"),
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
        behavior: Ezagent.ActionSet.ExternalMirror,
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
      # #154 genesis collapse (2026-06-20): the revoke-protected genesis cap is
      # the admin-entity-granted wildcard (`admin_genesis_cap/0`).
      bootstrap_cap = Ezagent.Capability.admin_genesis_cap()

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
        behavior: Ezagent.ActionSet.ExternalMirror,
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
        behavior: Ezagent.ActionSet.ExternalMirror,
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

  describe "codex r4 SPEC option-B — admin_invariant? requires explicit action: :any (no legacy fallback)" do
    # codex r4 outcome: empirical verification showed `Map.delete(cap, :action)`
    # and genuine pre-SPEC snapshot caps produce indistinguishable shapes
    # (both have :action key absent, both return :any via Map.get default).
    # No code-level fix can distinguish them at the cap-shape layer.
    #
    # Allen's choice (option B): remove the legacy fallback entirely.
    # Pre-SPEC admin caps lacking :action are rejected — operators must
    # re-grant via Identity.grant_cap (which now writes action: :any
    # explicitly via normalize!/2). Trade-off:
    #
    #   PRO: Map.delete forgery can't impersonate admin authority
    #   PRO: cap shape is unambiguous post-SPEC (always has :action)
    #   CON: pre-SPEC admin caps in snapshots need re-grant on upgrade
    #
    # These tests pin the new strict semantic — post-SPEC admin caps
    # accepted; legacy missing-key caps rejected.

    test "admin_invariant?: explicit action: :any post-SPEC admin cap is accepted" do
      # #154 genesis collapse (2026-06-20): the genesis granter is the admin
      # ENTITY (entity://system/user/admin), not the eliminated system://bootstrap.
      post_spec = %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: DateTime.utc_now()
      }

      assert Capability.admin_invariant?(post_spec),
             "post-SPEC explicit-wildcard admin cap MUST be recognized"
    end

    test "admin_invariant?: pre-SPEC legacy cap (Map.delete on :action key) is REJECTED" do
      # The legacy fallback is removed (option B). Pre-SPEC admin caps
      # serialized without :action field cannot impersonate admin
      # authority. Same shape as Map.delete forgery — neither succeeds.
      full_legacy = %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: DateTime.utc_now()
      }

      legacy_or_forged = Map.delete(full_legacy, :action)

      assert not Map.has_key?(legacy_or_forged, :action),
             "pre-condition: :action key absent (legacy OR forged shape)"

      refute Capability.admin_invariant?(legacy_or_forged),
             "post-option-B: legacy/forged missing-:action admin shape MUST be rejected — operator re-grant required"
    end

    test "admin_invariant?: narrow action does NOT pass admin recognition" do
      narrow = %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :create_session,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: DateTime.utc_now()
      }

      refute Capability.admin_invariant?(narrow),
             "narrow-action admin-shaped cap MUST NOT confer admin authority"
    end

    test "admin_invariant?: non-admin-entity granted_by rejected regardless of cap shape" do
      # #154 genesis collapse: the genesis granter is the admin ENTITY; an
      # admin-SHAPED wildcard granted by any OTHER entity is not the genesis cap.
      fake_admin = %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("entity://system/user/some-attacker"),
        granted_at: DateTime.utc_now()
      }

      refute Capability.admin_invariant?(fake_admin),
             "granted_by MUST be entity://system/user/admin — admin-shape with a " <>
               "non-admin-entity granter is not the genesis cap"
    end
  end
end
