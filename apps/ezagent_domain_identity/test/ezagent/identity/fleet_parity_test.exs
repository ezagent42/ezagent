defmodule Ezagent.Identity.FleetParityTest do
  @moduledoc """
  #189 PR-2 D2 — the fleet-completion barrier (codex spec-review F2). Tests
  BOTH directions (forward legacy→store, backward store→legacy), the closed
  worklist enumerated from LEGACY (empty store ⇒ incomplete, never "done"), and
  the explicit ephemeral-holder / canonical-admin exemptions.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.Capability
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.FleetParity

  @workspace URI.new!("workspace://fleet-parity")
  @issuer URI.new!("entity://fleet-parity/user/issuer")

  test "a licensed legacy user with NO store row is incomplete (missing_active_row)" do
    user = user_uri("licensed")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

    result = FleetParity.check()

    refute result.complete
    assert {:missing_active_row, URI.to_string(user)} in result.discrepancies
  end

  test "after backfilling the licensed user, its discrepancy clears" do
    user = user_uri("licensed-then-backfilled")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

    assert {:ok, :active} = Store.backfill(user, caps)

    result = FleetParity.check()
    refute_uri_flagged(result, user)
  end

  test "a license-INVALID legacy user with no store row is incomplete (absent_license_invalid)" do
    user = user_uri("unlicensed")
    # Caps WITHOUT a self-license — a license-invalid (regenesis'd) principal.
    caps = [issued_cap(user, :send)]
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

    result = FleetParity.check()
    refute result.complete
    assert {:absent_license_invalid, URI.to_string(user)} in result.discrepancies

    # Backfilling writes a durable revoked_unprovisioned row → clears it.
    assert {:ok, :revoked_unprovisioned} = Store.backfill(user, caps)
    refute_uri_flagged(FleetParity.check(), user)
  end

  test "a phantom store-only active row (no legacy backing) is rejected (phantom_active)" do
    agent = agent_uri("phantom")
    # Active store row with a current-valid license, but NO users row and NO
    # durable snapshot — a phantom principal the forward pass can't see.
    assert :ok = Store.persist(agent, licensed_caps(agent, [issued_cap(agent, :send)]))
    assert Store.status(agent) == :active

    result = FleetParity.check()
    refute result.complete
    assert {:phantom_active, URI.to_string(agent)} in result.discrepancies
  end

  test "the canonical admin's empty caps_json is EXEMPT from the license-invalid rule" do
    admin = Ezagent.URI.user(:system, :admin)
    # Drive the (seeded) admin to the fresh-boot empty-caps_json contract: no
    # durable license, currency supplied by the live slice.
    assert :ok = Ezagent.EntityCaps.UserStore.persist(admin, [])
    refute Store.has_current_self_license?([], admin)

    result = FleetParity.check()
    # The admin is EXEMPT — a license-invalid admin must NOT be flagged
    # absent_license_invalid / stale_active.
    refute_uri_flagged(result, admin)
  end

  test "incomplete on a partial store, complete after backfilling the whole population" do
    user = user_uri("only-principal")
    caps = licensed_caps(user, [])
    assert {:ok, _} = Ezagent.Users.create(user, nil, caps)

    # Clean the store within this sandbox transaction (rolled back after the
    # test) so the assertion is deterministic in a seeded dev DB.
    EzagentCore.Repo.delete_all(Ezagent.EntityCaps.Store)

    # Partial (empty) store + a non-empty legacy population ⇒ INCOMPLETE
    # (enumerated from legacy, so an empty store is never "done").
    refute FleetParity.check().complete

    # Backfill EVERY enumerated legacy principal (users + non-ephemeral
    # snapshots carrying `:identity`), mirroring the mix task — then complete.
    backfill_everything()

    result = FleetParity.check()
    assert result.complete, "residual discrepancies: #{inspect(result.discrepancies)}"
  end

  # Backfill every legacy principal the barrier enumerates (users + durable
  # snapshots), so `check/0` can legitimately report complete in a seeded DB.
  defp backfill_everything do
    for user <- Ezagent.Users.list_all() do
      uri = case user.uri do
        %URI{} = u -> u
        s when is_binary(s) -> Ezagent.URI.new!(s)
      end

      Store.backfill(uri, Map.get(user, :caps) || [])
    end

    for {uri_str, meta} <- Ezagent.Kind.list_durable_instances(),
        not user_uri?(uri_str),
        not ephemeral_kind?(meta.kind_type) do
      uri = Ezagent.URI.new!(uri_str)

      case snapshot_caps(uri) do
        {:ok, caps} -> Store.backfill(uri, caps)
        :none -> :ok
      end
    end

    :ok
  end

  defp ephemeral_kind?(kind_type) when is_binary(kind_type) do
    Ezagent.Identity.AuthenticatedHolders.ephemeral_holder?(String.to_existing_atom(kind_type))
  rescue
    _ -> false
  end

  defp ephemeral_kind?(_), do: false

  defp user_uri?(uri) when is_binary(uri) do
    match?(%URI{scheme: "entity"}, Ezagent.URI.new!(uri)) and
      Ezagent.URI.type?(Ezagent.URI.new!(uri), :user)
  rescue
    _ -> false
  end

  defp snapshot_caps(uri) do
    case Ezagent.Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) ->
        if Map.has_key?(identity, :caps) do
          caps =
            case Map.get(identity, :caps) do
              %MapSet{} = c -> MapSet.to_list(c)
              c when is_list(c) -> c
              _ -> []
            end

          {:ok, caps}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp refute_uri_flagged(result, uri) do
    uri_str = URI.to_string(uri)

    for {kind, flagged} <- result.discrepancies do
      refute flagged == uri_str, "expected #{uri_str} not flagged, got #{inspect({kind, flagged})}"
    end
  end

  # -------------------------------------------------------------------
  # Helpers (mirror store_test.exs)
  # -------------------------------------------------------------------

  defp issued_cap(receiver, action) do
    unsigned = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: URI.new!("session://fleet-parity/default/main"),
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: DateTime.utc_now()
    }

    {:ok, authority} = Ezagent.Cap.Authority.open(unsigned.instance, :session)
    authority_signed_cap_as!(authority, @issuer, receiver, unsigned)
  end

  defp licensed_caps(receiver, caps), do: [self_license(receiver) | caps]

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

  defp user_uri(suffix),
    do: URI.new!("entity://fleet-parity/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do: URI.new!("entity://fleet-parity/agent/#{suffix}-#{System.unique_integer([:positive])}")
end
