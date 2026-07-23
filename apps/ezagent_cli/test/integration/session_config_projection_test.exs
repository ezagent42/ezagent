defmodule EzagentCli.Integration.SessionConfigProjectionTest do
  use EzagentCore.DataCase, async: false

  test "CLI exposes canonical core operation names as thin facades" do
    expected =
      Ezagent.Session.Config.Catalog.core_operations()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    actual =
      EzagentCli.FacadeRegistry.list(:session_config)
      |> Enum.map(fn {name, _fun, _spec} -> Atom.to_string(name) end)
      |> Enum.sort()

    assert actual == expected

    for {name, _fun, spec} <- EzagentCli.FacadeRegistry.list(:session_config) do
      operation = Ezagent.Session.Config.operation(name)
      assert spec.canonical_schema == Ezagent.Session.Config.Operation.schema(operation)
    end
  end

  test "TreeBuilder restores Session-Config facades when the CLI application is load-only" do
    table = EzagentCli.FacadeRegistry.table()
    saved = :ets.tab2list(table)
    :ets.delete_all_objects(table)

    on_exit(fn ->
      :ets.delete_all_objects(table)
      :ets.insert(table, saved)
    end)

    _spec = EzagentCli.TreeBuilder.build([])

    assert {:ok, _fun, _spec} =
             EzagentCli.FacadeRegistry.lookup(:session_config, :list_templates)
  end

  test "token-only CLI list_templates calls the domain boundary without a session target" do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "session-config-cli")

    result =
      EzagentCli.Exec.exec(
        ["session_config", "list_templates", "--json"],
        token: token
      )

    assert result.exit_code == 0
    body = Jason.decode!(result.output)
    assert is_list(body["agent_templates"])
    assert is_list(body["session_templates"])
  end

  test "missing-token guidance names the executable bootstrap mint syntax" do
    result = EzagentCli.Exec.exec(["session_config", "list_templates"])

    assert result.exit_code == 4
    assert result.output =~ "mix ezagent.user.token <entity-uri> --mint"
    refute result.output =~ "ezagent.user.token mint <entity-uri>"
  end

  test "CLI boolean values retain false through the domain coercion boundary" do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "session-config-cli-bool")
    suffix = System.unique_integer([:positive])
    session_uri = Ezagent.URI.session("system", "generic", "cli-session-config-#{suffix}")
    agent_uri = Ezagent.URI.agent("system", "cli-session-config-#{suffix}")

    {:ok, _session_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: principal
      })

    {:ok, _agent_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, initial_caps: MapSet.new()})

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, Ezagent.Capability.workspace_of(agent_uri))

    # #195: the `add_participant` :session_membership admission gate no longer
    # consults the structural owner_uri/roster — it requires the caller to
    # DURABLY hold the born-signed current-generation member cap
    # (`cap(:session, Session, :receive, S)`). Low-level `Kind.spawn` above does
    # not grant it; the production session-creation path
    # (`session_creator.ex`) calls `grant_owner_at_creation`, and this is the
    # established test-fixture pattern (see session_config/execute_test.exs).
    :ok = Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session_uri, principal)

    on_exit(fn ->
      Ezagent.Kind.terminate(session_uri)
      Ezagent.Kind.terminate(agent_uri)
    end)

    join_target = Ezagent.URI.with_action(session_uri, :session, :join)
    {:ok, join_cap} = Ezagent.Cap.issue_for_action({:admin, principal}, principal, join_target)
    :ok = Ezagent.Identity.absorb_cap(principal, join_cap)
    :ok = Ezagent.Identity.CapAbsorbAwait.await_exact(principal, [join_cap], 5_000)

    result =
      EzagentCli.Exec.exec(
        [
          "session_config",
          "add_participant",
          "--target=#{URI.to_string(session_uri)}",
          "--ref=#{URI.to_string(agent_uri)}",
          "--role-name=temporary",
          "--in-session-template=false",
          "--json"
        ],
        token: token
      )

    assert result.exit_code == 0, inspect(result)
    assert {:ok, slice} = Ezagent.Kind.get_slice(session_uri, :session)
    assert slice.members[agent_uri].in_session_template == false
  end
end
