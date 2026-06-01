defmodule EzagentPluginLiveview.AgentApiKeysLive do
  @moduledoc """
  Per-agent API key management UI (Allen 2026-05-26 — moved from
  per-user post `Behavior.ApiKeys` flip to Agent Kind).

  Mount at `/identities/agents/:uri/api-keys`. URI is URL-encoded
  (`entity%3A%2F%2Fagent%2Fteam-alpha%2Fcurl_xxx`).

  Lists registered providers (masked) + lets the operator add /
  rotate / delete keys for any provider name. Keys land in
  `Ezagent.Behavior.ApiKeys` slice on the target Agent Kind via
  `Invocation.dispatch`.

  ## Permission

  - **Admin** (workspace admin / `system://bootstrap` wildcard holder)
    can edit any agent's keys.
  - **Agent creator** (the entity URI in the agent's `:api_keys`
    slice `:creator_uri` field) can edit this agent's keys. The
    creator field is populated at instantiate time by template
    paths that carry the caller (FUTURE — the SpawnRegistry-only
    direct-spawn path used today by curl/np leaves it `nil`, so
    until that's wired, only admin reaches edit on those agents).

  Cap enforcement is at dispatch step 5.5 — this LV merely shapes
  the dispatch args and surfaces a friendly "unauthorized" message
  for non-admin / non-creator callers.

  ## Plaintext display

  The full key is NEVER rendered after the operator submits — only
  the masked form (`sk-abcd...wxyz`) shows in the table. To rotate,
  type a new full key.
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  # V-4 scrub (audit 2026-05-23) — adopt the `<.card>`, `<.button>`,
  # `<.page_header>`, `<.badge>` atoms in render/1.
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.{Invocation, KindRegistry}

  @impl true
  def mount(%{"uri" => encoded}, _session, socket) do
    agent_uri = encoded |> URI.decode_www_form() |> Ezagent.URI.new!()
    caller_uri = socket.assigns.current_entity_uri

    # SPEC caps-cleanup-v1 §4.4 — admin caps now live in slice.
    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)
    creator_uri = lookup_creator_uri(agent_uri)

    {:ok,
     socket
     |> assign(:agent_uri, agent_uri)
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:creator_uri, creator_uri)
     |> assign(
       :creator?,
       creator_uri != nil and URI.to_string(caller_uri) == URI.to_string(creator_uri)
     )
     |> assign(
       :is_admin?,
       URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri())
     )
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(
       :form,
       to_form(%{"provider" => "deepseek", "key" => ""}, as: "api_key")
     )
     |> load_keys()}
  end

  # Allen 2026-05-26 — resolve creator via the same two-tier lookup
  # `Behavior.ApiKeys.data_owner/1` uses: slice `:creator_uri` first
  # (durable, set when instantiate threads it), then `AgentLineage`
  # ETS (post-spawn-recorded in `Behavior.Workspace.do_create_agent`).
  # This is what unsticks the codex HIGH-1 footgun where curl/np
  # creators couldn't see the edit form because the SpawnRegistry
  # path never threaded `creator_uri` into init args — the lineage
  # row is the in-VM fallback.
  defp lookup_creator_uri(%URI{} = agent_uri) do
    case Ezagent.Kind.get_slice(agent_uri, :api_keys) do
      {:ok, %{creator_uri: %URI{} = creator}} ->
        creator

      _ ->
        case Ezagent.AgentLineage.lookup(agent_uri) do
          {:ok, %URI{} = creator} -> creator
          _ -> nil
        end
    end
  end

  defp load_keys(socket) do
    case KindRegistry.lookup(socket.assigns.agent_uri) do
      :error ->
        assign(socket, :api_keys, :agent_not_live)

      {:ok, _pid} ->
        target =
          Ezagent.URI.with_action(socket.assigns.agent_uri, :identity, :list_api_keys)

        case Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{},
               ctx: %{
                 caller: socket.assigns.caller_uri,
                 caps: socket.assigns.caller_caps,
                 reply: :sync
               }
             }) do
          {:ok, %{api_keys: list}} -> assign(socket, :api_keys, list)
          {:error, reason} -> assign(socket, :api_keys, {:error, reason})
        end
    end
  rescue
    err -> assign(socket, :api_keys, {:error, err})
  end

  @impl true
  def handle_event("put", %{"api_key" => %{"provider" => provider, "key" => key}}, socket) do
    provider = String.trim(provider)
    key = String.trim(key)

    cond do
      not authorized?(socket) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("you must be the agent's creator or admin to edit its API keys")
         )}

      provider == "" ->
        {:noreply, assign(socket, :flash_error, gettext("provider required (e.g. `deepseek`)"))}

      key == "" ->
        {:noreply, assign(socket, :flash_error, gettext("key required"))}

      true ->
        dispatch(
          :put_api_key,
          socket,
          %{provider: provider, key: key},
          gettext("Saved key for `%{provider}`", provider: provider)
        )
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    if authorized?(socket) do
      dispatch(
        :delete_api_key,
        socket,
        %{provider: provider},
        gettext("Deleted key for `%{provider}`", provider: provider)
      )
    else
      {:noreply, assign(socket, :flash_error, gettext("unauthorized"))}
    end
  end

  defp authorized?(socket), do: socket.assigns.is_admin? or socket.assigns.creator?

  defp dispatch(action, socket, args, success_msg) do
    target = Ezagent.URI.with_action(socket.assigns.agent_uri, :identity, action)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: args,
           ctx: %{
             caller: socket.assigns.caller_uri,
             caps: socket.assigns.caller_caps,
             reply: :sync
           }
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:flash_info, success_msg)
         |> assign(:flash_error, nil)
         |> assign(:form, to_form(%{"provider" => "deepseek", "key" => ""}, as: "api_key"))
         |> load_keys()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:flash_error, gettext("dispatch failed: %{reason}", reason: inspect(reason)))
         |> assign(:flash_info, nil)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || Ezagent.URI.new!("entity://user/system/admin")
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/identities/agents"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("API Keys")}>
                <:subtitle>
                  <span class="font-mono text-xs">{URI.to_string(@agent_uri)}</span>
                  — {gettext(
                    "Per-agent secret storage for outbound LLM completion APIs (DeepSeek, OpenAI, etc.). The system itself holds no keys."
                  )}
                </:subtitle>
                <:actions>
                  <a
                    href="/identities/agents"
                    class="text-xs text-sky-700 dark:text-sky-300 hover:underline"
                  >
                    ← {gettext("Agents")}
                  </a>
                </:actions>
              </.page_header>

              <p
                :if={@flash_error}
                class="bg-rose-50 dark:bg-rose-950 text-rose-700 dark:text-rose-300 border border-rose-200 dark:border-rose-800 px-3 py-2 rounded-md text-sm mb-3"
              >
                {@flash_error}
              </p>
              <p
                :if={@flash_info}
                class="bg-emerald-50 dark:bg-emerald-950 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800 px-3 py-2 rounded-md text-sm mb-3"
              >
                {@flash_info}
              </p>

              <.card
                :if={@api_keys == :agent_not_live}
                class="mt-4 border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950"
              >
                <p class="text-sm text-amber-800 dark:text-amber-200">
                  {gettext(
                    "Agent Kind not currently live in KindRegistry. Trigger any dispatch on this URI to spawn it (e.g. invite it into a session), then return here."
                  )}
                </p>
              </.card>

              <.card
                :if={match?({:error, _}, @api_keys)}
                class="mt-4 border-rose-200 dark:border-rose-800 bg-rose-50 dark:bg-rose-950"
              >
                <p class="text-sm text-rose-700 dark:text-rose-300">
                  {gettext("Error loading keys:")}
                  <code class="font-mono text-xs">{inspect(elem(@api_keys, 1))}</code>
                </p>
              </.card>

              <.card :if={is_list(@api_keys)} class="mt-4" id="stored-keys">
                <:header>
                  {gettext("Stored keys (%{count})", count: length(@api_keys))}
                </:header>

                <p :if={@api_keys == []} class="text-sm text-zinc-500 italic">
                  {gettext("No API keys yet. Add one below to let this agent reach an upstream API.")}
                </p>

                <table :if={@api_keys != []} class="w-full text-xs border-collapse mt-2">
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">provider</th>
                      <th class="text-left">{gettext("masked")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={entry <- @api_keys}
                      class="border-b border-zinc-100 dark:border-zinc-900"
                    >
                      <td class="px-1 py-1 font-mono">{entry.provider}</td>
                      <td class="font-mono text-zinc-500">{entry.masked}</td>
                      <td class="text-right">
                        <.button
                          :if={@is_admin? or @creator?}
                          variant="outline"
                          size="sm"
                          phx-click="delete"
                          phx-value-provider={entry.provider}
                          class="text-xs px-2 py-0.5 h-auto text-rose-700 dark:text-rose-300 border-rose-300 dark:border-rose-700"
                        >
                          {gettext("Delete")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <.card :if={is_list(@api_keys)} class="mt-8" id="add-key-form">
                <:header>{gettext("Add / rotate key")}</:header>

                <p class="text-xs text-zinc-500 mb-3">
                  {gettext(
                    "Adding a key for an existing provider overwrites it (rotation). Same form serves both."
                  )}
                </p>

                <.form for={@form} phx-submit="put" class="flex flex-col gap-3">
                  <label class="flex flex-col gap-1">
                    <span class="text-xs uppercase tracking-wide text-zinc-500">provider</span>
                    <input
                      type="text"
                      name="api_key[provider]"
                      value={@form[:provider].value}
                      placeholder="deepseek"
                      class="block w-full px-3 py-2 text-sm rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    />
                  </label>

                  <label class="flex flex-col gap-1">
                    <span class="text-xs uppercase tracking-wide text-zinc-500">
                      {gettext("key (plaintext — never re-displayed after save)")}
                    </span>
                    <input
                      type="password"
                      name="api_key[key]"
                      value=""
                      placeholder="sk-..."
                      autocomplete="off"
                      class="block w-full px-3 py-2 text-sm font-mono rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    />
                  </label>

                  <div class="flex justify-end pt-2 border-t border-zinc-200 dark:border-zinc-800">
                    <.button :if={@is_admin? or @creator?} variant="primary" type="submit">
                      {gettext("Save")}
                    </.button>
                  </div>
                  <p
                    :if={not (@is_admin? or @creator?)}
                    class="text-xs text-rose-700 dark:text-rose-300"
                  >
                    {gettext("You must be the agent's creator or admin to edit its keys.")}
                  </p>
                </.form>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
