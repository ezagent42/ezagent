defmodule EzagentPluginLiveview.AppShell do
  @moduledoc """
  Nested-shell refactor PR-1 (SPEC §1, §3, §6 row 1) — the Tier-3
  application shell wrapper.

  `app_shell/1` is the single thing an LV renders. It renders the
  Tier-2 outer chrome (`EzagentDomainUi.IdeShell.ide_shell_outer/1`)
  and fills its `:command_palette` slot — ONCE — with the stateful
  `EzagentPluginLiveview.CommandPaletteComponent` LiveComponent.

  ## Why a Tier-3 wrapper exists (SPEC §3)

  The universal chrome must be owned in ONE place. But the command
  palette is a stateful `Phoenix.LiveComponent` (Tier-3), and the
  presentational shell is a stateless `Phoenix.Component` (Tier-2,
  `ezagent_domain_ui` — the stateless-atom layer, zero LV deps per
  the UI Contract). Putting the LiveComponent in Tier-2 would break
  that contract. A Tier-3 wrapper is the seam that lets both rules
  hold: it lives in `ezagent_plugin_liveview` (which MAY depend on
  LiveView), renders the Tier-2 chrome, and supplies the Tier-3
  LiveComponent into the chrome's slot.

  CmdK is wired exactly ONCE — here — instead of once per LV.

  ## Body slot

  `:body` is a passthrough: whatever the LV puts in `app_shell`'s
  `:body` is rendered into `ide_shell_outer`'s `:body`. An LV places
  one inner perspective there:

      <AppShell.app_shell perspective={:workspace} ...>
        <:body>
          <WorkspaceShell.workspace_shell current_path="/sessions" ...>
            <:main_window>...</:main_window>
          </WorkspaceShell.workspace_shell>
        </:body>
      </AppShell.app_shell>

  …or `perspective={:admin}` + `<AdminShell.admin_shell>` for a
  config page.

  PR-1 is purely additive — no LV is wired into `app_shell` yet;
  PR-2/PR-3 migrate consumers.
  """

  use Phoenix.Component

  alias EzagentDomainUi.IdeShell
  alias EzagentPluginLiveview.CommandPaletteComponent

  @doc """
  Render the outer chrome + wire CmdK once, with the LV's content in
  `:body`.

  `perspective` is threaded through to both `ide_shell_outer/1` (which
  picks the header context affordance) and `CommandPaletteComponent`
  (so an admin page surfaces system-scoped results only — SPEC §2/§3).
  """
  attr(:perspective, :atom,
    required: true,
    values: [:workspace, :admin],
    doc: "SPEC §2 context contract — `:workspace` or `:admin`."
  )

  attr(:current_entity_uri, :any, required: true)

  attr(:current_workspace_uri, :any,
    default: nil,
    doc: "Workspace URI the CmdK entity/session results are scoped to."
  )

  attr(:workspace_name, :string, default: nil)
  attr(:workspaces, :list, default: [])
  attr(:is_admin?, :boolean, default: false)
  attr(:is_system_member?, :boolean, default: false)

  attr(:cmdk_nav_routes, :list,
    default: [],
    doc: "Nav routes delivered DOWN from the `EzagentWeb.LiveAuth` `:cmdk_nav` on_mount assign."
  )

  attr(:cmdk_id, :string,
    default: "cmdk",
    doc: "DOM id for the CommandPaletteComponent LiveComponent."
  )

  slot(:body, required: true)

  def app_shell(assigns) do
    ~H"""
    <IdeShell.ide_shell_outer
      perspective={@perspective}
      current_entity_uri={@current_entity_uri}
      workspace_name={@workspace_name}
      workspaces={@workspaces}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
    >
      <:command_palette>
        <.live_component
          module={CommandPaletteComponent}
          id={@cmdk_id}
          nav_routes={@cmdk_nav_routes}
          perspective={@perspective}
          current_entity_uri={@current_entity_uri}
          current_workspace_uri={@current_workspace_uri}
        />
      </:command_palette>
      <:body>{render_slot(@body)}</:body>
    </IdeShell.ide_shell_outer>
    """
  end
end
