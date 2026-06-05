defmodule Ezagent.ExternalMirror.WorkerContractTest do
  @moduledoc """
  PR-EM-2 acceptance test #7 — contract invariants.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-2 acceptance bar (test 7):

  - `Ezagent.Entity.ExternalMirrorWorker.behaviors/0` includes
    `Ezagent.Behavior.ExternalMirrorWorker`.
  - Plus structural cap-shape pins:
    - `Behavior.ExternalMirrorWorker.cap_subjects/0` includes the
      `:publish` action with a non-empty description.
    - `Behavior.ExternalMirrorWorker.data_owner/1` returns
      `:no_owner` for an `entity://worker/...` URI (SPEC §4.3 —
      framework-internal Kind).

  Plus expanded Adapter / Binding behaviour declarations
  (PR-EM-2 expanded the PR-EM-1 stubs to the full SPEC §2.2 / §2.3
  callback sets). Test asserts the callback list matches the SPEC.
  """

  use ExUnit.Case, async: true

  describe "ExternalMirrorWorker Kind composition" do
    test "behaviors/0 returns [Ezagent.Behavior.ExternalMirrorWorker]" do
      assert Ezagent.Entity.ExternalMirrorWorker.behaviors() ==
               [Ezagent.Behavior.ExternalMirrorWorker]
    end

    test "type_name/0 is :external_mirror_worker" do
      assert Ezagent.Entity.ExternalMirrorWorker.type_name() == :external_mirror_worker
    end

    test "persistence/0 is :ephemeral (SPEC §4.3 — restart resets cursor per OQ-EM-10)" do
      assert Ezagent.Entity.ExternalMirrorWorker.persistence() == :ephemeral
    end

    test "supervisor/0 is RootSupervisor (SPEC §6.3 two-tier topology)" do
      assert Ezagent.Entity.ExternalMirrorWorker.supervisor() ==
               Ezagent.ExternalMirror.RootSupervisor
    end

    test "spawn_strategy/0 returns {:custom, WorkerSpawn, :spawn_kind_server}" do
      assert Ezagent.Entity.ExternalMirrorWorker.spawn_strategy() ==
               {:custom, Ezagent.ExternalMirror.WorkerSpawn, :spawn_kind_server}
    end

    test "terminate_strategy/0 returns {:custom, WorkerSpawn, :terminate_by_pid} (codex round-1 HIGH-2)" do
      assert Ezagent.Entity.ExternalMirrorWorker.terminate_strategy() ==
               {:custom, Ezagent.ExternalMirror.WorkerSpawn, :terminate_by_pid}
    end
  end

  describe "ExternalMirrorWorker Behavior shape" do
    test "actions/0 is [:publish]" do
      assert Ezagent.Behavior.ExternalMirrorWorker.actions() == [:publish]
    end

    test "state_slice/0 is :external_mirror_worker" do
      assert Ezagent.Behavior.ExternalMirrorWorker.state_slice() == :external_mirror_worker
    end

    test "cap_subjects/0 includes :publish with a non-empty description" do
      subjects = Ezagent.Behavior.ExternalMirrorWorker.cap_subjects()
      assert {:publish, desc} = List.keyfind(subjects, :publish, 0)
      assert is_binary(desc) and byte_size(desc) > 0
    end

    test "data_owner/1 on a worker URI returns :no_owner (SPEC §4.3 — framework-internal)" do
      worker_uri = Ezagent.URI.new!("entity://default/worker/em_deadbeefcafe")
      assert Ezagent.Behavior.ExternalMirrorWorker.data_owner(worker_uri) == :no_owner
    end

    test "data_owner/1 on :any returns :no_owner (bootstrap-admin grant only)" do
      assert Ezagent.Behavior.ExternalMirrorWorker.data_owner(:any) == :no_owner
    end

    test "post_init/2 schedules the Lifecycle :ezagent_activate continuation" do
      # Lifecycle migration (Phase B): the `use Ezagent.Lifecycle` macro
      # emits `post_init(_, _), do: {:continue, :ezagent_activate}`; the
      # engine drains it → handle_continue runs activate/2 (which resolves
      # the adapter/binding modules, opens the transport, and subscribes).
      assert Ezagent.Behavior.ExternalMirrorWorker.post_init(%{}, %{}) ==
               {:continue, :ezagent_activate}
    end
  end

  describe "Adapter behaviour callback set (PR-EM-2 expansion)" do
    test "declares the full SPEC §2.2 required callback set" do
      callbacks =
        Ezagent.ExternalMirror.Adapter.behaviour_info(:callbacks)
        |> Enum.sort()

      # Required (PR-EM-1 + PR-EM-2). target_ownership_check_timeout
      # is optional — checked separately below.
      expected =
        [
          adapter_id: 0,
          binding_module: 0,
          cap_subject: 0,
          description: 0,
          display_name: 0,
          event_to_payload: 1,
          target_ownership_check: 2,
          target_ownership_check_timeout: 0
        ]
        |> Enum.sort()

      assert callbacks == expected
    end

    test "target_ownership_check_timeout/0 is optional" do
      optional = Ezagent.ExternalMirror.Adapter.behaviour_info(:optional_callbacks)
      assert :target_ownership_check_timeout in Keyword.keys(optional)
    end
  end

  describe "Binding behaviour callback set (PR-EM-2 expansion)" do
    test "declares the full SPEC §2.3 required callback set" do
      callbacks =
        Ezagent.ExternalMirror.Binding.behaviour_info(:callbacks)
        |> Enum.sort()

      expected =
        [
          adapter_module: 0,
          init: 1,
          publish: 2,
          terminate: 2
        ]
        |> Enum.sort()

      assert callbacks == expected
    end

    test "terminate/2 is optional (SPEC §2.3 — no-op default)" do
      optional = Ezagent.ExternalMirror.Binding.behaviour_info(:optional_callbacks)
      assert :terminate in Keyword.keys(optional)
    end
  end

  describe "CapabilityRegistry wiring" do
    test "Worker.publish is registered against the ExternalMirrorWorker Kind" do
      assert {:ok, subject} =
               Ezagent.CapabilityRegistry.lookup_subject(
                 Ezagent.Entity.ExternalMirrorWorker,
                 :publish
               )

      assert subject.behavior == Ezagent.Behavior.ExternalMirrorWorker
    end
  end
end
