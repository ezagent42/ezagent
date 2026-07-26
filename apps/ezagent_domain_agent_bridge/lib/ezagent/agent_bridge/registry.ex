defmodule Ezagent.AgentBridge.Registry do
  @moduledoc """
  `agent_uri -> channel_pid` lookup table for bridge-backed agents.

  This is the unified registry for all bridge-backed agent kinds (cc,
  codex, ...). The deprecated cc-named shim (`EzagentPluginCc.BridgeRegistry`)
  and the `/cc_socket` mount were removed in Cleanup-3 (FF-4 3→0); all
  callers now use this module directly.
  """

  @table :ezagent_plugin_agent_bridges
  @pubsub EzagentCore.PubSub
  @topic "esr:agent_bridge:bridges"
  @legacy_topic "esr:cc_channel:bridges"

  @doc "ETS table init. Idempotent."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc "Generic PubSub topic for AgentBridge connect/disconnect events."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Legacy cc PubSub topic kept for the deprecation window."
  @spec legacy_topic() :: String.t()
  def legacy_topic, do: @legacy_topic

  @doc """
  Bind `agent_uri` to the Channel pid with optional metadata.

  Idempotent for the same pid. Returns `{:error, :already_bound}` when
  a different live pid already owns the URI.
  """
  @spec bind(URI.t(), pid(), map()) :: :ok | {:error, term()}
  def bind(%URI{} = agent_uri, channel_pid, info \\ %{})
      when is_pid(channel_pid) and is_map(info) do
    init()

    key = URI.to_string(agent_uri)
    row = %{pid: channel_pid, connected_at: DateTime.utc_now(), info: info}

    case :ets.lookup(@table, key) do
      [{^key, %{pid: existing_pid}}] when existing_pid == channel_pid ->
        :ok

      [{^key, %{pid: existing_pid}}] ->
        if Process.alive?(existing_pid) do
          {:error, :already_bound}
        else
          true = :ets.insert(@table, {key, row})
          broadcast_connected(agent_uri, info)
          :ok
        end

      [] ->
        true = :ets.insert(@table, {key, row})
        broadcast_connected(agent_uri, info)
        :ok
    end
  end

  @doc "Unbind `agent_uri` unconditionally (force). Prefer `unbind/2` from a channel."
  @spec unbind(URI.t()) :: :ok
  def unbind(%URI{} = agent_uri) do
    init()

    key = URI.to_string(agent_uri)
    existed? = :ets.member(@table, key)
    :ets.delete(@table, key)
    if existed?, do: broadcast_disconnected(agent_uri)
    :ok
  end

  @doc """
  Unbind `agent_uri` ONLY if the stored row's pid matches `channel_pid`.

  Pid-guarded: a STALE or SIBLING channel process terminating for the same
  agent URI must NOT delete the row owned by a DIFFERENT (newer) live channel.
  A cc agent can briefly have more than one channel process for the same URI
  (reconnect / transient join churn); with the unguarded `unbind/1`, one
  process's `terminate/2` would delete the binding a SECOND, still-live channel
  just wrote — so the agent vanishes from the registry despite a connected
  bridge, and `AgentBridge.deliver/2` returns `:no_bridge` (the 2026-06-02
  cc-agent-not-deliverable bug). Call this from channel `terminate/2` with
  `self()`.
  """
  @spec unbind(URI.t(), pid()) :: :ok
  def unbind(%URI{} = agent_uri, channel_pid) when is_pid(channel_pid) do
    init()

    key = URI.to_string(agent_uri)

    case :ets.lookup(@table, key) do
      [{^key, %{pid: ^channel_pid}}] ->
        :ets.delete(@table, key)
        broadcast_disconnected(agent_uri)
        :ok

      _ ->
        # Row owned by a different (newer) pid, or already gone — leave it.
        :ok
    end
  end

  @doc "Look up the live Channel pid bound to `agent_uri`."
  @spec lookup(URI.t()) :: {:ok, pid()} | :error
  def lookup(%URI{} = agent_uri) do
    init()

    case :ets.lookup(@table, URI.to_string(agent_uri)) do
      [{_, %{pid: pid}}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Back-compat list shape: `[{agent_uri, pid}]`."
  @spec list_all() :: [{URI.t(), pid()}]
  def list_all do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {key, %{pid: pid}} -> {Ezagent.URI.new!(key), pid} end)
  end

  @doc """
  List bound bridges with metadata:
  `[{agent_uri, %{pid: pid, connected_at: DateTime.t(), info: map()}}]`.
  """
  @spec list_connected() :: [{URI.t(), map()}]
  def list_connected do
    init()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {key, row} -> {Ezagent.URI.new!(key), row} end)
  end

  @doc "Number of currently bound bridges."
  @spec count() :: non_neg_integer()
  def count do
    init()
    :ets.info(@table, :size) || 0
  end

  @doc """
  High-level status atom for admin summary panels.

    * `:no_bridges` when the registry is empty
    * `{:connected, n}` when n bridges are bound
  """
  @spec status() :: :no_bridges | {:connected, pos_integer()}
  def status do
    case count() do
      0 -> :no_bridges
      n -> {:connected, n}
    end
  end

  defp broadcast_connected(agent_uri, info) do
    # V5 use-side H3 — the MAIN topic rides the sealed transport
    # (`%Signal{kind: :broadcast}`): `AgentBridge.ensure_ready/2` subscribes
    # from INSIDE an Agent Kind's dispatch, so every stray connect/disconnect
    # in its subscribe window must arrive as a sanctioned envelope (the
    # sealed Kind mailbox fail-louds on raw tuples). The legacy topic's only
    # subscriber is the world LiveView (never a Kind) — it stays raw.
    EzagentActor.Signal.broadcast(@topic, {:agent_bridge_connected, agent_uri, info})
    Phoenix.PubSub.broadcast(@pubsub, @legacy_topic, {:cc_connected, agent_uri, info})
  end

  defp broadcast_disconnected(agent_uri) do
    EzagentActor.Signal.broadcast(@topic, {:agent_bridge_disconnected, agent_uri})
    Phoenix.PubSub.broadcast(@pubsub, @legacy_topic, {:cc_disconnected, agent_uri})
  end
end
