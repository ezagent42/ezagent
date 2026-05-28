defmodule Ezagent.Behavior.ExternalMirrorWorkerMigrationParityTest do
  @moduledoc """
  Phase 2-d r3 — Migration parity for
  `Ezagent.Behavior.ExternalMirrorWorker`.

  This Behavior was migrated from the legacy `@behaviour
  Ezagent.Behavior` + manual `actions/0` / `interface/0` /
  `required_caps/0` / `cap_subjects/0` / `invoke/4` shape to the new
  `use Ezagent.Behavior` + per-action `action :publish, ...` macro
  declaration + `handle_publish/2` handler per SPEC §6.2.

  Per OQ-6: ExternalMirrorWorker is a `:hot_resource` Kind;
  `Ezagent.Entity.ExternalMirrorWorker.persistence/0` returns
  `:ephemeral` (asserted by `worker_contract_test.exs` —
  cross-referenced here so the Worker contract surface stays
  invariant across the Behavior migration).

  BootReconciler is framework-internal (NOT a Behavior); it was
  intentionally left unchanged per the Phase 2-d scope.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.ExternalMirrorWorker

  describe "new-contract markers" do
    test "ExternalMirrorWorker is a new-style Behavior" do
      assert function_exported?(ExternalMirrorWorker, :__behavior__?, 0)
      assert ExternalMirrorWorker.__behavior__?() == true
      assert Ezagent.Behavior.new_style?(ExternalMirrorWorker)
    end

    test ":publish action has matching handle_publish/2 (compile-time gate)" do
      assert :publish in ExternalMirrorWorker.__action_names__()
      assert function_exported?(ExternalMirrorWorker, :handle_publish, 2)
    end
  end

  describe "action surface parity" do
    test "actions/0 lists [:publish]" do
      assert ExternalMirrorWorker.actions() == [:publish]
    end

    test "state_slice/0 returns :external_mirror_worker (slice key unchanged)" do
      assert ExternalMirrorWorker.state_slice() == :external_mirror_worker
    end

    test "cap_subjects/0 carries the pre-migration :publish description" do
      assert [
               {:publish,
                "publish a Publisher event to an external system via the bound adapter+binding pair"}
             ] == ExternalMirrorWorker.cap_subjects()
    end

    test "interface/0 has the publish action spec with :cast mode" do
      iface = ExternalMirrorWorker.interface()
      assert iface[:publish].args == %{}
      assert iface[:publish].returns == %{ok: :boolean, cursor: :integer}
      assert iface[:publish].modes == [:cast]
    end

    test "required_caps/0 pins the :external_mirror_worker kind axis" do
      caps = ExternalMirrorWorker.required_caps()

      assert %Ezagent.Capability{
               kind: :external_mirror_worker,
               behavior: ExternalMirrorWorker,
               action: :publish
             } = caps[:publish]
    end
  end

  describe "lifecycle hooks (slice machinery — unchanged by migration)" do
    test "init_slice/1 + post_init/2 + handle_continue/3 + terminate/3 stay exported" do
      assert function_exported?(ExternalMirrorWorker, :init_slice, 1)
      assert function_exported?(ExternalMirrorWorker, :post_init, 2)
      assert function_exported?(ExternalMirrorWorker, :handle_continue, 3)
      assert function_exported?(ExternalMirrorWorker, :terminate, 3)
      assert function_exported?(ExternalMirrorWorker, :data_owner, 1)
      assert function_exported?(ExternalMirrorWorker, :handle_kind_message, 3)
    end

    test "post_init/2 returns `{:continue, :subscribe_and_init}` (split-init pattern)" do
      assert ExternalMirrorWorker.post_init(%{}, %{}) == {:continue, :subscribe_and_init}
    end

    test "init_slice/1 produces the documented :pending shape with all keys present" do
      args = %{
        session_uri: Ezagent.URI.parse!("session://default/team-alpha/p2d-worker-parity"),
        adapter_id: "test-adapter",
        target_id: "t-1",
        opts: %{}
      }

      slice = ExternalMirrorWorker.init_slice(args)

      assert slice.subscription_state == :pending
      assert slice.publisher_cursor == :latest
      assert slice.count == 0
      assert slice.error_count == 0
      assert is_nil(slice.binding_state)
      assert is_nil(slice.last_published_message_id)
      # The session_uri / adapter_id / target_id must round-trip
      # unchanged so the post_init handle_continue can resolve the
      # adapter + binding modules.
      assert slice.session_uri == args.session_uri
      assert slice.adapter_id == args.adapter_id
    end

    test "data_owner/1 always returns :no_owner (framework-internal Kind)" do
      worker_uri = Ezagent.URI.parse!("entity://worker/default/em_test_t1")
      assert ExternalMirrorWorker.data_owner(worker_uri) == :no_owner
      assert ExternalMirrorWorker.data_owner(:any) == :no_owner
      assert ExternalMirrorWorker.data_owner({:scope, :within_session, worker_uri}) == :no_owner
      assert ExternalMirrorWorker.data_owner({:weird, :shape}) == :no_owner
    end
  end

  describe "Worker Entity persistence (OQ-6 :hot_resource → :ephemeral)" do
    test "Ezagent.Entity.ExternalMirrorWorker.persistence/0 returns :ephemeral" do
      # Cross-check: OQ-6 + worker_contract_test.exs:34 both assert
      # this. Re-asserted here so the migration parity suite catches
      # an accidental flip from `:ephemeral` to `{:snapshot, _}`.
      assert Ezagent.Entity.ExternalMirrorWorker.persistence() == :ephemeral
    end
  end

  describe "BootReconciler framework-internal status (NOT a Behavior)" do
    test "BootReconciler is NOT migrated to use Ezagent.Behavior" do
      refute Ezagent.Behavior.new_style?(Ezagent.ExternalMirror.BootReconciler)
    end

    test "BootReconciler does not implement the Ezagent.Behavior contract" do
      refute function_exported?(Ezagent.ExternalMirror.BootReconciler, :actions, 0)
      refute function_exported?(Ezagent.ExternalMirror.BootReconciler, :state_slice, 0)
      refute function_exported?(Ezagent.ExternalMirror.BootReconciler, :handle_publish, 2)
    end
  end
end
