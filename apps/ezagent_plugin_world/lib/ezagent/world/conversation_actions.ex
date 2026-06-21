defmodule Ezagent.World.ConversationActions do
  @moduledoc """
  Socket-side conversation dispatch handlers for the world plugin
  (LV→world parity migration PR-1).

  Mirrors the LiveView plugin's `Admin.Compose` pattern: `WorldLive` keeps
  thin `handle_event` clauses and delegates the bodies here, so the shell
  module stays modular as later PRs add more conversation surface. Pure data
  shaping lives in `Ezagent.World.ConversationData`; this module owns the
  `Ezagent.Invocation.dispatch/1` calls + `push_event`/`assign` plumbing and
  returns `{:noreply, socket}` tuples ready to hand back from `WorldLive`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, connected?: 1, push_patch: 2]

  require Logger

  alias Ezagent.Behavior.Session.Membership
  alias Ezagent.Invocation
  alias Ezagent.World.ConversationData

  @doc """
  Route a `world:dispatch` conversation action to its handler (the dispatcher
  `WorldLive` delegates ALL conversation actions here, so the LiveView shell
  stays a thin host as the conversation surface grows). Each clause parses the
  `session_uri` arg then calls the matching action; an unknown action or a
  malformed session URI yields an error status. Read-only actions
  (`chat.load_older`/`chat.mark_displayed`) silently no-op on a bad URI.
  """
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(socket, "chat.send", %{"session_uri" => sid, "text" => text} = args)
      when is_binary(text) do
    grants = Map.get(args, "grants", [])
    with_session(socket, sid, &send_message(socket, &1, text, grants))
  end

  def handle_dispatch(socket, "chat.load_older", %{"session_uri" => sid, "before" => before})
      when is_binary(before) do
    with_session(socket, sid, &load_older(socket, &1, before), on_error: {:noreply, socket})
  end

  def handle_dispatch(socket, "chat.mark_displayed", %{"session_uri" => sid, "msg_id" => mid})
      when is_binary(mid) and mid != "" do
    with_session(socket, sid, &mark_displayed(socket, &1, mid), on_error: {:noreply, socket})
  end

  def handle_dispatch(socket, "session.switch", %{"session_uri" => sid}) do
    with_session(socket, sid, fn uri ->
      to = "/sessions?session=" <> URI.encode_www_form(URI.to_string(uri))
      {:noreply, push_patch(socket, to: to)}
    end)
  end

  def handle_dispatch(socket, "session.invite", %{"session_uri" => sid, "member" => member})
      when is_binary(member) do
    with_session(socket, sid, &invite_member(socket, &1, member))
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  # Parse the `session_uri` arg, then run `fun` with it. On a malformed URI use
  # `opts[:on_error]` (default: a `bad_session_uri` status).
  defp with_session(socket, sid, fun, opts \\ []) do
    case Ezagent.URI.new!(sid) do
      %URI{scheme: "session"} = uri -> fun.(uri)
      _ -> on_session_error(socket, opts)
    end
  rescue
    ArgumentError -> on_session_error(socket, opts)
  end

  defp on_session_error(socket, opts) do
    Keyword.get(opts, :on_error, {:noreply, assign(socket, :last_dispatch_status, "error:bad_session_uri")})
  end

  # Max attachments per message — server-enforced here (never trusts the client),
  # mirroring the LV `max_entries`. codex PR-2b #4.
  @max_attachments 5
  # Upload-grant TTL (1h) — bounds how long a minted `:attach` grant is replayable.
  @grant_max_age 3_600
  @grant_salt "world_attach"

  @doc """
  Send a chat message into a session via the `:session :send` dispatch
  (`:cast`, mirroring `Admin.Compose.submit/2`). The cast'd message returns
  to the sender through the inbound bridge, so no optimistic insert is done.
  Empty/whitespace text is refused without a dispatch. `grants` are signed
  upload tokens verified before their URIs are attached (PR-2b).
  """
  @spec send_message(Phoenix.LiveView.Socket.t(), URI.t(), String.t(), [String.t()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def send_message(socket, session_uri, text, grants \\ [])

  def send_message(socket, %URI{} = session_uri, text, grants)
      when is_binary(text) and is_list(grants) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())
    attachments = verify_grants(socket, grants, caller, session_uri)

    if String.trim(text) == "" and attachments == [] do
      {:noreply, assign(socket, :last_dispatch_status, "error:empty_message")}
    else
      msg = ConversationData.build_message(caller, text, session_uri, attachments)
      target = Ezagent.URI.with_action(session_uri, :session, :send)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{caller: caller, caps: caps, reply: :ignore}
        })

      case result do
        :ok -> {:noreply, assign(socket, :last_dispatch_status, "ok")}
        {:ok, _} -> {:noreply, assign(socket, :last_dispatch_status, "ok")}
        {:error, reason} -> {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
      end
    end
  end

  @doc """
  Page history backwards and push the older rows to the island for prepend
  (parity: `load_older_messages` over `Ezagent.MessageStore.older_than/3`).
  """
  @spec load_older(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def load_older(socket, %URI{} = session_uri, before) when is_binary(before) do
    {older, next_cursor} = ConversationData.load_older(session_uri, before)

    {:noreply,
     push_event(socket, "chat:older", %{"messages" => older, "oldest_cursor" => next_cursor})}
  end

  @doc """
  Fire-and-forget read marker (parity: `mark_displayed`). Best-effort — never
  surfaces an error to the user.
  """
  @spec mark_displayed(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def mark_displayed(socket, %URI{} = session_uri, msg_id) when is_binary(msg_id) and msg_id != "" do
    _ =
      Ezagent.Session.ReadMarker.mark(
        session_uri,
        socket.assigns.current_entity_uri,
        msg_id,
        :displayed
      )

    {:noreply, socket}
  end

  @doc """
  Invite an entity into the in-view session (LV→world parity PR-3b, mirroring
  `Admin.Invite.dispatch_invite/4`). Dispatches `:session :join` with the
  INVITED member; the inviter's own `:join` authority comes from their
  self-join on mount (`self_join/2` provisions an owner-rooted `:join` cap that
  the runtime reads from the live slice). On success, mounts the invited
  member's participation tier (best-effort, no-op for agents) and pushes the
  refreshed member list. A malformed URI or an unauthorized invite degrades to
  an error status — the panel just doesn't gain the member.
  """
  @spec invite_member(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def invite_member(socket, %URI{} = session_uri, member_str) when is_binary(member_str) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    case parse_member_uri(member_str) do
      {:ok, %URI{} = member_uri} ->
        # `:join` requires a LIVE member Kind (`:member_not_registered` else); a
        # registered-but-cold invitee (e.g. a user who hasn't logged in this
        # boot) is spawned from its snapshot first. Best-effort — a never-created
        # URI stays unspawned and the join below fails closed to an error status.
        _ = Ezagent.SpawnRegistry.spawn(member_uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(session_uri, :session, :join),
            mode: :call,
            args: %{member: member_uri},
            ctx: %{caller: caller, caps: caps, reply: :ignore}
          })

        case result do
          r when r == :ok or (is_tuple(r) and elem(r, 0) == :ok) ->
            _ = Membership.mount_participation_caps(session_uri, member_uri)
            {:noreply, push_members(assign(socket, :last_dispatch_status, "ok"))}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
        end

      :error ->
        {:noreply, assign(socket, :last_dispatch_status, "error:bad_member_uri")}
    end
  end

  defp parse_member_uri(str) do
    case Ezagent.URI.parse(String.trim(str)) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      _ -> :error
    end
  end

  @doc """
  Re-read the in-view session's members and push them to the React members
  panel (PR-3a inbound membership/presence handler). No-op off the
  conversation route (no session in view).
  """
  @spec push_members(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def push_members(socket) do
    # `push_event` is a no-op on the dead static render, so guard connected? —
    # the initial member list already rides in `data-world-state`.
    if connected?(socket) do
      case socket.assigns[:current_session_uri] do
        %URI{} = session_uri ->
          push_event(socket, "members:update", %{
            "members" => ConversationData.member_options(session_uri)
          })

        _ ->
          socket
      end
    else
      socket
    end
  end

  @doc """
  Best-effort self-join of the viewing caller to the in-view conversation,
  ported from the LiveView plugin's `SessionContext.maybe_self_join/2` (the
  parity reference). This is what makes the members panel + @mention dropdown
  populate: the conversation read-path (`ConversationData.member_options/1` →
  `Ezagent.Kind.get_slice/2`) reads LIVE slice state, which is empty for a cold
  session even though membership is PERSISTED. Self-joining on view spawns the
  session from its snapshot (so persisted members appear) and makes the viewer
  present.

  Runs only once the socket is `connected?/1` (never on the dead static render)
  and only once per session (deduped via `:self_joined`, mirroring
  `WorldLive`'s `:subscribed_topics` pattern), so repeated `handle_params`
  (e.g. `chat.load_older`) don't re-dispatch.

  Authorization is owner-rooted: `Membership.provision_join_authority/2` grants a
  per-session `:join` cap JIT (owner / existing member / first-non-anon
  owner-claim → granted; anyone else → denied), then the `:session :join`
  dispatch authorizes at the chokepoint. A denial degrades to "observe" — the
  viewer still sees the conversation, just isn't added as a member.
  """
  @spec self_join(Phoenix.LiveView.Socket.t(), URI.t()) :: Phoenix.LiveView.Socket.t()
  def self_join(socket, %URI{} = session_uri) do
    joined = Map.get(socket.assigns, :self_joined, MapSet.new())

    if connected?(socket) and not MapSet.member?(joined, session_uri) do
      socket
      |> assign(:self_joined, MapSet.put(joined, session_uri))
      |> do_self_join(session_uri)
    else
      socket
    end
  end

  defp do_self_join(socket, %URI{} = session_uri) do
    caller = Map.get(socket.assigns, :current_entity_uri)
    caps = Map.get(socket.assigns, :current_caps)

    case caller do
      %URI{} = caller_uri when not is_nil(caps) ->
        # JIT, owner-rooted per-session :join cap (`:sync` so it lands before the
        # dispatch authorizes via the live slice read).
        _ = Membership.provision_join_authority(session_uri, caller_uri)

        result =
          Invocation.dispatch(%Invocation{
            target: Ezagent.URI.with_action(session_uri, :session, :join),
            mode: :call,
            args: %{member: caller_uri},
            ctx: %{caller: caller_uri, caps: caps, reply: :ignore}
          })

        case result do
          r when r == :ok or (is_tuple(r) and elem(r, 0) == :ok) ->
            # Mount the per-class participation tier (parity with Invite.ex /
            # maybe_self_join). Best-effort, no-op for agents.
            _ = Membership.mount_participation_caps(session_uri, caller_uri)
            assign(socket, :last_join_status, "ok")

          {:error, reason} ->
            # Degrade to observe — the viewer still reads the conversation.
            Logger.debug(fn ->
              "World.self_join: #{URI.to_string(caller_uri)} could not join " <>
                "#{URI.to_string(session_uri)}: #{inspect(reason)} (observe-only)"
            end)

            assign(socket, :last_join_status, "error:#{reason(reason)}")
        end

      _ ->
        socket
    end
  end

  # Verify upload grants (PR-2b anti-laundering, codex #3). Each grant is a
  # `Phoenix.Token` minted by `WorldUploadsController` after a successful
  # `:session :attach` dispatch, binding `uri ↔ caller ↔ session`. A message may
  # only embed a `resource://…/uploads/…` URI whose grant: (a) verifies (MAC +
  # TTL) against THIS endpoint, and (b) was issued to THIS caller for THIS
  # session. A forged/expired/cross-session grant — or a raw URI with no grant —
  # yields nothing, so a client cannot launder an arbitrary uploads URI into a
  # message. At most `@max_attachments` are accepted (server-enforced count).
  defp verify_grants(socket, grants, %URI{} = caller, %URI{} = session_uri) do
    caller_str = URI.to_string(caller)
    session_str = URI.to_string(session_uri)

    grants
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_attachments)
    |> Enum.flat_map(&verify_grant(socket, &1, caller_str, session_str))
  end

  defp verify_grants(_socket, _grants, _caller, _session), do: []

  defp verify_grant(socket, grant, caller_str, session_str) do
    case Phoenix.Token.verify(socket, @grant_salt, grant, max_age: @grant_max_age) do
      {:ok, %{"uri" => uri_str, "caller" => ^caller_str, "session" => ^session_str}} ->
        case Ezagent.URI.parse(uri_str) do
          {:ok, %URI{} = uri} -> [uri]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)
end
