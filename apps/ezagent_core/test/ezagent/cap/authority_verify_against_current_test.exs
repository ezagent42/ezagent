defmodule Ezagent.Cap.AuthorityVerifyAgainstCurrentTest do
  @moduledoc """
  Unified-revocation Phase F-1 — `Ezagent.Cap.Authority.verify_against_current/3`
  is the fresh active-row read revocation basis (DECISION #2 / MF4): it verifies
  a cap against the TARGET's CURRENT active `kind_cap_authorities` row, read
  fresh from the DB on every call — never the live process's cached
  `state.authority` (which `regenesis/3`, a pure DB transaction, does not swap)
  and never the process-dict `verify_current/2`. A gen-bumped target's old-gen
  caps fail immediately, kill-independently.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3]

  alias Ezagent.Cap
  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    :ok
  end

  test "cap signed under gen N is denied after a LIVE target bumps to N+1 (fresh active-row read)" do
    {uri, pid, grantee} = start_target("live-bump")
    cap = mint_signed_cap_for(uri, grantee)

    assert Authority.verify_against_current(cap, grantee, uri)

    {:ok, bumped} = Authority.regenesis(uri, :test)
    assert bumped.generation == 2

    # The LIVE target still caches the stale gen-1 authority in `state.authority`
    # (regenesis is pure DB and never swaps a live process) — a cached-authority
    # check keeps validating the old cap. The fresh active-row read does not.
    cached = :sys.get_state(pid).authority
    assert Authority.verify(cached, cap, grantee)

    refute Authority.verify_against_current(cap, grantee, uri)

    # A cap signed under the NEW current generation verifies again.
    fresh = authority_signed_cap!(bumped, grantee, action_cap(uri))
    assert Authority.verify_against_current(fresh, grantee, uri)
  end

  test "fail-closed when the target has no active authority row" do
    {uri, _pid, grantee} = start_target("no-row")
    cap = mint_signed_cap_for(uri, grantee)
    unknown = unique_uri("never-genesis")

    refute Authority.verify_against_current(cap, grantee, unknown)
  end

  test "denies a cap presented by a non-grantee" do
    {uri, _pid, grantee} = start_target("presenter")
    cap = mint_signed_cap_for(uri, grantee)

    refute Authority.verify_against_current(cap, unique_user("attacker"), uri)
  end

  test "denies a tampered signed cap" do
    {uri, _pid, grantee} = start_target("tamper")
    cap = mint_signed_cap_for(uri, grantee)
    tampered = %{cap | granted_at: DateTime.add(cap.granted_at, 1, :second)}

    refute Authority.verify_against_current(tampered, grantee, uri)
  end

  test "denies an unsigned cap and a cap signed by a different target" do
    {uri, _pid, grantee} = start_target("unsigned")
    {other_uri, _pid, _other_grantee} = start_target("other-signer")

    unsigned = %{
      action_cap(uri)
      | granted_by: admin(),
        granted_at: DateTime.utc_now(),
        grantee_uri: grantee
    }

    refute Authority.verify_against_current(unsigned, grantee, uri)

    other_signed = mint_signed_cap_for(other_uri, grantee)
    refute Authority.verify_against_current(other_signed, grantee, uri)
  end

  test "normalizes a legacy signed struct before protocol verification" do
    {uri, pid, grantee} = start_target("legacy-protocol")
    authority = :sys.get_state(pid).authority
    cap = authority_signed_cap!(authority, grantee, action_cap(uri))
    assert cap.signing_version == 1

    legacy_cap =
      cap
      |> Map.from_struct()
      |> Map.drop([:signing_version, :grant_id])
      |> Map.put(:__struct__, Capability)

    assert Authority.verify_against_current(legacy_cap, grantee, uri)
  end

  test "issue overwrites caller protocol metadata with a fresh v2 grant id" do
    {uri, _pid, grantee} = start_target("framework-stamp")
    requested = %{action_cap(uri) | signing_version: 99, grant_id: "caller-controlled"}

    assert {:ok, first} = Cap.issue({:admin, admin()}, grantee, requested)
    assert {:ok, second} = Cap.issue({:admin, admin()}, grantee, requested)

    assert first.signing_version == 2
    assert is_binary(first.grant_id) and first.grant_id != ""
    refute first.grant_id == "caller-controlled"
    refute second.grant_id == first.grant_id
    assert Authority.verify_against_current(first, grantee, uri)
    assert Authority.verify_against_current(second, grantee, uri)
  end

  defp start_target(suffix) do
    uri = unique_uri(suffix)
    grantee = unique_user(suffix)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)
    {uri, pid, grantee}
  end

  defp mint_signed_cap_for(uri, grantee) do
    {:ok, cap} = Ezagent.Cap.issue({:admin, admin()}, grantee, action_cap(uri))
    cap
  end

  defp action_cap(uri) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/verify-current-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/verify-current-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
