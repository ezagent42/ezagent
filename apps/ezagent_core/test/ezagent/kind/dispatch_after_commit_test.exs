defmodule Ezagent.Kind.DispatchAfterCommitTest do
  @moduledoc """
  P2.5c — `{:dispatch_after_commit, %Cmd{}}` effect end-to-end through a
  real `Kind.Server`:

  - **success + ordering:** the deferred command is dispatched exactly once,
    AFTER the parent slice durably commits (observed via a probe message + a
    committed-slice read).
  - **enrichment (codex HIGH):** a deferred Cmd emitted with NO `caller`
    (default `:system`) is dispatched with `caller` = the emitting Kind's
    `self_uri`, NOT `:system` — proving it flowed through
    `Runtime.Effects.execute_buckets`' `enrich_dispatch_cmd`, not a raw
    `Router.dispatch`.
  - **commit-failure skip:** when `commit_and_notify` returns `{:error, _}`
    (forced via the P2.5c test-only seam), the deferred command is NOT
    dispatched and the call returns `{:error, {:persistence_failed, _}}`.
  - **observable failure (codex MEDIUM):** a deferred Cmd whose
    `Router.dispatch` returns `{:error, _}` AFTER a successful parent commit
    → the parent slice IS committed AND the failure is logged at `:error`
    (captured via `CaptureLog`), not silently dropped.

  The fixtures live inline so the handler-atom resolution
  (`String.to_existing_atom`) + cap-axis derivation have real modules.
  """

  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.{BehaviorRegistry, Invocation}

  # ---------------------------------------------------------------
  # Fixture Behavior — emits :dispatch_after_commit effects.
  # ---------------------------------------------------------------
  defmodule DacBehavior do
    @moduledoc false
    use Ezagent.Lifecycle, state_slice: :dac

    # `:trigger` emits a `{:dispatch_after_commit, cmd}` targeting THIS same
    # Kind's `:probe` action (self-dispatch — same workspace, cap-exempt).
    # The deferred Cmd is built with the default `caller: :vm_internal` so the
    # test can prove enrichment overrode it to `self_uri`.
    action(:trigger,
      args: %{},
      returns: :ok,
      caps: [:trigger],
      modes: [:call, :cast]
    )

    # `:probe` is the deferred target. It sends a message to the registered
    # test pid (carrying the caller it observed + the committed `:marker`) and
    # bumps a slice field so a committed-slice read can confirm it ran.
    action(:probe,
      args: %{},
      returns: :ok,
      caps: [:probe],
      modes: [:call, :cast]
    )

    # `:trigger_bad` emits a deferred Cmd at a NON-EXISTENT target — its
    # post-commit Router.dispatch fails AFTER the parent commit succeeds
    # (observable-failure path).
    action(:trigger_bad,
      args: %{},
      returns: :ok,
      caps: [:trigger_bad],
      modes: [:call]
    )

    # `:trigger_self_fail` emits a deferred Cmd at a LIVE self-target action
    # (`:probe_fail`) that FAILS inside its own handler AFTER the cast is
    # accepted — exercising the post-delivery failure path (codex P2.5c r2 HIGH),
    # distinct from `:trigger_bad`'s pre-delivery missing-target failure.
    action(:trigger_self_fail,
      args: %{},
      returns: :ok,
      caps: [:trigger_self_fail],
      modes: [:call]
    )

    # `:probe_fail` is a LIVE deferred target whose handler returns a bad shape,
    # which `Runtime` maps to `{:error, _}` — surfacing in the target's
    # `handle_cast` AFTER the cast was accepted.
    action(:probe_fail,
      args: %{},
      returns: :ok,
      caps: [:probe_fail],
      modes: [:call, :cast]
    )

    @impl Ezagent.ActionSet
    def cap_exempt_actions,
      do: [:trigger, :probe, :trigger_bad, :trigger_self_fail, :probe_fail]

    @impl Ezagent.Lifecycle
    def create(_args), do: {:ok, %{marker: :initial, probe_count: 0}}

    def handle_trigger(_args, ctx) do
      cap = :persistent_term.get({__MODULE__, :probe_cap})

      cmd =
        Ezagent.Cmd.new(
          ctx.self_uri,
          :probe,
          %{},
          # caller :vm_internal is the trusted-in-VM placeholder; enrichment
          # must rewrite it to the emitting Kind's self_uri.
          %{
            caller: :vm_internal,
            reply: :ignore,
            caps: MapSet.new([cap])
          }
        )

      {:ok, :ok,
       [
         {:set, :marker, :committed},
         {:dispatch_after_commit, cmd}
       ]}
    end

    def handle_probe(_args, ctx) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid}, nil)
      observed_caller = Map.get(ctx, :caller)
      committed_marker = ctx.read.(:marker, nil)

      if is_pid(test_pid) do
        send(test_pid, {:probe_ran, observed_caller, committed_marker})
      end

      count = ctx.read.(:probe_count, 0)
      {:ok, :ok, [{:set, :probe_count, count + 1}]}
    end

    def handle_trigger_bad(_args, _ctx) do
      missing = Ezagent.URI.new!("entity://team-alpha/agent/dac-missing-target")

      cmd =
        Ezagent.Cmd.new(missing, :probe, %{}, %{
          caller: :vm_internal,
          reply: :ignore,
          caps: MapSet.new()
        })

      {:ok, :ok,
       [
         {:set, :marker, :committed_bad},
         {:dispatch_after_commit, cmd}
       ]}
    end

    def handle_trigger_self_fail(_args, ctx) do
      cap = :persistent_term.get({__MODULE__, :probe_fail_cap})

      cmd =
        Ezagent.Cmd.new(ctx.self_uri, :probe_fail, %{}, %{
          caller: :vm_internal,
          reply: :ignore,
          caps: MapSet.new([cap])
        })

      {:ok, :ok,
       [
         {:set, :marker, :committed_selffail},
         {:dispatch_after_commit, cmd}
       ]}
    end

    # Returns a bad shape on purpose → Runtime maps it to `{:error, _}` in the
    # target's handle_cast, AFTER the deferred cast was already accepted.
    def handle_probe_fail(_args, _ctx), do: :not_a_valid_handler_return
  end

  defmodule DacKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :test_dac

    @impl true
    def behaviors, do: [DacBehavior]

    # `:on_change` so `commit/4` attempts a real durable write (and the
    # force-fail seam has something to fail).
    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
    :ok = BehaviorRegistry.register(DacKind, :trigger, DacBehavior)
    :ok = BehaviorRegistry.register(DacKind, :probe, DacBehavior)
    :ok = BehaviorRegistry.register(DacKind, :trigger_bad, DacBehavior)
    :ok = BehaviorRegistry.register(DacKind, :trigger_self_fail, DacBehavior)
    :ok = BehaviorRegistry.register(DacKind, :probe_fail, DacBehavior)

    :persistent_term.put({DacBehavior, :test_pid}, self())

    uri =
      Ezagent.URI.new!("entity://team-alpha/agent/test_dac-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.delete_env(:ezagent_core, :p2_5c_force_commit_failure_uris)
    end)

    {:ok, uri: uri}
  end

  defp install_deferred_caps!(uri) do
    authenticated_principal = Ezagent.Entity.User.admin_uri()

    :persistent_term.put(
      {DacBehavior, :probe_cap},
      signed_fixture_cap!(
        uri,
        DacKind.type_name(),
        DacBehavior,
        :probe,
        authenticated_principal
      )
    )

    :persistent_term.put(
      {DacBehavior, :probe_fail_cap},
      signed_fixture_cap!(
        uri,
        DacKind.type_name(),
        DacBehavior,
        :probe_fail,
        authenticated_principal
      )
    )
  end

  defp inv(uri, action) do
    presenter = Ezagent.URI.new!("entity://system/user/admin")
    cap = signed_fixture_cap!(uri, DacKind.type_name(), DacBehavior, action, presenter)

    %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=dac.#{action}"),
      mode: :call,
      args: %{},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new([cap]),
        reply: :ignore
      }
    }
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until_ready(uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(uri, deadline)
  end

  defp poll(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Kind never became :ready")
        else
          Process.sleep(5)
          poll(uri, deadline)
        end
    end
  end

  test "deferred dispatch runs AFTER commit with self_uri caller (enrichment)", %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({DacKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 1000)
    install_deferred_caps!(uri)

    assert {:ok, :ok} = GenServer.call(pid, {:ezagent_dispatch, inv(uri, :trigger)})

    # The deferred :probe must have run, observed the COMMITTED marker
    # (proving it ran post-commit, not in-handler), and observed the
    # emitting Kind's self_uri as caller (proving enrich_dispatch_cmd ran —
    # NOT the default :system).
    assert_receive {:probe_ran, observed_caller, committed_marker}, 1000
    assert committed_marker == :committed
    assert observed_caller == uri

    # Exactly once — no second deferred dispatch from a single :trigger.
    refute_receive {:probe_ran, _, _}, 200

    # The parent slice's in-handler marker committed (synchronous on the
    # :trigger call). probe_count is mutated by the async post-commit cast;
    # poll until it lands to confirm the deferred slice mutation committed.
    assert {:ok, %{marker: :committed}} = Ezagent.Kind.read(uri, :dac, spawn: :never)

    wait_until(fn ->
      match?({:ok, %{probe_count: 1}}, Ezagent.Kind.read(uri, :dac, spawn: :never))
    end)
  end

  test "canonical-admin deferred self-dispatch can use the live target authority", %{
    uri: uri
  } do
    {:ok, pid} = Ezagent.Kind.Server.start_link({DacKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 1000)

    cmd =
      Ezagent.Cmd.new(uri, :probe, %{}, %{
        caller: Ezagent.Entity.User.admin_uri(),
        authenticated_principal: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new(),
        reply: :ignore
      })

    # H3: deliver via the sealed envelope (same shape DeferredDispatch.enqueue
    # self-sends) — a raw `{:ezagent_run_deferred, …}` tuple is unsanctioned.
    send(pid, %EzagentActor.Signal{kind: :signal, payload: {:ezagent_run_deferred, [cmd]}})

    assert_receive {:probe_ran, observed_caller, :initial}, 1000
    assert observed_caller == Ezagent.Entity.User.admin_uri()
  end

  test "deferred dispatch is SKIPPED when the parent commit fails", %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({DacKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 1000)
    install_deferred_caps!(uri)

    # Force this URI's parent commit to fail.
    Application.put_env(
      :ezagent_core,
      :p2_5c_force_commit_failure_uris,
      MapSet.new([URI.to_string(uri)])
    )

    assert {:error, {:persistence_failed, {:p2_5c_forced_commit_failure, _}}} =
             GenServer.call(pid, {:ezagent_dispatch, inv(uri, :trigger)})

    # The probe MUST NOT have run — the parent commit failed, so the
    # settlement/delivery (here: the probe) must not leak.
    refute_receive {:probe_ran, _, _}, 300

    # The slice was NOT advanced (marker stays :initial, probe never ran).
    {:ok, %{probe_count: count, marker: marker}} =
      Ezagent.Kind.read(uri, :dac, spawn: :never)

    assert count == 0
    assert marker == :initial
  end

  test "a deferred dispatch that FAILS post-commit is logged, not silently dropped", %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({DacKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 1000)
    install_deferred_caps!(uri)

    log =
      capture_log(fn ->
        assert {:ok, :ok} = GenServer.call(pid, {:ezagent_dispatch, inv(uri, :trigger_bad)})
        # Give the post-commit dispatch a beat to run + log.
        Process.sleep(100)
      end)

    # The parent slice DID commit (the deferred failure is observational).
    {:ok, %{marker: marker}} = Ezagent.Kind.read(uri, :dac, spawn: :never)
    assert marker == :committed_bad

    # The failed post-commit dispatch was logged at :error.
    assert log =~ "DeferredDispatch.run"
    assert log =~ "post-commit dispatch FAILED"
  end

  test "a deferred dispatch to a LIVE target that FAILS post-delivery is logged, not silently lost",
       %{uri: uri} do
    {:ok, pid} = Ezagent.Kind.Server.start_link({DacKind, %{uri: uri}})
    :ok = wait_until_ready(uri, 1000)
    install_deferred_caps!(uri)

    log =
      capture_log(fn ->
        assert {:ok, :ok} =
                 GenServer.call(pid, {:ezagent_dispatch, inv(uri, :trigger_self_fail)})

        # Give the post-commit cast a beat to be accepted + fail target-side.
        Process.sleep(100)
      end)

    # The parent slice DID commit (the deferred target-side failure is
    # observational — it does not roll back the already-committed parent turn).
    {:ok, %{marker: marker}} = Ezagent.Kind.read(uri, :dac, spawn: :never)
    assert marker == :committed_selffail

    # codex P2.5c r2 HIGH: the cast was ACCEPTED (Router.dispatch returned :ok),
    # then the handler failed inside the target's handle_cast. Because the
    # deferred Cmd is reply: :ignore, no caller sees the error — so the target
    # server MUST log it. Without `log_unobservable_cast_error/2` this failure
    # would be silently lost in-uptime.
    assert log =~ "fire-and-forget cast dispatch FAILED"
  end
end
