defmodule Ezagent.Presence do
  @moduledoc """
  Cross-node liveness tracking for entity URIs. Thin URI-shaped wrapper
  over `Ezagent.Presence.Tracker` (Phoenix.Presence). Transport-agnostic;
  plugins write via `track/3`, anyone reads via `list/1` / `present?/1`
  / `subscribe/1`.

  ## Subscribe events

  Subscribers receive tuple messages of the form:

      {:ezagent_presence_diff, topic, %{
        joins:   %{transport_id => [meta]},
        leaves:  %{transport_id => [meta]},
        current: %{transport_id => [meta]}
      }}

  This is broadcast by `Ezagent.Presence.Tracker.handle_metas/4` via
  `Phoenix.PubSub.local_broadcast` after Phoenix.Presence has updated
  its CRDT. It's a documented translation of the raw
  `%Phoenix.Socket.Broadcast{event: "presence_diff"}` event the default
  dispatcher emits — direct GenServer subscribers can pattern-match
  the tuple without depending on `Phoenix.Channel` internals.

  ## Stale-window SLA

  After non-graceful node loss (SIGKILL, BEAM panic, hardware crash),
  remote views show this node's entries as ONLINE for up to ~30s
  (Phoenix.Tracker's default `down_period`) before they expire.
  Graceful shutdown is immediate (`permdown_on_shutdown: true` set
  on the Tracker in `EzagentCore.Application`).

  See SPEC `docs/superpowers/specs/2026-05-23-presence.md` §6.
  """

  alias Ezagent.Presence.Tracker

  @type entity_uri :: URI.t() | String.t()
  @type transport_id :: String.t()
  @type meta :: %{required(:transport) => atom(), optional(atom()) => any()}

  @doc "PubSub topic for `uri`'s presence diffs."
  @spec topic(entity_uri()) :: String.t()
  def topic(uri), do: "esr:presence:" <> to_uri_string(uri)

  @doc """
  Mark `uri` as present via `transport_id`. The calling process is
  monitored — exit auto-removes the entry. `meta` MUST include
  `:transport` (atom).

  Raises if the SAME pid tries to track the SAME `(uri, transport_id)`
  twice on the same topic (Phoenix.Presence's underlying behavior;
  caller bug — P2 let-it-crash).
  """
  @spec track(entity_uri(), transport_id(), meta()) ::
          {:ok, ref :: binary()} | {:error, term()}
  def track(uri, transport_id, meta) when is_map(meta) do
    track(self(), uri, transport_id, meta)
  end

  @doc """
  Same as `track/3` but lets a long-lived caller (e.g. a supervisor)
  track on behalf of a short-lived child process. `pid` is the
  monitored process whose exit removes the entry.
  """
  @spec track(pid(), entity_uri(), transport_id(), meta()) ::
          {:ok, ref :: binary()} | {:error, term()}
  def track(pid, uri, transport_id, meta)
      when is_pid(pid) and is_binary(transport_id) and is_map(meta) do
    Tracker.track(pid, topic(uri), transport_id, meta)
  end

  @doc "Remove a `(uri, transport_id)` entry. Idempotent."
  @spec untrack(entity_uri(), transport_id()) :: :ok
  def untrack(uri, transport_id) when is_binary(transport_id) do
    Tracker.untrack(self(), topic(uri), transport_id)
  end

  @doc """
  All `(transport_id → [meta])` tracked for `uri`. The list value handles
  the CRDT same-key-multiple-nodes case (a User with one tab on each
  of two nodes appears twice).
  """
  @spec list(entity_uri()) :: %{transport_id() => [meta()]}
  def list(uri) do
    Tracker.list(topic(uri))
    |> Enum.into(%{}, fn {tid, %{metas: metas}} -> {tid, metas} end)
  end

  @doc "True if any transport currently tracks `uri`."
  @spec present?(entity_uri()) :: boolean()
  def present?(uri), do: list(uri) != %{}

  @doc """
  Subscribe the calling process to presence diffs for `uri`.

  No cap check: presence subscription is an in-VM-internal operation
  (the only callers are trusted internal fan-out, e.g.
  `EzagentDomainInstanceMessage.PresenceFanout`). Under the #154
  VM-internal-trust model the authorization boundary is the dispatch
  chokepoint, which serves external callers; this helper is reached
  only from trusted in-VM code, so a secondary cap check here was
  dormant (its sole callers passed the trusted bypass) and was removed.
  The cap-only `Ezagent.ActionSet.Presence` marker that the dormant check
  consumed was deleted in the #154 cleanup (2026-06-20).

  The URI scheme is still validated: only entity user, agent, and worker
  principals are supported; any other scheme raises `ArgumentError`.

  Subscribers receive `{:ezagent_presence_diff, topic, %{joins,
  leaves, current}}` messages.
  """
  @spec subscribe(entity_uri()) :: :ok
  def subscribe(uri) do
    parsed_uri = parse_uri!(uri)
    _ = kind_module_of!(parsed_uri)

    Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic(parsed_uri))
  end

  @doc "Unsubscribe the calling process from `uri`'s presence diffs."
  @spec unsubscribe(entity_uri()) :: :ok
  def unsubscribe(uri) do
    Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic(uri))
  end

  # ----- Private -------------------------------------------------------------

  defp to_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp to_uri_string(s) when is_binary(s), do: s

  defp parse_uri!(%URI{} = uri), do: uri
  defp parse_uri!(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp kind_module_of!(%URI{scheme: "entity"} = uri) do
    cond do
      Ezagent.URI.type?(uri, :user) -> Ezagent.Entity.User
      Ezagent.URI.type?(uri, :agent) -> Ezagent.Entity.Agent
      Ezagent.URI.type?(uri, :worker) -> Ezagent.Entity.Agent
      true -> raise_unsupported_kind!(uri)
    end
  end

  defp kind_module_of!(%URI{} = uri), do: raise_unsupported_kind!(uri)

  defp raise_unsupported_kind!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.Presence.subscribe/1: unsupported URI " <>
            "#{inspect(Ezagent.URI.stable_key(uri))}. Only entity user, agent, " <>
            "and worker URIs are supported."
  end
end
