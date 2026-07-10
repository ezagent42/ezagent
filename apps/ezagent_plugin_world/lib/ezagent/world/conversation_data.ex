defmodule Ezagent.World.ConversationData do
  @moduledoc """
  Read-path + message construction for the world session-conversation surface
  (LV→world parity migration PR-1).

  Mirrors the `Ezagent.World.{AdminData,IdentityData,WorkspacePluginData}`
  pattern: `EzagentPluginWorld.WorldLive` stays the SSR/comms shell and this
  module owns the pure data shaping. Everything here is derived against
  core/domain survivors (`Ezagent.MessageStore`, `Ezagent.EntityPresenter`,
  `Ezagent.Message`) — NOT the retired LiveView plugin's `SessionContext`, so
  the LV app can be deleted wholesale at parity-migration PR-7.
  """

  @message_limit 50

  # world-native React renderers keyed by SessionView id → the render mode the
  # React side draws with. Any other view classifies by its declared target
  # (external json-render surface) or falls through to "unsupported" (honest
  # placeholder, never silently hidden).
  @native_react_ids %{conversation: "chat", pty: "pty"}

  @doc """
  Build the React `conversation` island state for a session.

  Loads the most-recent `#{@message_limit}` messages (chronological,
  oldest-first) plus the workspace session list (for the in-header selector)
  and the deep-link/inbound-filter session URI. `caller_uri` lets the island
  flag the viewer's own messages; `sessions` are the already-shaped session
  rows from `WorldLive`.
  """
  @spec state_for(URI.t(), %{
          required(:caller_uri) => URI.t() | nil,
          optional(:caller_caps) => Enumerable.t(),
          required(:workspace_uri) => URI.t() | nil,
          required(:sessions) => [map()]
        }) :: map()
  def state_for(%URI{} = session_uri, opts) when is_map(opts) do
    caller_uri = Map.fetch!(opts, :caller_uri)
    workspace_uri = Map.fetch!(opts, :workspace_uri)
    sessions = Map.fetch!(opts, :sessions)
    caller_caps = Map.get(opts, :caller_caps, MapSet.new())
    messages = load_messages(session_uri, caller_caps)
    members = member_options(session_uri)

    %{
      "component" => "conversation",
      "session_uri" => encode_uri(session_uri),
      "current_session_uri" => encode_uri(session_uri),
      "workspace_uri" => encode_uri(workspace_uri),
      "caller_uri" => encode_uri(caller_uri),
      "create_error" => nil,
      "templates" => Ezagent.World.WorkspacePluginData.session_template_names(workspace_uri),
      "messages" => messages,
      "oldest_cursor" => oldest_cursor_iso(messages),
      "members" => members,
      "human_role_slots" => human_role_slots(session_uri),
      "installed_socialwares" => installed_socialwares(session_uri),
      "unfilled_agent_role_slots" =>
        EzagentDomainInstanceMessage.SessionCreator.unfilled_agent_role_slots(session_uri),
      "invite_candidates" => invite_candidates(session_uri, caller_uri, workspace_uri, members),
      "routing_entity_candidates" =>
        routing_entity_candidates(caller_uri, workspace_uri, members),
      "routing_rules" => list_session_routing_rules(session_uri),
      "sessions" => sessions,
      # Registry-driven view tabs (Ezagent.UI.SessionViewRegistry). Each entry is
      # %{"id","label","icon","mode"}; mode ∈ chat|pty|external|unsupported. All
      # views are enumerated through the caller-aware `applicable_views/2`, so a
      # cap-gated view a caller can't see emits no tab.
      "views" => session_views(session_uri, caller_uri)
    }
  end

  @doc """
  The registry-driven view tabs for `session_uri` visible to `caller_uri`.

  Delegates enumeration + `applies_to?` + the cap gate to
  `Ezagent.UI.SessionViewRegistry.applicable_views/2` (the SAME caller-aware path
  that already runs `authorize_view/3`), so world never re-computes or bypasses
  visibility. world only classifies each returned view into a render `mode` the
  React side knows how to draw.
  """
  @spec session_views(URI.t(), URI.t() | nil) :: [map()]
  def session_views(%URI{} = session_uri, caller_uri) do
    session_uri
    |> Ezagent.UI.SessionViewRegistry.applicable_views(view_caller(caller_uri))
    |> Enum.map(fn %{id: id, label: label, icon: icon, module: mod} ->
      %{
        "id" => Atom.to_string(id),
        "label" => label,
        "icon" => icon,
        "mode" => render_mode(id, mod)
      }
    end)
  end

  @doc """
  The visible view id strings for `session_uri`/`caller_uri` — the SINGLE source
  the `switch_view` whitelist reads from, so a tab a caller can't see also can't
  be switched to (no bypass; gate and visibility are same-source).
  """
  @spec session_view_ids(URI.t(), URI.t() | nil) :: [String.t()]
  def session_view_ids(%URI{} = session_uri, caller_uri) do
    session_uri |> session_views(caller_uri) |> Enum.map(& &1["id"])
  end

  # Classify a registered view into a world React render mode. `:conversation`
  # and `:pty` have world-native React renderers; `:page`/`:hello_page` and any
  # view declaring an external render target draw through the external surface
  # (iframe); everything else is an honest "unsupported" placeholder.
  defp render_mode(id, mod) do
    cond do
      Map.has_key?(@native_react_ids, id) -> Map.fetch!(@native_react_ids, id)
      id in [:page, :hello_page] -> "external"
      external_render_view?(mod) -> "external"
      true -> "unsupported"
    end
  end

  defp external_render_view?(mod) do
    Ezagent.UI.SessionViewRegistry.external_render?(mod)
  rescue
    _ -> false
  end

  defp view_caller(%URI{} = caller), do: caller
  defp view_caller(_), do: nil

  @doc """
  Routing rules scoped to `session_uri`, shaped for the conversation island.

  Parses the shared MentionRouting store and keeps only matchers wrapped for
  this session. This mirrors the LV read path without depending on the LV app.
  """
  @spec list_session_routing_rules(URI.t()) :: [map()]
  def list_session_routing_rules(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(EzagentDomainInstanceMessage.Routing.MentionRouting)
    |> Enum.flat_map(fn row ->
      case Ezagent.Routing.Matcher.from_json(row.matcher_data) do
        {:ok, matcher} ->
          if matcher_targets_session?(matcher, session_str) do
            [
              %{
                "id" => row.id,
                "table" => row.table_name,
                "matcher" => inspect(matcher),
                "receivers" => row.receivers,
                "receivers_text" => Enum.join(row.receivers, ", "),
                "source" => row.source,
                "enabled" => row.enabled
              }
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  def list_session_routing_rules(_), do: []

  @doc """
  Session members as `%{"uri" => ..., "display_name" => ..., "online" => bool,
  "kind" => "user"|"agent"|"other"}` rows. Reads the authoritative session
  slice (`Ezagent.Kind.get_slice/2`) — the same source the server-side mention
  parse uses, so the @mention dropdown, the members panel, and routing can't
  drift. The panel (PR-3a) shows presence; the autocomplete ignores it.
  """
  @spec member_options(URI.t()) :: [map()]
  def member_options(%URI{} = session_uri) do
    member_meta = member_meta(session_uri)
    uris = Map.keys(member_meta)
    display_map = Ezagent.EntityPresenter.display_many(uris)

    uris
    |> Enum.sort()
    |> Enum.map(fn uri ->
      meta = Map.get(member_meta, uri, %{})
      kind = sender_kind(uri)

      %{
        "uri" => uri,
        "display_name" => member_display_name(uri, meta, display_map, kind),
        "online" => is_map(meta) and Map.get(meta, :online, false) == true,
        "role_name" => if(is_map(meta), do: Map.get(meta, :role_name), else: nil),
        "kind" => kind,
        "pty_alive" => kind == "agent" and pty_alive?(uri)
      }
    end)
  end

  defp pty_alive?(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = parsed} -> Ezagent.Domain.Pty.alive?(parsed)
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Human role slots installed on a session, including the current assigned member URI when present."
  @spec human_role_slots(URI.t()) :: [map()]
  def human_role_slots(%URI{} = session_uri) do
    members = member_meta(session_uri)

    assigned_by_role =
      Enum.reduce(members, %{}, fn
        {uri, %{role_name: role_name}}, acc when is_binary(role_name) ->
          Map.put_new(acc, role_name, uri)

        {_uri, _meta}, acc ->
          acc
      end)

    session_uri
    |> Ezagent.Socialware.Installation.installed_definitions()
    |> Enum.flat_map(& &1.roles)
    |> Enum.flat_map(fn
      %{fill: :human, role_name: role_name} when is_binary(role_name) ->
        [
          %{
            "role_name" => role_name,
            "assigned_uri" => Map.get(assigned_by_role, role_name)
          }
        ]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["role_name"])
    |> Enum.sort_by(& &1["role_name"])
  rescue
    _ -> []
  end

  @doc "Socialware definitions currently installed on this session, shaped for the management panel."
  @spec installed_socialwares(URI.t()) :: [map()]
  def installed_socialwares(%URI{} = session_uri) do
    session_uri
    |> Ezagent.Socialware.Installation.installed_definitions()
    |> Enum.map(fn definition ->
      %{
        "name" => definition.name,
        "title" => definition.title,
        "description" => definition.description,
        "roles" => socialware_role_rows(definition.roles)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  rescue
    _ -> []
  end

  def installed_socialwares(_), do: []

  defp socialware_role_rows(roles) when is_list(roles) do
    roles
    |> Enum.map(fn role ->
      %{
        "role_name" => Map.get(role, :role_name),
        "fill" => role |> Map.get(:fill) |> socialware_fill_name()
      }
    end)
    |> Enum.filter(&non_empty_string?(&1["role_name"]))
  end

  defp socialware_role_rows(_), do: []

  defp socialware_fill_name(fill) when is_atom(fill), do: Atom.to_string(fill)
  defp socialware_fill_name(fill) when is_binary(fill), do: fill
  defp socialware_fill_name(_), do: nil

  @doc """
  Entity rows the current caller can invite into `session_uri`.

  The option source combines the caller/workspace-authorized live picker rows
  with provisioned users and agent snapshots in the same workspace. This layer
  narrows those visible entities to useful session invite choices: only when the
  caller is currently in the session, and never entities that are already
  members.
  """
  @spec invite_candidates(URI.t(), URI.t() | nil, URI.t() | nil) :: [map()]
  def invite_candidates(%URI{} = session_uri, caller_uri, workspace_uri) do
    invite_candidates(session_uri, caller_uri, workspace_uri, member_options(session_uri))
  end

  @doc false
  @spec invite_candidates(URI.t(), URI.t() | nil, URI.t() | nil, [map()]) :: [map()]
  def invite_candidates(_session_uri, caller_uri, workspace_uri, members) when is_list(members) do
    member_uris = MapSet.new(members, &Map.get(&1, "uri"))
    caller_uri_str = encode_uri(caller_uri)

    if is_binary(caller_uri_str) and MapSet.member?(member_uris, caller_uri_str) do
      caller_uri
      |> entity_candidate_options(workspace_uri)
      |> Enum.flat_map(&invite_candidate_row/1)
      |> Enum.reject(&MapSet.member?(member_uris, &1["uri"]))
      |> sort_candidate_rows()
    else
      []
    end
  end

  def invite_candidates(_session_uri, _caller_uri, _workspace_uri, _members), do: []

  @doc """
  Entity rows the current caller can use in session routing controls.

  Unlike `invite_candidates/4`, this includes current members because routing
  rules usually target entities that are already in the conversation.
  """
  @spec routing_entity_candidates(URI.t() | nil, URI.t() | nil, [map()]) :: [map()]
  def routing_entity_candidates(caller_uri, workspace_uri, members) when is_list(members) do
    (entity_candidate_options(caller_uri, workspace_uri) ++ member_candidate_options(members))
    |> Enum.flat_map(&invite_candidate_row/1)
    |> Enum.uniq_by(& &1["uri"])
    |> sort_candidate_rows()
  end

  def routing_entity_candidates(_caller_uri, _workspace_uri, _members), do: []

  @doc """
  Parse @mentions in `text` into recipient entity URIs, against `members`
  (`member_options/1` rows). Recognizes explicit `@entity://...` URIs and bare
  `@name` tokens resolved by URI path segment, role name, then display name
  (unique match only). `open_role_slots` is used only to suppress colon-token
  head fallback when an unfilled A-2-style role exists. Port of the LiveView
  parser against survivors - world carries no reference to the LV plugin. The
  result is what the domain's recipient resolver consumes (`msg.mentions`), so
  this is the load-bearing piece, not the autocomplete UI.
  """
  @spec parse_mentions(String.t(), [map()]) :: [URI.t()]
  def parse_mentions(text, members), do: parse_mentions(text, members, [])

  @doc """
  Like `parse_mentions/2`, with the session's open human role slots included
  for A-2 colon-role fallback suppression. Open slots are never resolved as
  mentions; they only prevent `@source:role` from falling back to `@source`.
  """
  @spec parse_mentions(String.t(), [map()], [map() | String.t()]) :: [URI.t()]
  def parse_mentions(text, members, open_role_slots)
      when is_binary(text) and is_list(members) and is_list(open_role_slots) do
    (parse_uri_mentions(text) ++ parse_bare_mentions(text, members, open_role_slots))
    |> Enum.uniq_by(&URI.to_string/1)
  end

  def parse_mentions(_text, _members, _open_role_slots), do: []

  @doc """
  Fetch a page of messages older than `cursor` (ISO-8601), oldest-first.

  Returns `{rows, next_oldest_cursor}` for the island to prepend; an invalid
  cursor yields `{[], nil}` (no paging).
  """
  @spec load_older(URI.t(), String.t(), Enumerable.t()) :: {[map()], String.t() | nil}
  def load_older(%URI{} = session_uri, before, caller_caps \\ MapSet.new())
      when is_binary(before) do
    case DateTime.from_iso8601(before) do
      {:ok, cursor, _offset} ->
        rows =
          older_messages(session_uri, cursor, caller_caps)
          |> Enum.reverse()
          |> messages_to_rows()

        {rows, oldest_cursor_iso(rows)}

      _ ->
        {[], nil}
    end
  end

  @doc """
  Construct a chat `Ezagent.Message` for the composer.

  Parses @mentions server-side against the session's authoritative members
  (never trusting a client-supplied recipient list). `attachments` are
  `resource://…/uploads/…` URIs ALREADY VERIFIED by the caller
  (`ConversationActions.send_message/4` checks each upload grant's signature +
  caller/session binding before passing them here — PR-2b anti-laundering), so
  this function trusts the list it is given. `legend_triggers` stay empty.
  """
  @spec build_message(URI.t(), String.t(), URI.t(), [URI.t()]) :: Ezagent.Message.t()
  def build_message(sender, text, session_uri, attachments \\ [])

  def build_message(%URI{} = sender, text, %URI{} = session_uri, attachments)
      when is_binary(text) and is_list(attachments) do
    mentions = parse_mentions(text, member_options(session_uri), human_role_slots(session_uri))
    Ezagent.Message.new(sender, %{text: text, attachments: attachments}, mentions: mentions)
  end

  @doc "Render-ready row for a single message (resolves the sender display)."
  @spec message_row(Ezagent.Message.t()) :: map()
  def message_row(%Ezagent.Message{} = msg), do: message_row(msg, %{})

  @doc "Oldest-visible-cursor (ISO-8601) for backwards paging; `nil` when empty."
  @spec oldest_cursor_iso([map()]) :: String.t() | nil
  def oldest_cursor_iso([%{"at" => at} | _]) when is_binary(at), do: at
  def oldest_cursor_iso(_), do: nil

  defp load_messages(%URI{} = session_uri, caller_caps) do
    session_uri
    |> recent_messages(caller_caps)
    |> Enum.reverse()
    |> messages_to_rows()
  end

  defp recent_messages(%URI{} = session_uri, caller_caps) do
    if read_unfiltered?(session_uri, caller_caps) do
      Ezagent.MessageStore.recent_in_session(session_uri, @message_limit)
    else
      Ezagent.MessageStore.recent_visible_in_session(session_uri, @message_limit)
    end
  end

  defp older_messages(%URI{} = session_uri, %DateTime{} = cursor, caller_caps) do
    if read_unfiltered?(session_uri, caller_caps) do
      Ezagent.MessageStore.older_than(session_uri, cursor, @message_limit)
    else
      Ezagent.MessageStore.older_visible_than(session_uri, cursor, @message_limit)
    end
  end

  defp read_unfiltered?(%URI{} = session_uri, caller_caps) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    caller_caps
    |> cap_list()
    |> Enum.any?(&read_unfiltered_cap?(&1, session_uri, workspace_uri))
  rescue
    _ -> false
  end

  defp cap_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp cap_list(caps) when is_list(caps), do: caps
  defp cap_list(_), do: []

  defp read_unfiltered_cap?(
         %Ezagent.Capability{} = cap,
         %URI{} = session_uri,
         %URI{} = workspace_uri
       ) do
    cap_field?(cap.kind, :session) and
      cap_field?(cap.behavior, Ezagent.ActionSet.Session) and
      cap_field?(Map.get(cap, :action, :any), :read_unfiltered) and
      cap_instance?(cap.instance, session_uri, workspace_uri) and
      cap_workspace?(cap.workspace_uri, workspace_uri)
  end

  defp read_unfiltered_cap?(_, _, _), do: false

  defp cap_field?(:any, _needed), do: true
  defp cap_field?(same, same), do: true
  defp cap_field?(_, _), do: false

  defp cap_instance?(:any, _session_uri, _workspace_uri), do: true

  defp cap_instance?({:within_session, %URI{} = held}, %URI{} = session_uri, _workspace_uri),
    do: same_uri?(held, session_uri)

  defp cap_instance?({:within_workspace, %URI{} = held}, _session_uri, %URI{} = workspace_uri),
    do: same_uri?(held, workspace_uri)

  defp cap_instance?(%URI{} = held, %URI{} = session_uri, _workspace_uri),
    do: same_uri?(held, session_uri)

  defp cap_instance?(_, _, _), do: false

  defp cap_workspace?(:any, _workspace_uri), do: true
  defp cap_workspace?(%URI{} = held, %URI{} = workspace_uri), do: same_uri?(held, workspace_uri)
  defp cap_workspace?(_, _), do: false

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false

  defp messages_to_rows(messages) when is_list(messages) do
    sender_uris = Enum.map(messages, fn %Ezagent.Message{sender: s} -> URI.to_string(s) end)
    display_map = Ezagent.EntityPresenter.display_many(sender_uris)
    Enum.map(messages, &message_row(&1, display_map))
  end

  defp message_row(%Ezagent.Message{} = msg, display_map) do
    sender_str = URI.to_string(msg.sender)

    %{
      "id" => msg.id,
      "sender" => sender_str,
      "sender_display" =>
        Map.get(display_map, sender_str) || Ezagent.EntityPresenter.display(sender_str),
      "sender_kind" => sender_kind(sender_str),
      "text" => body_text(msg.body),
      # Optional json-render node tree — when present the world bubble renders it
      # with the json-render engine (like the preview), not plain text. `render_css`
      # is an optional per-card CSS theme (a user's explicit style ask).
      "render" => body_render(msg.body),
      "render_css" => body_render_css(msg.body),
      "attachments" => body_attachments(msg.body),
      "at" => datetime_iso(msg.inserted_at)
    }
  end

  defp body_render(%{render: r}) when not is_nil(r), do: r
  defp body_render(%{"render" => r}) when not is_nil(r), do: r
  defp body_render(_), do: nil

  defp body_render_css(%{render_css: c}) when is_binary(c), do: c
  defp body_render_css(%{"render_css" => c}) when is_binary(c), do: c
  defp body_render_css(_), do: nil

  defp sender_kind(uri_str) when is_binary(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} ->
        cond do
          Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, :user) -> "user"
          Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, :agent) -> "agent"
          true -> "other"
        end

      _ ->
        "other"
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  # Each attachment renders as `%{"name", "href"}`: an uploads `resource://…`
  # URI gets a signed `DownloadToken` link (the existing authed `/uploads/download`
  # route re-checks the participant at serve time, so minting does not widen
  # access — same contract as LV `att_to_link/1`); any other value renders as a
  # plain label with no href (PR-2b).
  defp body_attachments(%{attachments: list}) when is_list(list),
    do: Enum.map(list, &attachment_row/1)

  defp body_attachments(%{"attachments" => list}) when is_list(list),
    do: Enum.map(list, &attachment_row/1)

  defp body_attachments(_), do: []

  defp attachment_row(att) do
    case attachment_uri(att) do
      %URI{scheme: "resource"} = uri -> uploads_attachment_row(uri)
      _ -> %{"name" => attachment_label(att), "href" => nil}
    end
  end

  defp uploads_attachment_row(%URI{} = uri) do
    name = uri |> URI.to_string() |> Path.basename() |> strip_uuid_prefix()

    case safe_mint_download(uri) do
      {:ok, token} -> %{"name" => name, "href" => "/uploads/download?token=#{token}"}
      :error -> %{"name" => name, "href" => nil}
    end
  end

  defp safe_mint_download(%URI{} = uri) do
    {:ok, Ezagent.Uploads.DownloadToken.mint!(uri)}
  rescue
    _ -> :error
  end

  # Stored names are `<uuid>-<sanitized>`; show the human part in the link label.
  defp strip_uuid_prefix(name) when is_binary(name) do
    case Regex.run(~r/^[0-9a-fA-F-]{36}-(.+)$/, name) do
      [_, rest] -> rest
      _ -> name
    end
  end

  defp attachment_uri(%URI{} = uri), do: uri

  defp attachment_uri(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{} = uri} -> uri
      _ -> s
    end
  end

  defp attachment_uri(other), do: other

  defp attachment_label(%URI{} = uri), do: URI.to_string(uri)
  defp attachment_label(s) when is_binary(s), do: s
  defp attachment_label(other), do: inspect(other)

  defp datetime_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_iso(_), do: nil

  # %{uri_string => member_meta} from the session slice members map. Empty for a
  # cold/unknown session.
  defp member_meta(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        Map.new(members, fn {uri, meta} ->
          {encode_uri(uri), meta}
        end)

      _ ->
        %{}
    end
  end

  defp member_display_name(uri, meta, display_map, kind) do
    display_name = Map.get(display_map, uri, uri)
    role_name = member_role_name(meta)
    fallback = uri_display_fallback(uri)

    if kind == "agent" and non_empty_string?(role_name) and display_name in [uri, fallback] do
      role_name
    else
      display_name
    end
  end

  defp member_role_name(meta) when is_map(meta),
    do: Map.get(meta, :role_name) || Map.get(meta, "role_name")

  defp member_role_name(_meta), do: nil

  defp uri_display_fallback(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = parsed} -> uri_name(parsed) || uri
      _ -> uri
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp entity_options(caller_uri, workspace_uri) do
    uri_options = Module.concat([Ezagent.UI, UriOptions])

    if Code.ensure_loaded?(uri_options) and function_exported?(uri_options, :entities, 2) do
      apply(uri_options, :entities, [caller_uri, workspace_uri])
    else
      []
    end
  rescue
    _ -> []
  end

  defp entity_candidate_options(caller_uri, workspace_uri) do
    if caller_authorized_for_workspace?(caller_uri, workspace_uri) do
      (entity_options(caller_uri, workspace_uri) ++
         provisioned_user_options(workspace_uri) ++
         snapshot_agent_options(workspace_uri))
      |> Enum.uniq_by(&option_field(&1, :uri))
    else
      []
    end
  end

  defp provisioned_user_options(workspace_uri) do
    if Code.ensure_loaded?(Ezagent.Users) and
         function_exported?(Ezagent.Users, :list_in_workspace, 1) do
      users = apply(Ezagent.Users, :list_in_workspace, [workspace_uri])
      display_map = Ezagent.EntityPresenter.display_many(Enum.map(users, &encode_uri(&1.uri)))

      Enum.map(users, fn user ->
        uri_str = encode_uri(user.uri)

        %{
          uri: uri_str,
          label: Map.get(display_map, uri_str, uri_name(user.uri) || uri_str),
          flavor: nil
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp snapshot_agent_options(workspace_uri) do
    if Code.ensure_loaded?(Ezagent.Ecto.KindSnapshot) and
         function_exported?(Ezagent.Ecto.KindSnapshot, :list_in_workspace, 1) do
      Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
      |> Enum.flat_map(fn row ->
        with uri_str when is_binary(uri_str) and uri_str != "" <- Map.get(row, :uri),
             {:ok, %URI{scheme: "entity"} = uri} <- Ezagent.URI.parse(uri_str),
             {:ok, "agent"} <- Ezagent.URI.type(uri) do
          [
            %{
              uri: uri_str,
              label: Ezagent.EntityPresenter.display(uri_str),
              flavor: flavor_for_agent(uri)
            }
          ]
        else
          _ -> []
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp member_candidate_options(members) do
    Enum.map(members, fn member ->
      %{
        uri: Map.get(member, "uri"),
        label: Map.get(member, "display_name"),
        flavor: Map.get(member, "flavor")
      }
    end)
  end

  defp invite_candidate_row(option) when is_map(option) do
    uri_str = option_field(option, :uri)

    with uri_str when is_binary(uri_str) and uri_str != "" <- uri_str,
         {:ok, %URI{scheme: "entity"} = uri} <- Ezagent.URI.parse(uri_str),
         {:ok, kind} <- Ezagent.URI.type(uri),
         true <- kind in ["user", "agent"] do
      [
        %{
          "uri" => uri_str,
          "display_name" => invite_candidate_display_name(option, uri),
          "kind" => kind,
          "flavor" => option_field(option, :flavor)
        }
      ]
    else
      _ -> []
    end
  end

  defp invite_candidate_row(_option), do: []

  defp invite_candidate_display_name(option, %URI{} = uri) do
    uri_str = URI.to_string(uri)
    label = option_field(option, :label)
    name = uri_name(uri) || uri_str

    cond do
      not is_binary(label) -> name
      String.trim(label) in ["", uri_str] -> name
      true -> label
    end
  end

  defp invite_candidate_rank(%{"kind" => "user"}), do: 0
  defp invite_candidate_rank(%{"kind" => "agent"}), do: 1
  defp invite_candidate_rank(_), do: 2

  defp sort_candidate_rows(rows) do
    Enum.sort_by(rows, fn row ->
      {invite_candidate_rank(row), String.downcase(row["display_name"] || ""), row["uri"]}
    end)
  end

  defp option_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp option_field(_map, _key), do: nil

  defp uri_name(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  defp uri_name(_uri), do: nil

  defp flavor_for_agent(%URI{} = uri) do
    with {:ok, "agent"} <- Ezagent.URI.type(uri),
         {:ok, flavor} when is_binary(flavor) and flavor != "" <-
           Ezagent.UriQuery.resolve(:flavor, uri) do
      flavor
    else
      _ -> nil
    end
  end

  defp caller_authorized_for_workspace?(caller_uri, workspace_uri) do
    with {:ok, %URI{} = workspace} <- normalize_uri(workspace_uri),
         {:ok, %URI{} = caller_workspace} <- caller_workspace(caller_uri) do
      system_workspace?(caller_workspace) or
        Ezagent.URI.stable_key(caller_workspace) == Ezagent.URI.stable_key(workspace)
    else
      _ -> false
    end
  end

  defp caller_workspace(caller_uri) do
    with {:ok, %URI{} = caller} <- normalize_uri(caller_uri),
         %URI{} = workspace <- Ezagent.Capability.workspace_of(caller) do
      {:ok, workspace}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp normalize_uri(%URI{} = uri), do: {:ok, uri}

  defp normalize_uri(value) when is_binary(value) do
    Ezagent.URI.parse(value)
  end

  defp normalize_uri(_value), do: :error

  defp system_workspace?(%URI{} = workspace_uri) do
    Ezagent.URI.stable_key(workspace_uri) ==
      Ezagent.URI.stable_key(Ezagent.URI.workspace(:system))
  end

  defp matcher_targets_session?(matcher, session_str) do
    case matcher do
      {:in_session, ^session_str} ->
        true

      {:and, items} when is_list(items) ->
        Enum.any?(items, &matcher_targets_session?(&1, session_str))

      {:or, items} when is_list(items) ->
        Enum.any?(items, &matcher_targets_session?(&1, session_str))

      {:not, inner} ->
        matcher_targets_session?(inner, session_str)

      _ ->
        false
    end
  end

  # --- @mention parse (port vs survivors; NO LV dep) ----------------------

  defp parse_uri_mentions(text) do
    ~r/@(entity:\/\/[^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&safe_uri/1)
  end

  defp parse_bare_mentions(_text, [], _open_role_slots), do: []

  defp parse_bare_mentions(text, members, open_role_slots) do
    ~r/(?<![\p{L}\p{N}_])@([A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.flat_map(&resolve_member_token(&1, members, open_role_slots))
  end

  defp resolve_member_token(name, members, open_role_slots) do
    case resolve_member_name(name, members) do
      [] -> maybe_resolve_colon_head(name, members, open_role_slots)
      uris -> uris
    end
  end

  defp maybe_resolve_colon_head(name, members, open_role_slots) do
    case String.split(name, ":", parts: 2) do
      [head, _tail] ->
        if colon_role_name_present?(members, open_role_slots) do
          []
        else
          resolve_member_name(head, members)
        end

      _ ->
        []
    end
  end

  defp colon_role_name_present?(members, open_role_slots) do
    members
    |> Enum.map(&Map.get(&1, "role_name"))
    |> Kernel.++(Enum.map(open_role_slots, &role_name_value/1))
    |> Enum.any?(&(is_binary(&1) and String.contains?(&1, ":")))
  end

  defp role_name_value(%{"role_name" => role_name}), do: role_name
  defp role_name_value(%{role_name: role_name}), do: role_name
  defp role_name_value(role_name) when is_binary(role_name), do: role_name
  defp role_name_value(_), do: nil

  # Bare @name resolves by URI path segment, then role name, then display name -
  # unique match only inside the deciding tier.
  defp resolve_member_name(name, members) do
    [
      Enum.filter(members, &(uri_path_segment(Map.get(&1, "uri")) == name)),
      Enum.filter(members, &(Map.get(&1, "role_name") == name)),
      Enum.filter(members, &(Map.get(&1, "display_name") == name))
    ]
    |> Enum.reduce_while([], fn
      [], acc ->
        {:cont, acc}

      candidates, _acc ->
        {:halt, unique_candidate_uri(candidates)}
    end)
  end

  defp unique_candidate_uri(candidates) do
    case candidates |> Enum.map(&Map.get(&1, "uri")) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [uri_str] -> safe_uri(uri_str)
      _ -> []
    end
  end

  defp uri_path_segment(uri_str) when is_binary(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} ->
        case Ezagent.URI.name(uri) do
          {:ok, name} -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp uri_path_segment(_), do: nil

  defp safe_uri(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} -> [uri]
      _ -> []
    end
  end

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
