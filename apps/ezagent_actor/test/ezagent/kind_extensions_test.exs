defmodule Ezagent.KindExtensionsTest do
  @moduledoc """
  Tests for the new `use Ezagent.Kind, pattern: ...` macro per
  SPEC §2.3 + §3 composition patterns + OQ-2 / OQ-5
  compile-time enforcement.

  These tests cover the ADDITIVE new contract — the existing
  `@behaviour Ezagent.Kind` callback shape is untouched and its
  tests live in `kind_test.exs` (where present).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Kind

  # ---------------------------------------------------------------
  # Fixture Behaviors used by the Kind-attach tests
  # ---------------------------------------------------------------

  defmodule BehaviorA do
    @moduledoc false
    use Ezagent.ActionSet

    action(:a_action,
      args: %{},
      returns: :ok,
      caps: [:a]
    )

    def handle_a_action(_args, _ctx), do: {:ok, :ok, []}
  end

  defmodule BehaviorB do
    @moduledoc false
    use Ezagent.ActionSet

    action(:b_action,
      args: %{x: :integer},
      returns: %{y: :integer},
      caps: [:b]
    )

    def handle_b_action(_args, _ctx), do: {:ok, %{y: 0}, []}
  end

  defmodule BehaviorACollide do
    @moduledoc false
    use Ezagent.ActionSet

    # Same action name as BehaviorA — used to test OQ-5 collision
    # check at Kind-attach time.
    action(:a_action,
      args: %{},
      returns: :ok,
      caps: [:a]
    )

    def handle_a_action(_args, _ctx), do: {:ok, :ok, []}
  end

  defmodule SessionKind do
    @moduledoc false
    use Ezagent.Kind,
      pattern: :session,
      uri_scheme: "session://test/",
      type_name: :test_session

    attach(BehaviorA)
    attach(BehaviorB, actions: [:b_action])
  end

  defmodule EntityKind do
    @moduledoc false
    use Ezagent.Kind,
      pattern: :entity,
      uri_scheme: "entity://test_entity/",
      type_name: :test_entity

    attach(BehaviorA)
  end

  defmodule ColdResource do
    @moduledoc false
    use Ezagent.Kind,
      pattern: :resource,
      uri_scheme: "resource://test/",
      type_name: :test_cold_resource

    attach(BehaviorA)
  end

  defmodule HotResource do
    @moduledoc false
    use Ezagent.Kind,
      pattern: {:resource, :hot},
      uri_scheme: "resource://test_hot/",
      type_name: :test_hot_resource

    attach(BehaviorA)
  end

  describe "use Ezagent.Kind — pattern declaration" do
    test "__pattern__/0 returns :session for Session pattern" do
      assert SessionKind.__pattern__() == :session
    end

    test "__pattern__/0 returns :entity for Entity pattern" do
      assert EntityKind.__pattern__() == :entity
    end

    test "__pattern__/0 returns :resource for cold Resource pattern" do
      assert ColdResource.__pattern__() == :resource
    end

    test "__pattern__/0 returns {:resource, :hot} for hot Resource pattern" do
      assert HotResource.__pattern__() == {:resource, :hot}
    end

    test "__uri_scheme__/0 is not injected" do
      refute function_exported?(SessionKind, :__uri_scheme__, 0)
    end

    test "type_name/0 is injected when provided" do
      assert SessionKind.type_name() == :test_session
    end

    test "supervisor/0 defaults to nil when not provided" do
      # When `supervisor:` not passed to `use Ezagent.Kind`, the
      # function is NOT injected — falls through to the legacy
      # `function_exported?` check used by `Kind.spawn/2`.
      refute function_exported?(SessionKind, :supervisor, 0)
    end

    test "__kind__?/0 marker returns true" do
      assert SessionKind.__kind__?()
      assert EntityKind.__kind__?()
    end
  end

  describe "use Ezagent.Kind — validation" do
    test "missing :pattern raises ArgumentError" do
      assert_raise ArgumentError, ~r/requires :pattern/, fn ->
        Code.compile_string("""
        defmodule NoPattern do
          use Ezagent.Kind
        end
        """)
      end
    end

    test "unknown :pattern raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown :pattern/, fn ->
        Code.compile_string("""
        defmodule BadPattern do
          use Ezagent.Kind, pattern: :nonsense
        end
        """)
      end
    end
  end

  describe "attach + action collision (OQ-5)" do
    test "attaching two Behaviors with overlapping actions raises CompileError" do
      assert_raise CompileError, ~r/collision.*:a_action/s, fn ->
        Code.compile_string("""
        defmodule CollidingKind do
          use Ezagent.Kind, pattern: :entity, uri_scheme: "entity://x/"
          attach Ezagent.KindExtensionsTest.BehaviorA
          attach Ezagent.KindExtensionsTest.BehaviorACollide
        end
        """)
      end
    end

    test "attaching Behaviors with restricted :actions option avoids collision" do
      Code.compile_string("""
      defmodule RestrictedKind do
        use Ezagent.Kind, pattern: :entity, uri_scheme: "entity://r/"
        attach Ezagent.KindExtensionsTest.BehaviorA, actions: [:a_action]
        attach Ezagent.KindExtensionsTest.BehaviorACollide, actions: []
      end
      """)

      # Will only reach here if the above compiled without raising.
      assert Code.ensure_loaded?(RestrictedKind)
    end
  end

  describe "introspection helpers" do
    test "__attached__/0 lists every attached Behavior + opts" do
      attached = SessionKind.__attached__()
      modules = Enum.map(attached, fn {b, _} -> b end)
      assert BehaviorA in modules
      assert BehaviorB in modules
    end

    test "__action_to_behavior__/0 maps each action to its Behavior" do
      mapping = SessionKind.__action_to_behavior__()
      assert mapping[:a_action] == BehaviorA
      assert mapping[:b_action] == BehaviorB
    end

    # Phase 4 Item 3 (2026-05-28) — `__read_graph__/0` removed; the
    # Kind-level read-graph DSL was an unused planned path. Canonical
    # source for cross-Behavior read permissions is the per-Behavior
    # `reads_sibling_slices/0` callback (resolved via
    # `Ezagent.ActionSet.reads_sibling_slices_of/1`).

    test "Kind.new_style?/1 detects new-style Kinds" do
      assert Kind.new_style?(SessionKind)
      refute Kind.new_style?(Enum)
    end

    test "Kind.pattern_of/1 reads the pattern" do
      assert Kind.pattern_of(SessionKind) == :session
      assert Kind.pattern_of(HotResource) == {:resource, :hot}
      assert Kind.pattern_of(Enum) == nil
    end
  end

  # RF-3 — the Kind-level runtime `attach_behavior/2` API was RETIRED (no
  # runtime callers). Behaviors reach an instance per-instance (RF-1) and are
  # added/removed on a LIVE instance via `Ezagent.Kind.mount/2`/`detach/2`. The
  # COMPILE-TIME collision machinery (`attach/2` + `__before_compile__`) is
  # unchanged and still tested by the declaration-collision suites.
end
