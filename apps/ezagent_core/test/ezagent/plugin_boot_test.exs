defmodule Ezagent.Plugin.BootTest do
  @moduledoc """
  Tests for `Ezagent.Plugin.boot/1` — the two-phase declarative boot
  (SPEC §5, verification §9 items 3 + 5).

  Each test defines its own throwaway plugin module (a correct
  `use Ezagent.Plugin` module with the declarations the test needs) so
  the cases stay independent.
  """

  use ExUnit.Case, async: false

  # A GenServer used as a Phase-1 child. On `init` it records, via the
  # message it sends to the test process, whether the plugin's declared
  # Behavior is ALREADY published in BehaviorRegistry. If boot is
  # correctly two-phase, the child starts in Phase 1 *before* the
  # Phase-2 publish — so at child-init time the registry entry must be
  # absent (codex HIGH-2).
  defmodule ProbeChild do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      kind = Keyword.fetch!(opts, :probe_kind)
      action = Keyword.fetch!(opts, :probe_action)

      registry_state_at_child_init = Ezagent.BehaviorRegistry.lookup(kind, action)
      send(test_pid, {:child_init, self(), registry_state_at_child_init})

      {:ok, %{}}
    end
  end

  describe "boot/1 — happy path (SPEC §5)" do
    test "returns the Phase-1 supervisor's {:ok, pid}" do
      defmodule MinimalPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-min", name: "Boot Min", description: "d", version: "1.0.0"}
      end

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(MinimalPlugin)
      assert is_pid(sup_pid)
      assert Process.alive?(sup_pid)
      assert Supervisor.which_children(sup_pid) == []

      Supervisor.stop(sup_pid)
    end

    test "self-registers into PluginRegistry during Phase 2" do
      defmodule SelfRegPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-selfreg", name: "SelfReg", description: "d", version: "1.0.0"}
      end

      refute Enum.member?(Ezagent.PluginRegistry.list_all(), SelfRegPlugin)

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(SelfRegPlugin)

      assert Enum.member?(Ezagent.PluginRegistry.list_all(), SelfRegPlugin)
      assert %{slug: "boot-selfreg"} = Ezagent.PluginRegistry.info("boot-selfreg")

      Supervisor.stop(sup_pid)
    end

    test "publishes behaviors, template classes and agent flavors" do
      kind = Ezagent.Plugin.BootTest.Kind1
      behavior = Ezagent.Plugin.BootTest.Behavior1
      template_class = Ezagent.Plugin.BootTest.TemplateClass1
      tname = "boot-tc-#{System.unique_integer([:positive])}"

      Module.create(
        template_class,
        quote do
          @behaviour Ezagent.Kind.Template
          @impl true
          def template_name, do: unquote(tname)
          @impl true
          def validate(_), do: :ok
          @impl true
          def instantiate(_, _, _), do: {:ok, []}
        end,
        Macro.Env.location(__ENV__)
      )

      defmodule PublishingPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-publish", name: "Publish", description: "d", version: "1.0.0"}

        @impl true
        def behaviors,
          do: [
            {Ezagent.Plugin.BootTest.Kind1, :do_thing, Ezagent.Plugin.BootTest.Behavior1}
          ]

        @impl true
        def template_classes, do: [Ezagent.Plugin.BootTest.TemplateClass1]

        @impl true
        def agent_flavors,
          do: [
            %{
              flavor: "boot-flavor-x",
              kind: Ezagent.Plugin.BootTest.Kind1,
              template_class: Ezagent.Plugin.BootTest.TemplateClass1
            }
          ]
      end

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(PublishingPlugin)

      assert {:ok, ^behavior} = Ezagent.BehaviorRegistry.lookup(kind, :do_thing)
      assert {:ok, ^template_class} = Ezagent.TemplateRegistry.lookup(tname)

      assert {:ok, %{kind: ^kind, template_class: ^template_class}} =
               Ezagent.AgentFlavorRegistry.lookup("boot-flavor-x")

      Supervisor.stop(sup_pid)
    end

    test "calls after_boot/0 in Phase 3" do
      test_pid = self()
      ref = make_ref()
      Process.put({:after_boot_ref, __MODULE__}, {test_pid, ref})

      defmodule AfterBootPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-after", name: "After", description: "d", version: "1.0.0"}

        @impl true
        def after_boot do
          {test_pid, ref} = Process.get({:after_boot_ref, Ezagent.Plugin.BootTest})
          send(test_pid, {:after_boot_ran, ref})
          :ok
        end
      end

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(AfterBootPlugin)
      assert_received {:after_boot_ran, ^ref}

      Supervisor.stop(sup_pid)
    end
  end

  describe "boot/1 — two-phase ordering: children BEFORE publish (codex HIGH-2)" do
    test "a Phase-1 child observes the registry is NOT yet populated at its init" do
      test_pid = self()
      probe_kind = Ezagent.Plugin.BootTest.OrderKind
      probe_action = :ordered_action
      probe_behavior = Ezagent.Plugin.BootTest.OrderBehavior

      defmodule OrderingPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-order", name: "Order", description: "d", version: "1.0.0"}

        @impl true
        def children do
          [
            {Ezagent.Plugin.BootTest.ProbeChild,
             test_pid: Process.get({:ordering_test_pid, Ezagent.Plugin.BootTest}),
             probe_kind: Ezagent.Plugin.BootTest.OrderKind,
             probe_action: :ordered_action}
          ]
        end

        @impl true
        def behaviors do
          [
            {Ezagent.Plugin.BootTest.OrderKind, :ordered_action,
             Ezagent.Plugin.BootTest.OrderBehavior}
          ]
        end
      end

      Process.put({:ordering_test_pid, __MODULE__}, test_pid)

      # Sanity: the registry entry is absent before boot.
      assert :error = Ezagent.BehaviorRegistry.lookup(probe_kind, probe_action)

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(OrderingPlugin)

      # The child sent its observation FROM INSIDE `init`, which runs in
      # Phase 1. If boot were single-phase (publish-then-children, the
      # rev-1 bug) this would be `{:ok, _}`. Two-phase boot guarantees
      # `:error` — the publish had not happened yet.
      assert_received {:child_init, _child_pid, registry_at_init}
      assert registry_at_init == :error,
             "expected the Behavior to be UNPUBLISHED when the Phase-1 child " <>
               "started — children must boot before Phase-2 publish (SPEC §5)"

      # And after boot completes, Phase 2 HAS published it.
      assert {:ok, ^probe_behavior} =
               Ezagent.BehaviorRegistry.lookup(probe_kind, probe_action)

      Supervisor.stop(sup_pid)
    end
  end

  describe "boot/1 — non-core spawn scheme rejected (codex HIGH-4 / verification §9 item 3)" do
    test "a spawns/0 scheme outside the six core schemes raises" do
      defmodule BadSchemePlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-badscheme", name: "BadScheme", description: "d", version: "1.0.0"}

        @impl true
        def spawns do
          [{"slack", fn _uri -> {:ok, self()} end}]
        end
      end

      err =
        assert_raise ArgumentError, fn ->
          Ezagent.Plugin.boot(BadSchemePlugin)
        end

      assert err.message =~ "slack"
      assert err.message =~ "core schemes"
    end

    test "a core spawns/0 scheme is accepted" do
      # `resource` is a core scheme; capture + restore its spawn fn so
      # this test does not clobber shared SpawnRegistry state for the
      # rest of the (async: false) suite.
      original =
        case :ets.lookup(Ezagent.SpawnRegistry.table(), "resource") do
          [{"resource", fun}] -> {:fun, fun}
          [] -> :none
        end

      on_exit(fn ->
        case original do
          {:fun, fun} -> :ets.insert(Ezagent.SpawnRegistry.table(), {"resource", fun})
          :none -> :ets.delete(Ezagent.SpawnRegistry.table(), "resource")
        end
      end)

      defmodule GoodSchemePlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-goodscheme", name: "GoodScheme", description: "d", version: "1.0.0"}

        @impl true
        def spawns do
          [{"resource", fn _uri -> {:ok, self()} end}]
        end
      end

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(GoodSchemePlugin)
      assert "resource" in Ezagent.SpawnRegistry.registered_schemes()

      Supervisor.stop(sup_pid)
    end
  end
end
