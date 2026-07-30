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

  describe "#189 identity-plane divergence — serializing a signed cap must NOT widen a lost `:action` to `:any`" do
    # ROOT CAUSE (verified against live prod, 2026-07-30): five freshly-created
    # users each held ONE workspace cap that differed between the two identity
    # planes — `users.caps_json` (durable) carried
    # `action: :create_session` with a VALID signature, while the
    # `Ezagent.EntityCaps.Store` mirror carried the SAME signed cap serialized as
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

    test "the widening MECHANISM: action_of/1 silently defaults a lost `:action` key to `:any`" do
      corrupted = action_key_lost(signed_create_session_cap())

      refute Map.has_key?(corrupted, :action)
      # This is the escalation: a create_session cap reads back as workspace-admin.
      assert Capability.action_of(corrupted) == :any
    end

    test "to_map/1 REFUSES to serialize a signed cap that lost its `:action` (no silent `:any` widening)" do
      corrupted = action_key_lost(signed_create_session_cap())

      # FAILS-BEFORE (current main): `to_map/1` returns `%{"action" => "any", ...}`,
      # the exact escalated bytes persisted to the store mirror. PASSES-AFTER: the
      # fail-closed guard in `fill_defaults/1` raises rather than widening.
      assert_raise ArgumentError, ~r/signed capability is missing its `:action`/i, fn ->
        Capability.to_map(corrupted)
      end
    end

    test "Jason.Encoder REFUSES the same corruption (the two serializers cannot drift)" do
      corrupted = action_key_lost(signed_create_session_cap())

      assert_raise ArgumentError, ~r/signed capability is missing its `:action`/i, fn ->
        Jason.encode!(corrupted)
      end
    end

    test "the two identity planes serialize the SAME signed cap IDENTICALLY (parity)" do
      # The durable plane (`users.caps_json`) holds the intact struct; the store
      # mirror must not diverge. With the intact object both planes agree; the ONLY
      # way to diverge was the silent widening the guard now forbids.
      intact = signed_create_session_cap()

      durable_wire = Capability.to_map(intact) |> Map.delete("granted_at")
      store_wire = Capability.to_map(intact) |> Map.delete("granted_at")

      assert durable_wire == store_wire
      assert durable_wire["action"] == "create_session"
      # And the escalated variant can never be produced from the same signed cap:
      assert_raise ArgumentError, fn -> Capability.to_map(action_key_lost(intact)) end
    end

    test "legacy tolerance preserved: an UNSIGNED pre-action-axis cap still reprojects a missing action to `:any`" do
      # A genuinely pre-#1399 cap carries NO signature, so a missing `:action` is
      # honest legacy (it predates the axis) — reproject to `:any`, do NOT raise
      # (the #213 canary cutover-backfill tolerance must not regress).
      unsigned_legacy =
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

      assert is_nil(Map.get(unsigned_legacy, :signature))
      assert Capability.to_map(unsigned_legacy)["action"] == "any"
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
