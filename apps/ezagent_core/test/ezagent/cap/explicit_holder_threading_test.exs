defmodule Ezagent.Cap.ExplicitHolderThreadingTest do
  @moduledoc """
  Unified-revocation F-6: the verifier consumes the authenticated principal
  explicitly. Framework machinery in `ctx.caller` cannot lend its own live
  principal generation to the member whose request it is carrying.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Verifier}
  alias Ezagent.Capability
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)

    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  test "machinery caller cannot substitute its generation for the authenticated holder" do
    target = unique_agent("target")
    holder = unique_user("holder")
    machinery = unique_agent("reconciler")

    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: target}})
    assert :ok = await_ready(target)

    unsigned = %{
      action_cap(target)
      | granted_by: admin(),
        granted_at: DateTime.utc_now(),
        grantee_uri: holder
    }

    signed = Authority.sign(:sys.get_state(pid).authority, unsigned)
    needed_ctx = %{caller: machinery, caps: MapSet.new([signed])}

    license(%{holder => [signed], machinery => [:machinery_is_live]})

    assert {:ok, ^signed} =
             Verifier.authorize(TestKind, TestBehavior, :noop, target, holder, needed_ctx)

    license(%{holder => [], machinery => [:machinery_is_still_live]})

    assert {:error, :holder_revoked} =
             Verifier.authorize(TestKind, TestBehavior, :noop, target, holder, needed_ctx)
  end

  defp license(entries) do
    by_holder =
      Map.new(entries, fn {holder, caps} ->
        {Ezagent.URI.stable_key(holder), MapSet.new(caps)}
      end)

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, by_holder)
  end

  defp action_cap(target) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(target),
      Capability.workspace_of(target)
    )
  end

  defp unique_agent(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/f6-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/f6-#{suffix}-#{System.unique_integer([:positive])}"
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
