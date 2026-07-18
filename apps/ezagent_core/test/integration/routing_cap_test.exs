defmodule Ezagent.Integration.RoutingCapTest do
  @moduledoc """
  PR #146 (SPEC v2 §5.7) invariant test — routing rule mutations
  dispatch to **scope-owning Kinds** (the `routing-admin://default`
  synthetic singleton has been dissolved):

  - Global rules → `system://routing/default?action=routing.<action>`
  - Workspace rules → `workspace://<name>?action=routing.<action>`
    (this test covers global; workspace/session paths share the same
    Behavior + same Capability shape modulo `kind:`/`instance:`)

  CapBAC step 5.5 fires against the scope-owning Kind. Non-admin
  without an explicit per-scope routing cap gets `:unauthorized`
  and an audit row written.

  If this test breaks, the per-rule cap-protect is broken regardless
  of green LV tests (admin's all-cap always passes; the gate is the
  non-admin path).
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{Invocation, Routing.Matcher}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  # #52 Mode-B fix: `system://routing/default` is no longer eagerly
  # spawned at boot in `:test` (`EzagentCore.Application.register_system_kind/0`).
  # Spawn it HERE, inside the DataCase-checked-out test owner, so the
  # `Kind.Server.init/1` `kind_snapshots` read/write runs against an
  # owned sandbox connection (and the dispatches below have a live
  # target). This exercises the demand-spawn path the production lazy
  # dispatch relies on. (greppable: routing_default_uri)
  setup do
    uri = Ezagent.Entity.System.routing_default_uri()

    if match?({:ok, _pid}, Ezagent.KindRegistry.lookup(uri)) do
      :ok = Ezagent.Kind.terminate(uri)
      wait_until_gone(uri)
    end

    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # The DataCase shared owner already allows the test process; allow the
    # freshly-spawned routing Kind too so its in-test DB work is owned.
    {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
    _ = Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)

    on_exit(fn ->
      _ = Ezagent.Kind.terminate(uri)
    end)

    :ok
  end

  defp wait_until_gone(uri, attempts \\ 100)
  defp wait_until_gone(_uri, 0), do: flunk("routing sentinel did not terminate")

  defp wait_until_gone(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> Process.sleep(5) && wait_until_gone(uri, attempts - 1)
    end
  end

  defp admin_ctx(target) do
    presenter = Ezagent.Entity.User.admin_uri()
    instance = Ezagent.URI.instance(target)

    cap =
      signed_fixture_cap!(
        instance,
        Ezagent.Entity.System.type_name(),
        Ezagent.ActionSet.Routing,
        :add_rule,
        presenter
      )

    %{
      caller: presenter,
      caps: MapSet.new([cap]),
      reply: {:caller_inbox, self()}
    }
  end

  defp non_admin_ctx do
    %{
      caller: Ezagent.URI.new!("entity://team-alpha/user/non-admin-test"),
      caps: MapSet.new(),
      reply: {:caller_inbox, self()}
    }
  end

  defp global_routing_target(action) do
    Ezagent.URI.new!(
      "#{URI.to_string(Ezagent.Entity.System.routing_default_uri())}?action=routing.#{action}"
    )
  end

  test "admin can add a rule via global Routing dispatch" do
    matcher =
      Matcher.text_contains("admin-test-#{System.unique_integer([:positive])}")

    target = global_routing_target("add_rule")

    assert {:ok, %{id: id}} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :call,
               args: %{
                 table: MentionRouting,
                 matcher_json: Matcher.to_json(matcher),
                 receivers: ["session://team-alpha/default/cap-test"]
               },
               ctx: admin_ctx(target)
             })

    assert is_integer(id)
  end

  test "non-admin gets :unauthorized when adding rule" do
    assert {:error, :missing_cap} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: global_routing_target("add_rule"),
               mode: :call,
               args: %{
                 table: MentionRouting,
                 matcher_json: Matcher.to_json(Matcher.always()),
                 receivers: ["session://team-alpha/default/x"]
               },
               ctx: non_admin_ctx()
             })
  end

  test "non-admin gets :unauthorized for delete_rule" do
    assert {:error, :missing_cap} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: global_routing_target("delete_rule"),
               mode: :call,
               args: %{table: MentionRouting, id: 999_999},
               ctx: non_admin_ctx()
             })
  end

  # #52 Mode-B: the routing sentinel is now DEMAND-spawned (the `setup`
  # above spawns it inside the test owner), not eager-spawned at boot in
  # `:test`. The invariant is "it resolves once spawned", not "alive at boot".
  test "System Kind singleton resolves at system://routing/default once spawned" do
    uri = Ezagent.Entity.System.routing_default_uri()
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(uri)
  end

  test "System Kind type_name is :system" do
    assert Ezagent.Entity.System.type_name() == :system
  end

  test "Behavior.Routing is registered on System Kind for all routing actions" do
    for action <- Ezagent.ActionSet.Routing.actions() do
      assert {:ok, Ezagent.ActionSet.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.System, action)
    end
  end

  test "Behavior.Routing is registered on Workspace + Session Kinds (scope-owning)" do
    for action <- Ezagent.ActionSet.Routing.actions() do
      assert {:ok, Ezagent.ActionSet.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Workspace, action)

      assert {:ok, Ezagent.ActionSet.Routing} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, action)
    end
  end
end
