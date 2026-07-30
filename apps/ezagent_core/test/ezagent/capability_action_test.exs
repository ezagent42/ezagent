defmodule Ezagent.CapabilityActionTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 — acceptance criteria
  A1-A4 + C1 + the matcher-tolerance regression test (B3 lives in
  `test/integration/cap_action_axis_snapshot_restore_test.exs`).

  Pure-data assertions on the matcher's action-axis semantics — no
  Repo, no GenServer, no boot. Async-safe.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability

  describe "A1 — cap/3 stores the action atom" do
    test "Capability.cap(:session, Chat, :send).action == :send" do
      cap = Capability.cap(:session, Ezagent.ActionSet.Session, :send)
      assert cap.action == :send
    end

    test "Capability.cap(:session, Chat, :any).action == :any (declarative wildcard)" do
      cap = Capability.cap(:session, Ezagent.ActionSet.Session, :any)
      assert cap.action == :any
    end

    test "Capability.cap/5 stores the action atom" do
      session_uri = URI.new!("session://team-alpha/default/main")
      workspace_uri = URI.new!("workspace://team-alpha")

      cap =
        Capability.cap(:session, Ezagent.ActionSet.Session, :send, session_uri, workspace_uri)

      assert cap.action == :send
      assert cap.instance == session_uri
      assert cap.workspace_uri == workspace_uri
    end
  end

  describe "A2 — narrow action does NOT match a different action" do
    test "held :send does NOT authorize needed :join" do
      held = build_held_cap(:send)
      needed = build_needed(:join)

      refute Capability.matches?(held, needed),
             "a held cap narrowed to :send MUST NOT satisfy a needed :join cap-check — that's the PR #408 round-3 over-grant bug this SPEC fixes"
    end

    test "held :add_member does NOT authorize needed :create_session (the canonical bug)" do
      held = %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :add_member,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: DateTime.utc_now()
      }

      needed = %{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: URI.new!("workspace://team-alpha"),
        workspace_uri: URI.new!("workspace://team-alpha")
      }

      refute Capability.matches?(held, needed),
             "the PR #408 round-3 case: a workspace member cap intended for :add_member must NOT cover :create_session"
    end
  end

  describe "A3 — :any action wildcard preserves match" do
    test "held action :any matches needed :send" do
      held = build_held_cap(:any)
      needed = build_needed(:send)

      assert Capability.matches?(held, needed),
             "an action-wildcard held cap MUST match a concrete needed action — the matcher's `:any` wildcard semantics for the action axis must mirror the kind/behavior axes"
    end

    test "held action :send matches needed :send (identity)" do
      held = build_held_cap(:send)
      needed = build_needed(:send)

      assert Capability.matches?(held, needed)
    end
  end

  describe "A4 — old JSON row (6 fields, no action) loads as :any" do
    test "from_map shim defaults missing \"action\" to \"any\" before atomization" do
      old_row = %{
        "kind" => "chat",
        "behavior" => "Ezagent.ActionSet.Session",
        "instance" => "any",
        "workspace_uri" => "workspace://team-alpha",
        "granted_by" => "entity://system/user/admin",
        "granted_at" => "2026-01-01T00:00:00Z"
      }

      refute Map.has_key?(old_row, "action"),
             "test fixture invariant: the old row genuinely lacks an `\"action\"` key"

      cap = Capability.from_map(old_row)

      assert cap.action == :any,
             "Capability.from_map/1 MUST inject `\"action\" => \"any\"` before atomization for pre-action-axis JSON rows (SPEC §3.4 backward-compat read path)"
    end

    test "round-trip: from_map(to_map(cap)) preserves action" do
      original = build_held_cap(:send)
      round_tripped = original |> Capability.to_map() |> Capability.from_map()

      assert round_tripped.action == :send,
             "to_map/from_map must be lossless on the action axis"
    end

    test "action_of/1 returns :any for caps with no :action key" do
      legacy = Map.delete(build_held_cap(:any), :action)

      refute Map.has_key?(legacy, :action),
             "test fixture invariant: the legacy cap genuinely lacks :action"

      assert Capability.action_of(legacy) == :any,
             "action_of/1 MUST be missing-key tolerant per §3.3.1"
    end
  end

  describe "#189 identity-plane divergence — from_map (READ side) must NOT widen a signed cap's lost action to :any" do
    # ROOT CAUSE (verified against live prod stable node, 2026-07-30/31): five
    # freshly-created users each held ONE workspace cap that differed between the
    # two identity planes — `users.caps_json` (durable) carried
    # `action: :create_session` (signature VALID), while the
    # `Ezagent.EntityCaps.Store` mirror serialized the SAME signed cap as
    # `action: :any` (workspace-admin, signature now INVALID). `:any` on Workspace
    # is workspace-admin; `:create_session` is an ordinary member — a PRIVILEGE
    # divergence the `FleetParity.caps_parity/3` barrier correctly refused on.
    #
    # MECHANISM (READ side): `Ezagent.Capability.Normalize.from_map/1` is the
    # tolerant deserializer for `caps_json`. `Map.put_new("action", "any")`
    # SILENTLY defaults a MISSING `"action"` to `:any` while `decode_signature/1`
    # DECODES and preserves the map's `"signature"` verbatim — turning a JSON map
    # that has a signature but lost its `"action"` key into a signed `:any`
    # (workspace-admin) cap. This is the read-side symmetric twin of
    # `fill_defaults/1`'s write-side widening; a signed cap post-dates the
    # action-axis, so a signed-and-action-less map is corruption, not legacy.
    #
    # These are pure-data assertions on the deserialization chokepoint.

    # The signed `create_session` workspace cap AS STORED in `caps_json` (string-
    # keyed JSON map). A non-nil `"signature"` marks it post-action-axis: it MUST
    # carry a concrete `"action"`. (Signature bytes are a real base64url value
    # captured from the live stable node so `decode_signature/1` accepts them.)
    defp signed_create_session_json do
      %{
        "kind" => "workspace",
        "behavior" => "Ezagent.ActionSet.Workspace",
        "action" => "create_session",
        "instance" => "workspace://team-alpha",
        "workspace_uri" => "workspace://team-alpha",
        "granted_by" => "entity://system/user/admin",
        "granted_at" => "2026-07-30T15:05:12.545128Z",
        "signature" =>
          "QKFJhMyeoS4OhTPQb-JZ3UcWP06uqNAtWMC690JF56SGxNDS6RyQ4E6_p7N8TBRnnCXK5qstw945TeAh0wewAA",
        "key_id" => "kind-g1:CvcLxDl6515X4XmKWXIaR2F8y9qzKlNV5fNp2PGzhA8"
      }
    end

    test "control: the intact signed JSON decodes to the concrete :create_session action" do
      cap = Capability.from_map(signed_create_session_json())

      assert cap.action == :create_session
      refute is_nil(cap.signature), "the signature must round-trip (it covers create_session)"
    end

    test "from_map/1 REFUSES a signed map that lost its \"action\" (no silent :any widening)" do
      corrupted = Map.delete(signed_create_session_json(), "action")

      refute Map.has_key?(corrupted, "action"),
             "fixture invariant: the corrupted map genuinely lacks an \"action\" key"

      # FAILS-BEFORE (origin/main): `from_map/1` returns
      # `%Capability{action: :any, signature: <preserved>}` — the exact escalated,
      # signature-mismatched artifact that reached the store mirror. PASSES-AFTER:
      # the fail-closed guard raises rather than widening.
      assert_raise ArgumentError, ~r/signed capability map is missing its `"action"`/i, fn ->
        Capability.from_map(corrupted)
      end
    end

    test "legacy tolerance preserved: an UNSIGNED map missing \"action\" still decodes to :any" do
      # A genuinely pre-#1399 row carries NO signature, so a missing "action" is
      # honest legacy (it predates the axis) — tolerantly decode to :any, do NOT
      # raise (the SPEC §3.4 / A4 backward-compat read path must not regress).
      unsigned_legacy =
        signed_create_session_json() |> Map.delete("action") |> Map.delete("signature")

      assert is_nil(Map.get(unsigned_legacy, "signature"))
      assert Capability.from_map(unsigned_legacy).action == :any
    end

    test "the two identity planes cannot diverge through decode on the same signed cap" do
      # `to_map/1` ALWAYS serializes a concrete "action"; only the corrupted
      # (action-key-dropped) map produces the escalated variant, which decode now
      # refuses — so no `caps_json` ⇄ store round-trip can widen the signed cap.
      intact = signed_create_session_json()
      assert Capability.from_map(intact).action == :create_session

      assert_raise ArgumentError, fn ->
        Capability.from_map(Map.delete(intact, "action"))
      end
    end
  end

  describe "C1 — admin full-wildcard cap matches every action" do
    test "kind: :any, behavior: :any, action: :any matches a concrete needed cap" do
      admin = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      needed = build_needed(:add_member)

      assert Capability.matches?(admin, needed),
             "admin's full-wildcard cap MUST match every needed cap — that's the structural invariant of admin authority"
    end

    test "Capability.admin_invariant?/1 recognises the 5-axis full wildcard" do
      admin = %Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.user(:system, :admin),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      assert Capability.admin_invariant?(admin),
             "admin_invariant?/1 must accept the new 5-axis wildcard shape"
    end

    test "Capability.admin_invariant?/1 does NOT match legacy 4-axis wildcard (snapshot-restored)" do
      # SPEC 2026-05-27 capability-action-axis r4 option-B:
      # the legacy fallback was deliberately REMOVED from
      # `admin_invariant?/1`. Pre-SPEC admin caps missing `:action`
      # are no longer recognised at this layer — operators must
      # re-grant admin authority via `Identity.grant_cap` (which
      # goes through `normalize!/2` and writes `action: :any`
      # explicitly). Matcher-boundary tolerance for legacy snapshot
      # caps is still in place at dispatch step 5.5 (SPEC §3.3) —
      # so dispatch keeps working — but the admin-cap recogniser
      # is intentionally strict.
      legacy =
        Map.delete(
          %Capability{
            kind: :any,
            behavior: :any,
            action: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.user(:system, :admin),
            granted_at: ~U[2026-01-01 00:00:00Z]
          },
          :action
        )

      refute Map.has_key?(legacy, :action),
             "test fixture invariant: the legacy cap genuinely lacks :action"

      refute Capability.admin_invariant?(legacy),
             "admin_invariant?/1 must REJECT pre-SPEC caps missing :action (codex r4 SPEC option-B — legacy fallback removed)"
    end
  end

  # ----- helpers -----

  defp build_held_cap(action) do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: :any,
      workspace_uri: :any,
      granted_by: Ezagent.URI.new!("entity://system/user/admin"),
      granted_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp build_needed(action) do
    %{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://team-alpha/default/main"),
      workspace_uri: URI.new!("workspace://team-alpha")
    }
  end
end
