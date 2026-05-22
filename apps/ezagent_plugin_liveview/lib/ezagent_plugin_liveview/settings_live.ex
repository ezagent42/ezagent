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
       |> load_registration_domains()
       |> assign(:smtp_test_recipient, default_test_recipient(socket))
       |> assign(:smtp_test_result, nil)
       |> assign(:smtp_flash, nil)
       |> assign(:registration_flash, nil)}
    else
      # V1 fix (Allen 2026-05-21 17:44): /admin/settings is admin
      # scope. The avatar-dropdown "Admin" link is already gated by
      # `@is_admin?` for non-admins, so reaching this route is
      # either a deep link or a stale bookmark from when the page
      # lived at /settings. Redirect to /sessions with a flash.
      {:ok,
       socket
       |> put_flash(:error, "Admin Settings is restricted to admin entities.")
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
     |> assign(:smtp_flash, {:ok, "SMTP config saved."})}
  end

  def handle_event("send_test_email", %{"recipient" => recipient}, socket) do
    recipient = String.trim(recipient)

    cond do
      recipient == "" ->
        {:noreply, assign(socket, :smtp_test_result, {:error, "Recipient address required."})}

      not Ezagent.AppSettings.smtp_configured?() ->
        {:noreply,
         assign(socket, :smtp_test_result,
           {:error, "SMTP not configured — fill host/port/username/password/from above and save first."}
         )}

      true ->
        url = test_magic_link_url(socket)

        result =
          case do_deliver_magic_link(recipient, url) do
            {:ok, _} ->
              {:ok, "Test email delivered to #{recipient}."}

            {:error, reason} ->
              {:error, "Send failed: #{inspect(reason)}"}
          end

        {:noreply, assign(socket, :smtp_test_result, result)}
    end
  end

  def handle_event("update_test_recipient", %{"recipient" => r}, socket) do
    {:noreply, assign(socket, :smtp_test_recipient, r)}
  end

  # --- Task 4: registration domains ----------------------------------------

  def handle_event("save_registration_domains", %{"domains" => raw}, socket) do
    domains =
      raw
      |> String.split(~r/[\s,;\n]+/, trim: true)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    :ok = Ezagent.AppSettings.put("registration_domains", domains)

    {:noreply,
     socket
     |> load_registration_domains()
     |> assign(:registration_flash,
       {:ok,
        if(domains == [],
          do: "Allowlist cleared — self-registration disabled.",
          else: "Saved (#{length(domains)} domain#{if length(domains) == 1, do: "", else: "s"})."
        )}
     )}
  end

  defp load_smtp_form(socket) do
    cfg = Ezagent.AppSettings.get("smtp_config") || %{}

    assign(socket,
      smtp_config: cfg,
      smtp_configured?: Ezagent.AppSettings.smtp_configured?()
    )
  end

  defp load_registration_domains(socket) do
    domains = Ezagent.AppSettings.get("registration_domains") || []
    assign(socket, :registration_domains, domains)
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
              <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-2">Settings</div>
              <.section_link section={@section} value={:smtp} label="Email / SMTP" />
              <.section_link section={@section} value={:registration} label="Registration" />
              <.section_link section={@section} value={:access} label="Access & Identity" />
              <.section_link section={@section} value={:system} label="System" />
              <.section_link section={@section} value={:account} label="Account" />
              <.section_link section={@section} value={:preferences} label="Preferences" />
              <.section_link section={@section} value={:keyboard} label="Keyboard" />
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
    <.page_header title="Account">
      <:subtitle>Your Entity URI and display preferences.</:subtitle>
    </.page_header>
    <.card>
      <div class="space-y-3">
        <div>
          <div class="text-xs text-zinc-500">Entity URI</div>
          <.uri_chip uri={@current_entity_uri_str} />
        </div>
        <.empty_state
          title="Account profile editing"
          description="Phase 9 will add display name + avatar customization."
        />
      </div>
    </.card>
    """
  end

  defp render_section(assigns, :preferences) do
    ~H"""
    <.page_header title="Preferences">
      <:subtitle>UI preferences.</:subtitle>
    </.page_header>
    <.empty_state
      title="Theme switcher"
      description="Phase 9 will add dark / light theme toggle. Today fixed to light."
    />
    """
  end

  defp render_section(assigns, :keyboard) do
    ~H"""
    <.page_header title="Keyboard shortcuts">
      <:subtitle>Quick reference for built-in shortcuts.</:subtitle>
    </.page_header>
    <.card>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>Open Command Palette</span>
          <kbd class="font-mono text-zinc-500">⌘K / Ctrl+K</kbd>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>Close modal</span>
          <kbd class="font-mono text-zinc-500">Esc</kbd>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 py-1">
          <span>Send chat message</span>
          <kbd class="font-mono text-zinc-500">Enter</kbd>
        </div>
      </div>
    </.card>
    """
  end

  defp render_section(assigns, :access) do
    ~H"""
    <.page_header title="Access & Identity">
      <:subtitle>Manage users, capabilities, API keys, Feishu bindings.</:subtitle>
    </.page_header>
    <div class="grid grid-cols-2 gap-3">
      <.access_card href="/identities/users" title="Users" desc="List + create users + set passwords" />
      <.access_card href="/admin/registry" title="Registry" desc="Live registry of every Kind instance" />
      <.access_card href="/plugins/feishu/bindings" title="Feishu bindings" desc="open_id ↔ user URI bindings" />
    </div>
    """
  end

  defp render_section(assigns, :system) do
    ~H"""
    <.page_header title="System">
      <:subtitle>Cluster + plugin metadata.</:subtitle>
    </.page_header>
    <.card>
      <div class="text-xs space-y-2">
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>ezagent_core version</span>
          <span class="font-mono">{system_version()}</span>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>Elixir / OTP</span>
          <span class="font-mono">{System.version()} / {System.otp_release()}</span>
        </div>
        <div class="flex justify-between border-b border-zinc-100 dark:border-zinc-900 pb-1">
          <span>Loaded apps</span>
          <span class="font-mono">{loaded_app_count()}</span>
        </div>
      </div>
    </.card>
    """
  end

  # Task 4 — SMTP config (admin-only). Activates magic-link login.
  defp render_section(assigns, :smtp) do
    ~H"""
    <.page_header title="Email / SMTP">
        <:subtitle>
          Outbound mail config for magic-link sign-in. Until SMTP is set
          here, email login fails with <code>:smtp_not_configured</code>.
        </:subtitle>
      </.page_header>

      <.card class="mt-4">
        <div class="flex items-center justify-between mb-3">
          <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Relay credentials</h2>
          <.badge :if={@smtp_configured?} variant="success">Configured</.badge>
          <.badge :if={not @smtp_configured?} variant="warning">Not configured</.badge>
        </div>

        <.form for={%{}} as={:smtp} phx-submit="save_smtp" class="space-y-3">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <.smtp_field name="smtp[host]" label="Host" type="text" placeholder="smtp.example.com" value={Map.get(@smtp_config, "host", "")} />
            <.smtp_field name="smtp[port]" label="Port" type="number" placeholder="587" value={to_string(Map.get(@smtp_config, "port", ""))} />
            <.smtp_field name="smtp[username]" label="Username" type="text" placeholder="postmaster@example.com" value={Map.get(@smtp_config, "username", "")} />
            <.smtp_field name="smtp[password]" label="Password" type="password" placeholder={if(Map.get(@smtp_config, "password") not in [nil, ""], do: "(saved — leave blank to keep)", else: "(required)")} value="" />
            <.smtp_field name="smtp[from_address]" label="From address" type="email" placeholder="no-reply@example.com" value={Map.get(@smtp_config, "from_address", "")} />
            <div class="flex items-end gap-2">
              <label class="flex items-center gap-2 text-xs text-zinc-700 dark:text-zinc-300">
                <input type="checkbox" name="smtp[tls]" value="true" checked={Map.get(@smtp_config, "tls", true)} />
                <span>Use STARTTLS (recommended)</span>
              </label>
            </div>
          </div>
          <div class="flex justify-end">
            <.button type="submit" variant="primary" size="sm">Save SMTP config</.button>
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
        <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-3">Send test email</h2>
        <p class="text-xs text-zinc-500 mb-3">
          Sends a test magic-link email using the currently-saved SMTP config.
          Surfaces real delivery success or failure — no syntactic checks.
        </p>
        <form phx-submit="send_test_email" phx-change="update_test_recipient" class="flex gap-2 items-end flex-wrap">
          <div class="flex-1 min-w-0">
            <label for="smtp_test_recipient" class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1">Recipient</label>
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
            <.icon name="paper-airplane" size="xs" /> Send test
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
    <.page_header title="Registration">
        <:subtitle>
          Self-registration allowlist. Empty list = self-registration disabled
          (only admin-created users can sign in via magic link).
        </:subtitle>
      </.page_header>

      <.card class="mt-4">
        <h2 class="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-3">Allowed email domains</h2>
        <form phx-submit="save_registration_domains" class="space-y-3">
          <textarea
            name="domains"
            rows="6"
            placeholder="example.com&#10;company.com"
            class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
          ><%= Enum.join(@registration_domains, "\n") %></textarea>
          <p class="text-[11px] text-zinc-500">
            One per line, or comma/semicolon separated. Lowercased on save.
            Domain match only (no port / no scheme).
          </p>
          <div class="flex justify-end">
            <.button type="submit" variant="primary" size="sm">Save allowlist</.button>
          </div>
        </form>

        <p :if={match?({:ok, _}, @registration_flash)} class="text-emerald-600 dark:text-emerald-400 text-xs mt-3">
          {elem(@registration_flash, 1)}
        </p>
        <p :if={match?({:error, _}, @registration_flash)} class="text-rose-600 dark:text-rose-400 text-xs mt-3">
          {elem(@registration_flash, 1)}
        </p>

        <div class="mt-4 border-t border-zinc-200 dark:border-zinc-800 pt-3">
          <div class="text-xs text-zinc-500 mb-1">Currently allowed:</div>
          <div :if={@registration_domains == []} class="text-xs italic text-zinc-500">
            None — self-registration disabled.
          </div>
          <div :if={@registration_domains != []} class="flex flex-wrap gap-1">
            <span :for={d <- @registration_domains} class="inline-block px-2 py-0.5 text-[11px] font-mono bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300 rounded">{d}</span>
          </div>
        </div>
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
