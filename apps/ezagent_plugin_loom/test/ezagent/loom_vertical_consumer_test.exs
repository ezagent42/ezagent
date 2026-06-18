defmodule Ezagent.PluginLoom.LoomVerticalConsumerTest do
  @moduledoc """
  P2 gate: the FULL substrate chain end-to-end —
  authoring turn (TurnManager) → Surface version → settlement → CustomerOutbox →
  `Ezagent.Socialware.CustomerFeed` delivers the approved page + customer-visible
  message to a token-bound consumer. This is "loom goes through socialware".
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, Workspace}
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias Ezagent.PluginLoom.Template.LoomVerticalSession
  alias Ezagent.PluginLoom.TurnManager

  setup do
    ws = "loomcons-#{System.unique_integer([:positive])}"
    name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(ws)
    session_uri = Ezagent.URI.session(ws, :loom, name)
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, [^session_uri], _} =
      LoomVerticalSession.instantiate(
        "session.loom_vertical",
        %{
          "class" => "session.loom_vertical",
          "session_name" => name,
          "operator_uri" => URI.to_string(User.admin_uri())
        },
        workspace_uri
      )

    {:ok, _} = KindRegistry.lookup(session_uri)

    %{
      session: session_uri,
      manager: User.admin_uri(),
      token: CustomerAuth.issue_token(session_uri, workspace_uri),
      wrong_token: CustomerAuth.issue_token(session_uri, "workspace://other")
    }
  end

  test "authoring turn → consumer reads the approved page + chat via CustomerFeed", ctx do
    files = %{"/App.jsx" => "export default () => <h1>published page</h1>"}

    # before any turn: customer sees nothing
    assert {:ok, %{messages: [], page: nil}} = CustomerFeed.snapshot(ctx.session, ctx.token)

    assert {:ok, _} =
             TurnManager.build_page(ctx.session, ctx.manager, "publish a landing page", fn _ ->
               {:ok, %{tree: files, reply: "shipped your page"}}
             end)

    snapshot = wait_for_page(ctx.session, ctx.token, files)
    assert snapshot.page == files
    assert Enum.any?(snapshot.messages, &message_text?(&1, "shipped your page"))
  end

  test "a cross-workspace token is denied (socialware gating)", ctx do
    assert {:error, :unauthorized} = CustomerFeed.snapshot(ctx.session, ctx.wrong_token)
  end

  defp message_text?(message, text),
    do: Map.get(message.body, "text") == text or Map.get(message.body, :text) == text

  defp wait_for_page(session_uri, token, files) do
    wait_until(fn ->
      case CustomerFeed.snapshot(session_uri, token) do
        {:ok, %{page: ^files}} -> true
        _ -> false
      end
    end)

    {:ok, snapshot} = CustomerFeed.snapshot(session_uri, token)
    snapshot
  end

  defp wait_until(fun, attempts \\ 150)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")
  defp wait_until(fun, attempts) do
    if fun.(), do: :ok, else: (Process.sleep(20) && wait_until(fun, attempts - 1))
  end
end
