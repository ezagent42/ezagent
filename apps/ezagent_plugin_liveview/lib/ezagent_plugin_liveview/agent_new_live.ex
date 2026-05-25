defmodule EzagentPluginLiveview.AgentNewLive do
  @moduledoc """
  Phase 8c PR-N (Allen 2026-05-20) — UI for creating new agents.

  Mounts at `/identities/agents/new`. Form fields:

  - **flavor** — dropdown over the registered agent flavors. G-8 / V-1
    fix (audit 2026-05-23): the dropdown now reads from
    `Ezagent.AgentFlavorRegistry.list_all/0` at mount, so a new
    flavor plugin (e.g. `np` from #258) auto-appears without editing
    this LV. Plugin isolation (P11) restored.
  - **name** — short identifier; UI composes the full URI
    `entity://agent/<flavor>_<name>`. A live preview line shows the
    composed URI as the user types (phx-change "preview").
  - **caps** — comma-separated cap specs in the
    `Ezagent.Capability.Parser` grammar (e.g. `chat.send, workspace.read`).
    Empty is fine — agents can be created with no caps and have caps
    granted later via `/identities/agents/<uri>/caps`.

  Submit (`create_agent`) dispatches `Behavior.Workspace.:create_agent`
  via the unified facade `Ezagent.Workspace.create_agent/3` (SPEC
  `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).
  The same facade is what `mix ezagent.agent.create` calls — CLI and
  LV share one code path.

  1. Parse flavor + name + cwd + with_pty from form params
  2. Early UX validators (`validate_flavor/2`, `validate_name/1`,
     `validate_cwd_for_flavor/3`) for immediate feedback (the action
     body re-runs them as a safety net — defence in depth)
  3. Parse caps via `Ezagent.Capability.Parser.parse/3`
  4. `Ezagent.Workspace.create_agent(workspace_uri, args, caller_ctx)`
     — dispatches the action; the body handles template registration
     (cc/echo) or direct spawn (curl/future) + brings up PTY for cc
     and echo-with-PTY
  5. `Ezagent.Workspace.grant_initial_caps(agent_uri, caps, caller_ctx)`
     — dispatches `identity.grant_cap` per cap (caller's ctx, CapBAC-checked)
  6. `push_navigate(to: /identities/agents/<encoded>)`

  Wraps in `AppShell.app_shell` (`perspective: :workspace`) over
  `WorkspaceShell.workspace_shell` — agent creation is workflow, not
  config.
  """
  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.{AgentFlavorRegistry, Capability}
  alias Phoenix.LiveView.JS

  # G-8 / V-1 fix (audit 2026-05-23) — flavors are read at runtime from
  # `Ezagent.AgentFlavorRegistry` so a new agent-flavor plugin
  # (e.g. `np` from #258) auto-appears in the dropdown without touching
  # this LV. Plugin isolation (P11) is restored.
  #
  # `list_flavors/0` is the LV-facing helper added in this PR — it
  # delegates to `AgentFlavorRegistry.list_all/0` (which returns
  # `[{flavor, %{kind: ..., template_class: ...}}]`) and extracts just
  # the flavor names sorted for stable rendering. The fallback list is
  # used only if the registry isn't booted yet (e.g. in unit tests that
  # don't start the umbrella) — we don't want the LV to render an empty
  # `<select>` and silently break the form.
  @fallback_flavors ~w(cc echo curl)

  defp list_flavors do
    case AgentFlavorRegistry.list_all() do
      [] -> @fallback_flavors
      entries -> entries |> Enum.map(fn {flavor, _decl} -> flavor end) |> Enum.sort()
    end
  end

  # V-6 fix (audit 2026-05-23) — the hardcoded "default" workspace name
  # is now only the LAST-RESORT fallback when the LV is mounted outside
  # a workspace context (which shouldn't happen post-Phase-9). The
  # primary path reads the caller's `current_workspace_uri` from
  # socket assigns and uses its workspace segment.
  @fallback_workspace_name "default"

  @impl true
  def mount(_params, _session, socket) do
    flavors = list_flavors()
    default_flavor = if "cc" in flavors, do: "cc", else: List.first(flavors) || "cc"

    {:ok,
     socket
     |> assign(:flavors, flavors)
     |> assign(:flavor, default_flavor)
     |> assign(:name, "")
     |> assign(:caps_str, "")
     |> assign(:cwd, "")
     |> assign(:with_pty?, false)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(:preview_uri, preview_uri(default_flavor, "", workspace_name(socket)))}
  end

  @impl true
  def handle_event("preview", %{"agent" => params}, socket) do
    flavor = Map.get(params, "flavor", socket.assigns.flavor)
    name = Map.get(params, "name", socket.assigns.name)
    caps_str = Map.get(params, "caps", socket.assigns.caps_str)
    cwd = Map.get(params, "cwd", socket.assigns.cwd)
    # Checkbox: present in params iff checked. Absent → false.
    with_pty? = parse_checkbox(Map.get(params, "with_pty"))

    {:noreply,
     socket
     |> assign(:flavor, flavor)
     |> assign(:name, name)
     |> assign(:caps_str, caps_str)
     |> assign(:cwd, cwd)
     |> assign(:with_pty?, with_pty?)
     |> assign(:preview_uri, preview_uri(flavor, name, workspace_name(socket)))}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    flavor = Map.get(params, "flavor", "") |> String.trim()
    name = Map.get(params, "name", "") |> String.trim()
    caps_str = Map.get(params, "caps", "") |> String.trim()
    cwd = Map.get(params, "cwd", "") |> String.trim()
    with_pty? = parse_checkbox(Map.get(params, "with_pty"))

    workspace_name = workspace_name(socket)
    workspace_uri = URI.new!("workspace://#{workspace_name}")
    caller_ctx = %{caller: caller_uri(socket), caps: caller_caps(socket)}

    # SPEC 2026-05-25-agent-create-cli-gui-parity — the LV keeps its
    # UX-facing validators for early form feedback; the dispatched
    # action body re-runs them as a safety net. CLI ↔ LV parity is
    # locked by `Ezagent.Workspace.create_agent/3` being the single
    # entry both surfaces call.
    with :ok <- validate_flavor(flavor, socket.assigns.flavors),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         {:ok, caps} <- Capability.Parser.parse(caps_str, caller_uri(socket)),
         {:ok, %{agent_uri: agent_uri}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
             caller_ctx
           ),
         :ok <- Ezagent.Workspace.grant_initial_caps(agent_uri, caps, caller_ctx) do
      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:noreply, push_navigate(socket, to: "/identities/agents/#{encoded}")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:flash_error, friendly_error(reason))
         |> assign(:flash_info, nil)
         |> assign(:flavor, flavor)
         |> assign(:name, name)
         |> assign(:caps_str, caps_str)
         |> assign(:cwd, cwd)
         |> assign(:with_pty?, with_pty?)
         |> assign(:preview_uri, preview_uri(flavor, name, workspace_name))}
    end
  end

  # Phoenix form quirk: an unchecked checkbox sends NO param. To
  # distinguish "unchecked" from "field absent on partial change", a
  # hidden `name="agent[with_pty]" value="false"` sits before the
  # checkbox in the template (HTML form-data convention). The
  # checkbox itself sends `value="true"` when checked, which wins via
  # last-write in the params map.
  defp parse_checkbox(v) when v in ["true", "on", true], do: true
  defp parse_checkbox(_), do: false

  # ── helpers ────────────────────────────────────────────────────────

  # G-8 fix — validate against the LIVE flavor list (from socket assigns)
  # rather than a compile-time constant, so a newly-installed flavor
  # plugin is accepted on the next mount without a recompile.
  defp validate_flavor("", _), do: {:error, :flavor_required}

  defp validate_flavor(f, flavors) when is_list(flavors) do
    if f in flavors, do: :ok, else: {:error, {:bad_flavor, f}}
  end

  defp validate_name(""), do: {:error, :name_required}

  defp validate_name(name) do
    # Names are part of a URI path segment; restrict to a safe set so
    # we don't have to URL-encode the path on display. Matches the
    # informal convention used in seed data (`echo_default`,
    # `cc_demo-builder`) — alnum + dash + underscore.
    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_\-]*\z/ do
      :ok
    else
      {:error, {:bad_name, name}}
    end
  end

  # cc always needs a cwd (claude runs there). echo needs a cwd only
  # when the operator checked "With PTY" (the optional PTY runs
  # `/bin/bash -i` there per `Ezagent.PluginEcho.Template.EchoAgent`).
  # curl never needs a cwd.
  defp validate_cwd_for_flavor("cc", _with_pty?, ""), do: {:error, :cwd_required_for_cc}
  defp validate_cwd_for_flavor("cc", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("echo", true, ""), do: {:error, :cwd_required_for_echo_with_pty}
  defp validate_cwd_for_flavor("echo", true, cwd), do: validate_cwd_dir(cwd)
  defp validate_cwd_for_flavor("echo", false, _cwd), do: :ok

  defp validate_cwd_for_flavor("curl", _with_pty?, _cwd), do: :ok
  defp validate_cwd_for_flavor(_, _, _), do: :ok

  defp validate_cwd_dir(cwd) do
    expanded = Path.expand(cwd)

    cond do
      not File.dir?(expanded) -> {:error, {:cwd_not_a_dir, cwd}}
      true -> :ok
    end
  end

  # SPEC 2026-05-25-agent-create-cli-gui-parity (impl PR): the per-flavor
  # `register_and_instantiate/3` clauses (cc / echo / direct-spawn)
  # were DELETED from this LV. The orchestration lives inside
  # `Ezagent.Behavior.Workspace.invoke(:create_agent, ...)` — CLI + LV
  # both dispatch the SAME action, single code path.
  #
  # Helpers also moved into the action body: `compose_uri/3`,
  # `refuse_if_exists/1`, `agent_name/1`. `grant_all/3` moved into
  # `Ezagent.Workspace.grant_initial_caps/3`. The LV keeps only the
  # form-facing validators (`validate_flavor/2`, `validate_name/1`,
  # `validate_cwd_for_flavor/3`) for early UX feedback; the action
  # body re-runs them as a safety net.

  defp preview_uri(flavor, name, workspace_name)
       when is_binary(flavor) and is_binary(name) and is_binary(workspace_name) do
    cond do
      flavor == "" or name == "" -> "entity://agent/#{workspace_name}/<flavor>_<name>"
      true -> "entity://agent/#{workspace_name}/#{flavor}_#{name}"
    end
  end

  # V-6 fix — extract workspace name from socket's
  # `current_workspace_uri`. Falls back to `@fallback_workspace_name`
  # if the assign is missing (LV mounted outside a workspace context —
  # shouldn't happen post-Phase-9 but kept as belt-and-suspenders).
  defp workspace_name(socket) do
    case Map.get(socket.assigns, :current_workspace_uri) do
      %URI{scheme: "workspace", path: nil, host: name} when is_binary(name) and name != "" ->
        name

      uri_str when is_binary(uri_str) ->
        case URI.new(uri_str) do
          {:ok, %URI{scheme: "workspace", host: name}} when is_binary(name) and name != "" ->
            name

          _ ->
            @fallback_workspace_name
        end

      _ ->
        @fallback_workspace_name
    end
  end

  defp caller_uri(socket) do
    # Plumbed by EzagentWeb.LiveAuth.on_mount(:require_entity); falls
    # back to admin only if upstream auth broke (which would already
    # have redirected pre-mount, so this is belt-and-suspenders).
    Map.get(socket.assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()
  end

  defp caller_caps(socket) do
    caller = caller_uri(socket)

    if URI.to_string(caller) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
      Ezagent.Entity.User.admin_caps()
    else
      Ezagent.Identity.list_caps_for(caller)
    end
  end

  defp friendly_error(:flavor_required), do: gettext("Flavor is required.")
  defp friendly_error(:name_required), do: gettext("Name is required.")

  defp friendly_error({:bad_flavor, f}),
    do:
      gettext("Unknown flavor: %{flavor}. Choose one of: %{available}.",
        flavor: inspect(f),
        available: Enum.join(list_flavors(), " / ")
      )

  defp friendly_error({:bad_name, n}),
    do:
      gettext(
        "Name %{name} must start with a letter or digit and contain only letters, digits, '-', or '_'.",
        name: inspect(n)
      )

  defp friendly_error({:bad_uri, s}),
    do: gettext("Cannot build URI from inputs (got %{uri}).", uri: s)

  defp friendly_error({:already_exists, uri}),
    do: gettext("An agent already exists at %{uri}. Pick a different name.", uri: uri)

  defp friendly_error({:grant_failed, cap, reason}),
    do:
      gettext("Agent created but cap grant failed for %{cap}: %{reason}",
        cap: inspect(cap),
        reason: inspect(reason)
      )

  defp friendly_error(:cwd_required_for_cc),
    do: gettext("Working directory is required for cc agents (claude-code runs there).")

  defp friendly_error(:cwd_required_for_echo_with_pty),
    do:
      gettext(
        "Working directory is required when an echo agent is created with PTY (/bin/bash -i runs there)."
      )

  defp friendly_error({:cwd_not_a_dir, cwd}),
    do: gettext("Working directory %{cwd} doesn't exist or isn't a directory.", cwd: inspect(cwd))

  defp friendly_error({:template_register_failed, reason}),
    do: gettext("cc.agent template registration failed: %{reason}", reason: inspect(reason))

  defp friendly_error({:spawn_failed, reason}),
    do: gettext("Agent spawn failed: %{reason}", reason: inspect(reason))

  defp friendly_error({:bad_workspace_uri, uri}),
    do: gettext("Workspace URI was unrecognized (got %{uri}).", uri: inspect(uri))

  defp friendly_error(:unauthorized),
    do: gettext("You don't have permission to create agents in this workspace.")

  defp friendly_error(other),
    do: gettext("Create failed: %{reason}", reason: inspect(other))

  # ── render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin")
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/identities"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.breadcrumb items={[
                {gettext("Identities"), "/identities"},
                {gettext("New agent"), nil}
              ]} />

              <.page_header title={gettext("New agent")}>
                <:subtitle>
                  {gettext(
                    "Spawns a new Agent Kind into the registry. Same backend as %{cmd}.",
                    cmd: "mix ezagent.agent.create"
                  )}
                </:subtitle>
              </.page_header>

              <p :if={@flash_info} class="text-emerald-700 dark:text-emerald-300 text-sm mb-3">
                {@flash_info}
              </p>
              <p
                :if={@flash_error}
                class="text-red-700 dark:text-red-300 text-sm mb-3"
                id="flash-error"
              >
                {@flash_error}
              </p>

              <.card class="max-w-2xl">
                <form
                  id="agent-new-form"
                  phx-change="preview"
                  phx-submit="create_agent"
                  class="flex flex-col gap-4"
                >
                  <label class="flex flex-col gap-1">
                    <span class="text-xs uppercase tracking-wide text-zinc-500">
                      {gettext("Flavor")}
                    </span>
                    <select
                      name="agent[flavor]"
                      class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    >
                      <option :for={f <- @flavors} value={f} selected={f == @flavor}>{f}</option>
                    </select>
                    <span class="text-[11px] text-zinc-500">
                      {gettext(
                        "Which plugin runs this agent. Available flavors come from Ezagent.AgentFlavorRegistry; new flavor plugins auto-appear here."
                      )}
                    </span>
                  </label>

                  <label class="flex flex-col gap-1">
                    <span class="text-xs uppercase tracking-wide text-zinc-500">
                      {gettext("Name")}
                    </span>
                    <input
                      type="text"
                      name="agent[name]"
                      value={@name}
                      placeholder="demo"
                      autocomplete="off"
                      class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-mono"
                    />
                    <span class="text-[11px] text-zinc-500">
                      {gettext("Creates")}
                      <code class="font-mono text-zinc-700 dark:text-zinc-300">{@preview_uri}</code>
                    </span>
                  </label>

                  <%!--
                Domain.Pty SPEC v1 §10 row 3 + §11 item 6 — echo agents
                can opt into a /bin/bash -i PTY sidecar via the
                `echo.agent` Template Class. The hidden `false` input
                below the checkbox is the standard HTML form-data
                pattern so an unchecked box still submits a "false"
                value (Phoenix would otherwise drop the key entirely
                and our parse_checkbox/1 would default to false anyway
                — but explicit is clearer and matches the change-event
                payload shape between checked → unchecked transitions).
              --%>
                  <label :if={@flavor == "echo"} class="flex items-center gap-2" id="with-pty-row">
                    <input type="hidden" name="agent[with_pty]" value="false" />
                    <input
                      type="checkbox"
                      id="agent_with_pty"
                      name="agent[with_pty]"
                      value="true"
                      checked={@with_pty?}
                      class="h-4 w-4 rounded border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-emerald-600 dark:text-emerald-400 focus:ring-emerald-500 dark:focus:ring-emerald-400"
                    />
                    <span class="text-sm text-zinc-700 dark:text-zinc-300">
                      {gettext(
                        "With local PTY — echo agent gets a /bin/bash -i sidecar so it shows up in the Sessions Terminal tab + at /identities/agents/<uri>/terminal."
                      )}
                    </span>
                  </label>

                  <label
                    :if={@flavor == "cc" or (@flavor == "echo" and @with_pty?)}
                    class="flex flex-col gap-1"
                  >
                    <span class="text-xs uppercase tracking-wide text-zinc-500">
                      {gettext("Working directory")}
                      <span class="text-red-600 dark:text-red-400">*</span>
                    </span>
                    <input
                      type="text"
                      name="agent[cwd]"
                      value={@cwd}
                      placeholder={
                        if @flavor == "echo",
                          do: "/tmp/echo-sandbox",
                          else: "/Users/you/Workspace/my-project"
                      }
                      autocomplete="off"
                      class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-mono"
                    />
                    <span :if={@flavor == "cc"} class="text-[11px] text-zinc-500">
                      {gettext(
                        "Where claude-code runs. Required for cc flavor — the PtyServer starts in this directory. Must exist on the host. Registers a cc.agent template in workspace default so the agent boots ready-to-use."
                      )}
                    </span>
                    <span :if={@flavor == "echo" and @with_pty?} class="text-[11px] text-zinc-500">
                      {gettext(
                        "Where the echo agent's /bin/bash -i sidecar runs. Required because the operator selected With local PTY. Must exist on the host."
                      )}
                    </span>
                  </label>

                  <label class="flex flex-col gap-1">
                    <span class="text-xs uppercase tracking-wide text-zinc-500">
                      {gettext("Initial caps")}
                    </span>
                    <input
                      type="text"
                      name="agent[caps]"
                      value={@caps_str}
                      placeholder="chat.send, workspace.read"
                      autocomplete="off"
                      class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-mono"
                    />
                    <span class="text-[11px] text-zinc-500">
                      {gettext(
                        "Comma-separated kind.behavior specs (Ezagent.Capability.Parser). Leave empty to create with no caps and grant them later."
                      )}
                    </span>
                  </label>

                  <div class="flex justify-end gap-2 pt-2 border-t border-zinc-200 dark:border-zinc-800">
                    <.button variant="ghost" type="button" phx-click={JS.navigate("/identities")}>
                      {gettext("Cancel")}
                    </.button>
                    <.button variant="primary" type="submit">{gettext("Create agent")}</.button>
                  </div>
                </form>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
