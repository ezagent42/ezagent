defmodule EzagentPluginLiveview.AppShellTest do
  @moduledoc """
  Nested-shell refactor PR-1 — `app_shell/1` render tests.

  `app_shell` is the Tier-3 wrapper: it renders the Tier-2 outer
  chrome (`IdeShell.ide_shell_outer/1`) and fills its
  `:command_palette` slot — ONCE — with the `CommandPaletteComponent`
  LiveComponent. The `:body` slot is a passthrough.

  Because `app_shell` renders a `live_component`, it can only be
  exercised inside a real LiveView. These tests use `live_isolated`
  with a tiny harness LV (`AppShellHarnessLive`) that renders
  `app_shell` with a `perspective` driven by the mount params.

  They assert: the outer chrome renders, `:body` is passed through,
  CmdK is wired exactly once, and `perspective` reaches the header
  (`:admin` → system label, NOT the workspace dropdown).
  """
  use ExUnit.Case

  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  defmodule AppShellHarnessLive do
    @moduledoc false
    use Phoenix.LiveView

    alias EzagentPluginLiveview.AppShell

    @impl true
    def mount(_params, session, socket) do
      perspective =
        case Map.get(session, "perspective") do
          "admin" -> :admin
          _ -> :workspace
        end

      {:ok,
       socket
       |> assign(:perspective, perspective)
       |> assign(:current_entity_uri, "entity://user/system/admin")
       |> assign(:current_workspace_uri, "workspace://team-alpha")
       |> assign(:workspace_name, "default")
       |> assign(:workspaces, [%{name: "default", uri: "workspace://team-alpha"}])
       |> assign(:cmdk_nav_routes, [])}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <AppShell.app_shell
        perspective={@perspective}
        current_entity_uri={@current_entity_uri}
        current_workspace_uri={@current_workspace_uri}
        workspace_name={@workspace_name}
        workspaces={@workspaces}
        cmdk_nav_routes={@cmdk_nav_routes}
      >
        <:body>APP_BODY_CONTENT</:body>
      </AppShell.app_shell>
      """
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  describe "app_shell/1 — :workspace perspective" do
    test "renders outer chrome, passes :body through, wires CmdK once", %{conn: conn} do
      {:ok, _lv, html} = live_isolated(conn, AppShellHarnessLive)

      # Outer chrome rendered.
      assert html =~ ~s(id="ide-shell-outer")
      assert html =~ "⌘K"
      # :body passed through.
      assert html =~ "APP_BODY_CONTENT"
      # CmdK LiveComponent rendered exactly once.
      assert html =~ ~s(id="cmdk")
      assert length(String.split(html, ~s(id="cmdk"))) == 2,
             "CommandPaletteComponent must be rendered exactly once"
      # :workspace perspective with a workspaces list → workspace dropdown.
      assert html =~ ~s(aria-label="Switch workspace")
    end
  end

  describe "app_shell/1 — :admin perspective" do
    test "header shows the system label, NOT the workspace dropdown", %{conn: conn} do
      {:ok, _lv, html} =
        live_isolated(conn, AppShellHarnessLive, session: %{"perspective" => "admin"})

      # System-context label present; workspace dropdown ABSENT.
      assert html =~ "System"
      refute html =~ ~s(aria-label="Switch workspace")
      # Body still passed through + CmdK still wired once.
      assert html =~ "APP_BODY_CONTENT"
      assert html =~ ~s(id="cmdk")
    end
  end
end
