defmodule EzagentPluginLiveview.UserApiKeysLive do
  @moduledoc """
  PR #126 — per-user API key management UI.

  Mount at `/identities/users/:uri/api-keys`. URI is URL-encoded
  (`user%3A%2F%2Fadmin`).

  Lists registered providers (masked) + lets the user add / rotate /
  delete keys for any provider name. Keys land in
  `Ezagent.Behavior.ApiKeys` slice on the target User Kind via
  `Invocation.dispatch`.

  ## Self-vs-admin

  - Admin can edit any user's keys
  - Non-admin can edit only their own keys (caller_uri == user_uri)
    via the trailing `if-self?` check before dispatching put/delete

  Cap enforcement is at dispatch step 5.5 — this LV merely shapes the
  dispatch args.

  ## Plaintext display

  The full key is NEVER rendered after the operator submits — only
  the masked form (`sk-abcd...wxyz`) shows in the table. To rotate,
  type a new full key.
  """

  use Phoenix.LiveView
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  import Phoenix.Component

  alias Ezagent.{Invocation, KindRegistry}

  @impl true
  def mount(%{"uri" => encoded}, _session, socket) do
    user_uri = encoded |> URI.decode_www_form() |> URI.new!()
    caller_uri = socket.assigns.current_entity_uri

    caller_caps =
      if URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
        Ezagent.Entity.User.admin_caps()
      else
        Ezagent.Identity.list_caps_for(caller_uri)
      end

    {:ok,
     socket
     |> assign(:user_uri, user_uri)
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:self?, URI.to_string(caller_uri) == URI.to_string(user_uri))
     |> assign(:is_admin?, URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()))
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(
       :form,
       to_form(%{"provider" => "deepseek", "key" => ""}, as: "api_key")
     )
     |> load_keys()}
  end

  defp load_keys(socket) do
    case KindRegistry.lookup(socket.assigns.user_uri) do
      :error ->
        assign(socket, :api_keys, :user_not_live)

      {:ok, _pid} ->
        target =
          URI.new!("#{URI.to_string(socket.assigns.user_uri)}?action=identity.list_api_keys")

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
        {:noreply, assign(socket, :flash_error, "you can only edit your own API keys (admin can edit any)")}

      provider == "" ->
        {:noreply, assign(socket, :flash_error, "provider required (e.g. `deepseek`)")}

      key == "" ->
        {:noreply, assign(socket, :flash_error, "key required")}

      true ->
        dispatch(:put_api_key, socket, %{provider: provider, key: key}, "Saved key for `#{provider}`")
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    if authorized?(socket) do
      dispatch(:delete_api_key, socket, %{provider: provider}, "Deleted key for `#{provider}`")
    else
      {:noreply, assign(socket, :flash_error, "unauthorized")}
    end
  end

  defp authorized?(socket), do: socket.assigns.is_admin? or socket.assigns.self?

  defp dispatch(action, socket, args, success_msg) do
    target = URI.new!("#{URI.to_string(socket.assigns.user_uri)}?action=identity.#{action}")

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
         |> assign(:flash_error, "dispatch failed: #{inspect(reason)}")
         |> assign(:flash_info, nil)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
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
          current_path="/identities/users"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
      <header>
        <h1 style="font-size: 22px; font-weight: 600;">API Keys for <code>{URI.to_string(@user_uri)}</code></h1>
        <p style="font-size: 13px; color: #666;">
          Per-user secret storage for outbound LLM completion APIs (DeepSeek, OpenAI, etc.).
          The system itself holds no keys — every user supplies their own.
          <a href="/identities/users" style="margin-left: 16px; color: #0969da;">← Users</a>
        </p>
      </header>

      <p :if={@flash_error} style="background: #fde8e8; color: #b91c1c; padding: 8px 12px; border-radius: 4px; font-size: 13px;">
        {@flash_error}
      </p>
      <p :if={@flash_info} style="background: #e6f4ea; color: #15803d; padding: 8px 12px; border-radius: 4px; font-size: 13px;">
        {@flash_info}
      </p>

      <section :if={@api_keys == :user_not_live} style="margin-top: 24px; padding: 12px; background: #fef3c7; border-radius: 4px; font-size: 13px;">
        User Kind not currently live in KindRegistry. Trigger any dispatch on this URI to spawn it (e.g. log in as that user once), then return here.
      </section>

      <section :if={match?({:error, _}, @api_keys)} style="margin-top: 24px; padding: 12px; background: #fde8e8; border-radius: 4px; font-size: 13px;">
        Error loading keys: <code>{inspect(elem(@api_keys, 1))}</code>
      </section>

      <section :if={is_list(@api_keys)} style="margin-top: 24px;">
        <h2 style="font-size: 16px; font-weight: 500;">Stored keys ({length(@api_keys)})</h2>

        <p :if={@api_keys == []} style="font-size: 13px; color: #57606a; font-style: italic;">
          No API keys yet. Add one below to enable curl-agent instances that use this user as their owner.
        </p>

        <table :if={@api_keys != []} style="width: 100%; font-size: 13px; border-collapse: collapse; margin-top: 12px;">
          <thead>
            <tr style="border-bottom: 1px solid #d1d5da;">
              <th style="text-align: left; padding: 6px 0;">provider</th>
              <th style="text-align: left;">masked</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @api_keys} style="border-bottom: 1px solid #eee;">
              <td style="padding: 4px 0; font-family: monospace;">{entry.provider}</td>
              <td style="font-family: monospace; color: #57606a;">{entry.masked}</td>
              <td style="text-align: right;">
                <button :if={@is_admin? or @self?} phx-click="delete" phx-value-provider={entry.provider} style="padding: 4px 10px; background: white; color: #b91c1c; border: 1px solid #b91c1c; border-radius: 4px; cursor: pointer; font-size: 12px;">Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section :if={is_list(@api_keys)} style="margin-top: 32px; padding: 16px; border: 1px solid #d1d5da; border-radius: 6px;">
        <h2 style="font-size: 16px; font-weight: 500; margin: 0 0 12px 0;">Add / rotate key</h2>
        <p style="font-size: 12px; color: #57606a; margin: 0 0 12px 0;">
          Adding a key for an existing provider overwrites it (rotation). Same form serves both.
        </p>

        <.form for={@form} phx-submit="put">
          <div style="margin-bottom: 8px;">
            <label style="display: block; font-size: 13px; font-weight: 500;">provider</label>
            <input
              type="text"
              name="api_key[provider]"
              value={@form[:provider].value}
              placeholder="deepseek"
              style="width: 100%; padding: 6px 10px; border: 1px solid #d1d5da; border-radius: 4px;"
            />
          </div>

          <div style="margin-bottom: 8px;">
            <label style="display: block; font-size: 13px; font-weight: 500;">key (plaintext — never re-displayed after save)</label>
            <input
              type="password"
              name="api_key[key]"
              value=""
              placeholder="sk-..."
              autocomplete="off"
              style="width: 100%; padding: 6px 10px; border: 1px solid #d1d5da; border-radius: 4px; font-family: monospace;"
            />
          </div>

          <button
            :if={@is_admin? or @self?}
            type="submit"
            style="padding: 8px 16px; background: #0969da; color: white; border: none; border-radius: 4px; cursor: pointer;"
          >Save</button>
          <p :if={not (@is_admin? or @self?)} style="font-size: 12px; color: #b91c1c;">
            You can only edit your own keys. Admin (<code>entity://user/system/admin</code>) can edit any.
          </p>
        </.form>
      </section>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
