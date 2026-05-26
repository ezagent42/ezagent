defmodule EzagentPluginLiveview.SettingsLive do
  @moduledoc """
  Phase 8 阶段 D — Settings LV.

  V1 fix (Allen Feishu 2026-05-21 17:44): moved from `/settings` →
  `/admin/settings` and re-shelled into the admin drawer perspective
  instead of `EzagentDomainUi.IdeShell` (the workspace surface). The
  page hosts admin-only config (SMTP + registration domains) and
  never belonged in the avatar dropdown's personal-config
  "Preference" slot.

  Nested-shell PR-3 (SPEC §1, §6 row 3): now renders
  `AppShell.app_shell` (`perspective: :admin`) wrapping
  `AdminShell.admin_shell` — the page gains the universal chrome
  (avatar / notifications / search / ⌘K).

  Account / Preferences / Keyboard / Access & Identity / System.
  Most sections are placeholders in Phase 8; Access & Identity
  links to existing /admin/users etc.

  Phase 8c PR-O (Username & Auth UI Task 4 — 2026-05-20) — System
  section is now ADMIN-ONLY (gated by `@is_admin?`) and adds SMTP +
  registration-domains editors backed by `Ezagent.AppSettings`. The
  "Send test email" button calls `EzagentWeb.Mailer.deliver_magic_link/2`
  with a test URL — surfaces real `{:ok, _}` / `{:error, reason}` so
  the admin can verify SMTP end-to-end. **This page ACTIVATES the
  email-login flow** — until SMTP is set here, magic-link login fails
  with `:smtp_not_configured` in production.

  V1 fix tightens the admin scope at the mount level: non-admin
  callers are redirected to `/sessions` with a flash — defence in
  depth on top of the per-section `@is_admin?` UI gates.
  """
  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def mount(_params, _session, socket) do
    if Map.get(socket.assigns, :is_admin?) do
      {:ok,
       socket
       |> assign(:section, :smtp)
       |> load_smtp_form()
       |> assign(:smtp_test_recipient, default_test_recipient(socket))
       |> assign(:smtp_test_result, nil)
       |> assign(:smtp_flash, nil)
       # `registration_flash` retained for the SMTP test flash slot;
       # the registration_domains form was removed (PR-G2,
       # 2026-05-24) — per-workspace `magic_link_rule` rows are now
       # the source of truth (managed via /workspaces).
       |> assign(:registration_flash, nil)}
    else
      # V1 fix (Allen 2026-05-21 17:44): /admin/settings is admin
      # scope. The avatar-dropdown "Admin" link is already gated by
      # `@is_admin?` for non-admins, so reaching this route is
      # either a deep link or a stale bookmark from when the page
      # lived at /settings. Redirect to /sessions with a flash.
      {:ok,
       socket
       |> put_flash(:error, gettext("Admin Settings is restricted to admin entities."))
       |> push_navigate(to: "/sessions")}
    end
  end

  @impl true
  def handle_event("switch_section", %{"key" => key}, socket) do
    {:noreply, assign(socket, :section, String.to_existing_atom(key))}
  end

  # --- Task 4: SMTP ---------------------------------------------------------

  def handle_event("save_smtp", %{"smtp" => params}, socket) do
    cfg = %{
      "host" => String.trim(Map.get(params, "host", "")),
      "port" => String.trim(Map.get(params, "port", "")),
      "username" => String.trim(Map.get(params, "username", "")),
      "password" => Map.get(params, "password", ""),
      "from_address" => String.trim(Map.get(params, "from_address", "")),
      "tls" => Map.get(params, "tls", "true") in ["true", "on", true]
    }

    # Preserve previously-stored password when the form submits an
    # empty password field (so the user doesn't lose creds by editing
    # other fields). Empty string -> use existing, non-empty -> replace.
    cfg =
      if cfg["password"] == "" do
        existing = Ezagent.AppSettings.get("smtp_config") || %{}
        Map.put(cfg, "password", Map.get(existing, "password", ""))
      else
        cfg
      end

    :ok = Ezagent.AppSettings.put("smtp_config", cfg)

    {:noreply,
     socket
     |> load_smtp_form()
     |> assign(:smtp_flash, {:ok, gettext("SMTP config saved.")})}
  end

  def handle_event("send_test_email", %{"recipient" => recipient}, socket) do
    recipient = String.trim(recipient)

    cond do
      recipient == "" ->
        {:noreply,
         assign(socket, :smtp_test_result, {:error, gettext("Recipient address required.")})}

      not Ezagent.AppSettings.smtp_configured?() ->
        {:noreply,
         assign(socket, :smtp_test_result,
           {:error,
            gettext(
              "SMTP not configured — fill host/port/username/password/from above and save first."
            )}
         )}

      true ->
        url = test_magic_link_url(socket)

        result =
          case do_deliver_magic_link(recipient, url) do
            {:ok, _} ->
              {:ok, gettext("Test email delivered to %{recipient}.", recipient: recipient)}

            {:error, reason} ->
              {:error, gettext("Send failed: %{reason}", reason: inspect(reason))}
          end

        {:noreply, assign(socket, :smtp_test_result, result)}
    end
  end

  def handle_event("update_test_recipient", %{"recipient" => r}, socket) do
    {:noreply, assign(socket, :smtp_test_recipient, r)}
  end

  # --- Task 4: registration domains ----------------------------------------
  # REMOVED 2026-05-24 (PR-G2 cleanup, dead code audit finding):
  # `save_registration_domains` handler + `load_registration_domains/1`
  # helper deleted. Per-workspace `magic_link_rule` rows are now the
  # source of truth — operators manage rules via /workspaces.

  defp load_smtp_form(socket) do
    cfg = Ezagent.AppSettings.get("smtp_config") || %{}

    assign(socket,
      smtp_config: cfg,
      smtp_configured?: Ezagent.AppSettings.smtp_configured?()
    )
  end

  defp default_test_recipient(socket) do
    case Map.get(socket.assigns, :current_entity_uri) do
      %URI{} = uri ->
        case Ezagent.Entity.Profile.get(uri) do
          %{email: email} when is_binary(email) -> email
          _ -> ""
        end

      _ ->
        ""
    end
  end

  # Runtime call to avoid a compile cycle (ezagent_plugin_liveview must
  # not depend on :ezagent_web at compile time — see plugin mix.exs).
  # The web app IS started by then so the module is loaded.
  defp do_deliver_magic_link(recipient, url) do
    mailer = Module.concat([EzagentWeb, Mailer])

    if Code.ensure_loaded?(mailer) and function_exported?(mailer, :deliver_magic_link, 2) do
      apply(mailer, :deliver_magic_link, [recipient, url])
    else
      {:error, :mailer_not_loaded}
    end
  end

  # Endpoint-aware so the test email links to the right host
  # (production server gets its public URL; dev gets http://localhost:4000).
  # Endpoint lookup is runtime to avoid the compile cycle.
  defp test_magic_link_url(_socket) do
    endpoint = Module.concat([EzagentWeb, Endpoint])

    base =
      if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :url, 0) do
        apply(endpoint, :url, [])
      else
        "http://localhost:4000"
      end

    base <> "/auth/magic/test-token-from-settings-page"
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/settings" active_section={:settings}>
          <:main>
            <div class="flex flex-1 min-h-0">
          <%!-- V1 fix (Allen 2026-05-21 17:44): inner sub-section rail.
                AdminShell's outer sidebar selects which admin
                page is active (Overview / Workspaces / Logs / Registry
                / Snapshots / Settings); this inner rail switches
                between sub-sections of the Settings page itself. All
                sub-sections are admin-only at the mount-gate level, so
                the prior `:if={@is_admin?}` conditionals are dropped. --%>
          <aside class="w-56 shrink-0 border-r border-zinc-200 dark:border-zinc-800 bg-zinc-50/50 dark:bg-zinc-950/50">
            <div class="p-3 flex flex-col gap-px">
              <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-2">{gettext("Settings")}</div>
              <.section_link section={@section} value={:smtp} label={gettext("Email / SMTP")} />
              <.section_link section={@section} value={:registration} label={gettext("Registration")} />
              <.section_link section={@section} value={:access} label={gettext("Access & Identity")} />
              <.section_link section={@section} value={:system} label={gettext("System")} />
              <.section_link section={@section} value={:account} label={gettext("Account")} />
              <.section_link section={@section} value={:preferences} label={gettext("Preferences")} />
              <.section_link section={@section} value={:keyboard} label={gettext("Keyboard")} />
            </div>
          </aside>
          <div class="flex-1 overflow-auto px-6 py-6">
            {render_section(assigns, @section)}
          </div>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  attr :section, :atom, required: true
  attr :value, :atom, required: true
  attr :label, :string, required: true

  defp section_link(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_section"
      phx-value-key={Atom.to_string(@value)}
      class={[
        "text-left px-2 py-1 text-xs rounded",
        @section == @value && "bg-zinc-100 dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 font-medium"
          || "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
      ]}
    >
      {@label}
    </button>
    """
  end

  defp render_section(assigns, :account) do
    ~H"""
    <.page_header title={gettext("Account")}>
      <:subtitle>{gettext("Your Entity URI and display preferences.")}</:subtitle>
    </.page_header>
    <.card>
      <div class="space-y-3">
        <div>
          <div class="text-xs text-zinc-500">{gettext("Entity URI")}</div>
          <.uri_chip uri={@current_entity_uri_str} />
        </div>
        <.empty_state
          title={gettext("Account profile editing")}
          description={gettext("Phase 9 will add display name + avatar customization.")}
        />
      </div>
    </.card>
    """
  end

  defp render_section(assigns, :preferences) do
    ~H"""
    <.page_header title={gettext("Preferences")}>
      <:subtitle>{gettext("UI preferences.")}</:subtitle>
    </.page_header>
    <.empty_state
      title={gettext("Theme switcher")}
      description={gettext("Phase 9 will add dark / light theme toggle. Today fixed to light.")}
    />
    """
  end

  defp render_section(assigns, :keyboard) do
    ~H"""
    <.page_header title={gettext("Keyboard shortcuts")}>
      <:subtitle>{gettext("Quick reference for built-in shortcuts.")}</:subtitle>
    </.page_header>
    <.card>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>{gettext("Open Command Palette")}</span>
          <kbd class="font-mono text-zinc-500">⌘K / Ctrl+K</kbd>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>{gettext("Close modal")}</span>
          <kbd class="font-mono text-zinc-500">Esc</kbd>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>{gettext("Send chat message")}</span>
          <kbd class="font-mono text-zinc-500">Enter</kbd>
        </div>
      </div>
    </.card>
    """
  end

  defp render_section(assigns, :access) do
    ~H"""
    <.page_header title={gettext("Access & Identity")}>
      <:subtitle>{gettext("Manage users, capabilities, API keys, Feishu bindings.")}</:subtitle>
    </.page_header>
    <div class="grid grid-cols-2 gap-3">
      <.access_card href="/identities/users" title={gettext("Users")} desc={gettext("List + create users + set passwords")} />
      <.access_card href="/admin/registry" title={gettext("Registry")} desc={gettext("Live registry of every Kind instance")} />
      <.access_card href="/plugins/feishu/bindings" title={gettext("Feishu bindings")} desc={gettext("open_id ↔ user URI bindings")} />
    </div>
    """
  end

  defp render_section(assigns, :system) do
    ~H"""
    <.page_header title={gettext("System")}>
      <:subtitle>{gettext("Cluster + plugin metadata.")}</:subtitle>
    </.page_header>
    <.card>
      <div class="text-xs space-y-2">
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>{gettext("ezagent_core version")}</span>
          <span class="font-mono">{system_version()}</span>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>{gettext("Elixir / OTP")}</span>
          <span class="font-mono">{System.version()} / {System.otp_release()}</span>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>{gettext("Loaded apps")}</span>
          <span class="font-mono">{loaded_app_count()}</span>
        </div>
      </div>
    </.card>
    """
  end

  # Task 4 — SMTP config (admin-only). Activates magic-link login.
  defp render_section(assigns, :smtp) do
    ~H"""
    <.page_header title={gettext("Email / SMTP")}>
        <:subtitle>
          {gettext(
            "Outbound mail config for magic-link sign-in. Until SMTP is set here, email login fails with %{error}.",
            error: ":smtp_not_configured"
          )}
        </:subtitle>
      </.page_header>

      <.card class="mt-4">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{gettext("Relay credentials")}</h2>
          <.badge :if={@smtp_configured?} variant="success">{gettext("Configured")}</.badge>
          <.badge :if={not @smtp_configured?} variant="warning">{gettext("Not configured")}</.badge>
        </div>

        <.form for={%{}} as={:smtp} phx-submit="save_smtp" class="space-y-3">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <.smtp_field name="smtp[host]" label={gettext("Host")} type="text" placeholder="smtp.example.com" value={Map.get(@smtp_config, "host", "")} />
            <.smtp_field name="smtp[port]" label={gettext("Port")} type="number" placeholder="587" value={to_string(Map.get(@smtp_config, "port", ""))} />
            <.smtp_field name="smtp[username]" label={gettext("Username")} type="text" placeholder="postmaster@example.com" value={Map.get(@smtp_config, "username", "")} />
            <.smtp_field name="smtp[password]" label={gettext("Password")} type="password" placeholder={if(Map.get(@smtp_config, "password") not in [nil, ""], do: gettext("(saved — leave blank to keep)"), else: gettext("(required)"))} value="" />
            <.smtp_field name="smtp[from_address]" label={gettext("From address")} type="email" placeholder="no-reply@example.com" value={Map.get(@smtp_config, "from_address", "")} />
            <div class="flex items-end gap-2">
              <label class="flex items-center gap-2 text-xs text-zinc-700 dark:text-zinc-300">
                <input type="checkbox" name="smtp[tls]" value="true" checked={Map.get(@smtp_config, "tls", true)} />
                <span>{gettext("Use STARTTLS (recommended)")}</span>
              </label>
            </div>
          </div>
          <div class="flex justify-end">
            <.button type="submit" variant="primary" size="sm">{gettext("Save SMTP config")}</.button>
          </div>
        </.form>

        <p :if={match?({:ok, _}, @smtp_flash)} class="text-emerald-600 dark:text-emerald-400 text-xs mt-3">
          {elem(@smtp_flash, 1)}
        </p>
        <p :if={match?({:error, _}, @smtp_flash)} class="text-rose-600 dark:text-rose-400 text-xs mt-3">
          {elem(@smtp_flash, 1)}
        </p>
      </.card>

      <.card class="mt-4">
        <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-3">{gettext("Send test email")}</h2>
        <p class="text-xs text-zinc-500 mb-3">
          {gettext(
            "Sends a test magic-link email using the currently-saved SMTP config. Surfaces real delivery success or failure — no syntactic checks."
          )}
        </p>
        <form phx-submit="send_test_email" phx-change="update_test_recipient" class="flex gap-2 items-end flex-wrap">
          <div class="flex-1 min-w-0">
            <label for="smtp_test_recipient" class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1">{gettext("Recipient")}</label>
            <input
              type="email"
              id="smtp_test_recipient"
              name="recipient"
              value={@smtp_test_recipient}
              placeholder="you@example.com"
              required
              class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
            />
          </div>
          <.button type="submit" variant="outline" size="sm">
            <.icon name="paper-airplane" size="xs" /> {gettext("Send test")}
          </.button>
        </form>

        <p :if={match?({:ok, _}, @smtp_test_result)} class="text-emerald-600 dark:text-emerald-400 text-xs mt-3">
          ✓ {elem(@smtp_test_result, 1)}
        </p>
        <p :if={match?({:error, _}, @smtp_test_result)} class="text-rose-600 dark:text-rose-400 text-xs mt-3">
          ✗ {elem(@smtp_test_result, 1)}
        </p>
      </.card>
    """
  end

  # Task 4 — Registration domains (admin-only).
  defp render_section(assigns, :registration) do
    ~H"""
    <.page_header title={gettext("Registration")}>
        <:subtitle>
          {gettext(
            "Self-registration is now managed PER WORKSPACE via magic_link_rule rows. Each workspace specifies who may register into it (domain, user_list, or invite_only). See /workspaces."
          )}
        </:subtitle>
      </.page_header>

      <.card class="mt-4">
        <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-3">{gettext("Where did the registration_domains form go?")}</h2>
        <p class="text-xs text-zinc-600 dark:text-zinc-400">
          {gettext(
            "SPEC v2 (2026-05-24) — the global `registration_domains` AppSetting was replaced by per-workspace rules. To allow a domain to register, create a workspace at /workspaces and add a `domain` rule. Multiple domains? Multiple workspaces, one each — admin can promote users to system after."
          )}
        </p>
        <p class="text-xs text-zinc-600 dark:text-zinc-400 mt-2">
          <a href="/workspaces" class="underline">{gettext("Manage workspaces →")}</a>
        </p>
      </.card>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :value, :string, default: ""
  attr :placeholder, :string, default: ""

  defp smtp_field(assigns) do
    ~H"""
    <div>
      <label for={@name} class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1">{@label}</label>
      <input
        type={@type}
        id={@name}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
      />
    </div>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true

  defp access_card(assigns) do
    ~H"""
    <a href={@href} class="block">
      <.card>
        <div class="font-medium text-sm">{@title}</div>
        <div class="text-xs text-zinc-500 mt-1">{@desc}</div>
      </.card>
    </a>
    """
  end

  defp system_version do
    case Application.spec(:ezagent_core, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  defp loaded_app_count do
    Application.loaded_applications() |> length()
  end
end
