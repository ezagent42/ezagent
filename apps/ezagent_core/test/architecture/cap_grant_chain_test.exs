defmodule Ezagent.Architecture.CapGrantChainTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Invocation
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_grant-#{System.unique_integer([:positive])}"
      )

    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)

    {:ok,
     uri: uri,
     pid: pid,
     admin: Ezagent.URI.user(:system, :admin),
     alice: Ezagent.URI.new!("entity://team-alpha/user/alice"),
     bob: Ezagent.URI.new!("entity://team-alpha/user/bob")}
  end

  test "K.grant rejects a presenter with no authority-cap-on-K", context do
    assert {:error, :missing_cap} =
             grant(
               context.uri,
               context.alice,
               MapSet.new(),
               context.bob,
               action_cap(context.uri)
             )
  end

  test "canonical admin uses the sealed anchor to mint a cap accepted by K", context do
    assert {:ok, issued} =
             Ezagent.Cap.issue(
               {:admin, context.admin},
               context.alice,
               action_cap(context.uri)
             )

    assert issued.grantee_uri == context.alice
    assert issued.instance == context.uri
    assert is_binary(issued.signature)

    assert {:ok, %{echoed: "admin-minted"}} =
             invoke_noop(context.uri, context.alice, MapSet.new([issued]), "admin-minted")
  end

  test "admin delegates K.grant to Alice, who directs K to mint Bob's cap", context do
    assert {:ok, alice_authority} =
             Ezagent.Cap.issue(
               {:admin, context.admin},
               context.alice,
               grant_authority_cap(context.uri)
             )

    assert {:ok, bob_cap} =
             grant(
               context.uri,
               context.alice,
               MapSet.new([alice_authority]),
               context.bob,
               action_cap(context.uri)
             )

    assert bob_cap.granted_by == context.alice
    assert bob_cap.grantee_uri == context.bob

    assert {:ok, %{echoed: "delegated"}} =
             invoke_noop(context.uri, context.bob, MapSet.new([bob_cap]), "delegated")
  end

  test "a caller cannot impersonate an issuer by naming itself in the proposal", context do
    forged = %{action_cap(context.uri) | granted_by: context.alice}

    assert {:error, :missing_cap} =
             grant(context.uri, context.alice, MapSet.new(), context.bob, forged)
  end

  defp grant(uri, presenter, caps, grantee, cap) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(uri, :cap, :grant),
      mode: :call,
      args: %{grantee: grantee, cap: cap},
      ctx: %{caller: presenter, caps: caps, reply: {:caller_inbox, self()}},
      origin: :trusted_internal
    })
  end

  defp invoke_noop(uri, presenter, caps, message) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(uri, :test, :noop),
      mode: :call,
      args: %{msg: message},
      ctx: %{caller: presenter, caps: caps, reply: {:caller_inbox, self()}},
      origin: :authenticated_external
    })
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

  defp grant_authority_cap(uri) do
    Capability.cap(
      :test,
      Ezagent.Cap.Grant,
      :grant,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

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
