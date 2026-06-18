defmodule Ezagent.PluginLoom.TurnManagerTest do
  @moduledoc """
  P1 gate: the loom turn-manager drives the substrate Turn/Surface authoring
  loop using a PRODUCTION within-session cap (not system://bootstrap), with the
  page generator injected. Proves an authoring request lands a page in Surface.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, Workspace}
  alias Ezagent.Entity.User
  alias Ezagent.PluginLoom.Template.LoomVerticalSession
  alias Ezagent.PluginLoom.TurnManager

  setup do
    ws = "loommgr-#{System.unique_integer([:positive])}"
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
    %{session: session_uri, manager: User.admin_uri()}
  end

  test "build_page drives open→compose→settle and lands the page as an approved Surface version",
       ctx do
    files = %{"/App.jsx" => "export default () => <h1>hello loom</h1>"}
    generator = fn _request -> {:ok, %{tree: files, reply: "built your page"}} end

    assert {:ok, %{turn_id: _turn_id}} =
             TurnManager.build_page(ctx.session, ctx.manager, "make a hello page", generator)

    wait_until(fn ->
      case Ezagent.Kind.get_slice(ctx.session, :surface) do
        {:ok, %{approved: approved, versions: versions}}
        when is_integer(approved) ->
          Map.get(versions, approved) |> page_tree() == files

        _ ->
          false
      end
    end)

    assert {:ok, %{approved: approved, versions: versions}} =
             Ezagent.Kind.get_slice(ctx.session, :surface)

    assert is_integer(approved)
    assert versions[approved].tree == files
  end

  test "a second authoring turn appends a new approved version", ctx do
    g1 = fn _ -> {:ok, %{tree: %{"/App.jsx" => "v1"}, reply: "v1"}} end
    g2 = fn _ -> {:ok, %{tree: %{"/App.jsx" => "v2"}, reply: "v2"}} end

    assert {:ok, _} = TurnManager.build_page(ctx.session, ctx.manager, "v1", g1)
    wait_for_approved_tree(ctx.session, %{"/App.jsx" => "v1"})

    assert {:ok, _} = TurnManager.build_page(ctx.session, ctx.manager, "v2", g2)
    wait_for_approved_tree(ctx.session, %{"/App.jsx" => "v2"})

    {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert map_size(surface.versions) == 2
  end

  defp page_tree(nil), do: nil
  defp page_tree(%{tree: tree}), do: tree

  defp wait_for_approved_tree(session_uri, files) do
    wait_until(fn ->
      case Ezagent.Kind.get_slice(session_uri, :surface) do
        {:ok, %{approved: a, versions: v}} when is_integer(a) -> page_tree(Map.get(v, a)) == files
        _ -> false
      end
    end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")
  defp wait_until(fun, attempts) do
    if fun.(), do: :ok, else: (Process.sleep(20) && wait_until(fun, attempts - 1))
  end
end
