defmodule Ezagent.Kind.RuntimePhase3dTest do
  @moduledoc """
  Phase 3d runtime invariant gate (per memory
  `feedback_completion_requires_invariant_test`):

  Invariant #10 isn't truly tested by grep alone — a future refactor
  might keep `Capability.matches?` in the file but stop calling it
  from the dispatch path. This test exercises the actual dispatch
  with a denying ctx and asserts the deny manifests as
  `{:error, :unauthorized}` + `[:ezagent, :authz, :denied]` telemetry.

  If this test starts failing, the cap-deny gate has been bypassed
  somehow (stub revived, default cap silently injected, etc).
  """

  use ExUnit.Case
  alias Ezagent.{Invocation, KindRegistry}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Attach a telemetry handler for the duration of this test to capture
    # :authz events. Detach in on_exit.
    test_pid = self()
    handler_id = "phase3d-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ezagent, :authz, :granted],
        [:ezagent, :authz, :denied]
      ],
      fn event, _measurements, meta, _config ->
        send(test_pid, {:authz_event, event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "dispatch with empty caps → {:error, :unauthorized} + :denied telemetry" do
    # Echo plugin pre-spawns entity://system/agent/echo_default at boot; use it as the target.
    target = URI.new!("entity://system/agent/echo_default?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{msg: "should be denied"},
      ctx: %{
        caller: URI.new!("entity://team-alpha/user/nobody"),
        caps: MapSet.new(),
        reply: :ignore
      }
    }

    assert {:error, :unauthorized} = Invocation.dispatch(inv)

    # :denied telemetry fired
    assert_receive {:authz_event, [:ezagent, :authz, :denied], meta}, 500
    assert meta.target == target
    assert meta.action == :say
  end

  test "dispatch with admin caps → success + :granted telemetry" do
    target = URI.new!("entity://system/agent/echo_default?action=echo.say")

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{msg: "should be granted"},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: :ignore
      }
    }

    assert {:ok, %{echo: "should be granted"}} = Invocation.dispatch(inv)

    assert_receive {:authz_event, [:ezagent, :authz, :granted], _meta}, 500
  end

  test "KindRegistry still has entity://system/agent/echo_default (sanity — dispatch path live)" do
    assert {:ok, _pid} = KindRegistry.lookup(URI.new!("entity://system/agent/echo_default"))
  end
end
