defmodule Ezagent.Invariants.CapSigningInvariantTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cap, Capability, Invocation}
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)

    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/cap-invariant-#{System.unique_integer([:positive])}"
      )

    presenter = Ezagent.URI.new!("entity://team-alpha/user/cap-invariant-presenter")

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)) =>
        MapSet.new([:test_holder_license]),
      Ezagent.URI.stable_key(presenter) => MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    assert {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)

    {:ok, uri: uri, presenter: presenter}
  end

  test "INV-SIGN-1: only a current target-signed, receiver-bound artifact authorizes", context do
    assert {:ok, issued} =
             Cap.issue(
               {:admin, Ezagent.URI.user(:system, :admin)},
               context.presenter,
               action_cap(context.uri)
             )

    assert {:ok, %{echoed: "accepted"}} = invoke(context, issued, "accepted")

    tampered = %{issued | action: :raise}
    assert {:error, :missing_cap} = invoke(context, tampered, "blocked")

    assert {:ok, %{count: 1, last_msg: "accepted"}} =
             Ezagent.Kind.read(context.uri, :test, spawn: :never)
  end

  test "INV-SIGN-2: private target authority never appears in the generic runtime view",
       context do
    assert {:ok, pid} = Ezagent.KindRegistry.lookup(context.uri)
    private_key = :sys.get_state(pid).authority.private_key

    assert {:ok, runtime_view} = Ezagent.Kind.runtime_view(context.uri)
    refute Map.has_key?(runtime_view, :authority)
    refute contains_binary?(runtime_view, private_key)

    assert {:ok, slice} = Ezagent.Kind.SliceAccess.get_raw_slice(context.uri, :test)
    refute contains_binary?(slice, private_key)
  end

  defp invoke(context, cap, message) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(context.uri, :test, :noop),
      mode: :call,
      args: %{msg: message},
      ctx: %{
        caller: context.presenter,
        authenticated_principal: context.presenter,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      },
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

  defp contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp contains_binary?(term, needle),
    do: term |> :erlang.term_to_binary() |> contains_binary?(needle)

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
