defmodule Ezagent.Presence do
  @moduledoc """
  Cross-node liveness tracking for entity URIs. Thin URI-shaped wrapper
  over `Ezagent.Presence.Tracker` (Phoenix.Presence). Transport-agnostic;
  plugins write via `track/3`, anyone reads via `list/1` / `present?/1`
  / `subscribe/2`.

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

  alias Ezagent.{Capability, CapabilityRegistry}
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

  Caller MUST pass `ctx` containing `:caps`. Either:
  - `ctx.caps == :system` — internal trusted bypass (chat-domain
    PresenceFanout, system admin LV; matches the `Ezagent.Audit.Writer`
    pattern)
  - `ctx.caps == MapSet.t(Ezagent.Capability.t())` — checked against
    `CapabilityRegistry.needed_for(kind, :online, uri)`; raises
    `Ezagent.Capability.Unauthorized` on cap miss

  `kind` is resolved from the URI: `entity://user/...` →
  `Ezagent.Entity.User`, `entity://agent/...` → `Ezagent.Entity.Agent`.
  Other schemes raise `ArgumentError` (no Presence Behavior registered).

  Subscribers receive `{:ezagent_presence_diff, topic, %{joins,
  leaves, current}}` messages.
  """
  @spec subscribe(entity_uri(), ctx :: map()) :: :ok
  def subscribe(uri, ctx) do
    parsed_uri = parse_uri!(uri)
    kind_module = kind_module_of!(parsed_uri)

    check_subscribe_cap!(ctx, kind_module, parsed_uri)

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
  defp parse_uri!(s) when is_binary(s), do: URI.parse(s)

  defp kind_module_of!(%URI{scheme: "entity", host: "user"}), do: Ezagent.Entity.User
  defp kind_module_of!(%URI{scheme: "entity", host: "agent"}), do: Ezagent.Entity.Agent

  defp kind_module_of!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.Presence.subscribe/2: no Presence Behavior registered for " <>
            "URI #{inspect(URI.to_string(uri))}. Only entity://user/... and " <>
            "entity://agent/... are supported in V1."
  end

  defp check_subscribe_cap!(%{caps: :system}, _kind, _uri), do: :ok

  defp check_subscribe_cap!(ctx, kind_module, %URI{} = uri) do
    needed = CapabilityRegistry.needed_for(kind_module, :online, uri)
    caps = Map.get(ctx, :caps, MapSet.new())

    if any_cap_matches?(caps, needed) do
      :ok
    else
      raise Ezagent.Capability.Unauthorized,
        needed: needed,
        message:
          "Ezagent.Presence.subscribe/2: caller does not hold a :online cap " <>
            "matching #{inspect(needed)}."
    end
  end

  defp any_cap_matches?(caps, needed) when is_struct(caps, MapSet) do
    Enum.any?(caps, &Capability.matches?(&1, needed))
  end

  defp any_cap_matches?(_caps, _needed), do: false
end
