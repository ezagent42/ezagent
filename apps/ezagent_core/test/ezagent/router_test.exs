defmodule Ezagent.RouterTest do
  @moduledoc """
  Tests for `Ezagent.Router.dispatch/1` per SPEC §2.1.

  Phase 1 strategy: Router translates `%Cmd{}` → `%Invocation{}` and
  delegates to the existing dispatch path. These tests confirm:

  - Happy-path `:call` returns the Behavior's result
  - `:cast` returns `:ok` and delivers the result via the reply target
  - `:no_such_actor` for unknown URI
  - `:not_ready` fail-fast on `:call` to not-ready actor
  - `dispatch_saga/2` stubs cleanly when SagaRunner module missing
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cmd, Router, Test.TestKind, Test.TestBehavior}

  setup do
    # Registry the test fixture Behavior + a fresh instance.
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_router-#{System.unique_integer([:positive])}"
      )

    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :fail, TestBehavior)

    {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    :ok = wait_until_ready(uri)

    presenter = Ezagent.URI.user(:system, :admin)
    cap = signed_fixture_cap!(uri, :test, TestBehavior, :noop, presenter)
    fail_cap = signed_fixture_cap!(uri, :test, TestBehavior, :fail, presenter)

    {:ok, target: uri, presenter: presenter, cap: cap, fail_cap: fail_cap}
  end

  describe "dispatch/1 — happy path" do
    test ":call returns the handler result", %{target: target, presenter: presenter, cap: cap} do
      cmd =
        Cmd.new(target, :noop, %{msg: "hi-router"}, %{
          caller: presenter,
          authenticated_principal: presenter,
          reply: {:caller_inbox, self()},
          caps: MapSet.new([cap])
        })
        |> Map.put(:origin, :trusted_internal)

      # Legacy dispatch path is cap-checked at step 5.5. The test
      # fixture TestBehavior is not cap-gated in the BehaviorRegistry
      # the same way real Behaviors are, so caps don't matter here
      # — the InvocationTest setup proves this.
      assert {:ok, %{echoed: "hi-router"}} = Router.dispatch(cmd)
    end

    test ":cast returns :ok and delivers via caller_inbox", %{
      target: target,
      presenter: presenter,
      cap: cap
    } do
      cmd =
        Cmd.new(target, :noop, %{msg: "cast-router"}, %{
          mode: :cast,
          caller: presenter,
          authenticated_principal: presenter,
          reply: {:caller_inbox, self()},
          caps: MapSet.new([cap])
        })
        |> Map.put(:origin, :trusted_internal)

      assert :ok = Router.dispatch(cmd)
      assert_receive {:ezagent_reply, {:ok, %{echoed: "cast-router"}}}, 500
    end
  end

  describe "dispatch/1 — error paths" do
    test "no_such_actor for unknown URI" do
      cmd =
        Cmd.new(
          Ezagent.URI.new!("entity://team-alpha/agent/test_nope-not-exist"),
          :noop,
          %{msg: "x"},
          %{caller: :vm_internal, reply: {:caller_inbox, self()}, caps: MapSet.new()}
        )
        |> Map.put(:origin, :trusted_internal)

      assert {:error, :no_such_actor} = Router.dispatch(cmd)
    end

    test ":call to not-ready actor waits through the activate window then serves (C-A readiness)",
         %{target: target, presenter: presenter, cap: cap} do
      # Readiness contract (post-lifecycle remediation, spec C-A): a
      # synchronous dispatch to a `:not_ready` target waits-then-serves
      # rather than fail-fasting with `:not_ready`. Flip to ready from a
      # concurrent process during the bounded wait; the dispatch must
      # return the real result.
      :ok = Ezagent.ReadyGate.put(target, :not_ready)

      spawn(fn ->
        Process.sleep(50)
        :ok = Ezagent.ReadyGate.mark_ready(target)
      end)

      cmd =
        Cmd.new(target, :noop, %{msg: "x"}, %{
          caller: presenter,
          authenticated_principal: presenter,
          reply: {:caller_inbox, self()},
          caps: MapSet.new([cap])
        })
        |> Map.put(:origin, :trusted_internal)

      assert {:ok, _result} = Router.dispatch(cmd)
    after
      :ok
    end

    test "handler {:error, _} propagates as Router {:error, _}", %{
      target: target,
      presenter: presenter,
      fail_cap: fail_cap
    } do
      cmd =
        Cmd.new(target, :fail, %{}, %{
          caller: presenter,
          authenticated_principal: presenter,
          reply: {:caller_inbox, self()},
          caps: MapSet.new([fail_cap])
        })
        |> Map.put(:origin, :trusted_internal)

      assert {:error, :test_failure} = Router.dispatch(cmd)
    end
  end

  describe "dispatch_saga/2" do
    test "returns {:error, :saga_runner_not_loaded} when SagaRunner module is absent" do
      # Phase 1: Subagent D's `Ezagent.SagaRunner` module is not yet
      # in the codebase. Router stubs to a clean error.
      saga = %{name: "test_saga", steps: []}
      assert {:error, :saga_runner_not_loaded} = Router.dispatch_saga(saga, %{})
    end
  end

  describe "Cmd construction" do
    test "Cmd.new/4 fills ctx defaults" do
      cmd = Cmd.new("entity://x/agent/y", :ping, %{}, %{caller: :vm_internal})
      assert cmd.action == :ping
      assert cmd.ctx.caller == :vm_internal
      assert cmd.ctx.reply == :ignore
      assert cmd.ctx.command_uuid == nil
    end

    test "Cmd.new/4 accepts %URI{} target unchanged" do
      uri = Ezagent.URI.new!("entity://x/agent/y")
      cmd = Cmd.new(uri, :ping, %{}, %{caller: :vm_internal})
      assert cmd.target == uri
    end

    test "Cmd.new/4 raises on missing required key (via @enforce_keys)" do
      # Directly building the struct without args raises ArgumentError.
      assert_raise ArgumentError, fn ->
        struct!(Cmd, %{target: Ezagent.URI.new!("entity://x/y/z")})
      end
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp wait_until_ready(uri, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(uri, deadline)
  end

  defp do_wait(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_wait(uri, deadline)
        end
    end
  end
end
