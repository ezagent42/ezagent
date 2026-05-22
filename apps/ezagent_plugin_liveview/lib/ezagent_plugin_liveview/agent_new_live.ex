defmodule EzagentPluginLiveview.AgentNewLive do
  @moduledoc """
  Phase 8c PR-N (Allen 2026-05-20) — UI for creating new agents.

  Mounts at `/identities/agents/new`. Form fields:

  - **flavor** — dropdown over the built-in agent flavors
    (`cc / curl / echo`, matching `kind_module_from_flavor/1` in
    `EzagentDomainChat.Application`). Hard-coded for v1; future work
    can derive this list from `Ezagent.SpawnRegistry` once flavor
    registration becomes data-driven.
  - **name** — short identifier; UI composes the full URI
    `entity://agent/<flavor>_<name>`. A live preview line shows the
    composed URI as the user types (phx-change "preview").
  - **caps** — comma-separated cap specs in the
    `Ezagent.Capability.Parser` grammar (e.g. `chat.send, workspace.read`).
    Empty is fine — agents can be created with no caps and have caps
    granted later via `/identities/agents/<uri>/caps`.

  Submit (`create_agent`) follows the **template-produces-Kind**
  architecture (Allen 2026-05-21 V1 fix):

  1. Parse flavor + name → build `%URI{}`
  2. Validate name (non-empty, no `_` collision with flavor prefix)
  3. Refuse if the URI already exists in `KindRegistry` (no
     misleading "Create" on a noop — per memory
     `feedback_ui_no_misleading_buttons`)
  4. Parse caps via `Ezagent.Capability.Parser.parse/3`
  5. `register_and_instantiate/3` — for `cc`, registers the
     `cc.agent` template which chains through
     `Workspace.add_template → invoke_template → cc.agent.instantiate`
     and BOTH the Agent Kind AND the PtyServer come up. For
     `echo`, registers the `echo.agent` template (Domain.Pty SPEC
     v1 §10 row 3 / §11 item 6 — deferred PR-D sub-task, now in
     scope per Allen Feishu 2026-05-22); the same chain runs and
     a PtyServer is started iff the operator checked "With PTY".
     For `curl` (no template-driven per-instance lifecycle resource)
     we call `Ezagent.SpawnRegistry.spawn/1` directly.
  6. For each parsed cap: dispatch `identity.grant_cap` (same path as
     `EntityCapsLive`)
  7. `push_navigate(to: /identities/agents/<encoded>)`

  ### Why echo gets a template class now (was direct-spawn pre-2026-05-22)

  Pre Domain.Pty SPEC v1: echo had no per-instance lifecycle
  resource (no PTY, no token, no cwd), so direct
  `SpawnRegistry.spawn/1` was the clearer V1 choice. SPEC v1 §4
  introduced cross-flavor PTY opt-in: any plugin can attach a
  `Ezagent.Domain.Pty.Server` sidecar by branching in its template's
  `instantiate/3`. Echo's `echo.agent` template implements that
  branch — `with_pty: false` (default) spawns the Kind alone (same
  end state as the old direct path); `with_pty: true` ALSO starts a
  `/bin/bash -i` PtyServer so the agent shows up in the SessionView
  Terminal tab + `/identities/agents/:uri/terminal` standalone page.

  ### Why curl still goes direct

  curl agents have no PTY (HTTP only) and no working directory —
  per-instance state lives entirely in the owner User's `api_keys`
  slice. A minimal template class would be empty boilerplate.

  Wraps in `IdeShell.ide_shell` (workspace surface — agent creation
  is workflow, not config).
  """
  use Phoenix.LiveView
  alias EzagentDomainUi.IdeShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.{Capability, Invocation, KindRegistry}
  alias Phoenix.LiveView.JS

  # Flavors mirror `kind_module_from_flavor/1` in
  # `EzagentDomainChat.Application` (PR #149 §5.14). Order is
  # creation-frequency-descending: cc is the common case (Claude-Code
  # orchestrated agent), echo is the testing fixture, curl is the
  # external-HTTP variant.
  @flavors ~w(cc echo curl)

  # Phase 8c follow-up (Allen 2026-05-20) — cc agents need a PtyServer to
  # actually exec claude-code. PtyServer is started when a workspace's
  # `cc.agent` template references the agent_uri. Until this step exists,
  # AgentNewLive only created an identity skeleton ("Not running" forever).
  # We now also register the template inline as part of create_agent so a
  # fresh cc agent boots ready-to-use.
  #
  # Workspace target: hardcoded "default" for now. Per the
  # workspace=deployment-unit doc, current-workspace context is a Phase 9
  # concern; once it's a server-side concept this code reads from socket.
  @default_workspace_name "default"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:flavors, @flavors)
     |> assign(:flavor, "cc")
     |> assign(:name, "")
     |> assign(:caps_str, "")
     |> assign(:cwd, "")
     |> assign(:with_pty?, false)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(:preview_uri, preview_uri("cc", ""))}
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
     |> assign(:preview_uri, preview_uri(flavor, name))}
  end

  def handle_event("create_agent", %{"agent" => params}, socket) do
    flavor = Map.get(params, "flavor", "") |> String.trim()
    name = Map.get(params, "name", "") |> String.trim()
    caps_str = Map.get(params, "caps", "") |> String.trim()
    cwd = Map.get(params, "cwd", "") |> String.trim()
    with_pty? = parse_checkbox(Map.get(params, "with_pty"))

    with :ok <- validate_flavor(flavor),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         {:ok, agent_uri} <- compose_uri(flavor, name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, caps} <- Capability.Parser.parse(caps_str, caller_uri(socket)),
         :ok <- register_and_instantiate(flavor, agent_uri, %{cwd: cwd, with_pty?: with_pty?}),
         :ok <- grant_all(agent_uri, caps, socket) do
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
         |> assign(:preview_uri, preview_uri(flavor, name))}
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

  defp validate_flavor(f) when f in @flavors, do: :ok
  defp validate_flavor(""), do: {:error, :flavor_required}
  defp validate_flavor(f), do: {:error, {:bad_flavor, f}}

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

  # V1 fix Allen 2026-05-21 — template instantiate PRODUCES the Kind.
  # For cc: register the cc.agent template; the chain
  # `Workspace.add_template → invoke_template → cc.agent.instantiate`
  # ensures BOTH the Agent Kind AND the PtyServer are alive when this
  # returns. NO pre-spawn via `SpawnRegistry.spawn/1` — that path is
  # what the V1 fix removed (it created the Kind out-of-order, leaving
  # cc.agent.instantiate to spawn only the PtyServer).
  defp register_and_instantiate("cc", agent_uri, %{cwd: cwd}) do
    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => Path.expand(cwd)
    }

    case Ezagent.Workspace.add_template(@default_workspace_name, tmpl_name, tmpl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:template_register_failed, reason}}
    end
  end

  # Domain.Pty SPEC v1 §10 row 3 + §11 item 6 (deferred PR-D sub-task,
  # now in scope per Allen Feishu 2026-05-22): echo gets a Template
  # Class so the operator can opt into a `/bin/bash -i` PTY sidecar.
  # The chain `Workspace.add_template → invoke_template →
  # echo.agent.instantiate` ensures the Agent Kind AND (if
  # `with_pty: true`) the PtyServer are alive when this returns —
  # parallel to the cc.agent flow above.
  defp register_and_instantiate("echo", agent_uri, %{cwd: cwd, with_pty?: with_pty?}) do
    tmpl_name = "echo.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "echo.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "with_pty" => with_pty?,
      # Always write the cwd field; the template validator only
      # requires it when `with_pty: true`. Path.expand on "" is "" so
      # this round-trips safely for the no-PTY case.
      "cwd" => if(with_pty?, do: Path.expand(cwd), else: cwd)
    }

    case Ezagent.Workspace.add_template(@default_workspace_name, tmpl_name, tmpl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:template_register_failed, reason}}
    end
  end

  # curl has no per-instance lifecycle resource (no PTY, no cwd —
  # owner User's api_keys carries the auth). Direct spawn is the V1
  # path — see moduledoc for the rationale. `{:already_started, _}`
  # is treated as success because `refuse_if_exists/1` upstream
  # already rejected duplicates against a stale registry view; this
  # guards against a tight race.
  defp register_and_instantiate("curl", agent_uri, _params) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:spawn_failed, reason}}
    end
  end

  defp agent_name(%URI{path: "/" <> rest}) do
    # Phase 9 PR-2 (SPEC v3 §3): entity URI is /<workspace>/<entity_name>.
    case String.split(rest, "/", parts: 2) do
      [_workspace, entity_name] -> entity_name
      [name] -> name
    end
  end

  defp compose_uri(flavor, name) do
    full = "entity://agent/default/#{flavor}_#{name}"

    case URI.new(full) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> _} = u} -> {:ok, u}
      _ -> {:error, {:bad_uri, full}}
    end
  end

  defp refuse_if_exists(uri) do
    case KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> {:error, {:already_exists, URI.to_string(uri)}}
    end
  end

  defp preview_uri(flavor, name) when is_binary(flavor) and is_binary(name) do
    cond do
      flavor == "" or name == "" -> "entity://agent/<flavor>_<name>"
      true -> "entity://agent/default/#{flavor}_#{name}"
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

  defp grant_all(_agent_uri, [], _socket), do: :ok

  defp grant_all(agent_uri, [cap | rest], socket) do
    target =
      URI.new!("#{URI.to_string(agent_uri)}?action=identity.grant_cap")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: caller_uri(socket),
             caps: caller_caps(socket),
             reply: :sync
           }
         }) do
      {:ok, _} -> grant_all(agent_uri, rest, socket)
      {:error, reason} -> {:error, {:grant_failed, cap, reason}}
    end
  end

  defp friendly_error(:flavor_required), do: "Flavor is required."
  defp friendly_error(:name_required), do: "Name is required."

  defp friendly_error({:bad_flavor, f}),
    do: "Unknown flavor: #{inspect(f)}. Choose cc / echo / curl."

  defp friendly_error({:bad_name, n}),
    do:
      "Name #{inspect(n)} must start with a letter or digit and contain only letters, digits, '-', or '_'."

  defp friendly_error({:bad_uri, s}), do: "Cannot build URI from inputs (got #{s})."

  defp friendly_error({:already_exists, uri}),
    do: "An agent already exists at #{uri}. Pick a different name."

  defp friendly_error({:grant_failed, cap, reason}),
    do: "Agent created but cap grant failed for #{inspect(cap)}: #{inspect(reason)}"

  defp friendly_error(:cwd_required_for_cc),
    do: "Working directory is required for cc agents (claude-code runs there)."

  defp friendly_error(:cwd_required_for_echo_with_pty),
    do:
      "Working directory is required when an echo agent is created with PTY (/bin/bash -i runs there)."

  defp friendly_error({:cwd_not_a_dir, cwd}),
    do: "Working directory #{inspect(cwd)} doesn't exist or isn't a directory."

  defp friendly_error({:template_register_failed, reason}),
    do: "cc.agent template registration failed: #{inspect(reason)}"

  defp friendly_error({:spawn_failed, reason}),
    do: "Agent spawn failed: #{inspect(reason)}"

  defp friendly_error(other), do: "Create failed: #{inspect(other)}"

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
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/identities"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.breadcrumb items={[{"Identities", "/identities"}, {"New agent", nil}]} />

          <.page_header title="New agent">
            <:subtitle>
              Spawns a new Agent Kind into the registry. Same backend as <code>mix ezagent.agent.create</code>.
            </:subtitle>
          </.page_header>

          <p :if={@flash_info} class="text-emerald-700 dark:text-emerald-300 text-sm mb-3">
            {@flash_info}
          </p>
          <p :if={@flash_error} class="text-red-700 dark:text-red-300 text-sm mb-3" id="flash-error">
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
                <span class="text-xs uppercase tracking-wide text-zinc-500">Flavor</span>
                <select
                  name="agent[flavor]"
                  class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                >
                  <option :for={f <- @flavors} value={f} selected={f == @flavor}>{f}</option>
                </select>
                <span class="text-[11px] text-zinc-500">
                  Which plugin runs this agent. <code>cc</code>
                  = Claude-Code orchestrated; <code>echo</code>
                  = test fixture; <code>curl</code>
                  = external HTTP agent.
                </span>
              </label>

              <label class="flex flex-col gap-1">
                <span class="text-xs uppercase tracking-wide text-zinc-500">Name</span>
                <input
                  type="text"
                  name="agent[name]"
                  value={@name}
                  placeholder="demo"
                  autocomplete="off"
                  class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-mono"
                />
                <span class="text-[11px] text-zinc-500">
                  Creates
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
                  With local PTY — echo agent gets a <code>/bin/bash -i</code> sidecar so it
                  shows up in the Sessions Terminal tab + at <code>/identities/agents/&lt;uri&gt;/terminal</code>.
                </span>
              </label>

              <label
                :if={@flavor == "cc" or (@flavor == "echo" and @with_pty?)}
                class="flex flex-col gap-1"
              >
                <span class="text-xs uppercase tracking-wide text-zinc-500">
                  Working directory <span class="text-red-600 dark:text-red-400">*</span>
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
                  Where <code>claude-code</code>
                  runs. Required for <code>cc</code>
                  flavor
                  — the PtyServer starts in this directory. Must exist on the host.
                  Registers a <code>cc.agent</code>
                  template in workspace <code>default</code>
                  so the agent boots ready-to-use.
                </span>
                <span :if={@flavor == "echo" and @with_pty?} class="text-[11px] text-zinc-500">
                  Where the echo agent's <code>/bin/bash -i</code> sidecar runs. Required
                  because the operator selected <em>With local PTY</em>. Must exist on the host.
                </span>
              </label>

              <label class="flex flex-col gap-1">
                <span class="text-xs uppercase tracking-wide text-zinc-500">Initial caps</span>
                <input
                  type="text"
                  name="agent[caps]"
                  value={@caps_str}
                  placeholder="chat.send, workspace.read"
                  autocomplete="off"
                  class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-mono"
                />
                <span class="text-[11px] text-zinc-500">
                  Comma-separated <code>kind.behavior</code>
                  specs (<code>Ezagent.Capability.Parser</code>).
                  Leave empty to create with no caps and grant them later.
                </span>
              </label>

              <div class="flex justify-end gap-2 pt-2 border-t border-zinc-200 dark:border-zinc-800">
                <.button variant="ghost" type="button" phx-click={JS.navigate("/identities")}>
                  Cancel
                </.button>
                <.button variant="primary" type="submit">Create agent</.button>
              </div>
            </form>
          </.card>
        </div>
      </:main_window>

      <%!-- V1 UI PR-2b (SPEC §2.5) — CmdK command palette. The
            header search bar + ⌘K are global ide_shell chrome, so
            every ide_shell LV must render the palette (PR-2 wired it
            into admin_live only). Shared LiveComponent; `nav_routes`
            flows DOWN from `EzagentWeb.LiveAuth` `:cmdk_nav`. --%>
      <:command_palette>
        <.live_component
          module={EzagentPluginLiveview.CommandPaletteComponent}
          id="cmdk"
          nav_routes={@cmdk_nav_routes}
          current_entity_uri={@current_entity_uri}
          current_workspace_uri={@current_workspace_uri}
        />
      </:command_palette>
    </IdeShell.ide_shell>
    """
  end
end
