defmodule Ezagent.Architecture.CapVerifierDominanceTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant, Verifier}
  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      MapSet.new([:independent_holder_license])
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_verifier-#{System.unique_integer([:positive])}"
      )

    presenter = Ezagent.URI.new!("entity://team-alpha/user/alice")
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)
    authority = :sys.get_state(pid).authority

    unsigned = %Capability{
      kind: :test,
      behavior: TestBehavior,
      action: :noop,
      instance: uri,
      workspace_uri: Capability.workspace_of(uri),
      granted_by: Ezagent.URI.user(:system, :admin),
      granted_at: DateTime.utc_now(),
      grantee_uri: presenter
    }

    {:ok,
     uri: uri,
     target: target,
     presenter: presenter,
     pid: pid,
     authority: authority,
     unsigned: unsigned}
  end

  test "verifier accepts only a target-key-signed cap before the handler", context do
    signed = Authority.sign(context.authority, context.unsigned)
    invocation = invocation(context, MapSet.new([signed]))

    assert {:ok, %{echoed: "hello"}} =
             GenServer.call(context.pid, {:ezagent_dispatch, invocation})

    assert {:ok, %{count: 1}} = Ezagent.Kind.get_slice(context.uri, :test)
  end

  test "unsigned and vm_internal attempts fail before the handler mutates state", context do
    assert {:error, :missing_cap} =
             GenServer.call(
               context.pid,
               {:ezagent_dispatch, invocation(context, MapSet.new([context.unsigned]))}
             )

    vm_invocation = %Invocation{
      target: context.target,
      mode: :call,
      args: %{msg: "hello"},
      ctx: %{caller: :vm_internal, caps: MapSet.new(), reply: :ignore},
      origin: :trusted_internal
    }

    assert {:error, :presenter_required} =
             GenServer.call(context.pid, {:ezagent_dispatch, vm_invocation})

    assert {:ok, %{count: 0}} = Ezagent.Kind.get_slice(context.uri, :test)
  end

  test "verifier delegates to authorize/3 and denies a live target's old generation", context do
    signed = Authority.sign(context.authority, context.unsigned)

    assert {:ok, %{echoed: "hello"}} =
             GenServer.call(
               context.pid,
               {:ezagent_dispatch, invocation(context, MapSet.new([signed]))}
             )

    assert {:ok, _bumped} =
             Authority.regenesis(context.uri, :test, Ezagent.URI.user(:system, :admin))

    assert {:error, :missing_cap} =
             GenServer.call(
               context.pid,
               {:ezagent_dispatch, invocation(context, MapSet.new([signed]))}
             )

    assert {:ok, %{count: 1}} = Ezagent.Kind.get_slice(context.uri, :test)
  end

  test "non-cap routing is a closed framework allowlist" do
    assert Verifier.non_cap_action?(Ezagent.ActionSet.Agent.Receive, :receive)
    assert Verifier.non_cap_action?(Ezagent.ActionSet.SocialwarePublisherRead, :history)
    refute Verifier.non_cap_action?(TestBehavior, :noop)
    refute Verifier.non_cap_action?(Ezagent.ActionSet.IdentityAdmin, :grant_cap)
  end

  test "grant issuance consumes frozen validated intent, not rewritten args", context do
    bob = Ezagent.URI.new!("entity://team-alpha/user/bob")

    intent = Grant.freeze(context.uri, context.presenter, bob, context.unsigned)

    rewritten_after_validation = %{
      context.unsigned
      | action: :raise,
        grantee_uri: context.presenter
    }

    refute rewritten_after_validation.action == intent.cap.action
    issued = Grant.issue(context.authority, intent)

    assert issued.action == :noop
    assert issued.grantee_uri == bob
    assert Authority.verify(context.authority, issued, bob)
  end

  defp invocation(context, caps) do
    %Invocation{
      target: context.target,
      mode: :call,
      args: %{msg: "hello"},
      ctx: %{caller: context.presenter, caps: caps, reply: :ignore},
      origin: :authenticated_external
    }
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
