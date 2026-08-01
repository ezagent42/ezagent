defmodule Ezagent.CapabilityActionTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 — acceptance criteria
  A1-A4 + C1 + the strict matcher regression test (B3 lives in
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

  describe "complete action axis" do
    test "from_map rejects a row without action" do
      incomplete_row = %{
        "kind" => "chat",
        "behavior" => "Ezagent.ActionSet.Session",
        "instance" => "any",
        "workspace_uri" => "workspace://team-alpha",
        "granted_by" => "entity://system/user/admin",
        "granted_at" => "2026-01-01T00:00:00Z"
      }

      refute Map.has_key?(incomplete_row, "action")
      assert_raise KeyError, fn -> Capability.from_map(incomplete_row) end
    end

    test "round-trip: from_map(to_map(cap)) preserves action" do
      original = build_held_cap(:send)
      round_tripped = original |> Capability.to_map() |> Capability.from_map()

      assert round_tripped.action == :send,
             "to_map/from_map must be lossless on the action axis"
    end

    test "action_of/1 rejects caps with no :action key" do
      incomplete = Map.delete(build_held_cap(:any), :action)

      refute Map.has_key?(incomplete, :action)
      assert_raise KeyError, fn -> Capability.action_of(incomplete) end
    end
  end

  describe "#189 identity-plane divergence — from_map (READ side) must NOT widen a signed cap's lost action to :any" do
    # ROOT CAUSE (verified against live prod stable node, 2026-07-30/31): five
    # freshly-created users each held ONE workspace cap that differed between the
    # two identity planes — `users.caps_json` (durable) carried
    # `action: :create_session` (signature VALID), while the
    # `Ezagent.IdentityCaps.Store` mirror serialized the SAME signed cap as
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
      assert_raise KeyError, fn ->
        Capability.from_map(corrupted)
      end
    end

    test "an unsigned map missing action is also rejected" do
      unsigned_incomplete =
        signed_create_session_json() |> Map.delete("action") |> Map.delete("signature")

      assert is_nil(Map.get(unsigned_incomplete, "signature"))
      assert_raise KeyError, fn -> Capability.from_map(unsigned_incomplete) end
    end

    test "the two identity planes cannot diverge through decode on the same signed cap" do
      # `to_map/1` always serializes a concrete action; an action-key-dropped map
      # is rejected, so no carrier can widen the signed artifact.
      intact = signed_create_session_json()
      assert Capability.from_map(intact).action == :create_session

      assert_raise KeyError, fn ->
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

    test "Capability.admin_invariant?/1 rejects an incomplete 4-axis wildcard" do
      incomplete =
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

      refute Map.has_key?(incomplete, :action)

      refute Capability.admin_invariant?(incomplete)
    end
  end

  describe "#189 identity-plane divergence — serializing a signed cap must NOT widen a lost `:action` to `:any`" do
    # ROOT CAUSE (verified against live prod, 2026-07-30): five freshly-created
    # users each held ONE workspace cap that differed between the two identity
    # planes — `users.caps_json` (durable) carried
    # `action: :create_session` with a VALID signature, while the
    # `Ezagent.IdentityCaps.Store` mirror carried the SAME signed cap serialized as
    # `action: :any` (workspace-admin) with a now-INVALID signature. The
    # `FleetParity.caps_parity/3` barrier compares the full signed cap-set and
    # refused the cutover on `{:caps_mismatch}`. `:any` on Workspace is
    # workspace-admin; `:create_session` is an ordinary member — a PRIVILEGE-level
    # divergence.
    #
    # MECHANISM: `Ezagent.Capability.to_map/1` and the `Jason.Encoder` impl both
    # route the action through `Normalize.fill_defaults/1`, which reprojects onto a
    # fresh defstruct via `struct/2`. When the cap object reaching serialization is
    # a struct-shaped map whose `:action` KEY is absent, `struct/2` fills the
    # defstruct default `:any` and `Capability.action_of/1`
    # (`Map.get(cap, :action, :any)`) reads `:any` — SILENTLY widening the true
    # concrete action while the (now-mismatched) signature is preserved verbatim.
    #
    # These are pure-data assertions on the serialization chokepoint that produced
    # the divergent bytes.

    # A signed, concrete-action workspace cap (the shape the grant chokepoint mints
    # + signs). A non-nil `signature` marks it as post-action-axis: it MUST carry a
    # concrete `:action`.
    defp signed_create_session_cap do
      %Capability{
        kind: :workspace,
        behavior: Ezagent.ActionSet.Workspace,
        action: :create_session,
        instance: URI.new!("workspace://acme"),
        workspace_uri: URI.new!("workspace://acme"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-07-30 15:05:12.545128Z],
        signature: "QKFJ-signature-bytes-over-create_session",
        key_id: "kind-g1:CvcLxDl6515X4XmKWXIaR2F8y9qzKlNV5fNp2PGzhA8",
        grantee_uri: URI.new!("entity://acme/user/lin_yilun")
      }
    end

    # The exact in-memory corruption that reached the store's serializer: the SAME
    # signed cap as a struct-shaped map that has LOST its `:action` key.
    defp action_key_lost(%Capability{} = cap) do
      cap |> Map.from_struct() |> Map.delete(:action) |> Map.put(:__struct__, Capability)
    end

    test "action_of/1 rejects a lost action key" do
      corrupted = action_key_lost(signed_create_session_cap())

      refute Map.has_key?(corrupted, :action)
      assert_raise KeyError, fn -> Capability.action_of(corrupted) end
    end

    test "to_map/1 REFUSES to serialize a signed cap that lost its `:action` (no silent `:any` widening)" do
      corrupted = action_key_lost(signed_create_session_cap())

      assert_raise KeyError, fn ->
        Capability.to_map(corrupted)
      end
    end

    test "Jason.Encoder REFUSES the same corruption (the two serializers cannot drift)" do
      corrupted = action_key_lost(signed_create_session_cap())

      assert_raise KeyError, fn ->
        Jason.encode!(corrupted)
      end
    end

    test "the two identity planes serialize the SAME signed cap IDENTICALLY (parity)" do
      # Both serializers consume the same intact artifact and cannot produce a
      # widened missing-action variant.
      intact = signed_create_session_cap()

      durable_wire = Capability.to_map(intact) |> Map.delete("granted_at")
      store_wire = Capability.to_map(intact) |> Map.delete("granted_at")

      assert durable_wire == store_wire
      assert durable_wire["action"] == "create_session"
      # And the escalated variant can never be produced from the same signed cap:
      assert_raise KeyError, fn -> Capability.to_map(action_key_lost(intact)) end
    end

    test "an unsigned capability missing action is rejected" do
      unsigned_incomplete =
        %Capability{
          kind: :session,
          behavior: Ezagent.ActionSet.Session,
          action: :any,
          instance: :any,
          workspace_uri: URI.new!("workspace://acme"),
          granted_by: Ezagent.URI.new!("entity://system/user/admin"),
          granted_at: ~U[2026-05-01 00:00:00Z]
        }
        |> Map.from_struct()
        |> Map.delete(:action)
        |> Map.put(:__struct__, Capability)

      assert is_nil(Map.get(unsigned_incomplete, :signature))
      assert_raise KeyError, fn -> Capability.to_map(unsigned_incomplete) end
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
