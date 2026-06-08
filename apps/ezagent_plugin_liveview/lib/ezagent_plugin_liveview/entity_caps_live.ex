defmodule EzagentPluginLiveview.EntityCapsLive do
  @moduledoc """
  Phase 8c PR-G (Allen 2026-05-20) — generic caps grant UI for any
  Entity Kind. Mirrors the CLI surface of `Ezagent.Behavior.Identity`
  (`grant_cap` / `revoke_cap` / `list_caps`).

  Mounts at:

  - `/identities/users/:uri/caps` — preserves the legacy route
    (Phase 6 PR 6 originally shipped as user-only).
  - `/identities/agents/:uri/caps` — new in PR-G; agents already carry
    `Ezagent.Behavior.Identity` (`Ezagent.Entity.Agent.behaviors/0`),
    so the dispatch path works unchanged — this is purely a UI
    exposure of an API that always accepted any entity URI.

  URI param is URL-encoded. Operations dispatch via `Invocation`;
  CapBAC step 5.5 enforces admin caps on the calling LV session
  (the LV owner, not the target entity).

  ## Feishu user note

  Feishu webhook → ESR maps the inbound Feishu user_id to a User Kind
  URI (e.g. `entity://user/team-alpha/feishu:ou_xxx`). Once that User exists in
  the KindRegistry, this LV grants caps to it the same way as any
  local user — the "Feishu cap-grant UI" the SPEC calls out is
  exactly this page with the URI shaped accordingly.

  ## CLI equivalence

  No dedicated mix task exists for grant/revoke today — this LV is
  the canonical operator surface. The underlying calls are:

      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(entity_uri, :identity, :grant_cap),
        mode: :call,
        args: %{cap: %Capability{...}},
        ctx: %{caller: admin_uri, caps: admin_caps, reply: :sync}
      })

  (replace `grant_cap` with `revoke_cap` / `list_caps` as appropriate).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.{Capability, Invocation, KindRegistry}

  @impl true
  def mount(%{"uri" => encoded}, _session, socket) do
    entity_uri = encoded |> URI.decode_www_form() |> Ezagent.URI.new!()
    # PR #123 hardening: on_mount sets current_entity_uri; caller is
    # the logged-in user, not a hardcoded admin fallback.
    caller_uri = socket.assigns.current_entity_uri

    # SPEC caps-cleanup-v1 §4.4 — admin caps now live in slice.
    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)

    {:ok,
     socket
     |> assign(:entity_uri, entity_uri)
     |> assign(:entity_kind, entity_kind(entity_uri))
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(
       :grant_form,
       to_form(%{"kind" => "", "behavior" => "any", "instance" => "any", "action" => "any"},
         as: "grant"
       )
     )
     # SPEC 2026-05-27 capability-action-axis §3.6.1(b) — the action
     # selector is populated from the resolved behavior's `actions/0`.
     # Default behavior is `any` → no concrete actions to choose, only
     # the `:any` wildcard option.
     |> assign(:available_actions, actions_for_behavior("any"))
     |> load_caps()}
  end

  # Returns "user" | "agent" | "entity" for breadcrumb/copy.
  defp entity_kind(%URI{scheme: "entity"} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, kind} when kind in ["user", "agent"] -> kind
      _ -> "entity"
    end
  end

  defp entity_kind(_), do: "entity"

  defp load_caps(socket) do
    case KindRegistry.lookup(socket.assigns.entity_uri) do
      :error ->
        assign(socket, :caps, :entity_not_live)

      {:ok, _pid} ->
        # Dispatch list_caps and capture the result.
        target = Ezagent.URI.with_action(socket.assigns.entity_uri, :identity, :list_caps)

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
          {:ok, %{caps: caps}} -> assign(socket, :caps, caps)
          {:error, reason} -> assign(socket, :caps, {:error, reason})
        end
    end
  rescue
    err -> assign(socket, :caps, {:error, err})
  end

  @impl true
  # SPEC 2026-05-27 §3.6.1(b) — recompute the action selector whenever
  # the behavior field changes so the dropdown reflects the resolved
  # behavior's `actions/0`. The action set is sourced from the compiled
  # Behavior module (NOT user input); typing an unknown/`any` behavior
  # collapses the selector to just the `:any` wildcard option.
  def handle_event("grant_changed", %{"grant" => params}, socket) do
    behavior_str = Map.get(params, "behavior", "any")
    available = actions_for_behavior(behavior_str)

    # If the previously-chosen action is no longer valid for the new
    # behavior, fall back to `any` so the form never submits a stale
    # action atom.
    chosen = Map.get(params, "action", "any")

    chosen =
      if chosen == "any" or chosen in Enum.map(available, &Atom.to_string/1),
        do: chosen,
        else: "any"

    {:noreply,
     socket
     |> assign(:available_actions, available)
     |> assign(:grant_form, to_form(Map.put(params, "action", chosen), as: "grant"))}
  end

  def handle_event("grant", %{"grant" => params}, socket) do
    kind_str = Map.get(params, "kind", "") |> String.trim()
    behavior_str = Map.get(params, "behavior", "any")
    action_str = Map.get(params, "action", "any")

    cond do
      kind_str == "" ->
        {:noreply,
         assign(socket, :flash_error, gettext("Kind required (e.g. echo, agent, :any)"))}

      # codex review HIGH: reject an unknown kind atom BEFORE building
      # the cap. `safe_kind/1` uses `String.to_existing_atom` (no atom
      # minting from a crafted submit).
      safe_kind(kind_str) == :error ->
        {:noreply, assign(socket, :flash_error, gettext("unknown kind %{kind}", kind: kind_str))}

      # codex review HIGH: reject an unknown behavior BEFORE building the
      # cap. `safe_behavior/1` resolves to a LOADED Behavior module (or
      # `:any`); a crafted/unknown behavior is rejected — no
      # `String.to_atom/1`, and (codex MED) the cap is stored with the
      # MODULE so it actually matches dispatch `required_caps/0`.
      safe_behavior(behavior_str) == :error ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("unknown behavior %{behavior}", behavior: behavior_str)
         )}

      # codex review HIGH: validate the submitted action against the
      # resolved behavior's `actions/0` (the SAME trusted source the
      # selector is populated from) BEFORE building the cap. A crafted
      # submit that sends an action not in that set (or not `any`) is
      # REJECTED — no `String.to_atom/1` on the action field, so a
      # forged value can never mint a new atom or persist an undeclared
      # action that might become dispatchable later.
      not valid_action?(action_str, behavior_str) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("invalid action %{action} for behavior %{behavior}",
             action: action_str,
             behavior: behavior_str
           )
         )}

      true ->
        cap = build_cap(params, socket.assigns.caller_uri)

        do_grant_or_revoke(
          socket,
          :grant_cap,
          cap,
          gettext("Granted cap to %{uri}", uri: Ezagent.URI.stable_key(socket.assigns.entity_uri))
        )
    end
  end

  def handle_event("revoke", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    case Enum.at(socket.assigns.caps, idx) do
      nil ->
        {:noreply,
         assign(socket, :flash_error, gettext("cap not found at index %{index}", index: idx))}

      cap ->
        do_grant_or_revoke(socket, :revoke_cap, cap, gettext("Revoked cap"))
    end
  end

  defp do_grant_or_revoke(socket, action, cap, msg) do
    target =
      Ezagent.URI.with_action(socket.assigns.entity_uri, :identity, action)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: socket.assigns.caller_uri,
             # codex review HIGH: recompute the caller's caps FRESH at
             # mutation time (not the mount-time `:caller_caps` snapshot)
             # so a cap revoked after mount can no longer authorize a
             # grant/revoke until the socket remounts.
             caps: Ezagent.Identity.list_caps_for(socket.assigns.caller_uri),
             reply: :sync
           }
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:flash_info, msg)
         |> assign(:flash_error, nil)
         |> load_caps()}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
         )}
    end
  end

  defp build_cap(params, granted_by) do
    # Phase 9 PR-3 (SPEC v3 §4): the LV form doesn't expose a
    # workspace picker yet — Phase 9 PR-5 adds it as part of the
    # workspace selector overhaul. For now, default to the granted
    # entity's workspace (intra-workspace grant — the most common
    # operator action). Cross-workspace grants will require an
    # explicit workspace dropdown wired in PR-5.
    workspace_uri =
      case Map.get(params, "workspace_uri", "") do
        "any" -> :any
        "" -> default_workspace_for_entity(params)
        s when is_binary(s) -> Ezagent.URI.new!(s)
      end

    # codex review HIGH/MED: `kind` resolves via `String.to_existing_atom`
    # (no minting); `behavior` resolves to the LOADED Behavior MODULE so
    # the stored cap matches dispatch `required_caps/0` (a stored `:echo`
    # atom would never match `Ezagent.Behavior.Echo`). The `handle_event`
    # guard already rejected unknown kind/behavior, so the `:error` arms
    # are unreachable defence-in-depth (collapse to `:any`).
    kind =
      case safe_kind(Map.get(params, "kind", "any")) do
        :error -> :any
        k -> k
      end

    behavior =
      case safe_behavior(Map.get(params, "behavior", "any")) do
        :error -> :any
        b -> b
      end

    %Capability{
      kind: kind,
      behavior: behavior,
      # SPEC 2026-05-27 capability-action-axis §3.6.1(b) — the action
      # selector (populated from the resolved behavior's `actions/0`)
      # carries the chosen action here. Default `:any` mints a
      # behavior-wildcard cap (admitted by the grant-boundary check
      # because the logged-in admin's caps satisfy `holds_admin_caps?/1`);
      # a concrete action mints a NARROW cap so admins no longer NEED a
      # wildcard for a single-action surface.
      #
      # codex review HIGH: `safe_action/2` returns either `:any` or an
      # EXISTING atom drawn from the resolved behavior's `actions/0` —
      # never `String.to_atom/1` on the raw param. The `handle_event`
      # guard (`valid_action?/2`) already rejected anything else, so this
      # is defence-in-depth against atom-table forgery.
      action: safe_action(Map.get(params, "action", "any"), Map.get(params, "behavior", "any")),
      instance: to_uri_or_any(Map.get(params, "instance", "any")),
      workspace_uri: workspace_uri,
      granted_by: granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # Resolve the workspace for a grant when the LV form omits it —
  # falls back to the granted entity's own workspace.
  defp default_workspace_for_entity(_params) do
    # The LV doesn't currently pass entity_uri through the form
    # params (the form only carries kind/behavior/instance). Use
    # `:any` as the conservative default; PR-5 wires the entity
    # context through.
    :any
  end

  defp to_uri_or_any("any"), do: :any
  defp to_uri_or_any(""), do: :any
  defp to_uri_or_any(s) when is_binary(s), do: Ezagent.URI.new!(s)

  # codex review HIGH — kind atom resolution WITHOUT minting. `"any"`/
  # blank → `:any`; otherwise the kind must already exist as an atom
  # (`String.to_existing_atom`). A crafted/unknown kind string yields
  # `:error` (rejected upstream), never a fresh atom.
  defp safe_kind(s) when s in ["any", "*", "", nil], do: :any

  defp safe_kind(s) when is_binary(s) do
    String.to_existing_atom(String.trim(s))
  rescue
    ArgumentError -> :error
  end

  # codex review HIGH/MED — behavior resolution WITHOUT minting and to
  # the canonical MODULE. `"any"`/`"*"`/blank → `:any` (behavior
  # wildcard); otherwise resolve to a LOADED `Ezagent.Behavior.<X>`
  # module (the shape dispatch `required_caps/0` compares against).
  # Unknown → `:error` (rejected upstream).
  defp safe_behavior(s) when s in ["any", "*", "", nil], do: :any

  defp safe_behavior(s) when is_binary(s) do
    case resolve_behavior_module(s) do
      {:ok, module} -> module
      :error -> :error
    end
  end

  # SPEC 2026-05-27 capability-action-axis §3.6.1(b) — resolve a
  # behavior string to the list of concrete action atoms it declares.
  # The source is the COMPILED Behavior module's `actions/0` callback
  # (declared in code via the `action(...)` macro), so the selector's
  # option set is trustworthy — it can never carry a user-supplied
  # value. Returns `[]` for `any`/blank/unknown behaviors (the selector
  # then offers only the `:any` wildcard option).
  defp actions_for_behavior(behavior_str)
       when behavior_str in ["any", "*", "", nil],
       do: []

  defp actions_for_behavior(behavior_str) when is_binary(behavior_str) do
    case resolve_behavior_module(behavior_str) do
      {:ok, module} ->
        if function_exported?(module, :actions, 0) do
          module.actions() |> Enum.filter(&is_atom/1) |> Enum.sort()
        else
          []
        end

      :error ->
        []
    end
  end

  # codex review HIGH — action-axis forgery guard. The submitted action
  # is valid iff it is `"any"` (the behavior-wildcard) OR it is declared
  # by the resolved behavior's `actions/0`. Anything else (a crafted
  # submit bypassing the <select>) is rejected by the grant handler
  # BEFORE any atom is created.
  defp valid_action?("any", _behavior_str), do: true

  defp valid_action?(action_str, behavior_str) when is_binary(action_str) do
    action_str in Enum.map(actions_for_behavior(behavior_str), &Atom.to_string/1)
  end

  defp valid_action?(_action, _behavior), do: false

  # Convert a VALIDATED action string to an atom WITHOUT minting a new
  # one: `"any"` → `:any`; otherwise pick the matching existing atom out
  # of the resolved behavior's `actions/0`. Falls back to `:any` if the
  # lookup somehow misses (the handler guard makes that unreachable).
  defp safe_action("any", _behavior_str), do: :any
  defp safe_action("", _behavior_str), do: :any

  defp safe_action(action_str, behavior_str) when is_binary(action_str) do
    actions_for_behavior(behavior_str)
    |> Enum.find(:any, fn act -> Atom.to_string(act) == action_str end)
  end

  # Resolve a behavior name to its module via the same convention
  # `Ezagent.Capability.Parser` uses (`"echo" → Ezagent.Behavior.Echo`,
  # `"user_credentials" → Ezagent.Behavior.UserCredentials`).
  #
  # codex review HIGH: build the fully-qualified module name as a STRING
  # and resolve via `String.to_existing_atom/1` — NOT `Module.concat/1`,
  # which ALLOCATES the alias atom from attacker-controlled input before
  # the loaded check (an atom-table growth vector). `to_existing_atom`
  # raises (→ `:error`) for any name that isn't an already-existing
  # module atom, so a forged behavior string can never grow the atom
  # table. The subsequent `Code.ensure_loaded?/1` confirms it is an
  # actual loaded Behavior module, not just any pre-existing atom.
  defp resolve_behavior_module(name) when is_binary(name) do
    capitalized =
      name
      |> String.split("_")
      |> Enum.map_join("", &String.capitalize/1)

    module = String.to_existing_atom("Elixir.Ezagent.Behavior." <> capitalized)

    if Code.ensure_loaded?(module), do: {:ok, module}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp resolve_behavior_module(_), do: :error

  # Breadcrumb back-link target — `/identities` for agents (no
  # dedicated agents-list page), `/identities/users` for users
  # (preserves the existing user admin surface).
  defp parent_path("user"), do: "/identities/users"
  defp parent_path(_), do: "/identities"

  defp parent_label("user"), do: "← /identities/users"
  defp parent_label(_), do: "← /identities"

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        Ezagent.URI.stable_key(
          Map.get(assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()
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
          current_path={"/identities/" <> @entity_kind <> "s"}
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={
                gettext("Caps for %{uri}", uri: Ezagent.URI.stable_key(@entity_uri))
              }>
                <:subtitle>
                  {gettext(
                    "Live cap mutation via Identity Behavior. Admin caps required (CapBAC at dispatch step 5.5)."
                  )}
                  <a
                    href={parent_path(@entity_kind)}
                    class="text-zinc-600 dark:text-zinc-400 underline hover:text-zinc-900 dark:hover:text-zinc-100 ml-1"
                  >
                    {parent_label(@entity_kind)}
                  </a>
                </:subtitle>
              </.page_header>

              <p :if={@flash_info} class="text-emerald-700 dark:text-emerald-300 text-sm mb-3">
                {@flash_info}
              </p>
              <p :if={@flash_error} class="text-red-700 dark:text-red-300 text-sm mb-3">
                {@flash_error}
              </p>

              <.card class="mb-6">
                <:header>{gettext("Grant new cap")}</:header>
                <.form
                  for={@grant_form}
                  phx-submit="grant"
                  phx-change="grant_changed"
                  id="grant-cap-form"
                  class="grid grid-cols-4 gap-2 items-end"
                >
                  <label class="text-xs">
                    kind
                    <input
                      type="text"
                      name="grant[kind]"
                      value={@grant_form.params["kind"]}
                      placeholder="echo or :any"
                      class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md"
                    />
                  </label>
                  <label class="text-xs">
                    behavior
                    <input
                      type="text"
                      name="grant[behavior]"
                      value={@grant_form.params["behavior"] || "any"}
                      class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md"
                    />
                  </label>
                  <%!-- SPEC 2026-05-27 capability-action-axis §3.6.1(b) —
                    action selector populated from the resolved behavior's
                    `actions/0`. Defaults to `:any` (behavior-wildcard,
                    the pre-PR shape). Selecting a concrete action mints a
                    NARROW cap, so admins can grant one action of a
                    multi-action behavior without the over-grant the SPEC
                    closes — no wildcard fallback needed. --%>
                  <label class="text-xs">
                    action
                    <select
                      name="grant[action]"
                      class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md"
                    >
                      <option value="any" selected={(@grant_form.params["action"] || "any") == "any"}>
                        :any
                      </option>
                      <option
                        :for={act <- @available_actions}
                        value={Atom.to_string(act)}
                        selected={@grant_form.params["action"] == Atom.to_string(act)}
                      >
                        {Atom.to_string(act)}
                      </option>
                    </select>
                  </label>
                  <label class="text-xs">
                    instance
                    <input
                      type="text"
                      name="grant[instance]"
                      value={@grant_form.params["instance"] || "any"}
                      class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md"
                    />
                  </label>
                  <div class="col-span-4 flex justify-end">
                    <.button type="submit" variant="primary" size="sm">{gettext("Grant")}</.button>
                  </div>
                </.form>
              </.card>

              <.card>
                <:header>{gettext("Current caps")}</:header>
                <%= case @caps do %>
                  <% :entity_not_live -> %>
                    <p class="text-red-700 dark:text-red-300 text-sm">
                      {gettext("%{kind} Kind not registered (not live in BEAM).",
                        kind: String.capitalize(@entity_kind)
                      )}
                    </p>
                  <% {:error, reason} -> %>
                    <p class="text-red-700 dark:text-red-300 text-sm">
                      {gettext("Error reading caps: %{reason}", reason: inspect(reason))}
                    </p>
                  <% caps when is_list(caps) and caps == [] -> %>
                    <p class="text-zinc-500 italic text-sm">{gettext("No caps. Grant one above.")}</p>
                  <% caps when is_list(caps) -> %>
                    <table class="w-full text-sm">
                      <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                        <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                          <th class="px-2 py-2">kind</th>
                          <th class="py-2">behavior</th>
                          <th class="py-2">action</th>
                          <th class="py-2">instance</th>
                          <th class="py-2">granted_by</th>
                          <th></th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr
                          :for={{cap, i} <- Enum.with_index(caps)}
                          class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
                        >
                          <td class="px-2 py-2 font-mono text-xs">{inspect(cap.kind)}</td>
                          <td class="py-2 font-mono text-xs">{inspect(cap.behavior)}</td>
                          <td class="py-2 font-mono text-xs">{inspect(Capability.action_of(cap))}</td>
                          <td class="py-2 font-mono text-xs">{inspect(cap.instance)}</td>
                          <td class="py-2 font-mono text-xs">
                            {cap.granted_by && Ezagent.URI.stable_key(cap.granted_by)}
                          </td>
                          <td class="py-2 text-right pr-2">
                            <.button variant="danger" size="sm" phx-click="revoke" phx-value-index={i}>
                              {gettext("revoke")}
                            </.button>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                <% end %>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
