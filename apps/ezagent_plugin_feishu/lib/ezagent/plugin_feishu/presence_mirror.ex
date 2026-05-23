defmodule EzagentPluginFeishu.PresenceMirror do
  @moduledoc """
  Mirrors Feishu-bound user activity into `Ezagent.Presence`.

  PR-C of the Presence rollout (SPEC `docs/superpowers/specs/2026-05-23-presence.md`
  rev 3 §7). Every inbound Feishu message resolves to a bound user URI;
  this GenServer tracks that user URI as `:transport => :feishu` in
  `Ezagent.Presence` so chat surfaces (PresenceFanout → session :events
  → admin UI online dots) reflect "this user is reachable via Feishu".

  ## Lifecycle (V1 simplification)

  Track entries are held on THIS singleton's pid. Once a user is
  tracked they STAY tracked until this process crashes (typically only
  on Application shutdown). This is intentionally "sticky":

  - **Pro**: zero spurious offline flickers; matches Allen's "user
    is on Feishu" signal which is what session views want
  - **Con**: a user who stops using Feishu doesn't appear offline
    here; Feishu's SDK doesn't surface per-user offline events to
    us so we can't do better in V1

  V1.1+: subscribe to Feishu's typing/presence events if their SDK
  ships them, then untrack after a TTL since last activity.

  ## Integration

  `EzagentPluginFeishu.InboundDispatcher.dispatch/1` calls
  `touch/1` after `SenderResolver.resolve/1` returns
  `{:ok, caller_uri, _caps}`. `touch/1` is a cast — never blocks the
  inbound dispatch path.
  """

  use GenServer

  require Logger

  alias Ezagent.Presence

  @transport_id_prefix "feishu:"

  # ----- Client API ----------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Mark `caller_uri` as currently active via Feishu. Cast — never
  blocks the inbound dispatch path. Idempotent within this process's
  lifetime; the underlying `Ezagent.Presence.track/4` skips if the
  same (uri, transport_id) is already tracked on THIS pid.
  """
  @spec touch(URI.t()) :: :ok
  def touch(%URI{} = caller_uri) do
    GenServer.cast(__MODULE__, {:touch, caller_uri})
  end

  @doc """
  Debug introspection — returns the MapSet of currently-tracked
  caller URIs. Used by tests + admin LV.
  """
  @spec __tracked__() :: MapSet.t(URI.t())
  def __tracked__, do: GenServer.call(__MODULE__, :__tracked__)

  # ----- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_) do
    # State: MapSet of caller URIs already tracked through THIS pid
    # (so :touch is cheap-idempotent without round-tripping through
    # Phoenix.Presence's "would-raise-on-duplicate" path).
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_call(:__tracked__, _from, tracked) do
    {:reply, tracked, tracked}
  end

  @impl true
  def handle_cast({:touch, %URI{} = caller_uri}, tracked) do
    if MapSet.member?(tracked, caller_uri) do
      {:noreply, tracked}
    else
      transport_id = @transport_id_prefix <> URI.to_string(caller_uri)
      meta = %{transport: :feishu, since: DateTime.utc_now()}

      case Presence.track(self(), caller_uri, transport_id, meta) do
        {:ok, _ref} ->
          {:noreply, MapSet.put(tracked, caller_uri)}

        {:error, reason} ->
          Logger.warning(
            "FeishuPresenceMirror: Ezagent.Presence.track/4 failed " <>
              "caller_uri=#{URI.to_string(caller_uri)} reason=#{inspect(reason)}"
          )

          # Don't add to tracked set — retry on next touch
          {:noreply, tracked}
      end
    end
  end
end
