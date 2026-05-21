defmodule EzagentPluginCc.Application do
  @moduledoc """
  CC plugin Application — the unified Claude Code agent plugin
  (Allen 2026-05-19: merged from the previous `ezagent_plugin_cc_pty`
  + `ezagent_plugin_cc_channel` apps; both predecessors deleted).

  Responsibilities:

  - Host the v2 Phoenix.Channel WS bridge at `/cc_socket`
    (`Socket` + `Channel` + `BridgeRegistry`)
  - Mint + persist per-instance connect tokens (`TokenStore`)
  - Write the `mcp.json` Claude reads for the WS bridge sidecar
    (`McpConfigWriter`)
  - Register the unified `cc.agent` Template Class (PR-D2,
    Allen 2026-05-19 — replaces the pre-existing cc.pty +
    cc.channel_instance split)

  PTY runtime (PtyServer + Supervisor + Registry) moved to the new
  `ezagent_domain_pty` Tier-2 app in PR-A of the Domain.Pty SPEC
  (2026-05-21). cc plugin now spawns its claude PTY by building the
  full cmd string and calling `Ezagent.Domain.Pty.start/2`; the
  Server/Supervisor/Registry boot here is gone.

  ## Why the unified template

  Pre-PR-D2 the operator had to add TWO templates per CC agent —
  one `cc.pty` (spawns the PTY) and one `cc.channel_instance` (mints
  the token + makes BridgeRegistry happy). They were always added
  together, deleted together.

  Now: ONE template (`cc.agent`), ONE plugin. PR-D2 originally
  reserved a `mode` field (`"local-pty"` / `"remote-channel"`) for a
  future external-host bridge mode. Allen 2026-05-21 removed that
  field — the placeholder was never wired and the dichotomy was
  dead weight. If/when remote support returns it will land as a
  separate plugin + Template Class, not a mode dimension on this
  template.

  ## Boot order

  1. Init BridgeRegistry (ETS table for agent_uri → Channel pid)
  2. Register the `cc.agent` Template Class
  3. Register `Ezagent.Behavior.Pty` on `Ezagent.Entity.Agent` so
     `entity://agent/default/cc_<X>?action=pty.write` dispatches resolve.
     (PR #146: previously a synthetic `pty-input://default` singleton;
     dissolved per SPEC v2 §5.7 — PTY input now dispatches to the
     agent itself.)
  4. Re-run `Workspace.Loader.load_all/0` to instantiate any
     cc.agent templates that were skipped during boot before this
     plugin was up. Idempotent via the Domain.Pty :via Registry.
  """

  use Application

  alias EzagentPluginCc.BridgeRegistry

  @impl true
  def start(_type, _args) do
    :ok = BridgeRegistry.init()

    # Domain.Pty PR-A (2026-05-21): the PtyServerRegistry +
    # PtyServerSupervisor children moved to EzagentDomainPty.Application.
    # cc plugin's Application now boots ONLY a placeholder supervisor —
    # all stateful children (Bridge/Token/Socket) are either ETS-backed
    # (BridgeRegistry above) or pulled in via the umbrella's lifecycle
    # (Socket via EzagentWeb.Endpoint). Keeping an empty Supervisor
    # makes Application.stop work as the umbrella expects.
    children = []

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        :ok = register_template_classes()
        :ok = register_pty_behavior_on_agent()
        :ok = register_session_views()

        # Boot-ordering fix: chat plugin's Application.start calls
        # Ezagent.Workspace.Loader.load_all/0 BEFORE this plugin
        # starts. Re-run here so Workspaces declaring our Template
        # Classes get instantiated.
        _ = Ezagent.Workspace.Loader.load_all()

        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Phase 8b — register the PTY SessionView (admin_live calls
  # `Ezagent.UI.SessionViewRegistry.applicable_views/1` to decide
  # which view-switcher buttons show up).
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(EzagentPluginCc.Views.PtyView)
    :ok
  end

  defp register_template_classes do
    # PR-D2 (Allen 2026-05-19): cc.pty + cc.channel_instance collapsed
    # into a single cc.agent Template (originally with a "mode" form
    # field — that field was removed Allen 2026-05-21; only local-pty
    # remains).
    :ok = Ezagent.TemplateRegistry.register(Ezagent.PluginCc.Template.CcAgent)
    :ok
  end

  # PR #146 (SPEC v2 §5.7) — synthetic `pty-input://default` singleton
  # dissolved. Register `Behavior.Pty` on `Ezagent.Entity.Agent` so
  # xterm.js LV input dispatches to the agent's own URI:
  # `entity://agent/default/cc_<X>?action=pty.write`.
  defp register_pty_behavior_on_agent do
    alias Ezagent.BehaviorRegistry
    alias Ezagent.Behavior.Pty, as: PtyB
    alias Ezagent.Entity.Agent, as: AgentK

    Enum.each(PtyB.actions(), fn action ->
      :ok = BehaviorRegistry.register(AgentK, action, PtyB)
    end)

    :ok
  end
end
