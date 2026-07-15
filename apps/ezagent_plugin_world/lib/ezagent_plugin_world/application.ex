defmodule EzagentPluginWorld.Application do
  @moduledoc """
  Next-generation ezagent web app plugin.

  The plugin owns the `world` LiveView shell and React/Vite source. It declares no
  Kinds, Behaviors, spawns, template classes, agent flavors, or routing tables in
  PR-0; later PRs add dispatch-backed surfaces and layout management.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    with {:ok, pid} <- Ezagent.Plugin.boot(__MODULE__) do
      :ok = Ezagent.Cap.ReissuePolicy.Registry.register(Ezagent.World.CapReissuePolicy, 40)
      register_session_views()
      {:ok, pid}
    end
  end

  # world consumes the SessionView registry (owned by ezagent_domain_ui, a
  # declared dep). Registering ConversationView here makes chat a first-class
  # registry view, enumerated alongside pty / hello-page / … via
  # `Ezagent.UI.SessionViewRegistry.applicable_views/2` — no hard-coded chat tab.
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "world",
      name: "World",
      description: "The React/shadcn ezagent app over a LiveView comms shell.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
      {Ezagent.Entity.Workspace, :manage, Ezagent.World.Behavior.Layout}
    ]
  end

  @doc """
  Plugin-contributed `resource://<ws>/world-layouts/<name>` type (plugin-resource
  SPEC §4.4). The `world` layout store addresses its JSON through this `<type>`
  rather than raw `Ezagent.Home.path/1`.

  `<type>` AND `backend_component` are the slug-prefixed SINGLE segment
  `"world-layouts"` (NOT `"world/layouts"` — `safe_component?/1` rejects `/`; D7
  slug-prefix convention). The resolver joins the `world-layouts` Home component
  with `<ws>` and `<name>`.
  """
  @impl Ezagent.Plugin
  def resource_types do
    [
      {"world-layouts",
       %{backend_component: "world-layouts", authority: &__MODULE__.world_layout_authority/2}}
    ]
  end

  @doc """
  Authority for the `world-layouts` type. Asserts the resolved URI's structural
  `<ws>` segment equals the caller's authenticated `scope.workspace` — the
  workspace-isolation boundary for world layout JSON. Same shape as core's
  `Ezagent.Resource.FsResolver.uploads_authority/2`.

  R-3 (codex HIGH-4): `scope.workspace` is the AUTHENTICATED caller subject
  (threaded from `ctx.caller` at the cap-checked Behavior dispatch), NEVER taken
  from `uri` — so a forged/foreign `resource://victim/world-layouts/x` resolved
  under scope `acme` fails loud (the check is non-tautological because the two
  `<ws>` values come from independent sources).
  """
  @spec world_layout_authority(URI.t(), Ezagent.Resource.FsResolver.scope()) ::
          :ok | {:error, term()}
  def world_layout_authority(%URI{} = uri, %{workspace: scope_ws}) do
    with {:ok, uri_ws} <- Ezagent.URI.workspace_name(uri),
         {:ok, scope_ws_name} <- normalize_workspace(scope_ws) do
      if uri_ws == scope_ws_name do
        :ok
      else
        {:error, {:foreign_workspace, %{uri: uri_ws, scope: scope_ws_name}}}
      end
    else
      :error -> {:error, {:malformed_resource_uri, URI.to_string(uri)}}
      {:error, _} = err -> err
    end
  end

  # scope.workspace may be a plain workspace-name string OR a workspace URI;
  # both normalize to the name for comparison against the URI's `<ws>` segment
  # (mirrors core FsResolver's `workspace_name_of/1`).
  defp normalize_workspace(ws) when is_binary(ws) and ws != "", do: {:ok, ws}

  defp normalize_workspace(%URI{} = ws_uri) do
    case Ezagent.URI.workspace_name(ws_uri) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {:malformed_scope_workspace, URI.to_string(ws_uri)}}
    end
  end

  defp normalize_workspace(other), do: {:error, {:malformed_scope_workspace, other}}

  @impl Ezagent.Plugin
  def after_boot do
    Ezagent.World.LayoutBootstrap.ensure_system_admin_manage_cap()
  end
end
