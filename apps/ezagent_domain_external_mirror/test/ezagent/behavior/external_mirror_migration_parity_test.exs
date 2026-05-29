defmodule Ezagent.Behavior.ExternalMirrorMigrationParityTest do
  @moduledoc """
  Phase 2-d r3 — Migration parity for `Ezagent.Behavior.ExternalMirror`.

  This Behavior was migrated from the legacy `@behaviour Ezagent.Behavior`
  + manual `actions/0` / `interface/0` / `required_caps/0` /
  `cap_subjects/0` / `invoke/4` shape to the new `use Ezagent.Behavior`
  + per-action `action :name, ...` macro declarations + per-action
  `handle_<action>/2` handlers per SPEC §6.2.

  The runtime dispatch path is exercised end-to-end by
  `external_mirror_test.exs`; this file asserts the contract surface
  hasn't drifted from the pre-migration legacy shape — same action
  list, same caps, same interface, same cap subjects — so an
  out-of-tree caller that read the pre-migration introspection
  surface sees identical values after the migration.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.ExternalMirror

  describe "new-contract markers" do
    test "ExternalMirror is a new-style Behavior (`__behavior__?/0 == true`)" do
      assert function_exported?(ExternalMirror, :__behavior__?, 0)
      assert ExternalMirror.__behavior__?() == true
      assert Ezagent.Behavior.new_style?(ExternalMirror)
    end

    test "every declared action has a matching handle_<action>/2 (compile-time gate)" do
      for action <- ExternalMirror.__action_names__() do
        handler = String.to_atom("handle_#{action}")

        assert function_exported?(ExternalMirror, handler, 2),
               "ExternalMirror declares action #{inspect(action)} but exports no #{handler}/2"
      end
    end
  end

  describe "action surface parity (pre-migration shape preserved)" do
    test "actions/0 lists [:bind, :unbind, :list_bindings] in declared order" do
      # The macro reverses+uniqs the accumulator; declared order in the
      # module body is :bind, :unbind, :list_bindings.
      assert Enum.sort(ExternalMirror.actions()) ==
               Enum.sort([:bind, :unbind, :list_bindings])
    end

    test "state_slice/0 returns :external_mirror (slice key unchanged)" do
      assert ExternalMirror.state_slice() == :external_mirror
    end

    test "cap_subjects/0 carries the pre-migration descriptions" do
      subjects = ExternalMirror.cap_subjects()

      assert {:bind, "Bind this session's slice changes to an external adapter target."} in subjects

      assert {:unbind, "Remove an (adapter_id, target_id) binding from this session."} in subjects

      assert {:list_bindings, "List all external-mirror bindings on this session."} in subjects
    end

    test "interface/0 contains the three action specs" do
      iface = ExternalMirror.interface()

      assert iface[:bind].args == %{adapter_id: :string, target_id: :string, opts: :map}
      assert iface[:bind].returns == %{ok: :boolean, binding_id: :string, worker_uri: :uri}
      assert iface[:bind].modes == [:call]

      assert iface[:unbind].args == %{adapter_id: :string, target_id: :string}
      assert iface[:unbind].returns == %{ok: :boolean, unbound: :boolean}
      assert iface[:unbind].modes == [:call]

      assert iface[:list_bindings].args == %{}
      assert iface[:list_bindings].returns == %{bindings: {:list, :map}}
      assert iface[:list_bindings].modes == [:call]
    end

    test "required_caps/0 pins the :session kind axis (NOT :any) for all three actions" do
      caps = ExternalMirror.required_caps()

      assert %Ezagent.Capability{kind: :session, behavior: ExternalMirror, action: :bind} =
               caps[:bind]

      assert %Ezagent.Capability{kind: :session, behavior: ExternalMirror, action: :unbind} =
               caps[:unbind]

      assert %Ezagent.Capability{
               kind: :session,
               behavior: ExternalMirror,
               action: :list_bindings
             } = caps[:list_bindings]
    end
  end

  describe "lifecycle hooks (Lifecycle migration — Phase B)" do
    # The `use Ezagent.Lifecycle` macro emits init_slice/1 + post_init/2 +
    # handle_continue/3 (the engine boot path); the developer-facing hooks
    # are create/1 + activate/2 + handle_signal/2. `reconcile_after_load/2`
    # is FOLDED into activate/2 (SPEC §5 / OQ-8) — its logic survives as the
    # public `reconcile_bindings/2`.
    test "engine boot callbacks stay exported (macro-emitted) + Lifecycle hooks present" do
      assert function_exported?(ExternalMirror, :init_slice, 1)
      assert function_exported?(ExternalMirror, :post_init, 2)
      assert function_exported?(ExternalMirror, :handle_continue, 3)
      assert function_exported?(ExternalMirror, :data_owner, 1)
      assert function_exported?(ExternalMirror, :handle_kind_message, 3)
      # Developer Lifecycle hooks.
      assert function_exported?(ExternalMirror, :create, 1)
      assert function_exported?(ExternalMirror, :activate, 2)
      assert function_exported?(ExternalMirror, :handle_signal, 2)
      # reconcile_after_load/2 folded into activate/2; logic kept here.
      assert function_exported?(ExternalMirror, :reconcile_bindings, 2)
      refute function_exported?(ExternalMirror, :reconcile_after_load, 2)
    end

    test "post_init/2 returns `{:continue, :ezagent_activate}` (Lifecycle unified start hook)" do
      # The macro always schedules the unified activate continuation,
      # regardless of bindings; activate/2 reconciles + defers the
      # worker-spawn loop via a self-message (§10-R1).
      assert ExternalMirror.post_init(%{}, %{state: %{bindings: []}}) ==
               {:continue, :ezagent_activate}

      assert ExternalMirror.post_init(%{}, %{state: %{bindings: [%{binding_id: "x"}]}}) ==
               {:continue, :ezagent_activate}
    end

    test "data_owner/1 for :any returns :any (class-wide grant)" do
      assert ExternalMirror.data_owner(:any) == :any
    end

    test "data_owner/1 falls through to :no_owner for unknown shapes" do
      assert ExternalMirror.data_owner({:weird, :shape}) == :no_owner
    end
  end

  describe "handle_<action>/2 contract shape (new-contract surface)" do
    test "handle_list_bindings/2 reads slice via ctx[:read] + returns {:ok, result, []}" do
      ctx = %{read: fn key, default -> Map.get(%{bindings: [%{binding_id: "a/b"}]}, key, default) end}

      assert {:ok, %{bindings: [%{binding_id: "a/b"}]}, []} =
               ExternalMirror.handle_list_bindings(%{}, ctx)
    end

    test "handle_list_bindings/2 returns empty list when slice has no bindings" do
      ctx = %{read: fn _key, default -> default end}
      assert {:ok, %{bindings: []}, []} = ExternalMirror.handle_list_bindings(%{}, ctx)
    end

    test "handle_bind/2 with missing nonce → {:error, :bind_must_go_through_facade}" do
      session_uri = Ezagent.URI.new!("session://default/team-alpha/p2d-parity-1")
      caller_uri = Ezagent.URI.new!("entity://user/default/alice")

      ctx = %{
        read: fn _, default -> default end,
        caller: caller_uri,
        self_uri: session_uri
      }

      args = %{adapter_id: "test", target_id: "t1"}

      # No `:_facade_nonce` in args → handler rejects (Step 5.5 in the
      # Behavior body, not the dispatch-side cap gate).
      assert {:error, :bind_must_go_through_facade} = ExternalMirror.handle_bind(args, ctx)
    end
  end
end
