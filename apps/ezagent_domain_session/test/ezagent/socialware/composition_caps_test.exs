defmodule Ezagent.Socialware.CompositionCapsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{CompositionBinding, CompositionCaps, Installation}

  alias EzagentDomainInstanceMessage.{
    CompositionOwnedTestBehavior,
    CompositionOwnerlessTestBehavior
  }

  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  test "same non-admin owner mints, stores, and dispatches a concrete operate cap" do
    owner = user_uri("owner")
    source = live_agent("source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("target", owner, [CompositionOwnedTestBehavior])
    unrelated = live_agent("unrelated", owner, [CompositionOwnedTestBehavior])
    session = session_uri("same-owner")

    assert {:ok, %{active: 1, degraded: 0}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)
    assert {:ok, %{ok: true}} = dispatch_probe(source, target, :composition_owned_probe)
    assert {:error, :unauthorized} = dispatch_probe(source, unrelated, :composition_owned_probe)
  end

  test "foreign target degrades to participate-only and records the denied edge" do
    configurer = user_uri("configurer")
    foreign_owner = user_uri("foreign-target-owner")

    source =
      live_agent("foreign-target-source", configurer, Ezagent.Entity.Agent.base_behaviors())

    target = live_agent("foreign-target", foreign_owner, [CompositionOwnedTestBehavior])
    session = session_uri("foreign-target")

    assert {:ok, %{active: 0, degraded: 1}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               configurer,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)

    assert [%CompositionBinding{status: :degraded, inactive_reason: "grant_not_owner"}] =
             CompositionBinding.degraded_for_session(session)
  end

  test "ownerless target fails loud before ISSUE" do
    owner = user_uri("ownerless-owner")
    source = live_agent("ownerless-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("ownerless-target", owner, [CompositionOwnerlessTestBehavior])
    session = session_uri("ownerless")

    assert {:error, {:operate_target_ownerless, ^target, CompositionOwnerlessTestBehavior}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnerlessTestBehavior, :composition_ownerless_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    assert CompositionBinding.degraded_for_session(session) == []
  end

  test "foreign source is not absorbed and degrades separately from target issuance" do
    configurer = user_uri("source-configurer")
    foreign_owner = user_uri("foreign-source-owner")
    source = live_agent("foreign-source", foreign_owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("owned-target", configurer, [CompositionOwnedTestBehavior])
    session = session_uri("foreign-source")

    assert {:ok, %{active: 0, degraded: 1}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               configurer,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)

    assert [%CompositionBinding{status: :degraded, inactive_reason: "foreign_source"}] =
             CompositionBinding.degraded_for_session(session)
  end

  test "live target that does not mount the declared behavior fails loud" do
    owner = user_uri("nonconformant-owner")
    source = live_agent("nonconformant-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("nonconformant-target", owner, Ezagent.Entity.Agent.base_behaviors())
    session = session_uri("nonconformant")

    assert {:error,
            {:operate_target_not_conformant, ^target, CompositionOwnedTestBehavior,
             :composition_owned_probe}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )
  end

  test "an install without owner authorization cannot mint" do
    owner = user_uri("unauthorized-install-owner")
    source = live_agent("unauthorized-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("unauthorized-target", owner, [CompositionOwnedTestBehavior])
    session = session_uri("unauthorized-install")

    assert {:error, {:composition_install_not_owner_authorized, ^session}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               role_members: %{"source" => source, "target" => target}
             )
  end

  test "agent materialization rejects an unauthorized composition before spawning roles" do
    session = session_uri("unauthorized-materialize")
    owner = user_uri("unauthorized-materialize-owner")

    declarations =
      roles(CompositionOwnedTestBehavior, :composition_owned_probe)
      |> Enum.map(&Map.put(&1, :recipe, "must-not-be-resolved"))

    assert {:error, {:composition_install_not_owner_authorized, ^session}} =
             DefinitionAgents.materialize_definition_agents(
               session,
               workspace_uri(),
               owner,
               declarations
             )
  end

  test "union reconciliation keeps a shared cap until its last session binding leaves" do
    owner = user_uri("union-owner")
    source = live_agent("union-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("union-target", owner, [CompositionOwnedTestBehavior])
    first_session = session_uri("union-first")
    second_session = session_uri("union-second")
    role_members = %{"source" => source, "target" => target}
    declarations = roles(CompositionOwnedTestBehavior, :composition_owned_probe)

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               first_session,
               workspace_uri(),
               owner,
               declarations,
               install_authorized?: true,
               role_members: role_members
             )

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               second_session,
               workspace_uri(),
               owner,
               declarations,
               install_authorized?: true,
               role_members: role_members
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)
    assert :ok = CompositionCaps.deactivate_session(first_session)
    assert holds_operate_cap?(source, target, :composition_owned_probe)

    assert :ok = CompositionCaps.deactivate_session(second_session)
    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)
  end

  test "socialware uninstall and target departure revoke their last supported cap" do
    owner = user_uri("lifecycle-owner")
    source = live_agent("lifecycle-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("lifecycle-target", owner, [CompositionOwnedTestBehavior])
    declarations = roles(CompositionOwnedTestBehavior, :composition_owned_probe)
    role_members = %{"source" => source, "target" => target}

    uninstall_session = session_uri("uninstall")

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               uninstall_session,
               workspace_uri(),
               owner,
               declarations,
               install_authorized?: true,
               role_members: role_members
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)
    assert :ok = Installation.retract_session_installs(uninstall_session, owner)
    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)

    departure_session = session_uri("departure")

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               departure_session,
               workspace_uri(),
               owner,
               declarations,
               install_authorized?: true,
               role_members: role_members
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)
    assert :ok = CompositionCaps.deactivate_member(departure_session, target)
    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)
  end

  test "repairing the same declaration is idempotent by binding and cap identity" do
    owner = user_uri("repair-owner")
    source = live_agent("repair-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("repair-target", owner, [CompositionOwnedTestBehavior])
    session = session_uri("repair")
    role_members = %{"source" => source, "target" => target}
    declarations = roles(CompositionOwnedTestBehavior, :composition_owned_probe)

    for _ <- 1..2 do
      assert {:ok, %{active: 1, degraded: 0}} =
               CompositionCaps.reconcile_session(
                 session,
                 workspace_uri(),
                 owner,
                 declarations,
                 install_authorized?: true,
                 role_members: role_members
               )
    end

    assert [_binding] = CompositionBinding.active_for_session(session)
    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)

    assert 1 ==
             Enum.count(Ezagent.Identity.list_caps_for(source), fn cap ->
               cap.behavior == CompositionOwnedTestBehavior and
                 cap.action == :composition_owned_probe and
                 cap.instance == Ezagent.URI.instance(target)
             end)
  end

  test "dropping an edge during Definition reconciliation revokes its last supported cap" do
    owner = user_uri("definition-drop-owner")
    source = live_agent("definition-drop-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("definition-drop-target", owner, [CompositionOwnedTestBehavior])
    session = session_uri("definition-drop")

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)

    assert {:ok, %{active: 0, degraded: 0}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               [%{role_name: "source", fill: :agent, recipe: "source"}],
               role_members: %{"source" => source}
             )

    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)
  end

  test "a later reconcile retries revocation from inactive binding history" do
    owner = user_uri("revoke-retry-owner")
    source = live_agent("revoke-retry-source", owner, Ezagent.Entity.Agent.base_behaviors())
    target = live_agent("revoke-retry-target", owner, [CompositionOwnedTestBehavior])
    session = session_uri("revoke-retry")

    assert {:ok, %{active: 1}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               roles(CompositionOwnedTestBehavior, :composition_owned_probe),
               install_authorized?: true,
               role_members: %{"source" => source, "target" => target}
             )

    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)

    artifact =
      Enum.find(Ezagent.Identity.list_caps_for(source), fn cap ->
        cap.behavior == CompositionOwnedTestBehavior and
          cap.action == :composition_owned_probe and
          cap.instance == Ezagent.URI.instance(target)
      end)

    assert :ok = CompositionCaps.deactivate_session(session)
    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)

    # Model a lagging STORE that lands after the first reconciliation attempt.
    assert :ok = Ezagent.Identity.absorb_cap(source, artifact)
    assert eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end)

    assert {:ok, %{active: 0, degraded: 0}} =
             CompositionCaps.reconcile_session(
               session,
               workspace_uri(),
               owner,
               [],
               role_members: %{}
             )

    refute eventually(fn -> holds_operate_cap?(source, target, :composition_owned_probe) end, 5)
  end

  defp roles(behavior, action) do
    provenance = %{
      install_id: "composition-test",
      definition_config_id: "definition-v1",
      definition_content_hash: "definition-hash-v1"
    }

    [
      %{
        role_name: "source",
        fill: :agent,
        recipe: "source",
        composition_provenance: provenance,
        operates: [%{role: "target", behavior: behavior, action: action}]
      },
      %{role_name: "target", fill: :agent, recipe: "target"}
    ]
  end

  defp live_agent(name, owner, extra_behaviors) do
    uri = agent_uri(name)
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, workspace_uri())
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp dispatch_probe(caller, target, action) do
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: Ezagent.URI.with_action(target, :composition_owned_test, action),
      mode: :call,
      args: %{},
      ctx: %{caller: caller, caps: MapSet.new(), reply: {:caller_inbox, self()}}
    })
  end

  defp holds_operate_cap?(source, target, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(source), fn cap ->
      cap.kind == :agent and cap.behavior == CompositionOwnedTestBehavior and
        cap.action == action and cap.instance == Ezagent.URI.instance(target) and
        cap.workspace_uri == workspace_uri()
    end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp workspace_uri, do: Ezagent.URI.new!("workspace://composition")

  defp user_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/user/#{name}-#{System.unique_integer([:positive])}")

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://composition/agent/#{name}-#{System.unique_integer([:positive])}")

  defp session_uri(name),
    do:
      Ezagent.URI.new!(
        "session://composition/socialware/#{name}-#{System.unique_integer([:positive])}"
      )
end
