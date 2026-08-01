defmodule Ezagent.Identity.Offboarding.RevocationFenceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.Identity.Offboarding.RevocationFence
  alias Ezagent.Identity.Test.RevocationFenceAuthorityLoader
  alias Ezagent.{Cap, Capability, IdentityCaps}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, RevocationFenceAuthorityLoader)
    )

    on_exit(fn ->
      Application.put_env(:ezagent_core, Ezagent.Cap, previous)
      Application.delete_env(:ezagent_domain_identity, RevocationFenceAuthorityLoader)
    end)

    :ok
  end

  test "enroll is durable/idempotent and clear releases exactly one principal" do
    a = user("a")
    b = user("b")

    refute RevocationFence.fenced?(a)
    assert :ok = RevocationFence.enroll([a, b, a])
    assert RevocationFence.fenced?(a)
    assert RevocationFence.fenced?(b)
    assert MapSet.new(RevocationFence.pending()) == MapSet.new([a, b])

    assert :ok = RevocationFence.clear(a)
    refute RevocationFence.fenced?(a)
    assert RevocationFence.fenced?(b)
  end

  test "fence denies load + authorize before the holder generation is bumped" do
    holder = user("holder")
    target = agent("target")
    cap = signed_cap(holder, target)
    license = self_license(holder)

    assert {:ok, _user} = Ezagent.Users.create(holder, nil, [license, cap])

    Application.put_env(
      :ezagent_domain_identity,
      RevocationFenceAuthorityLoader,
      MapSet.new([cap])
    )

    needed = needed_cap(target)
    assert [_ | _] = IdentityCaps.load_persisted(holder)
    assert {:ok, ^cap} = Cap.authorize(holder, [cap], needed)

    assert :ok = RevocationFence.enroll([holder])
    assert IdentityCaps.load(holder) == []
    assert IdentityCaps.load_persisted(holder) == []
    assert {:error, :holder_revoked} = Cap.authorize(holder, [cap], needed)
  end

  test "fence rejects PAT authentication and cold-login spawn even while generation is current" do
    principal = user("login")
    assert {:ok, _user} = Ezagent.Users.create(principal, nil, [])
    assert {:ok, _authority} = Authority.open(principal, :user)
    assert {plain, _row} = Ezagent.Entity.Token.mint(principal)

    assert :ok = RevocationFence.enroll([principal])
    assert {:error, :invalid_credentials} = Ezagent.Entity.Token.authenticate(plain)
    assert {:error, :revocation_pending} = Ezagent.Entity.spawn_principal(principal)
  end

  defp signed_cap(holder, target) do
    assert {:ok, authority} = Authority.open(target, :agent)

    requested =
      Capability.cap(:agent, :any, :noop, target, Capability.workspace_of(target))

    intent = Grant.freeze(target, admin(), holder, requested)

    assert {:ok, cap} =
             Authority.with_current(authority, fn -> Authority.issue_current(intent) end)

    cap
  end

  defp self_license(holder) do
    assert {:ok, authority} = Authority.open(holder, :user)

    requested =
      Capability.cap(
        :user,
        Ezagent.ActionSet.Identity,
        :self_license,
        holder,
        Capability.workspace_of(holder)
      )

    intent = Grant.freeze(holder, holder, holder, requested)
    assert {:ok, license} = Grant.issue_self_license(authority, intent)
    license
  end

  defp needed_cap(target) do
    %{
      kind: :agent,
      behavior: :any,
      action: :noop,
      instance: target,
      workspace_uri: Capability.workspace_of(target)
    }
  end

  defp user(name),
    do: Ezagent.URI.user("revocation-fence", "#{name}-#{System.unique_integer([:positive])}")

  defp agent(name),
    do: Ezagent.URI.agent("revocation-fence", "#{name}-#{System.unique_integer([:positive])}")

  defp admin, do: Ezagent.URI.user(:system, :admin)
end
