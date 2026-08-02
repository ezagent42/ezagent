defmodule Ezagent.SelfLicenseMintOnCreateTest do
  @moduledoc """
  G-3/MF1 principal-axis proof.

  Every cap-obtaining route is covered by the assertions below: live Identity
  slice load, persisted snapshot load, cold snapshot restore, activate's
  persisted-cap re-read, and the initial-caps spawn input. A generation bump
  must leave every route inert; neither a live process nor a restart may mint
  a current-generation self-license.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cap, Capability, IdentityCaps}
  alias Ezagent.Cap.Authority

  defmodule PrincipalKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :agent

    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity]

    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  test "genuine create mints exactly one current self-license; bump and restart cannot re-arm" do
    principal = unique_agent("restart")

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(principal)
    end)

    assert {:ok, _pid} = Ezagent.Kind.spawn(PrincipalKind, %{uri: principal, initial_caps: []})
    wait_until_ready(principal)

    assert [license] = self_licenses(IdentityCaps.load(principal))
    assert [persisted_license] = self_licenses(IdentityCaps.load_persisted(principal))
    assert Capability.identity_key(license) == Capability.identity_key(persisted_license)
    assert Authority.verify_against_current(license, principal, principal)

    assert {:ok, stale_live_authority} = Authority.open(principal, :agent)
    assert {:ok, first_generation} = Authority.current_generation(principal)
    assert {:ok, bumped} = Authority.regenesis(principal, :agent)
    assert bumped.generation == first_generation + 1

    stale_intent =
      Ezagent.Cap.Grant.freeze(
        principal,
        principal,
        principal,
        self_license_request(principal)
      )

    assert {:ok, stale_remint} =
             Authority.with_current(stale_live_authority, fn ->
               Authority.issue_self_license_current(stale_intent)
             end)

    refute Authority.verify_against_current(stale_remint, principal, principal)

    # Live process retains only its stale cached generation-N signer.
    assert IdentityCaps.load(principal) == []
    assert IdentityCaps.load_persisted(principal) == []

    assert :ok = Ezagent.Kind.terminate(principal)
    assert :ok = Ezagent.SnapshotStore.delete(principal)
    refute Ezagent.Lifecycle.fresh_create?(principal)
    assert {:ok, _pid} = Ezagent.Kind.spawn(PrincipalKind, %{uri: principal, initial_caps: []})
    wait_until_ready(principal)

    # Cold restore is :existed and activate only re-unions the same stale
    # artifact; neither path mints a generation-(N+1) replacement.
    assert IdentityCaps.load(principal) == []
    assert IdentityCaps.load_persisted(principal) == []
  end

  test "ordinary grant issuance cannot construct the reserved self-license action" do
    principal = unique_agent("reserved")
    assert {:ok, authority} = Authority.open(principal, :agent)

    intent =
      Ezagent.Cap.Grant.freeze(
        principal,
        principal,
        principal,
        self_license_request(principal)
      )

    Authority.with_current(authority, fn ->
      assert {:error, :reserved_action} =
               Cap.issue({:held_by, principal}, principal, self_license_request(principal))

      assert {:error, :reserved_action} = Authority.issue_current(intent)
    end)

    assert {:error, :reserved_action} = Ezagent.Cap.Grant.issue(authority, intent)
  end

  test "the genuine-create mint guard rejects a second self-license" do
    principal = unique_agent("mint-guard")
    assert {:ok, authority} = Authority.open(principal, :agent)

    intent =
      Ezagent.Cap.Grant.freeze(
        principal,
        principal,
        principal,
        self_license_request(principal)
      )

    assert {:ok, license} =
             Authority.with_current(authority, fn ->
               Authority.issue_self_license_current(intent)
             end)

    assert {:error, :self_license_already_present} =
             Authority.with_current(authority, fn ->
               Ezagent.ActionSet.Identity.create(%{
                 uri: principal,
                 initial_caps: [license],
                 create_freshness: :created
               })
             end)
  end

  test "user self-license becomes authoritative at the creation boundary" do
    principal =
      Ezagent.URI.user(
        "self-license",
        "post-marker-#{System.unique_integer([:positive])}"
      )

    assert {:ok, _user} = Ezagent.Users.create(principal, nil, [])
    assert {:ok, authority} = Authority.open(principal, :user)

    assert {:ok, %{caps: caps} = state} =
             Authority.with_current(authority, fn ->
               Ezagent.ActionSet.Identity.create(%{
                 uri: principal,
                 initial_caps: [],
                 create_freshness: :created
               })
             end)

    assert [_license] = self_licenses(caps)
    assert Ezagent.IdentityCaps.Store.load(principal) == []
    assert :ok = Ezagent.IdentityCaps.Store.provision_created_identity(principal, state)

    assert [_license] =
             principal
             |> Ezagent.IdentityCaps.Store.load()
             |> self_licenses()
  end

  defp self_licenses(caps) do
    Enum.filter(caps, &(Capability.action_of(&1) == :self_license))
  end

  defp unique_agent(suffix) do
    Ezagent.URI.agent(
      "self-license",
      "#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp self_license_request(principal) do
    Capability.cap(
      :agent,
      Ezagent.ActionSet.Identity,
      :self_license,
      principal,
      Ezagent.URI.workspace_of(principal)
    )
  end

  defp wait_until_ready(uri, attempts \\ 100)

  defp wait_until_ready(_uri, 0), do: flunk("principal did not become ready")

  defp wait_until_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_ready(uri, attempts - 1)
    end
  end
end
