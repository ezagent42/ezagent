defmodule Ezagent.EntityCaps.StoreStatusDecodeTest do
  @moduledoc """
  #189 cutover — the identity-caps status decode-on-read regression (canary
  catch).

  The status enum is PERSISTED as a STRING (`identity_status: "..."`) but the
  read APIs (`status/1`, `status_result/1`, `backfill/2`) return a `status()`
  ATOM. Pre-fix all three decoded via `String.to_existing_atom/1`, which is
  load-order-fragile: the `@type status` typespec does NOT emit its atoms into
  the module's loadable atom chunk, and the only `:revoked_unprovisioned`
  literals live in OTHER modules' guards
  (`Ezagent.Identity.{PreEpochRemint, FleetParity}`). On a release node that ran
  `EzagentCore.Release.identity_cutover/1` BEFORE those modules were loaded,
  `String.to_existing_atom("revoked_unprovisioned")` raised `ArgumentError`
  ("not an already existing atom") and crashed the Step 1/3 backfill on the first
  license-invalid entity — a status the store itself WRITES.

  ## Why the red-check is a `.beam` atom-chunk assertion, not a raise

  The defect CANNOT be reproduced as a runtime raise inside a `mix test` VM:
  atoms are interned globally on module load and never un-interned, and the
  sibling test files + those guard-carrying lib modules all reference
  `:revoked_unprovisioned` as a literal — so by the time any test runs, the atom
  is already interned and `String.to_existing_atom/1` succeeds (a FALSE green,
  the sibling of "cleaning the data would be a false green"). The faithful,
  deterministic red→green is therefore a STRUCTURAL assertion on the compiled
  `Store` module: loading `Store` must intern its OWN status enum, i.e. every
  known status string must appear in `Store`'s atom chunk. That is true only
  when each atom is a compile-time LITERAL in `Store` (the `decode_status/1`
  fix), and it is immune to whatever else the test VM happened to intern.

    * PRE-FIX: `Store`'s atom chunk lacks `"revoked_unprovisioned"` → RED.
    * POST-FIX: it is present → GREEN.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.Store

  describe "Store self-interns its own status enum (structural red-check)" do
    # This is THE fail-before / pass-after check. It reads the on-disk compiled
    # `Store.beam` atom chunk (via `:code.which/1` + `:beam_lib`), NOT the VM's
    # global atom table, so incidental interning by sibling modules cannot mask
    # it. `mix test` recompiles before running, so the inspected artifact always
    # reflects the current source.
    test "every known identity_status string is present in Store's atom chunk" do
      beam = :code.which(Store)
      assert is_list(beam), "expected a loadable Store.beam path, got #{inspect(beam)}"

      {:ok, {Store, [{:atoms, atoms}]}} = :beam_lib.chunks(beam, [:atoms])
      interned = MapSet.new(atoms, fn {_index, atom} -> Atom.to_string(atom) end)

      for status_string <- ~w(active revoked_unprovisioned tombstoned) do
        assert status_string in interned,
               "loading Ezagent.EntityCaps.Store must intern the status atom " <>
                 "#{inspect(status_string)} (a compile-time literal in decode_status/1) " <>
                 "so the store's decode-on-read never depends on another module " <>
                 "having been loaded first — the #189 cutover canary crash"
      end
    end
  end

  describe "decode-on-read round-trips every persisted status (no raise)" do
    test "a license-invalid backfill lands revoked_unprovisioned and reads back through all sites" do
      # An UNLICENSED principal: `caps` carry no current-valid self-license, so
      # the write-boundary guard lands `revoked_unprovisioned` — WITHOUT this test
      # ever naming the atom in its setup (the persisted STRING is produced by the
      # real write path, not a literal we hand in).
      agent = agent_uri("revoked")

      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, [])

      # Independent proof the persisted column is the STRING (the read/write
      # asymmetry the bug lived in), decoded on read.
      assert Store.fetch(agent).identity_status == "revoked_unprovisioned"

      # status/1 (site 1) — decode via decode_status/1, no ArgumentError.
      assert Store.status(agent) == :revoked_unprovisioned
      # status_result/1 (site 2).
      assert Store.status_result(agent) == {:ok, :revoked_unprovisioned}
      # backfill/2 idempotent re-run (site 3) — never upgrades, decodes cleanly.
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, [])
    end

    test "a current-valid backfill lands active and reads back through all sites" do
      agent = agent_uri("active")
      caps = licensed_caps(agent)

      assert {:ok, :active} = Store.backfill(agent, caps)
      assert Store.fetch(agent).identity_status == "active"

      assert Store.status(agent) == :active
      assert Store.status_result(agent) == {:ok, :active}
      assert {:ok, :active} = Store.backfill(agent, caps)
    end

    test "a tombstoned row reads back through all sites" do
      agent = agent_uri("tombstone")

      assert :ok = Store.tombstone(agent)
      assert Store.fetch(agent).identity_status == "tombstoned"

      assert Store.status(agent) == :tombstoned
      assert Store.status_result(agent) == {:ok, :tombstoned}
      # backfill preserves a tombstone (never upgraded) and decodes it.
      assert {:ok, :tombstoned} = Store.backfill(agent, licensed_caps(agent))
    end

    test "an absent row is still distinguished from a decode (status/1 nil, status_result {:ok, nil})" do
      agent = agent_uri("absent")

      refute Store.has_row?(agent)
      assert Store.status(agent) == nil
      assert Store.status_result(agent) == {:ok, nil}
    end
  end

  describe "decode_status is total and fail-loud on an unknown status" do
    # A corrupt / schema-drifted row must fail LOUD, never decode to a silent
    # nil (which reads as "absent" and could let a legacy self-license authorize
    # a principal the store means to deny). The `identity_caps_identity_status_check`
    # DB constraint blocks writing an unknown status today (defense in depth), so
    # to model a PRE-constraint / drifted legacy row we drop the constraint inside
    # the sandbox transaction (isolated — it rolls back with the test), write the
    # bogus string directly, and assert the read raises a clear domain error.
    test "status/1 raises a clear ArgumentError on an unrecognized persisted status" do
      agent = agent_uri("corrupt")
      assert {:ok, :revoked_unprovisioned} = Store.backfill(agent, [])

      Ecto.Adapters.SQL.query!(
        EzagentCore.Repo,
        "ALTER TABLE identity_caps DROP CONSTRAINT identity_caps_identity_status_check",
        []
      )

      result =
        Ecto.Adapters.SQL.query!(
          EzagentCore.Repo,
          "UPDATE identity_caps SET identity_status = $1 WHERE uri = $2",
          ["legacy_bogus_status", key(agent)]
        )

      assert result.num_rows == 1

      error = assert_raise ArgumentError, fn -> Store.status(agent) end
      assert error.message =~ "unknown identity_status"
      assert error.message =~ "legacy_bogus_status"
    end
  end

  # -------------------------------------------------------------------
  # Helpers (mirror store_backfill_test.exs)
  # -------------------------------------------------------------------

  defp licensed_caps(receiver), do: [self_license(receiver)]

  defp self_license(receiver) do
    {:ok, type} = Ezagent.URI.type(receiver)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Ezagent.Cap.Authority.open(receiver, kind)

    requested =
      Capability.cap(
        kind,
        Ezagent.ActionSet.Identity,
        :self_license,
        receiver,
        Ezagent.URI.workspace_of(receiver)
      )

    intent = Ezagent.Cap.Grant.freeze(receiver, receiver, receiver, requested)

    {:ok, license} =
      Ezagent.Cap.Authority.with_current(authority, fn ->
        Ezagent.Cap.Authority.issue_self_license_current(intent)
      end)

    license
  end

  defp agent_uri(suffix),
    do:
      URI.new!(
        "entity://identity-caps-status-decode/agent/#{suffix}-#{System.unique_integer([:positive])}"
      )

  defp key(uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
end
