defmodule Ezagent.Invariants.PredicateARootCheckTest do
  @moduledoc """
  The old `granted_by` predicate was not an authenticity proof. This invariant
  pins its replacement: unsigned artifacts fail regardless of the claimed
  granter, while a target-minted artifact succeeds for its bound presenter.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)

    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/predicate-replacement-#{System.unique_integer([:positive])}"
      )

    presenter = Ezagent.URI.new!("entity://team-alpha/user/predicate-presenter")

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri()) =>
        MapSet.new([:test_holder_license]),
      Ezagent.URI.stable_key(presenter) => MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    assert {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)
    {:ok, uri: uri, presenter: presenter}
  end

  test "unsigned wildcard claiming a system granter is rejected", context do
    forged =
      unsigned_wildcard(
        context.uri,
        context.presenter,
        Ezagent.URI.new!("system://bootstrap/default")
      )

    assert {:error, :missing_cap} = dispatch(context, forged)
  end

  test "unsigned wildcard claiming an entity granter is equally rejected", context do
    forged = unsigned_wildcard(context.uri, context.presenter, Ezagent.URI.user(:system, :admin))
    assert {:error, :missing_cap} = dispatch(context, forged)
  end

  test "target-minted artifact is the positive control", context do
    requested =
      Capability.cap(
        :test,
        TestBehavior,
        :noop,
        context.uri,
        Capability.workspace_of(context.uri)
      )

    signed = signed_cap!(context.uri, context.presenter, requested)

    assert {:ok, %{echoed: "proof"}} = dispatch(context, signed)
  end

  defp unsigned_wildcard(uri, presenter, granter) do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: uri,
      workspace_uri: :any,
      granted_by: granter,
      granted_at: DateTime.utc_now(),
      grantee_uri: presenter
    }
  end

  defp dispatch(context, cap) do
    Invocation.dispatch(%Invocation{
      origin: :authenticated_external,
      target: Ezagent.URI.with_action(context.uri, :test, :noop),
      mode: :call,
      args: %{msg: "proof"},
      ctx: %{
        caller: context.presenter,
        authenticated_principal: context.presenter,
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    })
  end

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if deadline <= System.monotonic_time(:millisecond) do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
