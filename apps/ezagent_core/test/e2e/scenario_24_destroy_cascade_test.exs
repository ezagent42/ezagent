defmodule Ezagent.E2E.Scenario24DestroyCascadeTest do
  @moduledoc """
  E2E Scenario #24 — destroy cascade w/ Saga compensation.

  Catalogue: `docs/scenarios/24-destroy-cascade/scenario.md` (Category 12).
  Status pre-this-PR: ⚠️ implemented-with-gaps. The `sandbox_destroy_test.exs`
  + `lifecycle_terminate_test.exs` already pin single-step destroy; what
  this file adds is the cross-Kind cascade + `Ezagent.SagaRunner`
  compensation contract.

  ## Why this lives in `test/e2e/` not `test/integration/`

  Per `docs/scenarios/README.md` §1.3 + `feedback_completion_requires_invariant_test`:
  scenario catalog entries get their own invariant test that fails when
  the architectural goal regresses. Single-Behavior tests live in
  `test/integration/`; cross-Kind cascades live in `test/e2e/`.

  ## What "cascade" means in Phase 1

  Phase 1 (PR #451) ships the `SagaRunner` primitive. There is NO
  framework-driven cascade yet — no Kind dispatches a `:destroy` action
  that automatically reaches its dependent Kinds. The cascade is
  composed BY THE CALLER (operator UI, mix task, future plugin Behavior)
  via `SagaRunner.new() |> run(:terminate_session, ...) |> run(:destroy_agent, ...)`.

  These tests pin the contract that contract authors will rely on:

    - cascade composes via SagaRunner with real `lifecycle.terminate`
      + `sandbox.destroy` dispatches as forward steps;
    - on mid-cascade failure, prior steps' compensate fns run in
      reverse order;
    - compensate-fn failure writes an operator-repair marker
      (the SPEC §5.4 contract — independent of step semantics);
    - idempotent steps (terminate of an already-gone agent) do NOT
      poison the saga.

  Per scenario #24 §"Notes": the cascade scenario is only ✅ when an
  invariant test asserts "destroy(workspace) ⇒ count(orphans) == 0".
  Phase 1 cannot satisfy that for the workspace cascade (Behavior
  not migrated yet), so these tests pin the per-step cascade contract
  + leave the workspace-level invariant for Phase 2+.

  Async: `false` — exercises real DynamicSupervisors + KindRegistry +
  WorkspaceRegistry (shared ETS).
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  @moduletag scenario: "24-destroy-cascade"

  alias Ezagent.{Invocation, KindRegistry, SagaRunner}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Agent, as: AgentKind
  alias Ezagent.Entity.{Session, User}

  @workspace_uri URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  defp admin_ctx(target) do
    cap = signed_action_cap!(target, User.admin_uri())

    %{
      caller: User.admin_uri(),
      authenticated_principal: User.admin_uri(),
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end

  defp spawn_agent! do
    uri = Ezagent.URI.new!("entity://team-alpha/agent/scen24-agent-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(AgentKind, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)
    uri
  end

  defp spawn_session! do
    uri = Ezagent.URI.new!("session://team-alpha/default/scen24-sess-#{uniq()}")
    # P5-0b — thread the explicit chat-Session behavior set so the spawned
    # session persists a non-nil :kind_base and the scoped effective_set/2 guard
    # (Session.requires_explicit_behavior_set? == true) does not crash it.
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: uri, behaviors: Session.behaviors()})

    :ok =
      Ezagent.WorkspaceRegistry.bind(
        uri,
        Ezagent.Capability.workspace_of(uri)
      )

    uri
  end

  defp dispatch(uri, action, args \\ %{}) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: admin_ctx(target)
    })
  end

  defp wait_until_gone(uri, tries \\ 50) do
    cond do
      tries == 0 ->
        :still_alive

      KindRegistry.lookup(uri) == :error ->
        :gone

      true ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end

  # --------------------------------------------------------------------------
  # Section A — Cascade happy path (forward-only, no compensation invoked)
  # --------------------------------------------------------------------------
  describe "happy-path cascade: session -> agent destroy via SagaRunner" do
    test "two-step cascade fully terminates both Kinds; saga returns :ok" do
      # Setup: a session with an agent member. Cascade intent: destroy
      # the agent (sandbox.destroy) AFTER terminating any agent that
      # might be holding session resources. For the happy path both
      # forward steps succeed.
      session_uri = spawn_session!()
      agent_uri = spawn_agent!()

      assert {:ok, _} = KindRegistry.lookup(session_uri)
      assert {:ok, _} = KindRegistry.lookup(agent_uri)

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :destroy_agent,
          fn _ctx, _eff ->
            case dispatch(agent_uri, "sandbox.destroy") do
              {:ok, %{destroyed: true}} -> {:ok, :agent_destroyed, [{:emit, :agent_destroyed}]}
              other -> {:error, {:agent_destroy_failed, other}}
            end
          end,
          fn _err, _eff, _ctx ->
            # Best-effort: respawn the agent URI. Compensation honesty
            # (SagaRunner moduledoc): the new PID is a different actor,
            # but the URI is back in the registry for downstream visibility.
            case Ezagent.Kind.spawn(AgentKind, %{uri: agent_uri}) do
              {:ok, _pid} -> {:ok, :compensated}
              {:error, {:already_started, _}} -> {:ok, :compensated}
              other -> {:error, :compensation_failed, other}
            end
          end
        )
        |> SagaRunner.run(:mark_session_destroyed, fn _ctx, _eff ->
          # Session-level cascade step. In Phase 1 there is no
          # `session.destroy` action; we model the saga step as a
          # KindSnapshot.delete + DynamicSupervisor.terminate_child to
          # mirror what a Phase 2 Session destroy behavior would do.
          uri_str = URI.to_string(session_uri)

          case KindRegistry.lookup(session_uri) do
            {:ok, pid} ->
              :ok =
                DynamicSupervisor.terminate_child(
                  EzagentDomainInstanceMessage.SessionSupervisor,
                  pid
                )

              :ok = KindSnapshot.delete(uri_str)
              {:ok, :session_destroyed, [{:emit, :session_destroyed}]}

            :error ->
              # Idempotent — already gone counts as success.
              {:ok, :session_already_gone, []}
          end
        end)

      assert {:ok, %{step_results: results, events: events}} =
               SagaRunner.execute(saga, %{session_uri: session_uri, agent_uri: agent_uri})

      assert results.destroy_agent == :agent_destroyed
      assert results.mark_session_destroyed == :session_destroyed

      # Effects accumulated in forward order.
      assert events == [{:emit, :agent_destroyed}, {:emit, :session_destroyed}]

      # Both Kinds are gone.
      assert :gone = wait_until_gone(agent_uri)
      assert :gone = wait_until_gone(session_uri)
    end

    test "cascade with idempotent middle step (terminate of already-gone agent)" do
      # An already-terminated agent in the middle of a cascade must NOT
      # poison the saga — idempotent success.
      agent_uri = spawn_agent!()
      session_uri = spawn_session!()

      # Pre-destroy the agent BEFORE the cascade starts.
      assert {:ok, %{destroyed: true}} = dispatch(agent_uri, "sandbox.destroy")
      assert :gone = wait_until_gone(agent_uri)

      saga =
        SagaRunner.new()
        |> SagaRunner.run(:noop_pre, fn _ctx, _eff -> {:ok, :ok, []} end)
        |> SagaRunner.run(:redestroy_agent, fn _ctx, _eff ->
          # The agent is already gone — dispatch returns :no_such_actor.
          # Saga step maps that to idempotent :ok.
          case dispatch(agent_uri, "sandbox.destroy") do
            {:ok, %{destroyed: true}} -> {:ok, :destroyed, []}
            {:error, :no_such_actor} -> {:ok, :already_gone, []}
            {:error, :destroyed} -> {:ok, :already_gone, []}
            other -> {:error, {:unexpected, other}}
          end
        end)
        |> SagaRunner.run(:terminate_session, fn _ctx, _eff ->
          case KindRegistry.lookup(session_uri) do
            {:ok, pid} ->
              :ok =
                DynamicSupervisor.terminate_child(
                  EzagentDomainInstanceMessage.SessionSupervisor,
                  pid
                )

              {:ok, :session_destroyed, []}

            :error ->
              {:ok, :session_already_gone, []}
          end
        end)

      assert {:ok, %{step_results: results}} = SagaRunner.execute(saga, %{})
      assert results.redestroy_agent in [:destroyed, :already_gone]
      assert results.terminate_session == :session_destroyed
      assert :gone = wait_until_gone(session_uri)
    end
  end

  # --------------------------------------------------------------------------
  # Section B — Forward failure mid-cascade -> compensation walks in reverse
  # --------------------------------------------------------------------------
  describe "forward failure mid-cascade triggers reverse compensation" do
    test "two prior steps compensate in reverse when step 3 fails" do
      # Record compensation order using a process-dict-style Agent so
      # we can assert reverse-walk semantics on the real cascade.
      {:ok, comp_log} = Agent.start_link(fn -> [] end)

      agent_uri_a = spawn_agent!()
      agent_uri_b = spawn_agent!()

      record_compensate = fn step ->
        fn _err, _eff, _ctx ->
          Agent.update(comp_log, fn xs -> [step | xs] end)
          {:ok, :compensated}
        end
      end

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :reserve_a,
          fn _ctx, _eff ->
            # Mutate Agent A's slice via sandbox.update_config — observable
            # state change that compensate can undo.
            {:ok, _} =
              dispatch(agent_uri_a, "sandbox.update_config", %{
                config_dir_path: "/tmp/scen24-a-#{uniq()}",
                template_class: nil
              })

            {:ok, :reserved_a, [{:emit, :reserved_a}]}
          end,
          record_compensate.(:reserve_a)
        )
        |> SagaRunner.run(
          :reserve_b,
          fn _ctx, _eff ->
            {:ok, _} =
              dispatch(agent_uri_b, "sandbox.update_config", %{
                config_dir_path: "/tmp/scen24-b-#{uniq()}",
                template_class: nil
              })

            {:ok, :reserved_b, [{:emit, :reserved_b}]}
          end,
          record_compensate.(:reserve_b)
        )
        |> SagaRunner.run(:commit_destroy, fn _ctx, _eff ->
          # Simulated downstream failure (e.g. external mirror unbind
          # rejected by the sidecar). Triggers compensation walk.
          {:error, :external_unbind_failed}
        end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.failed_at == :commit_destroy
      assert err.reason == :external_unbind_failed

      # Reverse-order compensation: :b first, then :a.
      assert err.compensated == [:reserve_b, :reserve_a]
      assert err.operator_repair_marker == nil
      assert Agent.get(comp_log, & &1) == [:reserve_a, :reserve_b]

      # The Agents are STILL ALIVE — compensation here is a slice undo
      # surrogate; the Kinds were never terminated.
      assert {:ok, _} = KindRegistry.lookup(agent_uri_a)
      assert {:ok, _} = KindRegistry.lookup(agent_uri_b)
    end

    test "forward step that RAISES is treated as failure + triggers compensation" do
      {:ok, comp_log} = Agent.start_link(fn -> [] end)
      agent_uri = spawn_agent!()

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :ok_step,
          fn _ctx, _eff ->
            {:ok, _} =
              dispatch(agent_uri, "sandbox.update_config", %{
                config_dir_path: "/tmp/scen24-raise-#{uniq()}",
                template_class: nil
              })

            {:ok, :ok, []}
          end,
          fn _err, _eff, _ctx ->
            Agent.update(comp_log, fn xs -> [:ok_step | xs] end)
            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:raises, fn _ctx, _eff ->
          raise "synthetic cascade crash"
        end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.failed_at == :raises
      assert match?({:forward_raised, _}, err.reason)
      assert err.compensated == [:ok_step]
      assert Agent.get(comp_log, & &1) == [:ok_step]
    end
  end

  # --------------------------------------------------------------------------
  # Section C — Compensation failure -> operator-repair marker
  # --------------------------------------------------------------------------
  describe "compensation failure emits an operator-repair marker" do
    test "compensate returning :compensation_failed writes marker + halts walk" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :step_a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx ->
            # Simulate a compensation that itself fails (e.g. DB write-back
            # for the slice revert hits a unique-constraint conflict).
            {:error, :compensation_failed, :slice_revert_conflict}
          end
        )
        |> SagaRunner.run(:step_b, fn _ctx, _eff -> {:error, :downstream_boom} end)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.failed_at == :step_b
      assert err.reason == :downstream_boom

      # :step_a's compensate failed -> not in compensated list.
      assert err.compensated == []
      assert is_binary(err.operator_repair_marker)
      assert byte_size(err.operator_repair_marker) == 32

      # Marker is logged at :error level (per SagaRunner moduledoc §5.4).
      assert log =~ "[SagaRunner] operator-repair marker #{err.operator_repair_marker}"
      assert log =~ "slice_revert_conflict"
    end

    test "compensate raising counts as compensation_failed + marker fires" do
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :step_a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx -> raise "compensate explosion" end
        )
        |> SagaRunner.run(:step_b, fn _ctx, _eff -> {:error, :downstream_boom} end)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.compensated == []
      assert is_binary(err.operator_repair_marker)
      assert log =~ "[SagaRunner] operator-repair marker"
      assert log =~ "compensate_raised"
    end

    test "partial compensation: later step compensates, earlier step's compensate fails" do
      # 3 forward steps, :c fails. Reverse walk: :b succeeds, :a fails.
      # Marker fires; :b is in `compensated`, :a is NOT.
      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx ->
            {:error, :compensation_failed, :a_needs_manual_repair}
          end
        )
        |> SagaRunner.run(
          :b,
          fn _ctx, _eff -> {:ok, :b, []} end,
          fn _err, _eff, _ctx -> {:ok, :compensated} end
        )
        |> SagaRunner.run(:c, fn _ctx, _eff -> {:error, :c_boom} end)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> SagaRunner.execute(saga, %{}) end)

      assert {:error, err} = result
      assert err.failed_at == :c
      assert err.reason == :c_boom
      assert err.compensated == [:b]
      assert is_binary(err.operator_repair_marker)
    end
  end

  # --------------------------------------------------------------------------
  # Section D — Slice-revert compensation against a real Kind
  # --------------------------------------------------------------------------
  describe "compensate fn applies real slice-revert against an Agent Kind" do
    test "compensate writes back the pre-step slice on failure" do
      # Real-world compensation pattern: snapshot the slice BEFORE the
      # forward mutation; on failure, restore via dispatch. Asserts the
      # SagaRunner contract that compensate sees `effects_so_far`
      # (including the forward-step effect that captured the snapshot).
      agent_uri = spawn_agent!()
      old_path = "/tmp/scen24-pre-#{uniq()}"
      new_path = "/tmp/scen24-post-#{uniq()}"

      # Seed initial state.
      assert {:ok, _} =
               dispatch(agent_uri, "sandbox.update_config", %{
                 config_dir_path: old_path,
                 template_class: nil
               })

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :mutate,
          fn _ctx, _eff ->
            # Capture pre-image as part of the step's effects so the
            # compensate fn can read it back.
            {:ok, %{config_dir_path: captured}} = dispatch(agent_uri, "sandbox.read")

            {:ok, _} =
              dispatch(agent_uri, "sandbox.update_config", %{
                config_dir_path: new_path,
                template_class: nil
              })

            {:ok, :mutated, [{:snapshot, :sandbox, %{config_dir_path: captured}}]}
          end,
          fn _err, effects, _ctx ->
            # Find the snapshot effect this step left behind.
            pre =
              Enum.find_value(effects, fn
                {:snapshot, :sandbox, slice} -> slice
                _ -> nil
              end)

            {:ok, _} =
              dispatch(agent_uri, "sandbox.update_config", %{
                config_dir_path: pre.config_dir_path,
                template_class: nil
              })

            {:ok, :compensated}
          end
        )
        |> SagaRunner.run(:fail, fn _ctx, _eff -> {:error, :downstream} end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      assert err.compensated == [:mutate]

      # Real assertion: the slice's config_dir_path has been REVERTED
      # to the pre-image. This is the contract a Phase 2+ cascade
      # author can rely on.
      assert {:ok, %{config_dir_path: ^old_path}} = dispatch(agent_uri, "sandbox.read")
    end
  end

  # --------------------------------------------------------------------------
  # Section E — Empty / pathological saga shapes
  # --------------------------------------------------------------------------
  describe "saga edge cases for cascade composition" do
    test "empty cascade returns :ok with empty step_results + events" do
      # Cascade composers that hit an early-return path (no work to do)
      # must NOT crash the dispatch they're running inside.
      assert {:ok, %{step_results: results, events: events}} =
               SagaRunner.execute(SagaRunner.new(), %{})

      assert results == %{}
      assert events == []
    end

    test "step without compensate fn is silently skipped on rollback" do
      # Cascade authors may legitimately model some steps as
      # non-rollbackable (already-sent PubSub broadcasts, etc.). Saga
      # MUST NOT crash on the reverse walk because of a missing
      # compensate fn.
      {:ok, comp_log} = Agent.start_link(fn -> [] end)

      saga =
        SagaRunner.new()
        |> SagaRunner.run(
          :a,
          fn _ctx, _eff -> {:ok, :a, []} end,
          fn _err, _eff, _ctx ->
            Agent.update(comp_log, fn xs -> [:a | xs] end)
            {:ok, :compensated}
          end
        )
        # :b has NO compensate fn (nil).
        |> SagaRunner.run(:b, fn _ctx, _eff -> {:ok, :b, []} end)
        |> SagaRunner.run(:c, fn _ctx, _eff -> {:error, :boom} end)

      assert {:error, err} = SagaRunner.execute(saga, %{})
      # :b is silently skipped; :a is compensated.
      assert err.compensated == [:a]
      assert Agent.get(comp_log, & &1) == [:a]
    end
  end
end
