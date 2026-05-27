defmodule EzagentPluginLiveview.Admin.SessionExternalMirrorLive do
  @moduledoc """
  `/admin/sessions/:id/external_mirror` — per-session admin LV for the
  ExternalMirror Domain (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §9 PR-EM-4).

  Three responsibilities:

  1. **List bindings** — calls `Ezagent.ExternalMirror.list_bindings/2`
     so dispatch CapBAC step 5.5 enforces Cap 1 (session-level
     `:list_bindings`). For each binding, derives the Worker URI via
     `Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for/3` and fetches
     the `:external_mirror_worker` slice via `Ezagent.Kind.get_slice/2`
     to surface `count` / `error_count` / `last_published_at` /
     `last_publish_result` per SPEC §9 PR-EM-4.

  2. **Bind / unbind** — gated by caps per SPEC §5.4 P15
     **narrow-by-default**: the adapter dropdown lists ONLY adapters
     for which the caller holds the per-adapter allow cap (Cap 2,
     `adapter.cap_subject().behavior_module` on the session); adapters
     the caller can't bind to are hidden. Submit dispatches
     `Ezagent.ExternalMirror.bind/4` (full two-step facade — Check 2
     and Check 3 + facade-nonce) or `Ezagent.ExternalMirror.unbind/3`.

  3. **Drill-down** — clicking a binding row expands a panel showing
     the last 20 audit events whose `target` URI is the worker's URI
     (or the binding's session URI for `:bind` / `:unbind` itself).
     Subscribed to `Ezagent.Audit.stream_topic/0` while connected;
     newer events stream into the in-memory ring.

  ## Polling, not slice-change subscription

  V1 polls every 5s to refresh worker stats. The slice-change pub
  surface is a worthwhile next-step but adds PubSub coupling that
  per **P11** wants to stay narrow. Polling is the simpler default;
  upgrade once the slice change feed is in production with a stable
  topic.

  ## Admin gate

  The router mounts this under `live_session :require_admin` so the
  centralized gate (`EzagentWeb.LiveAuth.on_mount(:require_admin,
  ...)`) handles the admin redirect. THIS LV additionally enforces
  the per-session Cap 1 via `list_bindings/2` returning
  `{:error, :unauthorized}` — a workspace admin without the specific
  session cap still gets redirected with a clear flash, so the URL
  isn't a covert info-disclosure surface.

  ## Tier + layering

  Tier 3 (plugin LV). Reads via:
  - `Ezagent.ExternalMirror.list_bindings/2` (facade)
  - `Ezagent.ExternalMirror.bind/4` + `unbind/3` (facade)
  - `Ezagent.ExternalMirror.list_adapters/0` (Tier-2 read)
  - `Ezagent.Kind.get_slice/2` (Tier-1 primitive)
  - `Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for/3` (Tier-2 helper)
  - `Ezagent.Identity.list_caps_for/1` (Tier-2 read, caller caps)

  No raw `Phoenix.PubSub.subscribe` outside the well-known
  `Ezagent.Audit.stream_topic/0` (per **P11** + invariant 1 — the
  drill-down feed is a legitimate broadcast audience).
  """

  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.Capability
  alias Ezagent.ExternalMirror
  alias Ezagent.ExternalMirror.WorkerSpawn

  require Logger

  @poll_interval_ms 5_000
  @audit_ring_max 20

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    case parse_session_uri(raw_id) do
      {:ok, session_uri} ->
        do_mount(session_uri, socket)

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Invalid session URI in URL."))
         |> push_navigate(to: "/sessions")}
    end
  end

  defp do_mount(session_uri, socket) do
    caller_uri = socket.assigns[:current_entity_uri]
    caller_caps = caller_caps(caller_uri)
    ctx = build_ctx(caller_uri, caller_caps)

    case ExternalMirror.list_bindings(session_uri, ctx) do
      {:ok, bindings} ->
        if connected?(socket) do
          Process.send_after(self(), :poll_refresh, @poll_interval_ms)
          # The Audit topic is a `Phoenix.PubSub.broadcast` audience by
          # design — see `Ezagent.Audit` moduledoc (§5.7.6 legitimate
          # broadcast). Subscribing here is NOT the invariant-1 violation
          # the plugin-receiver-kind contract guards against.
          Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
        end

        {:ok,
         socket
         |> assign(:session_uri, session_uri)
         |> assign(:session_uri_str, URI.to_string(session_uri))
         |> assign(:caller_uri, caller_uri)
         |> assign(:caller_caps, caller_caps)
         |> assign(:ctx, ctx)
         |> assign(:bindings, decorate_bindings(bindings, session_uri))
         |> assign(:available_adapters, filter_adapters_by_cap(caller_caps, session_uri))
         |> assign(:bind_form, fresh_bind_form())
         |> assign(:expanded_binding_id, nil)
         # codex r1 MED-2 (2026-05-25): per-binding ring keyed by
         # binding_id ("<adapter_id>/<target_id>") + a separate ring
         # for session-level :bind / :unbind events. A noisy binding
         # can no longer evict another binding's history.
         |> assign(:binding_audit_events, %{})
         |> assign(:session_audit_events, [])}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, unauthorized_message(reason))
         |> push_navigate(to: "/sessions")}
    end
  end

  # ----- handle_info ---------------------------------------------------------

  @impl true
  def handle_info(:poll_refresh, socket) do
    Process.send_after(self(), :poll_refresh, @poll_interval_ms)
    {:noreply, refresh_bindings(socket)}
  end

  def handle_info({:audit_event, event}, socket) do
    # codex r1 MED-2 (2026-05-25): partition into a PER-BINDING ring +
    # a separate ring for session-level events (`:bind` / `:unbind`
    # itself). Previously a single 20-event global ring meant a noisy
    # binding could evict another binding's events — the expanded
    # panel was not actually "last 20 per binding."
    target = audit_event_target(event)

    cond do
      is_nil(target) ->
        {:noreply, socket}

      session_event?(target, socket.assigns.session_uri_str) ->
        # codex r2 MED (2026-05-25): the LV polls `list_bindings` every
        # 5s, which fires `:external_mirror.list_bindings` audit
        # events. Without an action filter those would saturate the
        # 20-event session ring inside ~100 seconds, evicting the
        # `:bind`/`:unbind` events the panel exists to surface.
        # Accept only the mutating actions; the read action is
        # observability noise.
        if interesting_session_action?(event) do
          {:noreply, prepend_to_ring(socket, :session_audit_events, event)}
        else
          {:noreply, socket}
        end

      true ->
        case binding_for_target(target, socket.assigns.bindings) do
          %{binding_id: binding_id} ->
            {:noreply, prepend_to_binding_ring(socket, binding_id, event)}

          nil ->
            {:noreply, socket}
        end
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ----- handle_event --------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh_bindings(socket)}

  def handle_event(
        "add_binding",
        %{"binding" => %{"adapter_id" => adapter_id, "target_id" => target_id}},
        socket
      ) do
    adapter_id = String.trim(to_string(adapter_id))
    target_id = String.trim(to_string(target_id))

    # codex r1 HIGH (2026-05-25): rebuild ctx from fresh caps so a
    # revoke-after-mount can no longer authorize a bind. Caching
    # `socket.assigns.ctx` from mount let a long-lived admin LV keep
    # dispatching mutations after Cap 1 / Cap 2 were removed from the
    # caller's slice. `caller_caps/1` round-trips through the dispatch
    # path so the cap set IS the live User Kind's `:identity` slice.
    fresh_ctx = fresh_ctx_for_action(socket)

    cond do
      adapter_id == "" ->
        {:noreply, put_flash(socket, :error, gettext("Pick an adapter."))}

      target_id == "" ->
        {:noreply, put_flash(socket, :error, gettext("Target id is required."))}

      true ->
        # codex r1 MED-1 (2026-05-25): NO precheck on adapter_id against
        # the dropdown's filtered list. Per P18 the facade is the
        # canonical authority — surface whatever it returns. The dropdown
        # filter remains a UX narrowing (P15 narrow-by-default); the
        # facade's `:unknown_adapter` (for ghost ids) and
        # `:adapter_not_authorized` (for ids the caller doesn't hold
        # Cap 2 for) reach the operator verbatim, so a tampered hidden
        # form input gets the precise error the facade would log
        # instead of a generic "not authorized" string.
        case ExternalMirror.bind(
               socket.assigns.session_uri,
               adapter_id,
               target_id,
               %{},
               fresh_ctx
             ) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:bind_form, fresh_bind_form())
             |> assign(:ctx, fresh_ctx)
             |> assign(:caller_caps, fresh_ctx.caps)
             |> put_flash(:info, gettext("Bound %{a} → %{t}.", a: adapter_id, t: target_id))
             |> refresh_bindings()}

          {:error, reason} ->
            # Per P18 surface the dispatch error verbatim — operators
            # need to see :adapter_not_authorized / :unknown_adapter /
            # :target_check_timeout / {:target_ownership_denied, _} to
            # debug. The atom IS the contract; don't translate.
            {:noreply,
             socket
             |> assign(:ctx, fresh_ctx)
             |> assign(:caller_caps, fresh_ctx.caps)
             |> put_flash(
               :error,
               gettext("Bind failed: %{r}", r: inspect(reason))
             )}
        end
    end
  end

  def handle_event(
        "unbind",
        %{"adapter-id" => adapter_id, "target-id" => target_id},
        socket
      ) do
    # codex r1 HIGH (2026-05-25): rebuild ctx from fresh caps — see
    # the same fix in add_binding above.
    fresh_ctx = fresh_ctx_for_action(socket)

    case ExternalMirror.unbind(
           socket.assigns.session_uri,
           adapter_id,
           target_id,
           fresh_ctx
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:ctx, fresh_ctx)
         |> assign(:caller_caps, fresh_ctx.caps)
         |> put_flash(:info, gettext("Unbound %{a} → %{t}.", a: adapter_id, t: target_id))
         |> refresh_bindings()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:ctx, fresh_ctx)
         |> assign(:caller_caps, fresh_ctx.caps)
         |> put_flash(
           :error,
           gettext("Unbind failed: %{r}", r: inspect(reason))
         )}
    end
  end

  def handle_event("toggle_expand", %{"binding-id" => binding_id}, socket) do
    new_expanded =
      if socket.assigns.expanded_binding_id == binding_id, do: nil, else: binding_id

    {:noreply, assign(socket, :expanded_binding_id, new_expanded)}
  end

  # ----- helpers -------------------------------------------------------------

  defp parse_session_uri(raw) when is_binary(raw) do
    decoded = URI.decode(raw)

    try do
      uri = Ezagent.URI.parse!(decoded)

      case uri do
        %URI{scheme: "session"} -> {:ok, uri}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp parse_session_uri(_), do: :error

  defp caller_caps(nil), do: MapSet.new()

  defp caller_caps(%URI{} = uri) do
    # Normalize via stock `URI.parse` so the URI's `:authority` field
    # is populated. `EzagentWeb.LiveAuth.parse_entity_uri/1` uses
    # `Ezagent.URI.parse!/1` which does NOT set `:authority`; the
    # downstream `Ezagent.Identity.bootstrap_self_cap/1` stores that
    # un-authority'd URI in `instance:` but `Ezagent.Capability.
    # cap_for_action/3` derives the needed instance from a
    # `URI.parse(...?action=...)` target whose `:authority` IS set.
    # `Capability.matches?/2`'s `instance_match?(same, same)` requires
    # struct equality — the `:authority` mismatch silently denies, and
    # `list_caps_for/1` returns `MapSet.new()` instead of the real
    # cap set. Re-parsing here closes the round-trip.
    normalized_uri = uri |> URI.to_string() |> URI.parse()
    Ezagent.Identity.list_caps_for(normalized_uri)
  end

  defp caller_caps(uri_str) when is_binary(uri_str), do: Ezagent.Identity.list_caps_for(uri_str)

  defp build_ctx(caller_uri, caller_caps) do
    %{
      caller: caller_uri || URI.parse("entity://user/system/admin"),
      caps: caller_caps || MapSet.new(),
      reply: :ignore
    }
  end

  defp unauthorized_message(:unauthorized),
    do: dgettext("errors", "You don't have permission to view this session's external mirrors.")

  defp unauthorized_message(:cross_workspace_denied),
    do:
      dgettext(
        "errors",
        "This session lives in a different workspace; switch workspace to manage it."
      )

  defp unauthorized_message(:no_such_actor),
    do: dgettext("errors", "Session isn't running yet — start it from /sessions first.")

  defp unauthorized_message(:not_ready),
    do: dgettext("errors", "Session is still starting up; try again in a moment.")

  defp unauthorized_message(other),
    do: gettext("Couldn't load bindings: %{r}", r: inspect(other))

  defp decorate_bindings(bindings, session_uri) do
    bindings
    |> Enum.map(fn binding ->
      worker_uri = WorkerSpawn.worker_uri_for(session_uri, binding.adapter_id, binding.target_id)
      stats = fetch_worker_stats(worker_uri)

      Map.merge(binding, %{
        worker_uri: worker_uri,
        worker_uri_str: URI.to_string(worker_uri),
        stats: stats
      })
    end)
  end

  defp fetch_worker_stats(%URI{} = worker_uri) do
    case Ezagent.Kind.get_slice(worker_uri, :external_mirror_worker) do
      {:ok, slice} when is_map(slice) ->
        %{
          count: Map.get(slice, :count, 0),
          error_count: Map.get(slice, :error_count, 0),
          last_published_at: Map.get(slice, :last_published_at),
          last_publish_result: Map.get(slice, :last_publish_result),
          subscription_state: Map.get(slice, :subscription_state, :unknown)
        }

      _ ->
        # Worker not (yet) spawned, or get_slice timed out — render
        # placeholders so the page doesn't crash on a partial reconcile.
        %{
          count: 0,
          error_count: 0,
          last_published_at: nil,
          last_publish_result: nil,
          subscription_state: :down
        }
    end
  end

  defp refresh_bindings(socket) do
    # codex r1 HIGH (2026-05-25): refresh ALSO re-resolves the caller's
    # caps so the dropdown's narrow-by-default reflects the live cap
    # state (revocation post-mount shrinks the dropdown on the next
    # poll cycle, not just on the next bind/unbind).
    fresh_ctx = fresh_ctx_for_action(socket)

    case ExternalMirror.list_bindings(socket.assigns.session_uri, fresh_ctx) do
      {:ok, bindings} ->
        socket
        |> assign(:ctx, fresh_ctx)
        |> assign(:caller_caps, fresh_ctx.caps)
        |> assign(:bindings, decorate_bindings(bindings, socket.assigns.session_uri))
        |> assign(
          :available_adapters,
          filter_adapters_by_cap(fresh_ctx.caps, socket.assigns.session_uri)
        )

      {:error, reason} when reason in [:unauthorized, :cross_workspace_denied] ->
        # codex r2 HIGH (2026-05-25): Cap 1 revoked mid-LV-session.
        # The previous render still shows the binding rows + worker
        # URIs the (now-unauthorized) caller can see. Per P18 + the
        # mount-side handling, an authorization loss is NOT
        # transient — clear the privileged surface AND navigate
        # away. Same shape mount uses for the same error class.
        socket
        |> assign(:bindings, [])
        |> assign(:available_adapters, [])
        |> assign(:binding_audit_events, %{})
        |> assign(:session_audit_events, [])
        |> assign(:ctx, fresh_ctx)
        |> assign(:caller_caps, fresh_ctx.caps)
        |> put_flash(:error, unauthorized_message(reason))
        |> push_navigate(to: "/sessions")

      {:error, _reason} ->
        # Transient (e.g. :not_ready / :no_such_actor / network glitch
        # during dispatch). Keep the LV mounted + surface a flash so
        # the operator knows; the next refresh cycle will recover.
        socket
        |> assign(:ctx, fresh_ctx)
        |> assign(:caller_caps, fresh_ctx.caps)
        |> put_flash(:error, gettext("Refresh failed — caps may have changed."))
    end
  end

  # codex r1 HIGH (2026-05-25): fresh ctx round-trips through
  # `Ezagent.Identity.list_caps_for/1` so the resulting MapSet IS the
  # User Kind's current `:identity` slice — not whatever was cached
  # at mount. Long-lived admin LVs would otherwise keep the original
  # mount-time caps and bypass post-mount revocation.
  defp fresh_ctx_for_action(socket) do
    caller_uri = socket.assigns.caller_uri
    build_ctx(caller_uri, caller_caps(caller_uri))
  end

  # P15 narrow-by-default: drop any adapter whose per-adapter allow cap
  # (Cap 2 per SPEC §4.2) the caller doesn't hold on THIS session. Per
  # SPEC §5.4 we filter on `cap_subject().behavior_module` directly so
  # the LV's dropdown matches what the bind facade would accept (no
  # TOCTOU at submit time).
  defp filter_adapters_by_cap(caller_caps, %URI{} = session_uri) do
    session_instance = Ezagent.URI.instance(session_uri)

    session_workspace =
      case Capability.workspace_of(session_uri) do
        %URI{} = ws -> ws
        :any -> :any
      end

    ExternalMirror.list_adapters()
    |> Enum.map(fn descriptor ->
      case ExternalMirror.AdapterRegistry.lookup(descriptor.id) do
        {:ok, module} -> Map.put(descriptor, :module, module)
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn %{module: module} ->
      caller_holds_adapter_cap?(caller_caps, module, session_instance, session_workspace)
    end)
  end

  defp caller_holds_adapter_cap?(caps, adapter_module, session_instance, session_workspace) do
    case safe_cap_subject(adapter_module) do
      {:ok, %{behavior_module: behavior_module}} ->
        # SPEC 2026-05-27 capability-action-axis — per-adapter Allow
        # Behaviors are convention cap-only with a single action
        # (e.g. `:allow_feishu`). Derive it from `actions/0`; fall
        # back to `:any` when unavailable.
        action =
          if Code.ensure_loaded?(behavior_module) and
               function_exported?(behavior_module, :actions, 0) do
            case behavior_module.actions() do
              [a] when is_atom(a) -> a
              _ -> :any
            end
          else
            :any
          end

        needed = %{
          kind: :session,
          behavior: behavior_module,
          action: action,
          instance: session_instance,
          workspace_uri: session_workspace
        }

        Enum.any?(caps, &Capability.matches?(&1, needed))

      :error ->
        false
    end
  end

  defp safe_cap_subject(adapter_module) do
    {:ok, adapter_module.cap_subject()}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp fresh_bind_form, do: to_form(%{"adapter_id" => "", "target_id" => ""}, as: "binding")

  defp audit_event_target(%{metadata: %{target: t}}) when is_binary(t), do: t
  defp audit_event_target(%{metadata: %{target: %URI{} = t}}), do: URI.to_string(t)
  defp audit_event_target(_), do: nil

  defp session_event?(target, session_uri_str) do
    target == session_uri_str or
      String.starts_with?(target, session_uri_str <> "?")
  end

  # codex r2 MED (2026-05-25): mutating bind/unbind only. `:list_bindings`
  # fires every 5s from the LV's own poll loop + from the operator
  # mounting the LV — both routine read noise that would saturate the
  # 20-event ring inside ~100s.
  defp interesting_session_action?(%{metadata: meta}) do
    action = Map.get(meta, :action)
    action in [:bind, :unbind, "bind", "unbind"]
  end

  defp interesting_session_action?(_), do: false

  defp binding_for_target(target, bindings) do
    Enum.find(bindings, fn b ->
      target == b.worker_uri_str or
        String.starts_with?(target, b.worker_uri_str <> "?")
    end)
  end

  defp prepend_to_ring(socket, assign_key, event) do
    existing = Map.get(socket.assigns, assign_key, [])
    update(socket, assign_key, fn _ -> Enum.take([event | existing], @audit_ring_max) end)
  end

  defp prepend_to_binding_ring(socket, binding_id, event) do
    rings = Map.get(socket.assigns, :binding_audit_events, %{})
    current = Map.get(rings, binding_id, [])
    new_ring = Enum.take([event | current], @audit_ring_max)
    assign(socket, :binding_audit_events, Map.put(rings, binding_id, new_ring))
  end

  # ----- render --------------------------------------------------------------

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
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={Map.get(assigns, :current_workspace_uri)}
      workspaces={Map.get(assigns, :workspaces, [])}
      workspace_name={Map.get(assigns, :workspace_name)}
      is_admin?={Map.get(assigns, :is_admin?, false)}
      is_system_member?={Map.get(assigns, :is_system_member?, false)}
      cmdk_nav_routes={Map.get(assigns, :cmdk_nav_routes, [])}
    >
      <:body>
        <AdminShell.admin_shell
          current_path={"/admin/sessions/" <> URI.encode_www_form(@session_uri_str) <> "/external_mirror"}
          active_section={:sessions}
        >
          <:main>
            <div class="px-6 py-6 max-w-6xl mx-auto text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("External mirrors")}>
                <:subtitle>
                  <span class="font-mono text-xs break-all">{@session_uri_str}</span>
                </:subtitle>
              </.page_header>

              <%!-- Existing bindings table --%>
              <.card id="bindings-card" class="mb-6">
                <div class="flex items-center justify-between mb-3">
                  <h2 class="text-sm font-medium uppercase tracking-wide text-zinc-700 dark:text-zinc-300">
                    {gettext("Bindings")}
                    <span class="ml-2 inline-block px-1.5 py-0.5 text-[10px] font-mono bg-zinc-100 dark:bg-zinc-800 rounded">
                      {length(@bindings)}
                    </span>
                  </h2>

                  <button
                    phx-click="refresh"
                    type="button"
                    class="text-xs text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100"
                  >
                    {gettext("Refresh")}
                  </button>
                </div>

                <p
                  :if={@bindings == []}
                  id="bindings-empty"
                  class="text-sm text-zinc-500 italic"
                >
                  {gettext("No external mirrors bound on this session.")}
                </p>

                <table
                  :if={@bindings != []}
                  id="bindings-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800 text-left text-[10px] uppercase tracking-wider text-zinc-500">
                      <th class="px-1 py-1.5">{gettext("Adapter")}</th>
                      <th class="px-1 py-1.5">{gettext("Target")}</th>
                      <th class="px-1 py-1.5">{gettext("Bound at")}</th>
                      <th class="px-1 py-1.5">{gettext("Worker")}</th>
                      <th class="px-1 py-1.5 text-right">{gettext("Publishes")}</th>
                      <th class="px-1 py-1.5 text-right">{gettext("Errors")}</th>
                      <th class="px-1 py-1.5">{gettext("Last result")}</th>
                      <th class="px-1 py-1.5">{gettext("Last @")}</th>
                      <th class="px-1 py-1.5 text-right">{gettext("Actions")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for binding <- @bindings do %>
                      <tr
                        id={"binding-row-" <> binding.binding_id}
                        class="border-b border-zinc-100 dark:border-zinc-900 hover:bg-zinc-50 dark:hover:bg-zinc-900 cursor-pointer"
                        phx-click="toggle_expand"
                        phx-value-binding-id={binding.binding_id}
                      >
                        <td class="px-1 py-1 font-mono">{binding.adapter_id}</td>
                        <td class="px-1 py-1 font-mono break-all">{inspect(binding.target_id)}</td>
                        <td class="px-1 py-1 font-mono text-[11px] text-zinc-500">
                          {DateTime.to_iso8601(binding.bound_at)}
                        </td>
                        <td class="px-1 py-1 font-mono text-[11px] text-zinc-500 break-all">
                          {binding.worker_uri_str}
                        </td>
                        <td class="px-1 py-1 text-right font-mono">{binding.stats.count}</td>
                        <td class="px-1 py-1 text-right font-mono">{binding.stats.error_count}</td>
                        <td class="px-1 py-1">
                          <.badge variant={result_badge_variant(binding.stats.last_publish_result)}>
                            {format_publish_result(binding.stats.last_publish_result)}
                          </.badge>
                        </td>
                        <td class="px-1 py-1 font-mono text-[11px] text-zinc-500">
                          {format_ts(binding.stats.last_published_at)}
                        </td>
                        <td class="px-1 py-1 text-right">
                          <button
                            phx-click="unbind"
                            phx-value-adapter-id={binding.adapter_id}
                            phx-value-target-id={binding.target_id}
                            data-confirm={gettext("Unbind %{a} → %{t}?", a: binding.adapter_id, t: binding.target_id)}
                            type="button"
                            class="text-xs text-rose-600 dark:text-rose-400 hover:underline"
                            phx-click-loading
                          >
                            {gettext("Unbind")}
                          </button>
                        </td>
                      </tr>
                      <tr :if={@expanded_binding_id == binding.binding_id}>
                        <td colspan="9" class="bg-zinc-50 dark:bg-zinc-900 px-4 py-3">
                          <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-2">
                            {gettext("Recent audit events (last 20 — per binding)")}
                          </div>
                          <div
                            :if={events_for_binding(@binding_audit_events, binding) == []}
                            class="text-xs italic text-zinc-500"
                          >
                            {gettext(
                              "No audit events for this binding yet. Trigger a slice change to generate publishes."
                            )}
                          </div>
                          <ul
                            :if={events_for_binding(@binding_audit_events, binding) != []}
                            class="space-y-1 font-mono text-[11px]"
                          >
                            <li
                              :for={ev <- events_for_binding(@binding_audit_events, binding)}
                              class="text-zinc-700 dark:text-zinc-300"
                            >
                              <span class="text-zinc-500">{DateTime.to_iso8601(ev.at)}</span>
                              <span class="ml-2">{format_audit_event(ev)}</span>
                            </li>
                          </ul>

                          <div :if={@session_audit_events != []} class="mt-4 pt-3 border-t border-zinc-200 dark:border-zinc-800">
                            <div class="text-[10px] uppercase tracking-wide text-zinc-500 mb-2">
                              {gettext("Session-level events (bind / unbind / list)")}
                            </div>
                            <ul class="space-y-1 font-mono text-[11px]">
                              <li :for={ev <- @session_audit_events} class="text-zinc-600 dark:text-zinc-400">
                                <span class="text-zinc-500">{DateTime.to_iso8601(ev.at)}</span>
                                <span class="ml-2">{format_audit_event(ev)}</span>
                              </li>
                            </ul>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </.card>

              <%!-- Add binding form --%>
              <.card id="add-binding-card">
                <h2 class="text-sm font-medium uppercase tracking-wide text-zinc-700 dark:text-zinc-300 mb-3">
                  {gettext("Add binding")}
                </h2>
                <p
                  :if={@available_adapters == []}
                  id="no-adapters-msg"
                  class="text-xs italic text-zinc-500"
                >
                  {gettext(
                    "You don't hold any per-adapter allow caps on this session. Ask an admin to grant one."
                  )}
                </p>

                <.form
                  :if={@available_adapters != []}
                  for={@bind_form}
                  id="add-binding-form"
                  phx-submit="add_binding"
                  class="grid grid-cols-1 sm:grid-cols-3 gap-3 items-end"
                >
                  <div>
                    <label class="block text-[10px] uppercase tracking-wide text-zinc-500 mb-1">
                      {gettext("Adapter")}
                    </label>
                    <select
                      name="binding[adapter_id]"
                      id="add-binding-adapter"
                      class="w-full text-xs px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 font-mono"
                    >
                      <option value="">{gettext("— pick —")}</option>
                      <option :for={a <- @available_adapters} value={a.id}>
                        {a.display_name} ({a.id})
                      </option>
                    </select>
                  </div>

                  <div>
                    <label class="block text-[10px] uppercase tracking-wide text-zinc-500 mb-1">
                      {gettext("Target id")}
                    </label>
                    <input
                      type="text"
                      name="binding[target_id]"
                      id="add-binding-target"
                      placeholder={gettext("adapter-specific (e.g. oc_xxx for Feishu)")}
                      class="w-full text-xs px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 font-mono"
                    />
                  </div>

                  <div>
                    <.button type="submit" variant="primary" class="w-full">
                      {gettext("Bind")}
                    </.button>
                  </div>
                </.form>
              </.card>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  # ----- view helpers --------------------------------------------------------

  defp result_badge_variant({:error, _}), do: "danger"
  defp result_badge_variant(:skip), do: "info"
  defp result_badge_variant(:ok), do: "success"
  defp result_badge_variant(_), do: "default"

  defp format_publish_result(:ok), do: gettext("ok")
  defp format_publish_result(:skip), do: gettext("skipped")
  defp format_publish_result({:error, reason}), do: "error: " <> short_reason(reason)
  defp format_publish_result(nil), do: gettext("—")
  defp format_publish_result(other), do: inspect(other)

  defp short_reason(reason) do
    reason
    |> inspect()
    |> String.slice(0, 60)
  end

  defp format_ts(nil), do: gettext("never")
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other), do: inspect(other)

  defp events_for_binding(binding_audit_events, %{binding_id: binding_id}) do
    Map.get(binding_audit_events, binding_id, [])
  end

  defp format_audit_event(%{event: event_path, metadata: meta}) do
    action = Map.get(meta, :action, "—")
    reason = Map.get(meta, :reason)

    parts = [
      "event=" <> inspect(event_path),
      "action=" <> to_string(action)
    ]

    parts =
      if reason, do: parts ++ ["reason=" <> inspect(reason)], else: parts

    Enum.join(parts, " ")
  end

end
