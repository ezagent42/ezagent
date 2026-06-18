defmodule Ezagent.PluginLoom.Template.LoomVerticalSessionTest do
  @moduledoc """
  P0 gate for loom-as-socialware-vertical: a `session.loom_vertical` session is the
  UNIFIED `Ezagent.Entity.Session` with the socialware behavior subset — so Turn
  and Surface are ACTIVE, and a page round-trips through the `:surface` slice
  (open → compose(page tree) → settle → approved version).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Workspace, WorkspaceRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.PluginLoom.Template.LoomVerticalSession

  setup do
    workspace_name = "loomv-#{System.unique_integer([:positive])}"
    session_name = "main-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)

    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    assert {:ok, [^session_uri], %{fresh?: true, vertical: :loom}} =
             LoomVerticalSession.instantiate(
               "session.loom_vertical",
               %{
                 "class" => "session.loom_vertical",
                 "session_name" => session_name,
                 "operator_uri" => URI.to_string(User.admin_uri())
               },
               workspace_uri
             )

    assert {:ok, _pid} = KindRegistry.lookup(session_uri)
    assert {:ok, ^workspace_uri} = WorkspaceRegistry.lookup(session_uri)

    %{workspace_uri: workspace_uri, session: session_uri}
  end

  test "loom session is the unified SocialwareSession — Turn/Surface active, page round-trips Surface",
       ctx do
    page_tree = %{type: "text", props: %{text: "loom approved page"}}

    # Turn is ACTIVE on this instance (would fail :unauthorized on a chat-only
    # session whose instance set excludes Turn).
    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "loom answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    # settle defers approve/commit_settlement to :dispatch_after_commit, so wait
    # for the surface to reflect the approved version.
    wait_until(fn ->
      case Ezagent.Kind.get_slice(ctx.session, :surface) do
        {:ok, %{approved: ^version, versions: versions}} ->
          Map.get(versions, version) == %{tree: page_tree, by_turn: turn_id}

        _ ->
          false
      end
    end)

    assert {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
    assert surface.approved == version
    assert surface.versions[version] == %{tree: page_tree, by_turn: turn_id}
  end

  defp target(session_uri, behavior, action),
    do: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.(), do: :ok, else: (Process.sleep(20) && wait_until(fun, attempts - 1))
  end
end
