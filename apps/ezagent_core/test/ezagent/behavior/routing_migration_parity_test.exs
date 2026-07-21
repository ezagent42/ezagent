defmodule Ezagent.ActionSet.RoutingMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.ActionSet.Routing` per
  SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3 Level 1
  (dispatch parity).

  Validates that the migrated `Ezagent.ActionSet.Routing` produces the
  same dispatch-visible outcomes via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_<action>/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration
  across its four actions:

    - `:add_rule`     — RuleStore.add + load_into_registry + counter bump
    - `:delete_rule`  — RuleStore.delete + load_into_registry + counter bump
    - `:disable_rule` — RuleStore.disable + load_into_registry + counter bump
    - `:enable_rule`  — RuleStore.enable + load_into_registry + counter bump

  ## Codex r3 P2-g coverage — full dispatch path

  The `:add_rule` dispatch-path test exercises the whole pipeline
  (`Invocation → BehaviorRegistry → CapBAC → handler → effects →
  state writeback`). The other three actions get focused
  handler-level tests because their dispatch path is identical (same
  Kind, same cap shape, same effect grammar) and the integration
  cost is borne already by `:add_rule`.

  ## Why a `system://routing/default` dispatch target

  The handler reads `ctx.self_uri` to derive workspace_uri for the
  RuleStore opts; we use `system://routing/default` (the global
  routing scope) so the workspace_uri stays unset and the cap axis
  resolves cleanly without needing a Workspace/Session ancestor.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Capability, Invocation}
  alias Ezagent.ActionSet.Routing
  alias Ezagent.Routing.RuleStore
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  # MentionRouting is a real RoutingRegistry table declared by the
  # chat plugin's boot path; using it here exercises the full
  # RuleStore.add → load_into_registry pipeline without needing
  # custom table-declaration boilerplate.
  @table MentionRouting

  # Long-lived owner for the @table ETS table. When the chat plugin
  # is booted (umbrella-wide test run), the plugin's Application owns
  # the table and this owner is a no-op (declare_table is a no-op for
  # an already-declared table by the same owner; the rescue handles
  # the other-owner case). When the chat plugin is NOT booted
  # (scoped `mix test apps/ezagent_core/...` run) the test process
  # would die between tests and take the ETS table with it; this
  # supervised process keeps the table alive across the whole suite.
  defmodule TableOwner do
    @moduledoc false
    use GenServer

    def start_link(table) do
      GenServer.start_link(__MODULE__, table)
    end

    @impl true
    def init(table) do
      try do
        Ezagent.RoutingRegistry.declare_table(table)
      rescue
        ArgumentError ->
          # Already declared by another owner (chat plugin booted) —
          # nothing more to do; the chat plugin owns the table for
          # this suite's lifetime.
          :ok
      end

      {:ok, table}
    end
  end

  setup_all do
    {:ok, _pid} = start_supervised({TableOwner, @table})
    :ok
  end

  defmodule StubRoutingKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :routing_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Routing]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubRoutingKind, :add_rule, Routing)
    :ok = BehaviorRegistry.register(StubRoutingKind, :delete_rule, Routing)
    :ok = BehaviorRegistry.register(StubRoutingKind, :disable_rule, Routing)
    :ok = BehaviorRegistry.register(StubRoutingKind, :enable_rule, Routing)

    self_uri = Ezagent.URI.new!("system://routing/default")
    _authority = install_test_authority!(self_uri, StubRoutingKind.type_name())
    admin_caps = :target_signed
    state = %{routing: %{calls: 0}}

    {:ok, self_uri: self_uri, admin_caps: admin_caps, state: state}
  end

  defp build_invocation(self_uri, action, args, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(self_uri)}?action=routing.#{action}")

    presenter = Ezagent.URI.user(:system, :admin)
    authority = Process.get({Ezagent.Cap.Authority, :current})

    requested =
      Capability.cap(
        StubRoutingKind.type_name(),
        Routing,
        action,
        self_uri,
        Capability.workspace_of(self_uri)
      )

    signed = authority_signed_cap!(authority, presenter, requested)
    assert caps == :target_signed

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new([signed]),
        reply: :sync
      }
    }
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.ActionSet.new_style?(Routing)
    end

    test "__action_names__/0 lists all four actions" do
      assert Enum.sort(Routing.__action_names__()) ==
               [:add_rule, :delete_rule, :disable_rule, :enable_rule]
    end

    test "every action has a handler exported" do
      for action <- [:add_rule, :delete_rule, :disable_rule, :enable_rule] do
        handler = String.to_atom("handle_#{action}")

        assert function_exported?(Routing, handler, 2),
               "missing handler #{handler}/2 for action :#{action}"
      end
    end
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test ":add_rule via Kind.Runtime.handle_dispatch/4 — full dispatch path",
         %{self_uri: self_uri, admin_caps: admin_caps, state: state} do
      # FULL dispatch-path coverage (codex r3 P2-g). Exercises:
      #   - BehaviorRegistry lookup
      #   - CapBAC (admin caps satisfy the :any/:add_rule gate)
      #   - handle_add_rule/2 invocation
      #   - RuleStore.add + load_into_registry (real DB writes via
      #     DataCase sandbox)
      #   - {:set, :calls, prev+1} effect application
      table = @table

      matcher_json = %{"type" => "always"}
      receivers = ["entity://system/user/admin"]

      inv =
        build_invocation(
          self_uri,
          :add_rule,
          %{
            table: table,
            matcher_json: matcher_json,
            receivers: receivers
          },
          admin_caps
        )

      assert {:ok, new_state, %{id: id}, _slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubRoutingKind, self_uri)

      assert is_integer(id) and id > 0

      # Counter bumped via {:set, :calls, prev+1} effect
      assert new_state.routing.calls == 1

      # Cleanup — leave RuleStore clean for sibling tests.
      _ = RuleStore.delete(id)
    end

    test ":delete_rule via Kind.Runtime — counter bumps + RuleStore.delete",
         %{self_uri: self_uri, admin_caps: admin_caps, state: state} do
      table = @table

      # Seed a rule we can delete.
      {:ok, matcher} = Ezagent.Routing.Matcher.from_json(%{"type" => "always"})
      {:ok, row} = RuleStore.add(table, matcher, ["entity://system/user/admin"], nil, [])

      inv =
        build_invocation(self_uri, :delete_rule, %{table: table, id: row.id}, admin_caps)

      assert {:ok, new_state, %{deleted: deleted_id}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubRoutingKind, self_uri)

      assert deleted_id == row.id
      assert new_state.routing.calls == 1
    end

    test ":disable_rule via Kind.Runtime — counter bumps + RuleStore.disable",
         %{self_uri: self_uri, admin_caps: admin_caps, state: state} do
      table = @table
      {:ok, matcher} = Ezagent.Routing.Matcher.from_json(%{"type" => "always"})
      {:ok, row} = RuleStore.add(table, matcher, ["entity://system/user/admin"], nil, [])

      inv =
        build_invocation(self_uri, :disable_rule, %{table: table, id: row.id}, admin_caps)

      assert {:ok, new_state, %{disabled: disabled_id}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubRoutingKind, self_uri)

      assert disabled_id == row.id
      assert new_state.routing.calls == 1

      _ = RuleStore.delete(row.id)
    end

    test ":enable_rule via Kind.Runtime — counter bumps + RuleStore.enable",
         %{self_uri: self_uri, admin_caps: admin_caps, state: state} do
      table = @table
      {:ok, matcher} = Ezagent.Routing.Matcher.from_json(%{"type" => "always"})
      {:ok, row} = RuleStore.add(table, matcher, ["entity://system/user/admin"], nil, [])
      :ok = RuleStore.disable(row.id)

      inv =
        build_invocation(self_uri, :enable_rule, %{table: table, id: row.id}, admin_caps)

      assert {:ok, new_state, %{enabled: enabled_id}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubRoutingKind, self_uri)

      assert enabled_id == row.id
      assert new_state.routing.calls == 1

      _ = RuleStore.delete(row.id)
    end

    test ":add_rule — bad matcher_json returns {:error, _}",
         %{self_uri: self_uri, admin_caps: admin_caps, state: state} do
      # `Matcher.from_json/1` rejects non-map / unknown-type shapes.
      # The handler must propagate the error verbatim (no slice
      # mutation, no RuleStore write).
      inv =
        build_invocation(
          self_uri,
          :add_rule,
          %{
            table: @table,
            matcher_json: %{"type" => "totally_bogus"},
            receivers: []
          },
          admin_caps
        )

      result = Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubRoutingKind, self_uri)

      # Either the handler returns {:error, _} directly or the
      # InterfaceValidator may have caught it earlier; both surface
      # as the same `{:error, _}` tuple from dispatch.
      assert match?({:error, _}, result), "expected error tuple, got #{inspect(result)}"
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Enum.sort(Routing.actions()) ==
               [:add_rule, :delete_rule, :disable_rule, :enable_rule]

      iface = Routing.interface()

      for action <- [:add_rule, :delete_rule, :disable_rule, :enable_rule] do
        assert Map.has_key?(iface, action), "interface missing #{action}"
      end

      subjects = Routing.cap_subjects() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(subjects) == [:add_rule, :delete_rule, :disable_rule, :enable_rule]
    end

    test "required_caps/0 uses the :any axis (multi-Kind registration)" do
      caps = Routing.required_caps()

      for action <- [:add_rule, :delete_rule, :disable_rule, :enable_rule] do
        assert %Ezagent.Capability{kind: :any, behavior: Routing, action: ^action} =
                 caps[action]
      end
    end

    test "workspace_scoped?/0 returns false (system://routing/default is cross-workspace)" do
      assert Routing.workspace_scoped?() == false
    end

    test "state_slice/0 preserved + create/1 builds persistent state (Lifecycle migration)" do
      # Slice key still auto-derives to `:routing`. Under `use
      # Ezagent.Lifecycle`, the persistent-state builder is `create/1`;
      # `init_slice/1` is the macro-emitted two-container wrapper.
      assert Routing.state_slice() == :routing
      assert Routing.create(%{}) == {:ok, %{calls: 0}}
      assert Routing.init_slice(%{}) == %{state: %{calls: 0}, transients: %{}}
    end

    test "data_owner/1 — workspace-scoped URI returns :any (workspace admin grants)" do
      ws_uri = Ezagent.URI.new!("workspace://team-alpha")
      assert Routing.data_owner(ws_uri) == :any
    end

    test "data_owner/1 — global system instance returns :no_owner (bootstrap-admin only)" do
      sys_uri = Ezagent.URI.new!("system://routing/default")
      assert Routing.data_owner(sys_uri) == :no_owner
    end
  end
end
