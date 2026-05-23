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

  alias Ezagent.{AgentFlavorRegistry, Capability, Invocation, KindRegistry}
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

    with :ok <- validate_flavor(flavor, socket.assigns.flavors),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         {:ok, agent_uri} <- compose_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, caps} <- Capability.Parser.parse(caps_str, caller_uri(socket)),
         :ok <-
           register_and_instantiate(flavor, agent_uri, %{
             cwd: cwd,
             with_pty?: with_pty?,
             workspace_name: workspace_name
           }),
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

  # V1 fix Allen 2026-05-21 — template instantiate PRODUCES the Kind.
  # For cc: register the cc.agent template; the chain
  # `Workspace.add_template → invoke_template → cc.agent.instantiate`
  # ensures BOTH the Agent Kind AND the PtyServer are alive when this
  # returns. NO pre-spawn via `SpawnRegistry.spawn/1` — that path is
  # what the V1 fix removed (it created the Kind out-of-order, leaving
  # cc.agent.instantiate to spawn only the PtyServer).
  #
  # V-6 fix (audit 2026-05-23) — `workspace_name` now derived from the
  # caller's `current_workspace_uri` instead of the hardcoded "default".
  defp register_and_instantiate("cc", agent_uri, %{cwd: cwd, workspace_name: workspace_name}) do
    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => Path.expand(cwd)
    }

    case Ezagent.Workspace.add_template(workspace_name, tmpl_name, tmpl) do
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
  defp register_and_instantiate("echo", agent_uri, %{
         cwd: cwd,
         with_pty?: with_pty?,
         workspace_name: workspace_name
       }) do
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

    case Ezagent.Workspace.add_template(workspace_name, tmpl_name, tmpl) do
      :ok -> :ok
      {:error, reason} -> {:error, {:template_register_failed, reason}}
    end
  end

  # G-8 follow-on — any flavor NOT in this LV's hardcoded handler list
  # (curl, np, future) goes through direct `SpawnRegistry.spawn/1`. The
  # AgentFlavorRegistry guarantees the URI parses + the kind module is
  # registered; SpawnRegistry handles the per-flavor spawn. This is the
  # generic path that lets a future flavor plugin work without LV edits.
  # `{:already_started, _}` is treated as success — `refuse_if_exists/1`
  # upstream already rejected duplicates against a stale registry view;
  # this guards against a tight race.
  defp register_and_instantiate(_flavor, agent_uri, _params) do
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

  # V-6 fix — `workspace_name` threaded from the caller's
  # `current_workspace_uri`. The URI segment per SPEC v3 §3 is
  # `entity://agent/<workspace>/<flavor>_<name>`.
  defp compose_uri(flavor, name, workspace_name) do
    full = "entity://agent/#{workspace_name}/#{flavor}_#{name}"

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
    do:
      gettext("Working directory %{cwd} doesn't exist or isn't a directory.", cwd: inspect(cwd))

  defp friendly_error({:template_register_failed, reason}),
    do: gettext("cc.agent template registration failed: %{reason}", reason: inspect(reason))

  defp friendly_error({:spawn_failed, reason}),
    do: gettext("Agent spawn failed: %{reason}", reason: inspect(reason))

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
          <.breadcrumb items={[{gettext("Identities"), "/identities"}, {gettext("New agent"), nil}]} />

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
                <span class="text-xs uppercase tracking-wide text-zinc-500">{gettext("Flavor")}</span>
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
                <span class="text-xs uppercase tracking-wide text-zinc-500">{gettext("Name")}</span>
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
                  {gettext("Working directory")} <span class="text-red-600 dark:text-red-400">*</span>
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
                <span class="text-xs uppercase tracking-wide text-zinc-500">{gettext("Initial caps")}</span>
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
