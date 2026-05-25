defmodule EzagentPluginLiveview.RoutingLive do
  @moduledoc """
  /routing — global MentionRouting rules editor.

  Per Phase 4-completion Spec 05 Part B B.2 — replaces the
  `mix ezagent.routing.add_rule` CLI workflow for admin operators.
  Workspace.routing_rules per Workspace stays config-only metadata
  (Q-RT-1 default γ); this LV manages the **global**
  `EzagentDomainChat.Routing.MentionRouting` table from the chat
  plugin.

  ## SessionRouting retirement (2026-05-25)

  The sibling `SessionRouting` table was deleted in this PR. It used
  to carry the Feishu chat ↔ session bridge; that responsibility now
  lives in the ExternalMirror domain's `external_mirror_bindings`
  table (PR-EM-3 #317 — see `Ezagent.ExternalMirror`). With only
  MentionRouting left, the top tab strip + left-sidebar table
  switcher are gone; the page renders MentionRouting directly with
  an explanatory blurb at the top.

  ## Form shape

  - **Matcher** — two modes via toggle:
    - **Form mode** (default): pick leaf type (mention / from /
      text_contains / text_matches / always) + arg input
    - **JSON mode**: paste arbitrary matcher JSON (for combinators —
      and/or/not). Live-validated via `Matcher.from_json/1`
  - **Receivers** — entity / session URI list (uri_picker, multi).
    Magic tokens `$session_users` / `$mentions` / `$session_members`
    expand at resolve time.

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
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  # V-4 scrub (audit 2026-05-23) — pull in `<.card>`, `<.button>`,
  # `<.page_header>`, `<.badge>` atoms to retire inline style="" usage.
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives
  import Phoenix.Component

  alias Ezagent.Routing.{Matcher, RuleStore}
  alias Ezagent.UI.UriOptions

  # PR #146: default rule scope is **global** — dispatches to the
  # System Kind sentinel for routing.
  @global_routing_uri Ezagent.Entity.System.routing_default_uri()

  # NOTE (2026-05-25): SessionRouting deleted — see moduledoc. Only
  # MentionRouting remains, so the table is a constant rather than a
  # list with a selector. The hidden form input `rule[table]` still
  # carries this URI-encoded module atom so dispatched payloads stay
  # shape-compatible with the routing-admin Behavior.
  @table EzagentDomainChat.Routing.MentionRouting

  @matcher_types [
    {"mention", "URI"},
    {"from", "URI"},
    {"text_contains", "substring"},
    {"text_matches", "regex"},
    {"always", nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # PR #123 hardening: live_session :require_user on_mount sets
    # current_entity_uri before mount/3 runs; admin fallback deleted.
    caller_uri = socket.assigns.current_entity_uri

    # SPEC caps-cleanup-v1 §4.4 — admin caps now live in slice.
    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)

    # V1 UI PR-1 (SPEC §1.2 / §1.5) — options for the uri_picker
    # components. Caller-authorized: UriOptions resolves workspace
    # authority itself from current_entity_uri + current_workspace_uri.
    workspace_uri = socket.assigns.current_workspace_uri

    {:ok,
     socket
     |> assign(:table, @table)
     |> assign(:matcher_types, @matcher_types)
     |> assign(:rules, load_rules(@table))
     |> assign(:flash_error, nil)
     |> assign(:matcher_mode, "form")
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:entity_options, UriOptions.entities(caller_uri, workspace_uri))
     |> assign(
       :receiver_options,
       receiver_options(caller_uri, workspace_uri)
     )
     |> assign(
       :add_form,
       to_form(
         %{
           "table" => Atom.to_string(@table),
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
  def handle_event("toggle_mode", %{"mode" => mode}, socket) when mode in ["form", "json"] do
    {:noreply, assign(socket, :matcher_mode, mode)}
  end

  def handle_event("add_rule", %{"rule" => params}, socket) do
    # NOTE (2026-05-25): the submitted `rule[table]` is always
    # MentionRouting now (SessionRouting deleted — see moduledoc) but
    # we still validate the hidden input to reject tampered values.
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
         :ok <- revalidate_receivers(socket, receivers),
         {:ok, _r} <-
           dispatch_routing_admin(socket, :add_rule, %{
             table: table,
             matcher_json: Matcher.to_json(matcher),
             receivers: receivers
           }) do
      {:noreply,
       socket
       |> assign(:rules, load_rules(@table))
       |> assign(:flash_error, nil)
       |> assign(
         :add_form,
         to_form(
           %{
             "table" => Atom.to_string(@table),
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
           gettext(
             "You don't have routing cap on the global system://routing/default scope. Ask admin to grant via mix ezagent.user.create."
           )
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
           gettext(
             "Cross-workspace denied — you're trying to add a routing rule in a different workspace. Ask admin for a cross-workspace cap."
           )
         )}

      {:error, {:invalid_uri, bad}} ->
        # SPEC §1.6 — a submitted URI failed server-side revalidation
        # (malformed, wrong scheme, out-of-workspace, or no live
        # target). Flash, do NOT dispatch.
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected URI %{uri} — not a valid in-workspace entity/session. Pick from the list or check the URI.",
             uri: inspect(bad)
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, :flash_error, gettext("add failed: %{reason}", reason: inspect(reason)))}

      false ->
        {:noreply, assign(socket, :flash_error, gettext("at least one receiver required"))}
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
               table: @table
             }) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:rules, load_rules(@table))
             |> assign(:flash_error, nil)}

          {:error, :unauthorized} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext(
                 "You don't have routing cap on the global system://routing/default scope to perform this action."
               )
             )}

          {:error, :cross_workspace_denied} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext(
                 "Cross-workspace denied — this rule lives in a different workspace. Ask admin for a cross-workspace cap."
               )
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket, :flash_error, gettext("failed: %{reason}", reason: inspect(reason)))}
        end

      _ ->
        {:noreply, assign(socket, :flash_error, gettext("bad id: %{id}", id: id_str))}
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

  # NOTE (2026-05-25): SessionRouting was deleted. The submitted
  # `rule[table]` hidden field is fixed to MentionRouting; we still
  # parse + whitelist-validate to reject any tampered value.
  defp parse_table(""), do: {:error, :missing_table}

  defp parse_table(s) when is_binary(s) do
    if s == Atom.to_string(@table) do
      {:ok, @table}
    else
      {:error, {:unknown_table, s}}
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

  # Mention-gated-routing (SPEC §3) — a receiver is valid when it is a
  # concrete in-workspace entity/session URI (`UriOptions.valid_for?/4`)
  # OR one of the recognized magic tokens (`$session_members`,
  # `$session_users`, `$mentions`). The "All session members
  # (broadcast)" picker option submits the `$session_members` token;
  # the magic tokens are not URIs so the URI validator would reject
  # them — special-case them here.
  defp revalidate_receivers(socket, receivers) do
    Enum.reduce_while(receivers, :ok, fn receiver, :ok ->
      cond do
        Ezagent.Routing.Resolver.magic_token?(receiver) ->
          {:cont, :ok}

        UriOptions.valid_for?(
          socket.assigns.caller_uri,
          socket.assigns.current_workspace_uri,
          receiver,
          [:entity, :session]
        ) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:invalid_uri, receiver}}}
      end
    end)
  end

  # Receiver picker options: in-workspace entities + sessions, with the
  # first-class "All session members (broadcast)" option prepended
  # (SPEC §3). That option's `uri` is the `$session_members` magic
  # token — selecting it submits the token, which `revalidate_receivers/2`
  # accepts and `Ezagent.Routing.Resolver` expands at resolve time.
  defp receiver_options(caller_uri, workspace_uri) do
    [broadcast_option() | UriOptions.entities_and_sessions(caller_uri, workspace_uri)]
  end

  # The synthetic "broadcast" picker option. `kind: :broadcast` so the
  # picker renders it distinctly from concrete entity/session URIs.
  defp broadcast_option do
    %{
      uri: Ezagent.Routing.Resolver.session_members_token(),
      label: gettext("All session members (broadcast)"),
      kind: :broadcast,
      flavor: nil
    }
  end

  @impl true
  def render(assigns) do
    # Phase 8 阶段 C: wrap in IdeShell.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
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
          current_path="/routing"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:resource_panel>
            <div class="p-3 flex flex-col gap-2">
              <div class="text-[10px] uppercase tracking-wide text-zinc-500">{gettext("Table")}</div>
              <div class="px-2 py-1 text-xs rounded font-mono bg-zinc-100 dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
                MentionRouting
              </div>
              <p class="text-[11px] text-zinc-500 mt-1">
                {gettext(
                  "SessionRouting was retired on 2026-05-25 — Feishu chat ↔ session bridging moved to the ExternalMirror domain (PR #317)."
                )}
              </p>
            </div>
          </:resource_panel>
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Routing Rules")}>
                <:subtitle>
                  {gettext(
                    "Global RoutingRegistry table. Per-workspace routing_rules stay config-only metadata (visible on Workspace detail page)."
                  )}
                </:subtitle>
              </.page_header>

              <%!-- 2026-05-25: SessionRouting retired — see moduledoc.
                With only MentionRouting left, the old <section
                id="table-tabs"> top-tab strip is gone. The MentionRouting
                explainer below replaces it; the left resource_panel
                still shows the table name (one item) for orientation. --%>
              <.card id="mention-routing-blurb" class="mb-4">
                <div class="space-y-3 text-xs leading-relaxed text-zinc-700 dark:text-zinc-300">
                  <%!-- HEEx note: `{...}` is the tag-engine's expression
                    interpolation, so literal Elixir-tuple syntax like
                    `{:mention, X}` would be parsed as an expression and
                    fail to compile. The matcher snippets are rendered
                    via `Phoenix.HTML.raw/1` of pre-built strings to
                    keep literal braces in the output. --%>
                  <%!-- English copy --%>
                  <div>
                    <p>
                      <strong class="font-semibold">MentionRouting</strong>
                      — the general message routing rule table. Matchers {Phoenix.HTML.raw(
                        ~s(<code class="font-mono">{:mention, X}</code>)
                      )} / {Phoenix.HTML.raw(~s(<code class="font-mono">{:from, Y}</code>))} / {Phoenix.HTML.raw(
                        ~s(<code class="font-mono">{:always}</code>)
                      )} match messages, dispatching to receivers (URIs + magic
                      tokens like <code class="font-mono">$session_users</code>
                      / <code class="font-mono">$mentions</code>
                      / <code class="font-mono">$session_members</code>). 90% of
                      rules here are admin-authored. The <code class="font-mono">system_default</code>
                      mention-gated rule lives here too.
                    </p>
                    <p class="mt-2 text-zinc-500">
                      <strong class="font-semibold">NOTE (2026-05-25)</strong>: SessionRouting table was removed —
                      it used to manage Feishu chat → session bridging; that
                      responsibility has migrated to the ExternalMirror domain's
                      <code class="font-mono">external_mirror_bindings</code>
                      table (PR-EM-3, #317).
                    </p>
                  </div>

                  <%!-- Chinese copy (bilingual_docs convention) --%>
                  <div lang="zh" class="border-t border-zinc-200 dark:border-zinc-800 pt-3">
                    <p>
                      <strong class="font-semibold">MentionRouting</strong>
                      — 通用消息路由规则表。matcher {Phoenix.HTML.raw(
                        ~s(<code class="font-mono">{:mention, X}</code>)
                      )} / {Phoenix.HTML.raw(~s(<code class="font-mono">{:from, Y}</code>))} / {Phoenix.HTML.raw(
                        ~s(<code class="font-mono">{:always}</code>)
                      )} 匹配消息，对应 receivers 列表（包含 magic tokens
                      <code class="font-mono">$session_users</code>
                      / <code class="font-mono">$mentions</code>
                      / <code class="font-mono">$session_members</code>）。这里
                      90% 的规则是 admin 手动加的。 <code class="font-mono">system_default</code>
                      那条 mention-gated rule 也在这。
                    </p>
                    <p class="mt-2 text-zinc-500">
                      <strong class="font-semibold">NOTE (2026-05-25)</strong>: SessionRouting 表已删除 —
                      它原管 Feishu chat → session 的桥接，职责已迁移到 ExternalMirror domain 的
                      <code class="font-mono">external_mirror_bindings</code>
                      表（PR-EM-3, #317）。
                    </p>
                  </div>
                </div>
              </.card>

              <.card id="rules-list">
                <p
                  :if={@rules == []}
                  id="rules-empty"
                  class="text-sm text-zinc-500 italic"
                >
                  {gettext("No rules yet. Add one below.")}
                </p>

                <table
                  :if={@rules != []}
                  id="rules-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">{gettext("ID")}</th>
                      <th class="text-left">{gettext("Source")}</th>
                      <th class="text-left">{gettext("Matcher")}</th>
                      <th class="text-left">{gettext("Receivers")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={rule <- @rules}
                      class={[
                        "border-b border-zinc-100 dark:border-zinc-900",
                        !rule.enabled && "opacity-50"
                      ]}
                    >
                      <td class="px-1 py-1">{rule.id}</td>
                      <td class="text-[11px]">
                        <.badge variant={source_badge_variant(rule.source)}>{rule.source}</.badge>
                        <span :if={!rule.enabled} class="text-zinc-500 ml-1">
                          {gettext("(disabled)")}
                        </span>
                      </td>
                      <td class="font-mono text-[11px] break-all">{inspect(rule.matcher)}</td>
                      <td class="font-mono text-[11px]">
                        <span :for={r <- rule.receivers}>{render_receiver(r)}</span>
                      </td>
                      <td class="whitespace-nowrap">
                        <.button
                          :if={rule.source != "system_default"}
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="delete_rule"
                          phx-value-id={rule.id}
                          class="text-[11px] px-2 py-0.5 h-auto text-rose-700 dark:text-rose-300 border-rose-300 dark:border-rose-700"
                          data-confirm={gettext("Delete this rule?")}
                        >
                          {gettext("Delete")}
                        </.button>
                        <.button
                          :if={rule.source == "system_default" and rule.enabled}
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="disable_rule"
                          phx-value-id={rule.id}
                          class="text-[11px] px-2 py-0.5 h-auto text-amber-700 dark:text-amber-300 border-amber-300 dark:border-amber-700"
                          data-confirm={
                            gettext(
                              "Disable this system_default rule? (admin opt-out — re-enable via Enable button)"
                            )
                          }
                        >
                          {gettext("Disable")}
                        </.button>
                        <.button
                          :if={rule.source == "system_default" and !rule.enabled}
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="enable_rule"
                          phx-value-id={rule.id}
                          class="text-[11px] px-2 py-0.5 h-auto text-emerald-700 dark:text-emerald-300 border-emerald-300 dark:border-emerald-700"
                        >
                          {gettext("Enable")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <.card id="add-rule" class="mt-6">
                <:header>{gettext("Add rule")}</:header>

                <div class="flex gap-2 mb-3">
                  <button
                    type="button"
                    phx-click="toggle_mode"
                    phx-value-mode="form"
                    class={mode_btn_class(@matcher_mode == "form")}
                  >
                    {gettext("Form mode")}
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_mode"
                    phx-value-mode="json"
                    class={mode_btn_class(@matcher_mode == "json")}
                  >
                    {gettext("JSON mode (combinators)")}
                  </button>
                </div>

                <.form for={@add_form} phx-submit="add_rule" class="flex flex-col gap-3">
                  <input type="hidden" name="rule[table]" value={Atom.to_string(@table)} />

                  <div
                    :if={@matcher_mode == "form"}
                    class="grid grid-cols-[200px_1fr] gap-2"
                  >
                    <%!-- 2026-05-25: matcher-type select. NOTE: we'd prefer
                      `<.input type="select">` from Phoenix CoreComponents,
                      but :ezagent_plugin_liveview deliberately does NOT
                      depend on :ezagent_web (would create a compile cycle —
                      see mix.exs comment). EzagentDomainUi.Primitives
                      ships <.form_field> (text inputs only) + <.uri_picker>
                      (entity URIs) but no <.select>, so we render the
                      <select> inline with the same shadcn-style classes as
                      <.uri_picker>'s filter input below: px-2 py-1.5 text-xs
                      border rounded-md font-mono + zinc palette. --%>
                    <select
                      name="rule[matcher_type]"
                      class="w-full px-2 py-1.5 text-xs border rounded-md font-mono border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
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
                      placeholder={gettext("pick an entity, or enter a substring/regex below")}
                    />
                  </div>

                  <div :if={@matcher_mode == "json"}>
                    <textarea
                      name="rule[matcher_json]"
                      rows="4"
                      placeholder={
                        ~s({"type":"and","items":[{"type":"mention","arg":"entity://agent/team-alpha/cc_x"},{"type":"from","arg":"entity://user/system/admin"}]})
                      }
                      class="w-full px-2 py-1.5 text-xs font-mono border rounded-md border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    ></textarea>
                    <p class="text-[11px] text-zinc-500 mt-1">
                      {gettext(
                        "Use full matcher JSON for combinators. Shapes: %{combinators} wrap leaf matchers (%{leaves}).",
                        combinators: "and / or / not",
                        leaves: "mention, from, text_contains, text_matches, always"
                      )}
                    </p>
                  </div>

                  <div>
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
                      label={gettext("Receivers")}
                      placeholder={gettext("add entities + sessions")}
                    />
                  </div>

                  <div class="flex justify-end pt-2 border-t border-zinc-200 dark:border-zinc-800">
                    <.button variant="success" type="submit">
                      {gettext("Add rule")}
                    </.button>
                  </div>
                </.form>

                <p
                  :if={@flash_error}
                  class="text-rose-700 dark:text-rose-300 text-sm mt-2"
                >
                  {@flash_error}
                </p>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  # V-4 scrub (audit 2026-05-23) — Tailwind classes replace inline
  # style strings; tab styling is now inlined into the render template
  # (single class list, no helper) for the table-tabs section.

  defp mode_btn_class(true),
    do:
      "px-3 py-1 bg-sky-600 dark:bg-sky-500 text-white rounded-md text-xs hover:bg-sky-700 dark:hover:bg-sky-600 transition-colors"

  defp mode_btn_class(false),
    do:
      "px-3 py-1 bg-white dark:bg-zinc-900 text-sky-700 dark:text-sky-300 border border-zinc-200 dark:border-zinc-800 rounded-md text-xs hover:bg-sky-50 dark:hover:bg-zinc-800 transition-colors"

  defp source_badge_variant("system_default"), do: "info"
  defp source_badge_variant(_), do: "default"

  # Render magic tokens as human-friendly hints, regular URIs as-is.
  defp render_receiver("$session_members"),
    do: gettext("(dynamic: all members of current session — broadcast)")

  defp render_receiver("$session_users"),
    do: gettext("(dynamic: User members of current session)")

  defp render_receiver("$mentions"),
    do: gettext("(dynamic: @-mentioned, validated members)")

  defp render_receiver(r), do: r
end
