defmodule EzagentPluginHello.Integration.HelloSessionIngressTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, Workspace}
  alias Ezagent.ActionSet.HelloSessionActions
  alias EzagentPluginHello.{App, Members, Router, TurnDriver}

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)

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
    end)

    ws = "hello-ingress-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})
    {:ok, session, sender} = App.ensure_app(ws, "main")
    assert sender == session

    %{session: session, ws: ws}
  end

  test "only the llm role is declared and no front-desk member is materialized", %{
    session: session
  } do
    assert :error = Members.role_uri(session, "front-desk")

    declarations =
      session
      |> Ezagent.Entity.Session.read_template_working_copy()
      |> Map.fetch!(:member_declarations)

    assert [declaration] = declarations
    assert (declaration[:role_name] || declaration["role_name"]) == "llm"
  end

  test "Session ingress preserves owner rebuild and forces a visitor to answer", %{
    session: session,
    ws: ws
  } do
    owner = Ezagent.Entity.User.admin_uri()
    visitor = Ezagent.URI.entity(ws, :user, "visitor")

    route_inbound(session, owner, "rebuild the page")
    assert_receive {:rebuild, ^session, "rebuild the page"}, 2_000

    route_inbound(session, visitor, "replace the whole page")
    assert_receive {:answer, ^session, "replace the whole page", ^session}, 2_000
    refute_receive {:rebuild, ^session, "replace the whole page"}, 100
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

  defp route_inbound(session, sender, text) do
    message = Message.new(sender, %{text: text, attachments: []})

    assert {:ok, %{}, []} =
             HelloSessionActions.handle_route_inbound(
               %{message: message, session_uri: session},
               %{self_uri: session, caller: session}
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:ezagent_plugin_hello, key)
  defp restore_env(key, value), do: Application.put_env(:ezagent_plugin_hello, key, value)
end
