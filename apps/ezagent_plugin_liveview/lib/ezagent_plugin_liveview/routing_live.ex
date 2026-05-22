defmodule EzagentPluginLiveview.RoutingLive do
  @moduledoc """
  /admin/routing — global RoutingRegistry rules editor.

  Per Phase 4-completion Spec 05 Part B B.2 — replaces the
  `mix ezagent.routing.add_rule` CLI workflow for admin operators.
  Workspace.routing_rules per Workspace stays config-only metadata
  (Q-RT-1 default γ); this LV manages the **global** RoutingRegistry
  tables (MentionRouting + SessionRouting from chat plugin).

  ## Form shape

  - **Table** select — registered table modules
    (`EzagentDomainChat.Routing.MentionRouting` / `SessionRouting`)
  - **Matcher** — two modes via toggle:
    - **Form mode** (default): pick leaf type (mention / from /
      text_contains / text_matches / always) + arg input
    - **JSON mode**: paste arbitrary matcher JSON (for combinators —
      and/or/not). Live-validated via `Matcher.from_json/1`
  - **Receivers** — comma-separated URI strings

  ## Auth (PR #146 — SPEC v2 §5.7)

  Routing mutations dispatch to the **scope-owning Kind** instead of
  a synthetic `routing-admin://default` singleton:

  - Global rules → `system://routing/default?action=routing.<action>`
  - Workspace rules → `workspace://<name>?action=routing.<action>`
  - Session rules → `session://<name>?action=routing.<action>`

  Phase 4 v1 LV still defaults all rules to the global scope. The
  scope picker is the contract surface for future "narrow this rule
  to workspace X" / "narrow to session Y" — wired in this PR with
  the global default; per-scope UI lands in a follow-up.
  """

  use Phoenix.LiveView
  alias EzagentDomainUi.IdeShell
  use EzagentDomainUi.Primitives
  import Phoenix.Component

  alias Ezagent.Routing.{Matcher, RuleStore}
  alias Ezagent.UI.UriOptions

  # PR #146: default rule scope is **global** — dispatches to the
  # System Kind sentinel for routing.
  @global_routing_uri Ezagent.Entity.System.routing_default_uri()

  @tables [
    {"MentionRouting", EzagentDomainChat.Routing.MentionRouting},
    {"SessionRouting", EzagentDomainChat.Routing.SessionRouting}
  ]

  @matcher_types [
    {"mention", "URI"},
    {"from", "URI"},
    {"text_contains", "substring"},
    {"text_matches", "regex"},
    {"always", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    [{_, first_table} | _] = @tables

    # PR #123 hardening: live_session :require_user on_mount sets
    # current_entity_uri before mount/3 runs; admin fallback deleted.
    caller_uri = socket.assigns.current_entity_uri

    caller_caps =
      if URI.to_string(caller_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
        Ezagent.Entity.User.admin_caps()
      else
        Ezagent.Identity.list_caps_for(caller_uri)
      end

    # V1 UI PR-1 (SPEC §1.2 / §1.5) — options for the uri_picker
    # components. Caller-authorized: UriOptions resolves workspace
    # authority itself from current_entity_uri + current_workspace_uri.
    workspace_uri = socket.assigns.current_workspace_uri

    {:ok,
     socket
     |> assign(:tables, @tables)
     |> assign(:matcher_types, @matcher_types)
     |> assign(:current_table, first_table)
     |> assign(:rules, load_rules(first_table))
     |> assign(:flash_error, nil)
     |> assign(:matcher_mode, "form")
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:entity_options, UriOptions.entities(caller_uri, workspace_uri))
     |> assign(
       :receiver_options,
       UriOptions.entities_and_sessions(caller_uri, workspace_uri)
     )
     |> assign(
       :add_form,
       to_form(
         %{
           "table" => Atom.to_string(first_table),
           "matcher_type" => "mention",
           "matcher_arg" => "",
           "matcher_json" => "",
           "receivers" => ""
         },
         as: "rule"
       )
     )}
  end

  defp load_rules(table) do
    RuleStore.list(table)
    |> Enum.map(fn row ->
      matcher =
        case Matcher.from_json(row.matcher_data) do
          {:ok, m} -> m
          _ -> :invalid
        end

      %{
        id: row.id,
        matcher: matcher,
        matcher_data: row.matcher_data,
        receivers: row.receivers,
        source: row.source,
        enabled: row.enabled
      }
    end)
  end

  @impl true
  def handle_event("switch_table", %{"table" => table_str}, socket) do
    case parse_table(table_str) do
      {:ok, table} ->
        {:noreply,
         socket
         |> assign(:current_table, table)
         |> assign(:rules, load_rules(table))
         |> assign(:flash_error, nil)}

      _ ->
        {:noreply, assign(socket, :flash_error, "unknown table: #{table_str}")}
    end
  end

  def handle_event("toggle_mode", %{"mode" => mode}, socket) when mode in ["form", "json"] do
    {:noreply, assign(socket, :matcher_mode, mode)}
  end

  def handle_event("add_rule", %{"rule" => params}, socket) do
    with {:ok, table} <- parse_table(Map.get(params, "table", "")),
         {:ok, matcher} <- parse_matcher(socket.assigns.matcher_mode, params),
         receivers when is_list(receivers) <-
           parse_receivers(Map.get(params, "receivers", "")),
         true <- length(receivers) > 0 || {:error, :no_receivers},
         # V1 UI PR-1 (SPEC §1.6) — the uri_picker hidden inputs are
         # untrusted user-controlled DOM. Revalidate every submitted
         # URI server-side before dispatch. Form-mode mention/from
         # matchers carry one entity URI; receivers carry entity +
         # session URIs. JSON-mode matchers are validated by
         # Matcher.from_json (the JSON combinator stays a textarea).
         :ok <- revalidate_matcher_arg(socket, params),
         :ok <- revalidate_uris(socket, receivers, [:entity, :session]),
         {:ok, _r} <-
           dispatch_routing_admin(socket, :add_rule, %{
             table: table,
             matcher_json: Matcher.to_json(matcher),
             receivers: receivers
           }) do
      {:noreply,
       socket
       |> assign(:current_table, table)
       |> assign(:rules, load_rules(table))
       |> assign(:flash_error, nil)
       |> assign(
         :add_form,
         to_form(
           %{
             "table" => Atom.to_string(table),
             "matcher_type" => "mention",
             "matcher_arg" => "",
             "matcher_json" => "",
             "receivers" => ""
           },
           as: "rule"
         )
       )}
    else
      {:error, :unauthorized} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           "You don't have routing cap on the global system://routing/default scope. " <>
             "Ask admin to grant via mix ezagent.user.create."
         )}

      {:error, :cross_workspace_denied} ->
        # Phase 9 PR-4 — workspace isolation. Routing rules on
        # workspace://<X>?action=routing.add_rule against a workspace
        # other than the caller's. Routing on system://routing/default
        # bypasses isolation (system is :any-workspace) — this branch
        # is for the workspace-scoped scope.
        {:noreply,
         assign(
           socket,
           :flash_error,
           "Cross-workspace denied — you're trying to add a routing rule in a " <>
             "different workspace. Ask admin for a cross-workspace cap."
         )}

      {:error, {:invalid_uri, bad}} ->
        # SPEC §1.6 — a submitted URI failed server-side revalidation
        # (malformed, wrong scheme, out-of-workspace, or no live
        # target). Flash, do NOT dispatch.
        {:noreply,
         assign(
           socket,
           :flash_error,
           "Rejected URI #{inspect(bad)} — not a valid in-workspace " <>
             "entity/session. Pick from the list or check the URI."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, "add failed: #{inspect(reason)}")}

      false ->
        {:noreply, assign(socket, :flash_error, "at least one receiver required")}
    end
  end

  def handle_event("delete_rule", %{"id" => id_str}, socket),
    do: rule_action(id_str, :delete_rule, socket)

  def handle_event("disable_rule", %{"id" => id_str}, socket),
    do: rule_action(id_str, :disable_rule, socket)

  def handle_event("enable_rule", %{"id" => id_str}, socket),
    do: rule_action(id_str, :enable_rule, socket)

  defp rule_action(id_str, action, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        case dispatch_routing_admin(socket, action, %{
               id: id,
               table: socket.assigns.current_table
             }) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:rules, load_rules(socket.assigns.current_table))
             |> assign(:flash_error, nil)}

          {:error, :unauthorized} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               "You don't have routing cap on the global system://routing/default " <>
                 "scope to perform this action."
             )}

          {:error, :cross_workspace_denied} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               "Cross-workspace denied — this rule lives in a different workspace. " <>
                 "Ask admin for a cross-workspace cap."
             )}

          {:error, reason} ->
            {:noreply, assign(socket, :flash_error, "failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, assign(socket, :flash_error, "bad id: #{id_str}")}
    end
  end

  # PR #146 (SPEC v2 §5.7) — dispatch routing mutations against the
  # scope-owning Kind. Default scope is global (System Kind); per-rule
  # scope narrowing lands in a follow-up PR with workspace/session
  # picker fields.
  defp dispatch_routing_admin(socket, action, args) do
    scope_uri = @global_routing_uri

    target =
      URI.parse("#{URI.to_string(scope_uri)}?action=routing.#{Atom.to_string(action)}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: socket.assigns.caller_uri,
        caps: socket.assigns.caller_caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp parse_table(""), do: {:error, :missing_table}

  defp parse_table(s) when is_binary(s) do
    try do
      {:ok, String.to_existing_atom(s)}
    rescue
      ArgumentError -> {:error, {:unknown_table, s}}
    end
  end

  defp parse_matcher("form", %{"matcher_type" => type, "matcher_arg" => arg}) do
    case type do
      "mention" when is_binary(arg) and arg != "" ->
        {:ok, Matcher.mention(arg)}

      "from" when is_binary(arg) and arg != "" ->
        {:ok, Matcher.from(arg)}

      "text_contains" when is_binary(arg) and arg != "" ->
        {:ok, Matcher.text_contains(arg)}

      "text_matches" when is_binary(arg) and arg != "" ->
        try do
          {:ok, Matcher.text_matches(arg)}
        rescue
          e -> {:error, {:invalid_regex, Exception.message(e)}}
        end

      "always" ->
        {:ok, Matcher.always()}

      _ ->
        {:error, {:invalid_matcher_form, type, arg}}
    end
  end

  defp parse_matcher("json", %{"matcher_json" => json}) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, decoded} ->
        case Matcher.from_json(decoded) do
          {:ok, m} -> {:ok, m}
          err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_matcher(_, _), do: {:error, :empty_matcher}

  # V1 UI PR-1 — the receivers field is now a :multi uri_picker, which
  # submits `rule[receivers][]` as a list. The legacy comma-separated
  # string clause is kept for the free-text fallback (which submits the
  # same `rule[receivers][]` name — also a list — but the no-JS
  # dead-render path can still post a bare string).
  defp parse_receivers(list) when is_list(list) do
    list
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_receivers(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_receivers(_), do: []

  # SPEC §1.6 — server-side revalidation of uri_picker submissions.
  #
  # Form-mode mention/from matchers carry one entity URI from the
  # `:single` picker; revalidate it. text_*/always carry no URI;
  # JSON-mode matchers are validated by `Matcher.from_json` (the JSON
  # combinator textarea is intentionally not a picker).
  defp revalidate_matcher_arg(socket, %{"matcher_type" => type, "matcher_arg" => arg})
       when type in ["mention", "from"] and is_binary(arg) and arg != "" do
    revalidate_uris(socket, [arg], [:entity])
  end

  defp revalidate_matcher_arg(_socket, _params), do: :ok

  # Each submitted URI must pass the SHARED validator
  # `UriOptions.valid_for?/4` — the same check the options were built
  # from. Returns `:ok` or `{:error, {:invalid_uri, uri}}`.
  defp revalidate_uris(socket, uris, kinds) do
    caller_uri = socket.assigns.caller_uri
    workspace_uri = socket.assigns.current_workspace_uri

    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      if UriOptions.valid_for?(caller_uri, workspace_uri, uri, kinds) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_uri, uri}}}
      end
    end)
  end

  @impl true
  def render(assigns) do
    # Phase 8 阶段 C: wrap in IdeShell.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <IdeShell.ide_shell
      current_entity_uri={@current_entity_uri_str}
      current_path="/routing"
      status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
    >
      <:resource_panel>
        <div class="p-3 flex flex-col gap-1">
          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-1">Tables</div>
          <button
            :for={{label, mod} <- @tables}
            type="button"
            phx-click="switch_table"
            phx-value-table={Atom.to_string(mod)}
            class={[
              "text-left px-2 py-1 text-xs rounded font-mono",
              (@current_table == mod &&
                 "bg-zinc-100 dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100") ||
                "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            ]}
          >
            {label}
          </button>
        </div>
      </:resource_panel>
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <header>
            <h1 style="font-size: 22px; font-weight: 600;">Routing Rules</h1>
            <p style="font-size: 13px; color: #666;">
              Global RoutingRegistry tables. Per-workspace routing_rules stay config-only metadata (visible on Workspace detail page).
            </p>
          </header>

          <section id="table-tabs" style="margin-top: 24px; display: flex; gap: 8px;">
            <button
              :for={{label, mod} <- @tables}
              type="button"
              phx-click="switch_table"
              phx-value-table={Atom.to_string(mod)}
              style={tab_style(@current_table == mod)}
            >
              {label}
            </button>
          </section>

          <section id="rules-list" style="margin-top: 16px;">
            <p :if={@rules == []} id="rules-empty" style="color: #57606a; font-style: italic;">
              No rules in this table. Add one below.
            </p>

            <table
              :if={@rules != []}
              id="rules-table"
              style="width: 100%; font-size: 13px; border-collapse: collapse;"
            >
              <thead>
                <tr style="border-bottom: 1px solid #d1d5da;">
                  <th style="text-align: left; padding: 6px 4px;">ID</th>
                  <th style="text-align: left;">Source</th>
                  <th style="text-align: left;">Matcher</th>
                  <th style="text-align: left;">Receivers</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={rule <- @rules}
                  style={"border-bottom: 1px solid #eaeef2;" <> (if !rule.enabled, do: " opacity: 0.5;", else: "")}
                >
                  <td style="padding: 4px 4px;">{rule.id}</td>
                  <td style="font-size: 11px;">
                    <span style={source_badge_style(rule.source)}>{rule.source}</span>
                    <span :if={!rule.enabled} style="color: #57606a; margin-left: 4px;">
                      (disabled)
                    </span>
                  </td>
                  <td style="font-family: monospace; font-size: 11px;">{inspect(rule.matcher)}</td>
                  <td style="font-family: monospace; font-size: 11px;">
                    <span :for={r <- rule.receivers}>{render_receiver(r)}</span>
                  </td>
                  <td>
                    <button
                      :if={rule.source != "system_default"}
                      type="button"
                      phx-click="delete_rule"
                      phx-value-id={rule.id}
                      style="padding: 4px 10px; background: white; color: #cf222e; border: 1px solid #cf222e; border-radius: 4px; cursor: pointer; font-size: 11px;"
                      data-confirm="Delete this rule?"
                    >
                      Delete
                    </button>
                    <button
                      :if={rule.source == "system_default" and rule.enabled}
                      type="button"
                      phx-click="disable_rule"
                      phx-value-id={rule.id}
                      style="padding: 4px 10px; background: white; color: #9a6700; border: 1px solid #9a6700; border-radius: 4px; cursor: pointer; font-size: 11px;"
                      data-confirm="Disable this system_default rule? (admin opt-out — re-enable via Enable button)"
                    >
                      Disable
                    </button>
                    <button
                      :if={rule.source == "system_default" and !rule.enabled}
                      type="button"
                      phx-click="enable_rule"
                      phx-value-id={rule.id}
                      style="padding: 4px 10px; background: white; color: #1f883d; border: 1px solid #1f883d; border-radius: 4px; cursor: pointer; font-size: 11px;"
                    >
                      Enable
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section
            id="add-rule"
            style="margin-top: 24px; padding: 16px; border: 1px solid #d1d5da; border-radius: 6px;"
          >
            <h2 style="font-size: 14px; font-weight: 500; margin: 0 0 12px 0;">Add rule</h2>

            <div style="margin-bottom: 12px; display: flex; gap: 8px;">
              <button
                type="button"
                phx-click="toggle_mode"
                phx-value-mode="form"
                style={mode_btn_style(@matcher_mode == "form")}
              >
                Form mode
              </button>
              <button
                type="button"
                phx-click="toggle_mode"
                phx-value-mode="json"
                style={mode_btn_style(@matcher_mode == "json")}
              >
                JSON mode (combinators)
              </button>
            </div>

            <.form for={@add_form} phx-submit="add_rule">
              <input type="hidden" name="rule[table]" value={Atom.to_string(@current_table)} />

              <div
                :if={@matcher_mode == "form"}
                style="display: grid; grid-template-columns: 200px 1fr; gap: 8px; margin-bottom: 12px;"
              >
                <select
                  name="rule[matcher_type]"
                  style="padding: 6px 10px; border: 1px solid #d1d5da; border-radius: 4px;"
                >
                  <option :for={{t, _arg_label} <- @matcher_types} value={t}>{t}</option>
                </select>
                <%!--
              V1 UI PR-1 (SPEC §1.2) — matcher arg is a :single
              uri_picker over in-workspace entities. allow_freetext is
              ON so text_contains / text_matches matchers (substring /
              regex args, not URIs) can still be entered via the
              manual-entry disclosure.
            --%>
                <.uri_picker
                  name="rule[matcher_arg]"
                  mode={:single}
                  kinds={[:entity]}
                  options={@entity_options}
                  allow_freetext={true}
                  placeholder="pick an entity, or enter a substring/regex below"
                />
              </div>

              <div :if={@matcher_mode == "json"} style="margin-bottom: 12px;">
                <textarea
                  name="rule[matcher_json]"
                  rows="4"
                  placeholder={
                    ~s({"type":"and","items":[{"type":"mention","arg":"entity://agent/default/cc_x"},{"type":"from","arg":"entity://user/system/admin"}]})
                  }
                  style="width: 100%; padding: 6px 10px; border: 1px solid #d1d5da; border-radius: 4px; font-family: monospace; font-size: 12px;"
                ></textarea>
                <p style="font-size: 11px; color: #57606a; margin: 4px 0 0;">
                  Use full matcher JSON for combinators. Shapes: <code>and / or / not</code>
                  wrap leaf matchers
                  (<code>mention</code>, <code>from</code>, <code>text_contains</code>, <code>text_matches</code>, <code>always</code>).
                </p>
              </div>

              <div style="margin-bottom: 12px;">
                <%!--
              V1 UI PR-1 (SPEC §1.2) — receivers is a :multi uri_picker
              (chips + autocomplete) over in-workspace entities +
              sessions. Submits as rule[receivers][] — a list, same
              shape parse_receivers/1 + dispatch already expect.
            --%>
                <.uri_picker
                  name="rule[receivers]"
                  mode={:multi}
                  kinds={[:entity, :session]}
                  options={@receiver_options}
                  label="Receivers"
                  placeholder="add entities + sessions"
                />
              </div>

              <button
                type="submit"
                style="padding: 8px 16px; background: #1f883d; color: white; border: none; border-radius: 4px; cursor: pointer;"
              >
                Add rule
              </button>
            </.form>

            <p :if={@flash_error} style="color: #cf222e; font-size: 13px; margin-top: 8px;">
              {@flash_error}
            </p>
          </section>
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

  defp tab_style(true),
    do: tab_base() <> "background: #0969da; color: white; border-color: #0969da;"

  defp tab_style(false), do: tab_base() <> "background: white; color: #0969da;"

  defp tab_base,
    do:
      "padding: 6px 16px; border: 1px solid #d1d5da; border-radius: 4px; cursor: pointer; font-size: 13px; "

  defp mode_btn_style(true),
    do:
      "padding: 4px 12px; background: #0969da; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px;"

  defp mode_btn_style(false),
    do:
      "padding: 4px 12px; background: white; color: #0969da; border: 1px solid #d1d5da; border-radius: 4px; cursor: pointer; font-size: 12px;"

  defp source_badge_style("system_default"),
    do:
      "background: #ddf4ff; color: #0969da; padding: 2px 6px; border-radius: 3px; font-size: 10px;"

  defp source_badge_style(_),
    do:
      "background: #f6f8fa; color: #57606a; padding: 2px 6px; border-radius: 3px; font-size: 10px;"

  # Render magic tokens as human-friendly hints, regular URIs as-is.
  defp render_receiver("$session_members"), do: "(dynamic: members of current session)"
  defp render_receiver(r), do: r
end
