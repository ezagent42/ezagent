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
  import Phoenix.LiveView, only: [push_event: 3, connected?: 1]

  require Logger

  alias Ezagent.Behavior.Session.Membership
  alias Ezagent.Invocation
  alias Ezagent.World.ConversationData

  @doc """
  Send a chat message into a session via the `:session :send` dispatch
  (`:cast`, mirroring `Admin.Compose.submit/2`). The cast'd message returns
  to the sender through the inbound bridge, so no optimistic insert is done.
  Empty/whitespace text is refused without a dispatch.
  """
  @spec send_message(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def send_message(socket, %URI{} = session_uri, text) when is_binary(text) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    if String.trim(text) == "" do
      {:noreply, assign(socket, :last_dispatch_status, "error:empty_message")}
    else
      msg = ConversationData.build_message(caller, text, session_uri)
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

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)
end
