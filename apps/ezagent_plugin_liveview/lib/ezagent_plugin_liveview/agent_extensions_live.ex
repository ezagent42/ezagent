defmodule EzagentPluginLiveview.AgentExtensionsLive do
  @moduledoc """
  PR3 2026-05-24 (Allen) — plugin-agnostic per-agent extension
  management page at `/identities/agents/:uri/extensions`.

  ## Architecture

  This LV knows NOTHING about Claude Code plugins / skills / MCP
  servers / hooks. It dispatches via:

      1. `Ezagent.AgentFlavorRegistry.lookup(flavor)` → `template_class`
      2. `sandbox.read` dispatch on agent_uri → `config_dir_path`
      3. `template_class.list_extensions(config_dir_path)` → `[%{id, name, description, enabled?}]`
      4. operator clicks toggle → `template_class.toggle_extension(config_dir_path, ext_id, enabled?)`

  The LV is the OPERATOR SURFACE for `Ezagent.Kind.Template`'s 3
  extension callbacks (PR2 contract; PR3 cc implementation). Future
  plugin types (Codex, Curl, ...) implementing the same 3 callbacks
  get this UI for free.

  ## URL shape

  `/identities/agents/:uri/extensions` — `:uri` is URL-encoded
  `entity://agent/<workspace>/<flavor>_<name>` (mirrors `AgentDetailLive`).

  ## What an extension means

  Plugin-neutral term. cc plugin implements it as Claude Code
  "plugins" (Anthropic terminology — bundles of skills, agents,
  commands, MCP servers, hooks under `<config_dir>/.claude/plugins/`).
  A future Codex plugin could implement it as prompt snippets, etc.
  """

  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias Ezagent.AgentFlavorRegistry
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(%{"uri" => encoded_uri}, _session, socket) do
    # Codex PR3 round-1 CRITICAL — use the AUTHENTICATED caller's
    # identity + caps for dispatch (NOT admin_caps). The admin_live
    # session pipeline puts `current_entity_uri` on socket.assigns;
    # caps come from `Ezagent.Identity.list_caps_for/1` (mirrors the
    # pattern in admin_live.ex:105-112).
    caller_uri = Map.get(socket.assigns, :current_entity_uri)

    caller_caps = resolve_caller_caps(caller_uri)

    case parse_agent_uri(encoded_uri) do
      {:ok, agent_uri} ->
        case resolve_template_class(agent_uri) do
          {:ok, template_class} ->
            socket =
              socket
              |> assign(:not_found, false)
              |> assign(:agent_uri, agent_uri)
              |> assign(:template_class, template_class)
              |> assign(:caller_uri, caller_uri)
              |> assign(:caller_caps, caller_caps)
              |> assign(:flash, nil)
              |> load_extensions()

            {:ok, socket}

          {:error, reason} ->
            {:ok,
             socket
             |> assign(:not_found, true)
             |> assign(:agent_uri, agent_uri)
             |> assign(:bad_reason, reason)}
        end

      :error ->
        {:ok,
         socket
         |> assign(:not_found, true)
         |> assign(:bad_uri, encoded_uri)}
    end
  end

  # Mirror of admin_live.ex:107-112 — admin entity gets admin_caps,
  # everyone else gets their actual identity caps. Falls back to
  # admin_uri when current_entity_uri is missing (only happens during
  # unauthenticated probes — the LV won't render anyway since the
  # outer pipeline rejects).
  defp resolve_caller_caps(nil), do: Ezagent.Entity.User.admin_caps()

  defp resolve_caller_caps(caller_uri) do
    if URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
      Ezagent.Entity.User.admin_caps()
    else
      Ezagent.Identity.list_caps_for(caller_uri)
    end
  end

  # Mirror `AgentDetailLive.parse_agent_uri/1` — entity://agent/<ws>/<flavor>_<name>.
  defp parse_agent_uri(encoded) do
    decoded = URI.decode_www_form(encoded)

    case URI.new(decoded) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest} = uri}
      when is_binary(rest) and rest != "" ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  # Extract flavor from `entity://agent/<workspace>/<flavor>_<name>`
  # (Phase 9 PR-2 URI shape) → look up Template Class via
  # `AgentFlavorRegistry`.
  defp resolve_template_class(%URI{path: "/" <> rest}) do
    with [_workspace, entity_name] <- String.split(rest, "/", parts: 2),
         [flavor, _suffix] <- String.split(entity_name, "_", parts: 2),
         {:ok, %{template_class: tc}} <- AgentFlavorRegistry.lookup(flavor) do
      {:ok, tc}
    else
      :error -> {:error, :unknown_flavor}
      _ -> {:error, :bad_agent_uri}
    end
  end

  defp resolve_template_class(_), do: {:error, :bad_agent_uri}

  # Dispatch `sandbox.read` to fetch the agent's `:sandbox` slice
  # (config_dir_path + template_class), then call `list_extensions/1`
  # on the resolved Template Class. Failures are surfaced as flash
  # messages so the operator sees what went wrong.
  defp load_extensions(socket) do
    template_class = socket.assigns.template_class

    case sandbox_read(socket) do
      {:ok, %{config_dir_path: nil}} ->
        socket
        |> assign(:config_dir_path, nil)
        |> assign(:extensions, [])
        |> assign(:flash, {:info, "Agent has no per-agent config dir — extensions unavailable."})

      {:ok, %{config_dir_path: dir}} when is_binary(dir) ->
        case template_class.list_extensions(dir) do
          {:ok, exts} ->
            socket
            |> assign(:config_dir_path, dir)
            |> assign(:extensions, exts)
            |> assign(:flash, nil)

          {:error, reason} ->
            socket
            |> assign(:config_dir_path, dir)
            |> assign(:extensions, [])
            |> assign(:flash, {:error, "Failed to list extensions: #{inspect(reason)}"})
        end

      {:error, :destroyed} ->
        socket
        |> assign(:config_dir_path, nil)
        |> assign(:extensions, [])
        |> assign(
          :flash,
          {:error, "Agent has been destroyed — extensions no longer available."}
        )

      {:error, reason} ->
        socket
        |> assign(:config_dir_path, nil)
        |> assign(:extensions, [])
        |> assign(:flash, {:error, "Could not read sandbox slice: #{inspect(reason)}"})
    end
  end

  defp sandbox_read(socket) do
    agent_uri = socket.assigns.agent_uri
    caller_uri = socket.assigns.caller_uri
    caller_caps = socket.assigns.caller_caps

    target = URI.parse("#{URI.to_string(agent_uri)}?action=sandbox.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: caller_uri || Ezagent.Entity.User.admin_uri(),
             caps: caller_caps,
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_sandbox_read, other}}
    end
  end

  @impl true
  def handle_event("toggle", %{"id" => ext_id, "enabled" => enabled_str}, socket) do
    enabled? = enabled_str == "true"
    config_dir = socket.assigns.config_dir_path
    template_class = socket.assigns.template_class

    cond do
      is_nil(config_dir) ->
        {:noreply,
         assign(socket, :flash, {:error, "No config dir — cannot toggle extensions."})}

      # Codex PR3 round-1 CRITICAL — pre-check that the caller's caps
      # authorize a write on this agent's sandbox slice. Mutation
      # otherwise had no CapBAC gate at all (direct template_class
      # function call). The cap we need is :write_path on Sandbox
      # (the SAME cap the spawn orchestrator used to populate the
      # slice); same workspace as the agent.
      not authorized_to_toggle?(socket) ->
        {:noreply,
         assign(
           socket,
           :flash,
           {:error,
            "Unauthorized: you need Sandbox :write_path cap on this agent's workspace " <>
              "to toggle extensions."}
         )}

      true ->
        case template_class.toggle_extension(config_dir, ext_id, enabled?) do
          :ok ->
            {:noreply,
             socket
             |> assign(:flash, {:info, "Extension #{ext_id} toggled."})
             |> load_extensions()}

          {:error, :install_from_source_not_implemented} ->
            {:noreply,
             assign(
               socket,
               :flash,
               {:error,
                "Install from source not implemented yet (marketplace integration TBD). " <>
                  "Operator can manually copy a plugin bundle into the config dir."}
             )}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash,
               {:error, "Toggle failed: #{inspect(reason)}"}
             )}
        end
    end
  end

  # CapBAC pre-check for the toggle mutation path. Builds the same
  # cap shape `Ezagent.Capability.cap_for_action/3` would derive for
  # `Sandbox :write_path` on the agent URI, then checks the caller's
  # caps via `Capability.matches?/2`.
  defp authorized_to_toggle?(socket) do
    caller_caps = socket.assigns.caller_caps
    agent_uri = socket.assigns.agent_uri
    workspace_uri = Ezagent.Capability.workspace_of(agent_uri)

    needed = %{
      kind: :agent,
      behavior: Ezagent.Behavior.Sandbox,
      instance: agent_uri,
      workspace_uri: workspace_uri
    }

    caller_caps
    |> normalize_caps()
    |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
  end

  defp normalize_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_caps(caps) when is_list(caps), do: caps
  defp normalize_caps(_), do: []

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold">Agent not found</h1>
      <p :if={assigns[:bad_uri]}>
        Could not parse agent URI: <code>{@bad_uri}</code>
      </p>
      <p :if={assigns[:bad_reason]}>
        Reason: <code>{inspect(@bad_reason)}</code>
      </p>
      <p :if={assigns[:agent_uri]}>
        <a
          href={"/identities/agents/#{URI.encode_www_form(URI.to_string(@agent_uri))}"}
          class="underline"
        >
          Back to agent detail
        </a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-4">
      <div>
        <h1 class="text-2xl font-bold">Agent Extensions</h1>
        <p class="text-sm text-gray-600">
          Per-agent config dir:
          <code>{@config_dir_path || "(none)"}</code>
        </p>
        <p class="text-sm text-gray-600">
          Template Class: <code>{inspect(@template_class)}</code>
        </p>
        <p>
          <a
            href={"/identities/agents/#{URI.encode_www_form(URI.to_string(@agent_uri))}"}
            class="underline"
          >
            Back to agent detail
          </a>
        </p>
      </div>

      <div :if={@flash} class="p-3 rounded border">
        <p :if={match?({:info, _}, @flash)} class="text-blue-700">
          {flash_text(@flash)}
        </p>
        <p :if={match?({:error, _}, @flash)} class="text-red-700">
          {flash_text(@flash)}
        </p>
      </div>

      <div :if={@extensions == []} class="p-4 border rounded bg-gray-50">
        <p class="text-gray-700">No extensions installed.</p>
        <p class="text-sm text-gray-500 mt-2">
          Extensions live under
          <code>{@config_dir_path || "<config_dir>"}/.claude/plugins/</code>.
          Drop a plugin bundle (<code>.claude-plugin/plugin.json</code> manifest) there
          and it will appear here.
        </p>
      </div>

      <ul :if={@extensions != []} class="space-y-2">
        <li :for={ext <- @extensions} class="p-3 border rounded">
          <div class="flex items-start justify-between">
            <div class="flex-1">
              <div class="font-medium">{ext.name}</div>
              <div class="text-sm text-gray-600">{ext.description}</div>
              <div class="text-xs text-gray-400 mt-1"><code>{ext.id}</code></div>
            </div>
            <div class="ml-4">
              <button
                type="button"
                phx-click="toggle"
                phx-value-id={ext.id}
                phx-value-enabled={to_string(not ext.enabled?)}
                class={toggle_button_class(ext.enabled?)}
              >
                {toggle_button_text(ext.enabled?)}
              </button>
            </div>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  defp flash_text({_kind, msg}), do: msg
  defp flash_text(_), do: ""

  defp toggle_button_class(true), do: "px-3 py-1 rounded text-sm bg-green-100 text-green-800"
  defp toggle_button_class(false), do: "px-3 py-1 rounded text-sm bg-gray-100 text-gray-800"

  defp toggle_button_text(true), do: "Enabled — click to remove"
  defp toggle_button_text(false), do: "Disabled — click to install"
end
