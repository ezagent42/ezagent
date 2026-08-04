defmodule EzagentPluginHello.PageView do
  @moduledoc """
  Internal `SessionView` for a hello session's page surface — the un-degraded
  internal render.

  Socialware's own `PageView` renders the Surface tree with a tiny 5-type
  server-side HEEx renderer, which does NOT know hello's catalog
  (page/section/card/heading/button/image) and shows "Unsupported node" for them.
  This view instead emits a `<div phx-hook="HelloRenderer" data-spec=…>` that
  hydrates hello's `@json-render` island (`/assets/hello/main.js`, the SAME
  renderer the customer surface uses) INSIDE the world LiveView shell — so the
  internal reader sees the real rendered page.

  Registered via `Ezagent.UI.SessionViewRegistry` from
  `EzagentPluginHello.Application.start/2`; world renders any registered
  SessionView generically, so this needs no edit to world (handoff §6/§117).
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias Ezagent.ActionSet.Surface

  # T2-2b — this view is cap-gated: its visibility requires the caller to hold
  # the `{Session, :hello_render}` cap (declared by HelloRender). The unified
  # `SessionView.authorize_view/3` reads this to gate applicable/render.
  @impl true
  def view_behavior, do: Ezagent.ActionSet.HelloRender

  @impl true
  def id, do: :hello_page

  @impl true
  def label, do: "Page"

  @impl true
  def icon, do: "panel-top"

  @impl true
  def applies_to?(%URI{} = session_uri) do
    # Applicability is configuration, not liveness. A persisted hello install
    # must keep its Page tab while the session Kind is cold (for example after
    # an application restart); reading the live-only surface here made the tab
    # disappear until some unrelated action happened to wake the session.
    hello_session?(session_uri)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def applies_to?(_), do: false

  defp hello_session?(%URI{} = session_uri) do
    Ezagent.URI.type?(session_uri, :hello) or manifest_installed_hello?(session_uri)
  end

  defp manifest_installed_hello?(%URI{} = session_uri) do
    session_uri
    |> Ezagent.Socialware.Installation.installed_definitions()
    |> Enum.any?(fn definition ->
      "hello" in definition.uses or Ezagent.ActionSet.HelloRender in definition.views
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :surface, fn -> load_surface(assigns[:session_uri]) end)

    assigns =
      assigns
      |> assign(:tree, Surface.internal_tree(assigns[:surface] || %{}))
      |> assign(:module_url, module_url())

    ~H"""
    <div id="hello-page-view" class="flex-1 overflow-auto bg-white dark:bg-zinc-950 min-h-0 p-5">
      <div
        :if={is_nil(@tree)}
        id="hello-page-empty"
        class="h-full min-h-64 flex items-center justify-center text-sm text-zinc-500 dark:text-zinc-400"
      >
        No page version yet.
      </div>

      <div
        :if={not is_nil(@tree)}
        id="hello-page-renderer"
        phx-hook="HelloRenderer"
        phx-update="ignore"
        data-hello-module-url={@module_url}
        data-spec={Jason.encode!(@tree)}
      >
      </div>
    </div>
    """
  end

  # Internal-only: the external surface renders the approved tree through the
  # socialware external SPA, not this SessionView. (external_render?/0 +
  # external_render/1 are optional callbacks — omitted → internal-only.)

  defp module_url do
    Application.get_env(:ezagent_plugin_hello, :hello_module_url, "/assets/hello/main.js")
  end

  defp load_surface(%URI{} = session_uri) do
    # Rendering is the point where waking a cold session is appropriate. This
    # rehydrates the persisted surface when the user actually opens the Page.
    case Ezagent.Kind.read(session_uri, :surface) do
      {:ok, surface} -> surface
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp load_surface(_), do: %{}
end
