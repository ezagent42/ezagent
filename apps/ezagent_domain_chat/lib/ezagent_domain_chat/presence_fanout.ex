defmodule EzagentDomainChat.PresenceFanout do
  @moduledoc """
  Decision Log #93 consumer — bridges `Ezagent.Presence` diffs into
  per-session `:events` topics so chat surfaces (LV chat stream,
  admin session-list, future routing rules) see member online/offline
  signals without subscribing to Presence directly.

  ## Why this exists

  Chat sessions need to render "X is online" / "Y went offline"
  signals next to their members. Per SPEC P9 and rev-3 §8 of the
  Presence SPEC, this responsibility lives in the chat DOMAIN (not
  `Ezagent.Presence` itself — Presence is a primitive that knows
  nothing about sessions or chat membership). The fanout is a tiny
  GenServer that maintains an in-memory reverse index
  `user_uri => MapSet(session_uri)` and rebroadcasts presence diffs
  scoped to interested sessions.

  ## State machine

  - **Subscribes to** `esr:session_membership:changes` (global topic
    broadcast by `Ezagent.Behavior.Chat.broadcast_membership/2`):
    - `{:session_membership_change, session_uri, {:member_joined, member_uri}}`
      → add `(session_uri ↔ member_uri)` to index; on FIRST mapping
      for `member_uri`, `Presence.subscribe(member_uri, %{caps: :system})`.
    - `{:session_membership_change, _, {:member_left, member_uri}}` →
      remove from index; on LAST removal, `Presence.unsubscribe(member_uri)`.
    - `{:session_membership_change, _, {:member_offline, ...}}` → no
      index change (membership stays; just last-seen update — handled
      by Chat slice). Ignored here.

  - **Receives** `{:ezagent_presence_diff, "esr:presence:<user_uri>",
    %{joins, leaves, current}}` from `Ezagent.Presence`. Derives
    `member_uri` from topic; for each interested session:

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        Ezagent.Behavior.Chat.session_events_topic(session_uri),
        {:member_presence, session_uri, member_uri,
         %{online?: current != %{}}}
      )

  ## V1 limitation

  Fanout starts with an EMPTY index. Existing sessions whose members
  joined BEFORE the fanout boots are not tracked until a member
  rejoin or new join. A future "rebuild at boot from KindRegistry +
  Chat slices" step is a follow-up — for V1, operators triggering a
  redeploy can ask the user to refresh / rejoin.

  Per SPEC `docs/superpowers/specs/2026-05-23-presence.md` rev 3 §8 +
  Decision Log #93 + the post-Presence PR-A acceptance.
  """

  use GenServer

  require Logger

  alias Ezagent.Behavior.Chat
  alias Ezagent.Presence

  @membership_topic "esr:session_membership:changes"

  # ----- Client API ----------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Debug introspection — returns the current reverse index. Not for
  production callers; used by tests + admin observability.
  """
  @spec __index__() :: %{URI.t() => MapSet.t(URI.t())}
  def __index__, do: GenServer.call(__MODULE__, :__index__)

  # ----- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_) do
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, @membership_topic)
    # State: %{user_uri => MapSet.t(session_uri)}
    {:ok, %{}}
  end

  @impl true
  def handle_call(:__index__, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(
        {:session_membership_change, %URI{} = session_uri, {:member_joined, %URI{} = member_uri}},
        state
      ) do
    sessions = Map.get(state, member_uri, MapSet.new())

    # FIRST session for this member → subscribe to Presence diffs
    if MapSet.size(sessions) == 0 do
      :ok = Presence.subscribe(member_uri, %{caps: :system})
    end

    new_state = Map.put(state, member_uri, MapSet.put(sessions, session_uri))
    {:noreply, new_state}
  end

  def handle_info(
        {:session_membership_change, %URI{} = session_uri, {:member_left, %URI{} = member_uri}},
        state
      ) do
    sessions = Map.get(state, member_uri, MapSet.new())
    new_sessions = MapSet.delete(sessions, session_uri)

    # LAST session removed → unsubscribe from Presence
    new_state =
      if MapSet.size(new_sessions) == 0 do
        :ok = Presence.unsubscribe(member_uri)
        Map.delete(state, member_uri)
      else
        Map.put(state, member_uri, new_sessions)
      end

    {:noreply, new_state}
  end

  # :member_offline is a last-seen timestamp update; membership stays
  # so the index is unchanged. Chat slice handles the timestamp.
  def handle_info({:session_membership_change, _, {:member_offline, _, _}}, state) do
    {:noreply, state}
  end

  # Catch any other shape that lands on the topic (defensive — better
  # to log + ignore than crash the singleton fanout).
  def handle_info({:session_membership_change, _, _other}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ezagent_presence_diff, topic, %{current: current}},
        state
      ) do
    case topic_to_member_uri(topic) do
      {:ok, member_uri} ->
        sessions = Map.get(state, member_uri, MapSet.new())
        online? = current != %{}

        Enum.each(sessions, fn session_uri ->
          Phoenix.PubSub.broadcast(
            EzagentCore.PubSub,
            Chat.session_events_topic(session_uri),
            {:member_presence, session_uri, member_uri, %{online?: online?}}
          )
        end)

        {:noreply, state}

      :error ->
        Logger.warning(
          "PresenceFanout: ignored ezagent_presence_diff with " <>
            "untracked topic shape: #{inspect(topic)}"
        )

        {:noreply, state}
    end
  end

  # Defensive — anything else on this process's mailbox is unexpected.
  def handle_info(_msg, state), do: {:noreply, state}

  # ----- Internal helpers ----------------------------------------------------

  defp topic_to_member_uri("esr:presence:" <> uri_str) do
    {:ok, URI.parse(uri_str)}
  rescue
    _ -> :error
  end

  defp topic_to_member_uri(_), do: :error
end
