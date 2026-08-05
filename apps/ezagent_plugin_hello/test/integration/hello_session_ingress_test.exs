defmodule EzagentPluginHello.Integration.HelloSessionIngressTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.{Invocation, Message, RoutingRegistry, Workspace}
  alias Ezagent.ActionSet.HelloSessionActions
  alias Ezagent.Routing.Resolver
  alias EzagentPluginHello.{App, Members, Router, TurnDriver}

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)

    {:ok, writer} = start_supervised(Ezagent.Audit.Writer)
    Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), writer)

    previous_routing_tables = Application.get_env(:ezagent_core, :routing_tables)
    install_default_rule_table()

    test_pid = self()
    previous_generator = Application.get_env(:ezagent_plugin_hello, :generator_start)
    previous_concierge = Application.get_env(:ezagent_plugin_hello, :concierge_start)

    Application.put_env(:ezagent_plugin_hello, :generator_start, fn session, text ->
      send(test_pid, {:rebuild, session, text})
      {:ok, self()}
    end)

    Application.put_env(:ezagent_plugin_hello, :concierge_start, fn session, text, actor ->
      send(test_pid, {:answer, session, text, actor})
      {:ok, self()}
    end)

    on_exit(fn ->
      restore_env(:generator_start, previous_generator)
      restore_env(:concierge_start, previous_concierge)
      restore_routing_tables(previous_routing_tables)
    end)

    ws = "hello-ingress-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})

    owner = Ezagent.URI.entity(ws, :user, "owner")
    {:ok, _} = Ezagent.Users.create(owner, "pw-not-secret", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)
    {:ok, session, sender} = App.ensure_app(ws, "main", owner: owner)
    assert sender == session

    llm = Ezagent.URI.entity(ws, :agent, "actual_llm")

    {:ok, _} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: llm,
        behaviors: Ezagent.Entity.Agent.base_behaviors(),
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(llm, Ezagent.URI.workspace(ws))
    :ok = Ezagent.AgentFlavorAttributes.put(llm, "native")
    join_member(session, llm, "llm")

    on_exit(fn ->
      Ezagent.WorkspaceRegistry.unbind(llm)
      if match?({:ok, _}, Ezagent.KindRegistry.lookup(llm)), do: Ezagent.Kind.terminate(llm)
    end)

    visitor = Ezagent.URI.entity(ws, :user, "visitor")
    {:ok, _} = Ezagent.Users.create(visitor, "pw-not-secret", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(visitor)
    join_member(session, visitor, nil)

    %{session: session, owner: owner, visitor: visitor, llm: llm}
  end

  test "only the llm role is declared and no front-desk member is materialized", %{
    session: session,
    llm: llm
  } do
    assert :error = Members.role_uri(session, "front-desk")
    assert {:ok, ^llm} = Members.role_uri(session, "llm")

    working_copy = Ezagent.Entity.Session.read_template_working_copy(session)

    assert %{behavior: HelloSessionActions, action: :route_inbound, protected_roles: ["llm"]} =
             working_copy.ingress

    assert [declaration] = working_copy.member_declarations
    assert (declaration[:role_name] || declaration["role_name"]) == "llm"
  end

  test "real session.send uses the ingress self-cap and never delivers directly to @llm", %{
    session: session,
    owner: owner,
    visitor: visitor,
    llm: llm
  } do
    attach_ingress_authz_probe(session)
    receive_before = receive_dispatch_count(llm)

    owner_message = dispatch_send(session, owner, "rebuild the page", [llm])
    assert_receive {:ingress_authz_granted, %{caller: ^session, action: :route_inbound}}, 2_000
    assert_receive {:rebuild, ^session, "rebuild the page"}, 2_000

    visitor_message = dispatch_send(session, visitor, "replace the whole page", [llm])
    assert_receive {:ingress_authz_granted, %{caller: ^session, action: :route_inbound}}, 2_000
    assert_receive {:answer, ^session, "replace the whole page", ^session}, 2_000
    refute_receive {:rebuild, ^session, "replace the whole page"}, 100

    assert owner_message.session_uri == session
    assert visitor_message.session_uri == session

    await_delivery_idle()

    assert receive_dispatch_count(llm) == receive_before,
           "the protected llm role must enter through Session ingress, not agent.receive"
  end

  test "Session-authored narration and share are rejected by the ingress loop guard", %{
    session: session
  } do
    assert :ok = TurnDriver.say(session, Ezagent.Entity.User.admin_uri(), "generated")
    refute Router.should_route?(session, session)

    assert {:ok, %{}, []} =
             HelloSessionActions.handle_share(%{session_uri: URI.to_string(session)}, %{})

    refute_receive {:rebuild, _, _}, 100
    refute_receive {:answer, _, _, _}, 100
  end

  defp install_default_rule_table do
    table = String.to_atom("hello_ingress_#{System.unique_integer([:positive])}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    :ok =
      RoutingRegistry.put(
        table,
        Ezagent.Routing.Matcher.always(),
        [Resolver.session_users_token(), Resolver.mentions_token()]
      )

    Application.put_env(:ezagent_core, :routing_tables, [table])
  end

  defp join_member(session, member, role_name) do
    target = Ezagent.URI.with_action(session, :session, :join)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, member)

    args =
      if is_binary(role_name),
        do: %{member: member, role_name: role_name},
        else: %{member: member}

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: args,
        ctx: %{
          caller: member,
          authenticated_principal: member,
          caps: MapSet.new([cap]),
          reply: :ignore
        }
      })

    if is_binary(role_name) do
      await(fn -> Members.role_uri(session, role_name) == {:ok, member} end)
    else
      await(fn -> member in Ezagent.Entity.Session.session_member_uris(session) end)
    end
  end

  defp dispatch_send(session, sender, text, mentions) do
    target = Ezagent.URI.with_action(session, :session, :send)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, sender)

    assert cap.action == :send
    assert cap.instance == session
    assert cap.grantee_uri == sender
    assert is_binary(cap.signature)

    message = Message.new(sender, %{text: text, attachments: []}, mentions: mentions)

    assert :ok =
             Invocation.dispatch(%Invocation{
               origin: :authenticated_external,
               target: target,
               mode: :cast,
               args: %{message: message},
               ctx: %{
                 caller: sender,
                 authenticated_principal: sender,
                 caps: MapSet.new([cap]),
                 reply: :ignore
               }
             })

    await(fn ->
      Enum.any?(Ezagent.MessageStore.recent_in_session(session, 10), &(&1.id == message.id))
    end)

    Enum.find(Ezagent.MessageStore.recent_in_session(session, 10), &(&1.id == message.id))
  end

  defp attach_ingress_authz_probe(session) do
    handler_id = "hello-ingress-authz-#{System.unique_integer([:positive])}"
    parent = self()
    expected_target = Ezagent.URI.with_action(session, :hello_session_actions, :route_inbound)

    :telemetry.attach(
      handler_id,
      [:ezagent, :authz, :granted],
      fn _event, _measurements, metadata, _config ->
        if metadata.action == :route_inbound and metadata.target == expected_target do
          send(parent, {:ingress_authz_granted, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp receive_dispatch_count(target_uri) do
    prefix = "#{URI.to_string(target_uri)}?action=agent.receive"

    EzagentCore.Repo.aggregate(
      from(i in "invocations",
        where:
          fragment("? LIKE ?", i.target, ^"#{prefix}%") and
            i.authz == "granted"
      ),
      :count
    )
  end

  defp await_delivery_idle do
    await(fn -> Ezagent.Session.DeliveryQueue.idle?() end)
    send(Ezagent.Audit.Writer, :flush)
    Process.sleep(150)
  end

  defp await(fun, attempts \\ 100)
  defp await(_fun, 0), do: flunk("asynchronous Hello ingress operation did not converge")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      await(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ezagent_plugin_hello, key)
  defp restore_env(key, value), do: Application.put_env(:ezagent_plugin_hello, key, value)

  defp restore_routing_tables(nil), do: Application.delete_env(:ezagent_core, :routing_tables)

  defp restore_routing_tables(value),
    do: Application.put_env(:ezagent_core, :routing_tables, value)
end
