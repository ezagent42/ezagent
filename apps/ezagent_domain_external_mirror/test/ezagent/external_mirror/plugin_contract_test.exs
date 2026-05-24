defmodule Ezagent.ExternalMirror.PluginContractTest do
  @moduledoc """
  Plugin contract integration tests (PR-EM-1 acceptance test 3 + 7).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.1 + §9 PR-EM-1.

  Pins:
  - A fixture plugin declaring valid `adapters/0` wires BOTH
    registries on `Ezagent.Plugin.boot/1`'s `publish` phase.
  - The Grill-5 runtime guard (`assert_adapter_decl!`) catches every
    failure mode the compiler gate catches — defense-in-depth for a
    hot-installed plugin that bypassed the build.
  - **Invariant test 7**: every `(adapter, binding)` pair landed in
    BOTH registries — cross-module integrity at boot. Catches a
    future refactor that registers ONE side but not the other.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

  setup do
    :ets.delete_all_objects(AdapterRegistry.table())
    :ets.delete_all_objects(BindingRegistry.table())
    :ok
  end

  describe "Ezagent.Plugin.boot/1 publishes adapters/0" do
    test "wires AdapterRegistry + BindingRegistry for a valid pair" do
      plugin = define_plugin("conforming_v1", [{MockAdapter, MockBinding}])

      assert {:ok, _sup_pid} = Ezagent.Plugin.boot(plugin)

      # AdapterRegistry: id → module
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")

      # BindingRegistry: id → binding_module (Grill-5 1:1 reverse-lookup)
      assert {:ok, MockBinding} = BindingRegistry.lookup("mock_em")
    end

    test "a plugin with no adapters/0 declaration leaves both registries empty" do
      plugin = define_plugin("empty_v1", [])

      assert {:ok, _sup_pid} = Ezagent.Plugin.boot(plugin)

      assert AdapterRegistry.list() == []
      assert BindingRegistry.list_all() == []
    end
  end

  describe "Ezagent.Plugin.boot/1 Grill-5 runtime defense-in-depth" do
    # The :ezagent_plugin_check compiler is the primary gate; runtime
    # `assert_adapter_decl!` is the backstop. These tests exercise the
    # runtime path directly.

    test "rejects a SINGLE module implementing both behaviours (Grill-5 e)" do
      # The Dual module isn't a real adapter — but the runtime guard
      # only needs to detect adapter == binding, so a raw module ref
      # suffices.
      dual = build_dual_module()
      plugin = define_plugin("dual_v1", [{dual, dual}])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "DIFFERENT modules"
      assert err.message =~ "Grill-5"
    end

    test "rejects a (adapter, binding) where adapter.binding_module() != binding (Grill-5 c)" do
      # MockAdapter says its binding_module/0 is MockBinding, but the
      # plugin pairs it with OtherBinding.
      alias Ezagent.ExternalMirror.TestSupport.OtherBinding

      plugin = define_plugin("mismatch_v1", [{MockAdapter, OtherBinding}])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "binding_module"
      assert err.message =~ "Grill-5"
    end

    test "rejects a non-tuple entry as malformed" do
      plugin = define_plugin("malformed_v1", [:not_a_tuple])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "malformed adapters/0 entry"
    end
  end

  # codex r2 HIGH-2 — rollback does NOT delete pre-existing rows.
  # The previous reduce-accumulator-lost-on-rescue bug had
  # `rollback_adapters!(decls)` re-walking every declaration and
  # deleting any row whose module matched. A boot that hit a later
  # failure could unregister rows other plugins (or earlier idempotent
  # registrations) had written. Receipts-driven rollback fixes it:
  # only rows whose receipt was `:ok` (this attempt's insert_new
  # returned true) get deleted.
  describe "codex r2 HIGH-2 — rollback preserves pre-existing rows" do
    test "second boot attempt that fails late does NOT delete row inserted by first boot" do
      # First boot — registers MockAdapter (insert_new returns true).
      plugin_a = define_plugin("preexist_a", [{MockAdapter, MockBinding}])
      assert {:ok, _} = Ezagent.Plugin.boot(plugin_a)
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")

      # Second boot — declares the SAME pair (idempotent re-register
      # returns `{:ok, :already_present}`), then a MALFORMED second
      # entry that triggers Phase 1 validation failure AFTER the
      # idempotent re-register. Wait — Phase 1 catches malformed
      # entries BEFORE any write, so a malformed entry won't reach
      # the rollback path.
      #
      # The real risk: Phase 2 succeeds for one pair then fails for
      # another (e.g. concurrent race detected at insert_new). To
      # simulate, declare TWO pairs where the second collides with
      # a DIFFERENT pre-registered adapter — the first pair's
      # idempotent re-register returns `{:already_present}` (no
      # rollback needed); the second pair's register raises (dup id
      # from different module).
      alias Ezagent.ExternalMirror.TestSupport.OtherAdapter
      alias Ezagent.ExternalMirror.TestSupport.OtherBinding

      # Pre-register OtherAdapter under a DIFFERENT id we'll cause
      # a collision against — actually OtherAdapter and MockAdapter
      # share id "mock_em", so trying to register OtherAdapter when
      # MockAdapter is present raises. That's our failing Phase 2.

      # Second-boot plugin: idempotent same pair + a colliding pair.
      plugin_b =
        define_plugin("preexist_b", [
          # Phase 2 step 1: idempotent re-register → `{:ok, :already_present}`
          {MockAdapter, MockBinding},
          # Phase 2 step 2: dup id from different module → raise.
          {OtherAdapter, OtherBinding}
        ])

      # Plugin B's boot must raise...
      assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin_b) end

      # ...AND the pre-existing row from plugin_a must survive
      # untouched (receipts-driven rollback ignored the
      # `:already_present` receipt).
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em"),
             "rollback over-deleted: MockAdapter row was inserted by " <>
               "plugin_a's earlier boot; plugin_b's failed boot must NOT " <>
               "delete it (codex r2 HIGH-2 regression)"

      assert {:ok, MockBinding} = BindingRegistry.lookup("mock_em")
    end

    test "successful boot leaves no receipts in process dictionary (cleanup)" do
      # Belt-and-suspenders: the receipts ref is process-local and
      # MUST be cleared by `after` so it can't leak across boots.
      keys_before = Process.get_keys()
      plugin = define_plugin("cleanup_v1", [{MockAdapter, MockBinding}])
      assert {:ok, _} = Ezagent.Plugin.boot(plugin)
      keys_after = Process.get_keys()

      em_receipts_keys =
        Enum.filter(keys_after -- keys_before, fn k ->
          match?({:em_pr1_receipts, _}, k)
        end)

      assert em_receipts_keys == [],
             "receipts leaked: #{inspect(em_receipts_keys)}"
    end
  end

  # codex r2 MEDIUM — registry rejects modules missing required
  # callbacks (Elixir's @behaviour is a compiler warning, not
  # runtime guarantee).
  describe "codex r2 MEDIUM — required-callback verification" do
    defmodule HalfBakedAdapter do
      # Declares @behaviour but only implements 2 of 4 callbacks.
      @behaviour Ezagent.ExternalMirror.Adapter

      @impl true
      def adapter_id, do: "half_baked"

      @impl true
      def binding_module, do: HalfBakedBinding
      # No display_name/0, no description/0.
    end

    defmodule HalfBakedBinding do
      @behaviour Ezagent.ExternalMirror.Binding
      # No adapter_module/0!
    end

    test "AdapterRegistry.register/1 rejects an adapter missing display_name/0 + description/0" do
      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(HalfBakedAdapter)
        end

      assert err.message =~ "display_name/0"
      assert err.message =~ "description/0"

      refute err.message =~ "adapter_id/0",
             "adapter_id/0 IS implemented — should not be in missing list"
    end

    test "BindingRegistry.register_module/2 rejects a binding missing adapter_module/0" do
      err =
        assert_raise ArgumentError, fn ->
          BindingRegistry.register_module("anything", HalfBakedBinding)
        end

      assert err.message =~ "adapter_module/0"
    end
  end

  # codex r1 HIGH-1 — multi-adapter boot rollback.
  # If a plugin declares MULTIPLE adapter pairs and a later one
  # fails validation or registration, NO earlier pair may remain
  # in either registry — boot is all-or-nothing. Previously
  # per-pair iteration left earlier pairs registered when a later
  # pair failed → `list_adapters/0` advertised an adapter whose
  # plugin boot never completed.
  describe "codex r1 HIGH-1 — multi-adapter boot rollback" do
    test "intra-batch duplicate adapter_id is rejected BEFORE any write" do
      # Two pairs claiming the same adapter_id — caught in Phase 1
      # validation; no registry writes happen.
      plugin =
        define_plugin("rollback_intra_dup", [
          {MockAdapter, MockBinding},
          # Re-use MockAdapter — same adapter_id "mock_em".
          {MockAdapter, MockBinding}
        ])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "two entries with the same adapter_id"

      # Both registries must be empty (nothing was written).
      assert AdapterRegistry.list() == []
      assert BindingRegistry.list_all() == []
    end

    test "early malformed entry → no later writes happen" do
      # First entry is malformed (not a tuple); Phase 1 validation
      # raises before reaching Phase 2 writes. No partial state.
      plugin =
        define_plugin("rollback_early_fail", [
          :malformed_entry,
          {MockAdapter, MockBinding}
        ])

      assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end

      assert AdapterRegistry.list() == []
      assert BindingRegistry.list_all() == []
    end
  end

  # codex r1 HIGH-2 — atomic registration prevents silent overwrite.
  # `:ets.insert_new/2` makes register/register_module atomic — a
  # concurrent attempt to register the same `adapter_id` from a
  # different module fails loudly with an `ArgumentError`, never
  # silently overwrites.
  describe "codex r1 HIGH-2 — atomic registration prevents silent overwrite" do
    test "concurrent same-module register/1 from many tasks: idempotent (no race-induced raise)" do
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> AdapterRegistry.register(MockAdapter) end)
        end

      results = Task.await_many(tasks, 5_000)

      # Exactly ONE task's `insert_new/2` returns true → `:ok`. The
      # other 19 see the row already exists for the SAME module →
      # `{:ok, :already_present}`. No raises (would mean a different
      # module won and ours lost — but every task uses MockAdapter).
      # codex r2 HIGH-2 distinguished return shape.
      ok_count = Enum.count(results, &(&1 == :ok))
      already_count = Enum.count(results, &(&1 == {:ok, :already_present}))

      assert ok_count == 1,
             "exactly one task should win the atomic insert; got " <>
               "#{ok_count} :ok / #{already_count} {:ok, :already_present} " <>
               "/ raw: #{inspect(results)}"

      assert already_count == 19

      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")
    end

    test "concurrent DIFFERENT modules sharing adapter_id: exactly one wins; rest raise" do
      alias Ezagent.ExternalMirror.TestSupport.OtherAdapter

      # MockAdapter and OtherAdapter both claim adapter_id "mock_em".
      # Atomic insert_new means exactly ONE distinct module lands;
      # tasks for the other module raise. Previously the
      # lookup-then-insert race let the loser silently overwrite the
      # winner.
      tasks =
        for i <- 1..40 do
          mod = if rem(i, 2) == 0, do: MockAdapter, else: OtherAdapter

          Task.async(fn ->
            try do
              AdapterRegistry.register(mod)
              :ok
            rescue
              ArgumentError -> :dup_raised
            end
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # At least one task succeeded; at least one raised (the loser's
      # module attempts must have hit the atomic guard).
      assert :ok in results
      assert :dup_raised in results

      # The winner is one of the two modules — never absent (no
      # silent overwrite leaving the table empty).
      {:ok, winner} = AdapterRegistry.lookup("mock_em")
      assert winner in [MockAdapter, OtherAdapter]
    end
  end

  # codex r1 MEDIUM-1 — direct-call defense in depth.
  # Even bypassing `Ezagent.Plugin.boot/1`, a direct call to
  # `AdapterRegistry.register/1` or
  # `BindingRegistry.register_module/2` must reject modules that
  # don't implement the relevant `@behaviour`. Belt-and-suspenders
  # with the source-scan compiler gate.
  describe "codex r1 MEDIUM-1 — direct-call defense in depth" do
    defmodule NotAnAdapter do
      def adapter_id, do: "not_real"
    end

    defmodule NotABinding do
      def adapter_module, do: nil
    end

    test "AdapterRegistry.register/1 rejects a module without @behaviour Adapter" do
      err =
        assert_raise ArgumentError, fn ->
          AdapterRegistry.register(NotAnAdapter)
        end

      assert err.message =~ "@behaviour Ezagent.ExternalMirror.Adapter"
    end

    test "BindingRegistry.register_module/2 rejects a module without @behaviour Binding" do
      err =
        assert_raise ArgumentError, fn ->
          BindingRegistry.register_module("anything", NotABinding)
        end

      assert err.message =~ "@behaviour Ezagent.ExternalMirror.Binding"
    end
  end

  describe "invariant 7: cross-module integrity at boot" do
    test "every adapter registered also has its paired binding registered" do
      # The invariant: post-boot, for every entry in AdapterRegistry,
      # BindingRegistry must contain a matching adapter_id key. Catches
      # a future refactor that registers ONE side but not the other.
      plugin = define_plugin("integrity_v1", [{MockAdapter, MockBinding}])

      assert {:ok, _} = Ezagent.Plugin.boot(plugin)

      adapter_ids =
        AdapterRegistry.list()
        |> Enum.map(& &1.id)
        |> MapSet.new()

      binding_ids =
        BindingRegistry.list_all()
        |> Enum.map(fn {id, _mod} -> id end)
        |> MapSet.new()

      assert MapSet.equal?(adapter_ids, binding_ids),
             "adapter_ids #{inspect(adapter_ids)} != binding_ids #{inspect(binding_ids)} — " <>
               "boot wiring registered ONE side but not the other (Grill-5 violation)"
    end
  end

  # --- helpers ------------------------------------------------------

  # Build a throwaway `use Ezagent.Plugin` module that declares the
  # given `adapters/0` payload. Same pattern as plugin_registry_test.
  defp define_plugin(slug, adapters_payload) do
    module = String.to_atom("Elixir.Ezagent.ExternalMirror.PluginContractTest.Plugin_#{slug}")

    Module.create(
      module,
      quote do
        use Ezagent.Plugin

        @impl true
        def plugin_info do
          %{
            slug: unquote(slug),
            name: "P-#{unquote(slug)}",
            description: "test fixture plugin",
            version: "0.1.0"
          }
        end

        @impl true
        def adapters, do: unquote(Macro.escape(adapters_payload))
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  # Build a one-off module that implements BOTH Adapter and Binding
  # behaviours — for the Grill-5 (e) runtime-defense test.
  defp build_dual_module do
    name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.PluginContractTest.Dual_#{System.unique_integer([:positive])}"
      )

    Module.create(
      name,
      quote do
        @behaviour Ezagent.ExternalMirror.Adapter
        @behaviour Ezagent.ExternalMirror.Binding

        @impl Ezagent.ExternalMirror.Adapter
        def adapter_id, do: "dual"

        @impl Ezagent.ExternalMirror.Adapter
        def display_name, do: "Dual"

        @impl Ezagent.ExternalMirror.Adapter
        def description, do: "illegal"

        @impl Ezagent.ExternalMirror.Adapter
        def binding_module, do: __MODULE__

        @impl Ezagent.ExternalMirror.Binding
        def adapter_module, do: __MODULE__
      end,
      Macro.Env.location(__ENV__)
    )

    name
  end
end
