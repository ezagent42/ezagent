defmodule EzagentPluginLiveview.Admin.SessionContext do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1, stream: 4]

  use Gettext, backend: EzagentPluginLiveview.Gettext

  require Logger

  alias Ezagent.UI.SessionViewRegistry
  alias EzagentPluginLiveview.Views.ConversationView

  @message_limit 50
  @view_display_order [:conversation, :page, :routing, :external_mirror, :pty]
  @routing_tables_for_session [
    EzagentDomainInstanceMessage.Routing.MentionRouting
  ]

  @doc """
  URI of the default `:main` session for `workspace_uri`.

  For a `workspace://` URI, scopes the session to that workspace's name;
  any other input falls back to the `:system` workspace.
  """
  def default_main_session_uri(%URI{scheme: "workspace"} = workspace_uri),
    do: Ezagent.URI.session(Ezagent.URI.name!(workspace_uri), :default, :main)

  def default_main_session_uri(_),
    do: Ezagent.URI.session(:system, :default, :main)

  @doc """
  Switch the LiveView to `session_uri`, loading its messages and views.

  Authorizes the view via `authorize_session_view/2` first; on success it
  self-joins, assigns the session context, picks a `current_view` (keeps the
  existing one if still applicable, else the first applicable view, else
  `:conversation`), and resets the `:messages` stream. A
  `:cross_workspace_denied` authorization failure assigns a `flash_error`
  instead and leaves the current session unchanged.
  """
  def select_session(socket, %URI{} = session_uri) do
    case authorize_session_view(socket, session_uri) do
      :ok ->
        new_messages = load_session_messages(session_uri)
        applicable = SessionViewRegistry.applicable_views(session_uri)

        new_view =
          cond do
            Enum.any?(applicable, &(&1.id == socket.assigns.current_view)) ->
              socket.assigns.current_view

            applicable != [] ->
              hd(applicable).id

            true ->
              :conversation
          end

        socket
        |> assign(:current_session_uri, session_uri)
        |> maybe_self_join(session_uri)
        |> assign_session_context(session_uri)
        |> assign(:current_view, new_view)
        |> assign(:active_pty_agent_uri, nil)
        |> assign(:oldest_cursor, oldest_cursor(new_messages))
        |> assign(:messages_empty?, new_messages == [])
        |> stream(:messages, new_messages, reset: true)

      {:error, :cross_workspace_denied} ->
        assign(
          socket,
          :flash_error,
          gettext("Cross-workspace denied — that session belongs to a different workspace.")
        )
    end
  end

  @doc """
  Authorize the caller to VIEW `session_uri` from the current socket.

  Returns `:ok` when the session has no specific workspace (`:any`), when its
  workspace matches the caller's `current_workspace_uri`, or when the caller
  holds explicit cross-workspace authority; otherwise
  `{:error, :cross_workspace_denied}`.
  """
  def authorize_session_view(socket, %URI{} = session_uri) do
    caller_workspace = socket.assigns[:current_workspace_uri]
    target_workspace = Ezagent.Capability.workspace_of(session_uri)
    caller_uri = socket.assigns[:caller_uri]
    caller_caps = socket.assigns[:caller_caps] || []

    cond do
      target_workspace == :any ->
        :ok

      match?(%URI{}, caller_workspace) and match?(%URI{}, target_workspace) and
          URI.to_string(caller_workspace) == URI.to_string(target_workspace) ->
        :ok

      caller_holds_cross_workspace_authority?(caller_uri, caller_caps) ->
        :ok

      true ->
        {:error, :cross_workspace_denied}
    end
  end

  @doc """
  Whether `caller_uri` holds any capability granting cross-workspace access.

  Normalizes `caps` (list / `MapSet` / single) to a list and returns `true` if
  any of them is a cross-workspace capability for `caller_uri`. A `nil` caller
  never has cross-workspace authority.
  """
  def caller_holds_cross_workspace_authority?(nil, _caps), do: false

  def caller_holds_cross_workspace_authority?(%URI{} = caller_uri, caps) do
    caps_list =
      cond do
        is_list(caps) -> caps
        is_struct(caps, MapSet) -> MapSet.to_list(caps)
        true -> List.wrap(caps)
      end

    Enum.any?(caps_list, &Ezagent.Capability.cross_workspace?(&1, caller_uri))
  end

  @doc """
  Best-effort self-join of the caller to `session_uri` on a live socket.

  No-op until the socket is `connected?/1` (so the join runs once, not on the
  dead static render). When connected and the caller has both a URI and caps,
  it just-in-time provisions the per-session `:join` cap (owner-rooted) then
  dispatches `session.join`; on success it mounts the participation-tier caps.
  Every failure (`:unauthorized`, cross-workspace, unregistered member, other)
  is handled gracefully — a flash or a log — and returns the socket so the
  caller can at least observe.
  """
  def maybe_self_join(socket, %URI{} = session_uri) do
    if not connected?(socket) do
      socket
    else
      do_maybe_self_join(socket, session_uri)
    end
  end

  defp do_maybe_self_join(socket, %URI{} = session_uri) do
    caller_uri = Map.get(socket.assigns, :caller_uri) || socket.assigns[:current_entity_uri]
    caller_caps = Map.get(socket.assigns, :caller_caps)

    case caller_uri do
      %URI{} = caller_uri when not is_nil(caller_caps) ->
        target = Ezagent.URI.with_action(session_uri, :session, :join)

        # #154 PR-甲-2 §B — session-policy join authority. `User.default_caps`
        # no longer mints a broad `cap(:session,:any,:any)` baseline, so the
        # self-joiner's `caller_caps` no longer carries `:join`. Provision the
        # per-session `:join` cap JUST-IN-TIME, owner-rooted (owner / existing
        # member / first-non-anon owner-claim → granted; anyone else → denied →
        # the existing `:unauthorized` flash degrades to "observe"). `:sync` so
        # the cap lands in the joiner's slice before the dispatch authorizes via
        # the live slice read (`granted_via_holds_cap?`).
        _ =
          Ezagent.Behavior.Session.Membership.provision_join_authority(
            session_uri,
            caller_uri
          )

        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{member: caller_uri},
            ctx: %{
              caller: caller_uri,
              caps: caller_caps,
              reply: :ignore
            }
          })

        case result do
          :ok ->
            # #154 PR-甲-2 §A — mount the per-class participation tier AFTER a
            # successful join (caller-side; resolves `Users.confirmed?` from the
            # DB, never `handle_join`). Best-effort + no-op for agents.
            _ =
              Ezagent.Behavior.Session.Membership.mount_participation_caps(
                session_uri,
                caller_uri
              )

            socket

          {:ok, _} ->
            _ =
              Ezagent.Behavior.Session.Membership.mount_participation_caps(
                session_uri,
                caller_uri
              )

            socket

          {:error, :unauthorized} ->
            assign(
              socket,
              :flash_error,
              gettext(
                "No chat.join cap on %{session} — ask the session owner to invite you, or you can only observe.",
                session: URI.to_string(session_uri)
              )
            )

          {:error, :cross_workspace_denied} ->
            assign(
              socket,
              :flash_error,
              gettext(
                "Session %{session} is in another workspace — auto-join skipped.",
                session: URI.to_string(session_uri)
              )
            )

          {:error, {:member_not_registered, _}} ->
            Logger.warning(
              "AdminLive.maybe_self_join: caller Kind not registered " <>
                "for #{URI.to_string(caller_uri)} on #{URI.to_string(session_uri)} — " <>
                "skipping auto-join (next remount will retry)."
            )

            socket

          {:error, reason} ->
            Logger.warning(
              "AdminLive.maybe_self_join: chat.join failed for " <>
                "#{URI.to_string(caller_uri)} on #{URI.to_string(session_uri)}: " <>
                inspect(reason)
            )

            socket
        end

      _ ->
        socket
    end
  end

  @doc """
  Assign every per-session derived value the admin view renders for `session_uri`.

  Reads the session's members, legends, applicable views, scoped routing rules
  and external-mirror bindings, builds invite/member option lists and the
  session-info summary, computes orchestrator health and restart eligibility,
  and assigns them all onto the socket (finishing with the routing URI option
  lists). Used both on initial select and on refresh.
  """
  def assign_session_context(socket, session_uri) do
    members = read_session_members(session_uri)
    member_uris = Enum.map(members, & &1.uri)
    invite_options = invite_options_for(socket, session_uri, member_uris)

    applicable =
      session_uri
      |> SessionViewRegistry.applicable_views()
      |> sort_views()

    session_routing_rules = list_session_scoped_rules(session_uri)
    session_bindings = list_session_bindings(socket, session_uri)
    display_map = Ezagent.EntityPresenter.display_many(member_uris)

    member_options =
      member_uris
      |> Enum.sort()
      |> Enum.map(fn uri ->
        %{"uri" => uri, "display_name" => Map.get(display_map, uri, uri)}
      end)

    {orchestrator_health, can_restart?} = compute_orchestrator_health(socket, session_uri)
    session_legends = read_session_legends(session_uri)

    socket
    |> assign(:session_members, members)
    |> assign(:member_options, member_options)
    |> assign(:session_legends, session_legends)
    |> assign(:invite_options, invite_options)
    |> assign(:display_map, display_map)
    |> assign(:applicable_views, applicable)
    |> assign(:view_module, view_module_for(applicable, current_view_or_default(socket)))
    |> assign(:session_info, build_session_info(session_uri, members))
    |> assign(:feishu_chat_ids, feishu_chat_ids_for(session_uri))
    |> assign(:session_routing_rules, session_routing_rules)
    |> assign(:session_bindings, session_bindings)
    |> assign(:orchestrator_health, orchestrator_health)
    |> assign(:orchestrator_can_restart?, can_restart?)
    |> assign(:orchestrator_flash_error, nil)
    |> assign_routing_uri_options()
  end

  @doc """
  Classify a session's orchestrator and whether the caller may restart it.

  Returns `{health, can_restart?}`. `can_restart?` is `true` only when the
  orchestrator is `:crashed` AND the caller holds the restart capability. A
  session not bound to a workspace (or a non-URI input) yields `{nil, false}`.
  """
  def compute_orchestrator_health(socket, %URI{} = session_uri) do
    case Ezagent.Orchestrator.Health.classify(session_uri) do
      {:ok, health} ->
        can_restart? =
          health.status == :crashed and
            caller_can_restart_orchestrator?(socket, session_uri)

        {health, can_restart?}

      {:error, :session_not_workspace_bound} ->
        {nil, false}
    end
  end

  def compute_orchestrator_health(_socket, _), do: {nil, false}

  @doc """
  Whether the socket's caller holds the orchestrator-restart capability.

  Checks `caller_caps` against the `OrchestratorAdmin.restart` capability
  scoped to `session_uri`'s workspace (`:any` when the session has none).
  """
  def caller_can_restart_orchestrator?(socket, %URI{} = session_uri) do
    caps = Map.get(socket.assigns, :caller_caps, MapSet.new())

    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri:
        case Ezagent.Capability.workspace_of(session_uri) do
          %URI{} = ws -> ws
          :any -> :any
        end
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end

  def caller_can_restart_orchestrator?(_socket, _), do: false

  @doc """
  Extract the orchestrator fields (`:orchestrator_uri`, `:orchestrator_status`,
  `:orchestrator_error`) from a session-create result map into a flat meta map,
  defaulting missing keys to `nil`.
  """
  def session_create_meta(result) when is_map(result) do
    %{
      orchestrator_uri: Map.get(result, :orchestrator_uri),
      orchestrator_status: Map.get(result, :orchestrator_status),
      orchestrator_error: Map.get(result, :orchestrator_error)
    }
  end

  @doc """
  External-mirror bindings for `session_uri`, as the socket's caller.

  Dispatches `ExternalMirror.list_bindings/2` with the caller's identity and
  caps; returns the binding list or `[]` on any error or exception (the admin
  view degrades to "no bindings" rather than crashing).
  """
  def list_session_bindings(socket, %URI{} = session_uri) do
    ctx = %{
      caller: Map.get(socket.assigns, :caller_uri) || socket.assigns.current_entity_uri,
      caps: Map.get(socket.assigns, :caller_caps, MapSet.new()),
      reply: :ignore
    }

    case Ezagent.ExternalMirror.list_bindings(session_uri, ctx) do
      {:ok, bindings} -> bindings
      _ -> []
    end
  rescue
    _ -> []
  end

  def list_session_bindings(_socket, _), do: []

  @doc """
  Invitable entities for `session_uri`, excluding existing members.

  Lists the caller's visible entities in the session's workspace and rejects
  any whose URI is already in `member_uris`. Returns `[]` when the socket has
  no current entity URI.
  """
  def invite_options_for(socket, session_uri, member_uris) do
    case Map.get(socket.assigns, :current_entity_uri) do
      %URI{} = caller_uri ->
        joined = MapSet.new(member_uris)

        caller_uri
        |> Ezagent.UI.UriOptions.entities(invite_workspace_uri(socket, session_uri))
        |> Enum.reject(&MapSet.member?(joined, &1.uri))

      _ ->
        []
    end
  end

  @doc """
  Workspace URI to scope invites to, using the socket's current session.

  Convenience over `invite_workspace_uri/2` that reads
  `current_session_uri` from the socket assigns.
  """
  def invite_workspace_uri(socket) do
    invite_workspace_uri(socket, Map.get(socket.assigns, :current_session_uri))
  end

  @doc """
  Workspace URI to scope invites to for `session_uri`.

  Prefers the session's own workspace; falls back to the socket's
  `current_workspace_uri` when the session has none (or the arg is not a URI).
  """
  def invite_workspace_uri(socket, %URI{} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = ws -> ws
      _ -> socket.assigns.current_workspace_uri
    end
  end

  def invite_workspace_uri(socket, _), do: socket.assigns.current_workspace_uri

  @doc """
  Reset the invite UI after a successful invite.

  Re-derives the session context (so the new member appears), closes the invite
  modal, clears any flash error, and returns a `{:noreply, socket}` reply tuple.
  """
  def invite_ok(socket, session_uri) do
    {:noreply,
     socket
     |> assign_session_context(session_uri)
     |> assign(:invite_open, false)
     |> assign(:flash_error, nil)}
  end

  @doc """
  Assign the entity / receiver option lists for the routing-rule form.

  Computes both from the caller and the routing workspace
  (`routing_workspace_uri/1`) and assigns `:routing_entity_options` and
  `:routing_receiver_options`.
  """
  def assign_routing_uri_options(socket) do
    caller_uri = socket.assigns.current_entity_uri
    workspace_uri = routing_workspace_uri(socket)

    socket
    |> assign(:routing_entity_options, Ezagent.UI.UriOptions.entities(caller_uri, workspace_uri))
    |> assign(:routing_receiver_options, routing_receiver_options(caller_uri, workspace_uri))
  end

  @doc """
  Receiver options for a routing rule: the broadcast token plus entities/sessions.

  Prepends an "all session members (broadcast)" option (keyed by the resolver's
  session-members token) ahead of the caller's visible entities and sessions in
  `workspace_uri`.
  """
  def routing_receiver_options(caller_uri, workspace_uri) do
    broadcast = %{
      uri: Ezagent.Routing.Resolver.session_members_token(),
      label: gettext("All session members (broadcast)"),
      kind: :broadcast,
      flavor: nil
    }

    [broadcast | Ezagent.UI.UriOptions.entities_and_sessions(caller_uri, workspace_uri)]
  end

  @doc """
  Workspace URI used to scope routing-rule options.

  Prefers the current session's workspace; falls back to the socket's
  `current_workspace_uri` when there is no session or the session has no
  workspace.
  """
  def routing_workspace_uri(socket) do
    case Map.get(socket.assigns, :current_session_uri) do
      %URI{} = session_uri ->
        case Ezagent.Capability.workspace_of(session_uri) do
          %URI{} = ws -> ws
          _ -> socket.assigns.current_workspace_uri
        end

      _ ->
        socket.assigns.current_workspace_uri
    end
  end

  @doc """
  Order session views by the fixed `@view_display_order`.

  Views whose `:id` appears in the order list come first in that order; any
  unlisted view sorts after them, ordered by `:id`.
  """
  def sort_views(views) do
    Enum.sort_by(views, fn %{id: id} ->
      case Enum.find_index(@view_display_order, &(&1 == id)) do
        nil -> {1, id}
        idx -> {0, idx}
      end
    end)
  end

  @doc """
  The socket's `:current_view`, defaulting to `:conversation` when unset.
  """
  def current_view_or_default(socket) do
    case Map.get(socket.assigns, :current_view) do
      nil -> :conversation
      v -> v
    end
  end

  @doc """
  Resolve the view module to render for `current_view_id`.

  Returns the matching view's `:module` from `applicable`; if none matches,
  falls back to the registered `:conversation` view module, and finally to
  `ConversationView` if even that lookup fails.
  """
  def view_module_for(applicable, current_view_id) do
    case Enum.find(applicable, &(&1.id == current_view_id)) do
      %{module: mod} ->
        mod

      nil ->
        case SessionViewRegistry.lookup(:conversation) do
          {:ok, mod} -> mod
          :error -> ConversationView
        end
    end
  end

  @doc """
  Re-run `assign_session_context/2` for the socket's current session.

  Used to refresh members, views and routing after a mutation.
  """
  def refresh_views_and_members(socket) do
    assign_session_context(socket, socket.assigns.current_session_uri)
  end

  @doc """
  Build the header summary map for `session_uri`.

  Returns `%{member_count, workspace_uri, created_at, generator}`. Note
  `created_at` is the timestamp of the session's MOST RECENT message
  (`MessageStore.recent_in_session/2` ordered newest-first), used as a proxy
  for activity; `generator` is the spawning template info or `nil`.
  """
  def build_session_info(%URI{} = session_uri, members) do
    workspace_str =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws_uri} -> URI.to_string(ws_uri)
        :error -> nil
      end

    created_at =
      case Ezagent.MessageStore.recent_in_session(session_uri, 1) do
        [%Ezagent.Message{inserted_at: at}] -> at
        _ -> nil
      end

    %{
      member_count: length(members),
      workspace_uri: workspace_str,
      created_at: created_at,
      generator: load_generator_info(session_uri)
    }
  end

  @doc """
  Spawning-template ("generator") summary for a live session, or `nil`.

  Returns `nil` when the session isn't running, has no session slice, or has no
  orchestrator template and no agent slots. Otherwise returns a map describing
  the working copy: `orchestrator_template_uri`, `agent_slots`, the count of
  `filled` vs `pending` slots, and the `description`. Any exception degrades to
  `nil`.
  """
  def load_generator_info(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      :error ->
        nil

      {:ok, _pid} ->
        slice =
          case Ezagent.Kind.get_slice(session_uri, :session) do
            {:ok, chat_slice} when is_map(chat_slice) -> chat_slice
            _ -> nil
          end

        if is_map(slice) do
          wc = Ezagent.Behavior.Session.template_working_copy(slice)

          if (wc[:agent_slots] || []) == [] and is_nil(wc[:orchestrator_template_uri]) do
            nil
          else
            slots = wc[:agent_slots] || []
            filled = Enum.count(slots, fn {_n, _src, worker, _g} -> not is_nil(worker) end)
            pending = length(slots) - filled

            %{
              orchestrator_template_uri: wc[:orchestrator_template_uri],
              agent_slots: slots,
              filled: filled,
              pending: pending,
              description: wc[:description] || ""
            }
          end
        end
    end
  rescue
    _ -> nil
  end

  @doc """
  Routing rules scoped to `session_uri`, across the session routing tables.

  Scans `@routing_tables_for_session`, parses each rule's matcher (skipping
  invalid ones), keeps only matchers that target this session, and returns a
  display-shaped map per rule (id, table name, matcher + repr, receivers +
  repr, source, enabled), sorted by id.
  """
  def list_session_scoped_rules(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    @routing_tables_for_session
    |> Enum.flat_map(fn table ->
      rules = Ezagent.Routing.RuleStore.list(table)

      for row <- rules,
          matcher = parse_matcher(row.matcher_data),
          matcher != :invalid,
          matcher_targets_session?(matcher, session_str) do
        %{
          id: row.id,
          table_name: Atom.to_string(table),
          matcher: matcher,
          matcher_repr: inspect(matcher),
          receivers: row.receivers,
          receivers_repr: Enum.join(row.receivers, ", "),
          source: row.source,
          enabled: row.enabled
        }
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  def list_session_scoped_rules(_), do: []

  @doc """
  Parse stored matcher JSON into a matcher term.

  Returns the matcher on success, or the `:invalid` sentinel (not an
  `{:error, _}` tuple) on any parse failure, so callers can filter it out.
  """
  def parse_matcher(matcher_data) do
    case Ezagent.Routing.Matcher.from_json(matcher_data) do
      {:ok, m} -> m
      _ -> :invalid
    end
  end

  @doc """
  Whether a routing matcher references `session_str`.

  True for an `{:in_session, s}` leaf matching the session, and recursively
  through `:and` / `:or` (any) and `:not` (inner) combinators; any other
  matcher returns `false`.
  """
  def matcher_targets_session?({:in_session, s}, session_str), do: s == session_str

  def matcher_targets_session?({:and, items}, s) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, s))

  def matcher_targets_session?({:or, items}, s) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, s))

  def matcher_targets_session?({:not, inner}, s),
    do: matcher_targets_session?(inner, s)

  def matcher_targets_session?(_, _), do: false

  @doc """
  Feishu chat IDs bound to `session_uri`, or `[]` when the Feishu plugin is absent.

  Guards on the optional `EzagentPluginFeishu.InboundChatLookup` module being
  loaded so the admin view works without the Feishu plugin.
  """
  def feishu_chat_ids_for(%URI{} = session_uri) do
    if Code.ensure_loaded?(EzagentPluginFeishu.InboundChatLookup) do
      EzagentPluginFeishu.InboundChatLookup.chat_ids_for(session_uri)
    else
      []
    end
  end

  @doc false
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members \\ [])

  def parse_mentions(text, members) when is_binary(text) and is_list(members) do
    uri_form = parse_uri_mentions(text)
    bare_form = parse_bare_mentions(text, members)

    (uri_form ++ bare_form)
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_, _), do: []

  @doc false
  @spec parse_mentions(String.t(), [map()], map()) :: {[URI.t()], [String.t()]}
  def parse_mentions(text, members, legends)
      when is_binary(text) and is_list(members) and is_map(legends) do
    if map_size(legends) == 0 do
      {parse_mentions(text, members), []}
    else
      legend_names =
        legend_mention_tokens(text)
        |> Enum.filter(fn name ->
          match?({:legend, _}, Ezagent.Routing.Legend.mention_token(legends, name))
        end)

      stripped_text = strip_legend_tokens(text, legend_names)
      mentions = parse_mentions(stripped_text, members)

      {mentions, legend_names}
    end
  end

  def parse_mentions(_, _, _), do: {[], []}

  defp strip_legend_tokens(text, []), do: text

  defp strip_legend_tokens(text, legend_names) do
    Enum.reduce(legend_names, text, fn name, acc ->
      re = ~r/(?<![\p{L}\p{N}_])@#{Regex.escape(name)}/u
      Regex.replace(re, acc, "")
    end)
  end

  defp legend_mention_tokens(text) do
    ~r/(?<![\p{L}\p{N}_])@([\p{L}\p{N}][\p{L}\p{N}._-]*)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp parse_uri_mentions(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn uri_str ->
      try do
        [Ezagent.URI.new!(uri_str)]
      rescue
        ArgumentError -> []
      end
    end)
  end

  defp parse_bare_mentions(text, members) when members != [] do
    ~r/(?<![\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(fn name -> resolve_member_name(name, members) end)
  end

  defp parse_bare_mentions(_, _), do: []

  defp resolve_member_name(name, members) do
    by_segment = match_members(members, &(uri_path_segment(Map.get(&1, "uri")) == name))

    candidates =
      if by_segment != [] do
        by_segment
      else
        match_members(members, &(Map.get(&1, "display_name") == name))
      end

    case unique_uris(candidates) do
      [uri_str] ->
        try do
          [Ezagent.URI.new!(uri_str)]
        rescue
          ArgumentError -> []
        end

      _ ->
        []
    end
  end

  defp match_members(members, pred) do
    Enum.filter(members, fn
      m when is_map(m) -> pred.(m)
      _ -> false
    end)
  end

  defp unique_uris(members) do
    members
    |> Enum.map(&Map.get(&1, "uri"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp uri_path_segment(uri_str) when is_binary(uri_str) do
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{} = uri -> uri |> Ezagent.URI.name() |> elem_or_nil()
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp uri_path_segment(_), do: nil

  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(:error), do: nil

  @doc """
  Convert a view-id string to its existing atom safely.

  Returns `{:ok, atom}` for a known atom, or `:error` (no new atoms are
  created) when the string isn't an existing atom or isn't a binary.
  """
  def safe_view_id(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end

  def safe_view_id(_), do: :error

  @doc """
  Count currently-registered agent Kinds (entity URIs of type `:agent`).
  """
  def count_alive_agents do
    Ezagent.KindRegistry.list_all()
    |> Enum.count(fn {uri_str, _pid} -> entity_type?(uri_str, :agent) end)
  end

  @doc """
  Count connected agent bridges, or `0` when the bridge registry is unavailable.
  """
  def count_connected_bridges do
    if Code.ensure_loaded?(Ezagent.AgentBridge.Registry) do
      length(Ezagent.AgentBridge.Registry.list_connected())
    else
      0
    end
  end

  @doc """
  The `:ezagent_core` application version as a string, or `"dev"` if unset.
  """
  def ezagent_version do
    case Application.spec(:ezagent_core, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  PubSub topic for a session's events; delegates to
  `Ezagent.Behavior.Session.session_events_topic/1`.
  """
  def session_events_topic(%URI{} = uri), do: Ezagent.Behavior.Session.session_events_topic(uri)

  @doc """
  List sessions in a workspace.

  Delegates to `EzagentDomainInstanceMessage.list_sessions/1` for a
  `workspace://` URI; returns `[]` for anything else.
  """
  def list_sessions_for(%URI{scheme: "workspace"} = workspace_uri),
    do: EzagentDomainInstanceMessage.list_sessions(workspace_uri)

  def list_sessions_for(_), do: []

  @doc """
  Load the most recent messages of a session as render-ready rows.

  Fetches up to `@message_limit` newest messages, reverses them to
  chronological (oldest-first) order, and maps them through
  `messages_to_rows/1` for the message stream.
  """
  def load_session_messages(%URI{} = session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
    |> messages_to_rows()
  end

  @doc """
  Cursor (oldest visible `:at` timestamp) for "load older" paging.

  Takes the `:at` of the FIRST row — which, given the oldest-first ordering
  produced by `load_session_messages/1`, is the oldest currently-loaded
  message. Returns `nil` when there are no rows / no DateTime.
  """
  def oldest_cursor(rows) do
    case rows do
      [%{at: %DateTime{} = at} | _] -> at
      _ -> nil
    end
  end

  @doc """
  Log a non-ready orchestrator status seen while rehydrating a session.

  No-op (returns `:ok`) when the meta's `:orchestrator_status` is `:ready`;
  otherwise logs the status and error for diagnostics. Always returns `:ok`.
  """
  def log_orchestrator_status_on_rehydrate(session_uri, meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        :ok

      status ->
        Logger.info(
          "AdminLive.ensure_main_session rehydrate: orchestrator " <>
            "status=#{inspect(status)} for #{URI.to_string(session_uri)} " <>
            "(error=#{inspect(Map.get(meta, :orchestrator_error))})"
        )
    end
  end

  def log_orchestrator_status_on_rehydrate(_, _), do: :ok

  defp read_session_members(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members} = slice} when is_map(members) ->
        last_seen = Map.get(slice, :last_seen, %{})

        for {uri, %{online: online?}} <- members do
          %{
            uri: URI.to_string(uri),
            online: online?,
            last_seen: Map.get(last_seen, uri)
          }
        end
        |> Enum.sort_by(& &1.uri)

      _ ->
        []
    end
  end

  defp read_session_legends(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} when is_map(slice) -> Ezagent.Behavior.Session.legends_of(slice)
      _ -> %{}
    end
  end

  # NOTE: maps to the LEGACY topic (`esr:cc_channel:bridges`), not the
  # generic AgentBridge topic. admin_live subscribes here and only handles
  # the `{:cc_connected, _, _}` / `{:cc_disconnected, _}` messages, which
  # are broadcast solely on the legacy topic. The deprecated shim's
  # `BridgeRegistry.topic/0` delegated to `legacy_topic/0`, so this call
  # preserves that behavior after removing the shim.
  @doc """
  PubSub topic the admin view subscribes to for bridge connect/disconnect events.

  Deliberately the LEGACY topic (`esr:cc_channel:bridges`), not the generic
  AgentBridge topic, because the `{:cc_connected, _, _}` / `{:cc_disconnected,
  _}` messages admin_live handles are broadcast only there.
  """
  def bridge_topic_safely, do: Ezagent.AgentBridge.Registry.legacy_topic()

  @doc """
  Render-ready row for a single message.

  Resolves the sender's display name and kind (`:user` / `:agent` / `:other`)
  and extracts body text + attachment links into a map keyed for the message
  stream. For batches prefer `messages_to_rows/1`, which resolves display names
  in one query.
  """
  def message_to_row(%Ezagent.Message{} = msg) do
    sender_str = URI.to_string(msg.sender)

    %{
      id: msg.id,
      sender: sender_str,
      sender_display: Ezagent.EntityPresenter.display(sender_str),
      sender_kind: sender_kind(sender_str),
      text: body_text(msg.body),
      attachments: body_attachments(msg.body),
      at: msg.inserted_at
    }
  end

  @doc """
  Render-ready rows for a list of messages.

  Like `message_to_row/1` but resolves all sender display names in a single
  `EntityPresenter.display_many/1` batch, avoiding per-row lookups.
  """
  def messages_to_rows(messages) when is_list(messages) do
    sender_uris = Enum.map(messages, fn %Ezagent.Message{sender: s} -> URI.to_string(s) end)
    display_map = Ezagent.EntityPresenter.display_many(sender_uris)

    Enum.map(messages, fn %Ezagent.Message{} = msg ->
      sender_str = URI.to_string(msg.sender)

      %{
        id: msg.id,
        sender: sender_str,
        sender_display: Map.get(display_map, sender_str, sender_str),
        sender_kind: sender_kind(sender_str),
        text: body_text(msg.body),
        attachments: body_attachments(msg.body),
        at: msg.inserted_at
      }
    end)
  end

  defp sender_kind(uri_str) do
    cond do
      entity_type?(uri_str, :user) -> :user
      entity_type?(uri_str, :agent) -> :agent
      true -> :other
    end
  end

  defp entity_type?(uri_str, type) when is_binary(uri_str) and is_atom(type) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} -> Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, type)
      {:error, _} -> false
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp body_attachments(%{attachments: list}) when is_list(list),
    do: Enum.map(list, &att_to_link/1)

  defp body_attachments(%{"attachments" => list}) when is_list(list),
    do: Enum.map(list, &att_to_link/1)

  defp body_attachments(_), do: []

  # Resource-unification P2 — render the download link as a signed capability
  # token (`Ezagent.Uploads.DownloadToken`, a core module both ezagent_web and
  # this plugin may depend on) pointing at the SOLE internal download route
  # `/uploads/download?token=`. The legacy `/files/<name>` route is retired (no
  # shim). Minting is safe here: the LiveView already authorized the caller for
  # this session at mount (it would not have loaded these messages otherwise), so
  # rendering its attachments' tokens does not widen access; the short-TTL token
  # is then re-checked at download time by the controller's ws-segment authority.
  defp att_to_link(%URI{scheme: "resource"} = uri) do
    if Ezagent.URI.type?(uri, :uploads) do
      token = Ezagent.Uploads.DownloadToken.mint!(uri)
      {display_name(Ezagent.URI.name!(uri)), "/uploads/download?token=#{token}"}
    else
      {URI.to_string(uri), URI.to_string(uri)}
    end
  end

  defp att_to_link(%URI{} = uri), do: {URI.to_string(uri), URI.to_string(uri)}

  defp att_to_link(s) when is_binary(s) do
    try do
      att_to_link(Ezagent.URI.new!(s))
    rescue
      ArgumentError -> {s, s}
    end
  end

  defp display_name(<<_uuid::binary-size(36), "-", rest::binary>>), do: rest
  defp display_name(other), do: other

  @doc """
  Build a routing matcher from a session-routing form's params.

  Maps `"matcher_type"` (`"mention"` / `"from"` / `"text_contains"` — each
  requiring a non-empty `"matcher_arg"` — or `"always"`) to the corresponding
  `Ezagent.Routing.Matcher` constructor, returning `{:ok, matcher}`. Anything
  else returns `{:error, :invalid_matcher_form}`.
  """
  def build_session_form_matcher(%{"matcher_type" => "mention", "matcher_arg" => arg})
      when is_binary(arg) and arg != "",
      do: {:ok, Ezagent.Routing.Matcher.mention(arg)}

  def build_session_form_matcher(%{"matcher_type" => "from", "matcher_arg" => arg})
      when is_binary(arg) and arg != "",
      do: {:ok, Ezagent.Routing.Matcher.from(arg)}

  def build_session_form_matcher(%{"matcher_type" => "text_contains", "matcher_arg" => arg})
      when is_binary(arg) and arg != "",
      do: {:ok, Ezagent.Routing.Matcher.text_contains(arg)}

  def build_session_form_matcher(%{"matcher_type" => "always"}),
    do: {:ok, Ezagent.Routing.Matcher.always()}

  def build_session_form_matcher(_), do: {:error, :invalid_matcher_form}

  @doc """
  Normalize session-routing receivers into a trimmed, non-empty list.

  Accepts either a list of strings or a comma-separated string; trims each
  entry and drops blanks. Any other input yields `[]`.
  """
  def parse_session_receivers(list) when is_list(list) do
    list
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_session_receivers(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_session_receivers(_), do: []

  @doc """
  Validate a matcher form's `"matcher_arg"` as an entity URI when applicable.

  For `"mention"` / `"from"` matchers with a non-empty arg, checks the arg is a
  valid entity URI for the caller (via `revalidate_session_uris/3`); returns
  `:ok` for any other matcher type or empty arg (nothing to validate).
  """
  def revalidate_session_matcher_arg(socket, %{
        "matcher_type" => type,
        "matcher_arg" => arg
      })
      when type in ["mention", "from"] and is_binary(arg) and arg != "" do
    revalidate_session_uris(socket, [arg], [:entity])
  end

  def revalidate_session_matcher_arg(_socket, _params), do: :ok

  @doc """
  Validate that every URI in `uris` is allowed for the caller, of the given `kinds`.

  Checks each against `UriOptions.valid_for?/4` for the caller and routing
  workspace; returns `:ok` if all pass, or halts with
  `{:error, {:invalid_uri, uri}}` on the first that doesn't.
  """
  def revalidate_session_uris(socket, uris, kinds) do
    caller_uri = socket.assigns.current_entity_uri
    workspace_uri = routing_workspace_uri(socket)

    Enum.reduce_while(uris, :ok, fn uri, :ok ->
      if Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, uri, kinds) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_uri, uri}}}
      end
    end)
  end

  @doc """
  Validate each routing receiver as a magic token or an allowed entity/session URI.

  Magic tokens (e.g. the broadcast token) pass unconditionally; every other
  receiver must be a caller-valid entity or session URI. Returns `:ok` if all
  pass, else halts with the first `{:error, _}`.
  """
  def revalidate_session_receivers(socket, receivers) do
    Enum.reduce_while(receivers, :ok, fn receiver, :ok ->
      cond do
        Ezagent.Routing.Resolver.magic_token?(receiver) ->
          {:cont, :ok}

        true ->
          case revalidate_session_uris(socket, [receiver], [:entity, :session]) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  @doc """
  Scope a matcher to `session_uri`.

  Returns an already-`{:in_session, _}` matcher unchanged; otherwise wraps the
  leaf in an `all_of([in_session(session_uri), leaf])` so a session-scoped rule
  only fires within that session.
  """
  def wrap_in_session({:in_session, _} = m, _session_uri), do: m

  def wrap_in_session(leaf, %URI{} = session_uri) do
    Ezagent.Routing.Matcher.all_of([
      Ezagent.Routing.Matcher.in_session(session_uri),
      leaf
    ])
  end

  @doc """
  Convert a routing-table-name string to its existing atom safely.

  Returns `{:ok, atom}` for a known atom, or `{:error, {:unknown_table, s}}`
  when the string is not an existing atom (no new atoms are created).
  """
  def safe_table_atom(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> {:error, {:unknown_table, s}}
  end

  @doc """
  Dispatch a `routing` behavior action on the current session.

  Targets `current_session_uri` with `?action=routing.<action>`, dispatched as
  a `:call` with the caller's identity/caps and replies routed to the caller's
  inbox (`{:caller_inbox, self()}`).
  """
  def dispatch_session_routing(socket, action, args) do
    session_uri = socket.assigns.current_session_uri
    target = Ezagent.URI.with_action(session_uri, :routing, action)

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

  @doc """
  Extract the workspace name from a URI (struct or string), or `nil`.

  Accepts a `URI` struct or a URI string (parsed leniently — a parse failure
  yields `nil`); returns the workspace name or `nil` when the URI carries none.
  """
  def workspace_name_from_uri(nil), do: nil

  def workspace_name_from_uri(%URI{} = uri) do
    case Ezagent.URI.workspace_name(uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  def workspace_name_from_uri(uri_str) when is_binary(uri_str) do
    try do
      uri_str
      |> Ezagent.URI.new!()
      |> workspace_name_from_uri()
    rescue
      ArgumentError -> nil
    end
  end

  def workspace_name_from_uri(_), do: nil

  @doc """
  Session-template names available in the current workspace, sorted.

  Reads the workspace store by the `current_workspace_uri`'s name and returns
  the sorted keys of its `:session_templates` map; returns `[]` when there is
  no workspace or it has no templates.
  """
  def template_class_options_for(assigns) do
    case Map.get(assigns, :current_workspace_uri) do
      %URI{scheme: "workspace"} = workspace_uri ->
        ws_name = Ezagent.URI.name!(workspace_uri)

        case Ezagent.Workspace.Store.get_by_name(ws_name) do
          %{session_templates: tmpls} when is_map(tmpls) ->
            tmpls |> Map.keys() |> Enum.sort()

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
