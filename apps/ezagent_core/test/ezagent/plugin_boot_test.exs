defmodule Ezagent.Plugin.BootTest do
  @moduledoc """
  Tests for `Ezagent.Plugin.boot/1` — the two-phase declarative boot
  (SPEC §5, verification §9 items 3 + 5).

  Each test defines its own throwaway plugin module (a correct
  `use Ezagent.Plugin` module with the declarations the test needs) so
  the cases stay independent.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

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

      # PR-5 MEDIUM-4: `boot/1` now behaviour-checks every
      # `agent_flavors/0` entry — `kind` must @behaviour Ezagent.Kind
      # and `behavior` must @behaviour Ezagent.Behavior. Create real
      # minimal modules (these registrations land in the global
      # *Registry ETS tables — see the on_exit cleanup below).
      Module.create(
        kind,
        quote do
          @behaviour Ezagent.Kind
          @impl true
          def type_name, do: :boot_test_kind1
          @impl true
          def behaviors, do: []
          @impl true
          def persistence, do: :ephemeral
        end,
        Macro.Env.location(__ENV__)
      )

      # `Behavior1` is a real Ezagent.Behavior — including `interface/0`
      # — so anything that enumerates BehaviorRegistry (e.g. the CLI
      # TreeBuilder) never crashes on it even before the on_exit
      # cleanup runs.
      Module.create(
        behavior,
        quote do
          @behaviour Ezagent.Behavior
          @impl true
          def actions, do: [:do_thing]
          @impl true
          def cap_subjects, do: [{:do_thing, "test fixture"}]
          @impl true
          def state_slice, do: :boot_test
          @impl true
          def init_slice(_args), do: %{}
          @impl true
          def invoke(:do_thing, slice, _args, _ctx), do: {:ok, slice, %{}}
          @impl true
          def interface,
            do: %{do_thing: %{args: %{}, returns: %{}, modes: [:cast]}}
        end,
        Macro.Env.location(__ENV__)
      )

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

      # `boot/1`'s Phase-2 publish writes to the global BehaviorRegistry
      # / TemplateRegistry / AgentFlavorRegistry ETS tables — shared
      # process-wide state. Clean them up so this test's throwaway
      # modules do not leak into other suites (the CLI TreeBuilder
      # enumerates BehaviorRegistry; a stale fake entry would crash it).
      on_exit(fn ->
        :ets.delete(Ezagent.BehaviorRegistry.table(), {kind, :do_thing})
        :ets.delete(Ezagent.TemplateRegistry.table(), tname)
        :ets.delete(Ezagent.AgentFlavorRegistry.table(), "boot-flavor-x")
      end)

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

  # Inline fixture modules for the two-phase ordering test. Previously
  # referenced as bare atoms — worked because BehaviorRegistry.register/3
  # was a raw ETS insert that didn't load the module. After
  # CapabilityRegistry migration (SPEC 2026-05-23-capability-registry §3.2)
  # register/3 calls `behavior.cap_subjects/0`, so the module must exist.
  defmodule OrderKind do
    def type_name, do: :order_kind_test
  end

  defmodule OrderBehavior do
    @behaviour Ezagent.Behavior
    def actions, do: [:ordered_action]
    def cap_subjects, do: [{:ordered_action, "test fixture — ordering probe"}]
    def state_slice, do: :order_test
    def init_slice(_), do: %{}
    def invoke(_, slice, _, _), do: {:ok, slice}
    def interface, do: %{}
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

  describe "boot/1 — any spawns/0 declaration rejected (codex PR-5 HIGH-1)" do
    # PR-5 HIGH-1 supersedes the old "non-core scheme rejected / core
    # scheme accepted" pair. `SpawnRegistry.register/2` is scheme-keyed
    # and OVERWRITES — so even a CORE scheme spawn declared by a plugin
    # hijacks that scheme's dispatcher (invariant 8). A plugin owns NO
    # scheme; therefore ANY non-empty `spawns/0` is a hard error.

    test "a spawns/0 declaring a non-core scheme raises" do
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

      assert err.message =~ "spawns/0"
      assert err.message =~ "may NOT register a scheme-level spawn"
    end

    test "a spawns/0 declaring a CORE scheme is ALSO rejected (the HIGH-1 hole)" do
      # This is the exact hole codex found: `{"entity", fun}` passed the
      # old @core_schemes allowlist, then OVERWROTE the entity://
      # dispatcher. It must now hard-fail.
      defmodule CoreSchemeHijackPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-hijack", name: "Hijack", description: "d", version: "1.0.0"}

        @impl true
        def spawns do
          [{"entity", fn _uri -> {:ok, self()} end}]
        end
      end

      # Capture whatever spawn fn (if any) the "entity" scheme had
      # before — the standalone ezagent_core test may have none.
      entity_before = :ets.lookup(Ezagent.SpawnRegistry.table(), "entity")

      err =
        assert_raise ArgumentError, fn ->
          Ezagent.Plugin.boot(CoreSchemeHijackPlugin)
        end

      assert err.message =~ "spawns/0"
      assert err.message =~ "hijack"

      # The plugin's spawn fn never reached SpawnRegistry — the "entity"
      # scheme entry is byte-for-byte unchanged (not clobbered). `boot/1`
      # rejects spawns/0 in `reject_spawns!` BEFORE any `publish/1` work.
      assert :ets.lookup(Ezagent.SpawnRegistry.table(), "entity") == entity_before
    end

    test "a plugin with the default empty spawns/0 boots fine" do
      defmodule NoSpawnPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-nospawn", name: "NoSpawn", description: "d", version: "1.0.0"}
      end

      assert NoSpawnPlugin.spawns() == []
      assert {:ok, sup_pid} = Ezagent.Plugin.boot(NoSpawnPlugin)
      Supervisor.stop(sup_pid)
    end
  end

  describe "boot/1 — config_surface/0 validation (codex PR-5 MEDIUM-5)" do
    test "a :form config_surface/0 is rejected" do
      defmodule FormSurfacePlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-form", name: "Form", description: "d", version: "1.0.0"}

        @impl true
        def config_surface, do: %{kind: :form, fields: []}
      end

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(FormSurfacePlugin) end
      assert err.message =~ ":form"
      assert err.message =~ "V2" or err.message =~ "V1"
    end

    test "a malformed config_surface/0 is rejected" do
      defmodule BadSurfacePlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-badsurface", name: "BadSurface", description: "d", version: "1.0.0"}

        @impl true
        def config_surface, do: %{kind: :route}
      end

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(BadSurfacePlugin) end
      assert err.message =~ "config_surface/0"
    end

    test "a valid :route config_surface/0 boots fine" do
      defmodule RouteSurfacePlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-route", name: "Route", description: "d", version: "1.0.0"}

        @impl true
        def config_surface, do: %{kind: :route, path: "/x", label: "X"}
      end

      assert {:ok, sup_pid} = Ezagent.Plugin.boot(RouteSurfacePlugin)
      Supervisor.stop(sup_pid)
    end
  end

  describe "boot/1 — agent_flavors/0 behaviour validation (codex PR-5 MEDIUM-4)" do
    test "an agent flavor whose kind is not an Ezagent.Kind raises" do
      # NotAKind is a plain module — does not @behaviour Ezagent.Kind.
      defmodule NotAKind do
        def hello, do: :world
      end

      template_class = Ezagent.Plugin.BootTest.MedTC

      Module.create(
        template_class,
        quote do
          @behaviour Ezagent.Kind.Template
          @impl true
          def template_name, do: "med-tc-#{System.unique_integer([:positive])}"
          @impl true
          def validate(_), do: :ok
          @impl true
          def instantiate(_, _, _), do: {:ok, []}
        end,
        Macro.Env.location(__ENV__)
      )

      defmodule BadFlavorKindPlugin do
        use Ezagent.Plugin
        @impl true
        def plugin_info,
          do: %{slug: "boot-badflavor", name: "BadFlavor", description: "d", version: "1.0.0"}

        @impl true
        def agent_flavors do
          [
            %{
              flavor: "badkind",
              kind: Ezagent.Plugin.BootTest.NotAKind,
              template_class: Ezagent.Plugin.BootTest.MedTC
            }
          ]
        end
      end

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(BadFlavorKindPlugin) end
      assert err.message =~ "Ezagent.Kind"
    end
  end
end
