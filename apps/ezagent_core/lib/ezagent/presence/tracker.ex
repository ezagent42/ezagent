defmodule Ezagent.Presence.Tracker do
  @moduledoc false

  # Phoenix.Presence-backed CRDT for cross-node liveness tracking.
  # Thin wrapper — the public API + URI-shaped helpers live in
  # `Ezagent.Presence`. This module only implements `handle_metas/4`
  # to bridge Phoenix's `%Phoenix.Socket.Broadcast{}` events into a
  # plain `{:ezagent_presence_diff, topic, %{...}}` tuple subscribers
  # can pattern-match without depending on `Phoenix.Channel` internals.
  #
  # See SPEC `docs/superpowers/specs/2026-05-23-presence.md` §3.3.

  use Phoenix.Presence,
    otp_app: :ezagent_core,
    pubsub_server: EzagentCore.PubSub

  alias Phoenix.PubSub

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    # Phoenix.Presence's handle_metas/4 call shape is inconsistent across
    # the joins/leaves/presences args — joins/leaves arrive in `%{key
    # => %{metas: [meta]}}` (wrapped), but `presences` may arrive in
    # either shape depending on diff-merge path. Normalize defensively
    # to `%{key => [meta]}` for ALL three so the SPEC contract holds
    # uniformly.
    msg =
      {:ezagent_presence_diff, topic,
       %{
         joins: normalize(joins),
         leaves: normalize(leaves),
         current: normalize(presences)
       }}

    PubSub.local_broadcast(EzagentCore.PubSub, topic, msg)
    {:ok, state}
  end

  defp normalize(presences) when is_map(presences) do
    Enum.into(presences, %{}, fn
      {key, %{metas: metas}} -> {key, metas}
      {key, metas} when is_list(metas) -> {key, metas}
    end)
  end
end
