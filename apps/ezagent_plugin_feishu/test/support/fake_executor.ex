defmodule EzagentPluginFeishu.UserBindingSeed.FakeExecutor do
  @moduledoc """
  Test-only fake executor for plan-validation tests (handoff B1
  permission-avoidance pivot).

  This is a NAMED module (via `start/1` → `Agent.start(..., name:
  __MODULE__)`). Tests inject only its function port:

      FakeExecutor.start(existing: [...])
      Application.put_env(
        :ezagent_plugin_feishu,
        :seed_executor_port,
        FakeExecutor.port()
      )

  The importer receives the two functions without a dynamic module
  receiver, proving the A-layer (plan) works without the deferred B-layer
  runtime execution integration. It is test-only and is never a production
  authorization path.
  """

  use Agent

  # --- lifecycle ---

  @doc "Start the named Agent with optional keyword options."
  def start(opts \\ []) do
    Agent.start(
      fn ->
        %{
          binds: [],
          list_currents: [],
          existing: Keyword.get(opts, :existing, []),
          results: Keyword.get(opts, :results, %{})
        }
      end,
      name: __MODULE__
    )
  end

  @doc "Stop the named Agent."
  def stop, do: Agent.stop(__MODULE__)

  @doc "Construct the test-only seed executor function port."
  def port do
    %{list_current: &list_current/1, bind: &bind/3}
  end

  # --- Function port callbacks (called by importer) ---

  defp list_current(_workspace_uri) do
    Agent.update(__MODULE__, fn s ->
      %{s | list_currents: [cursor() | s.list_currents]}
    end)

    {:ok, Agent.get(__MODULE__, & &1.existing)}
  end

  defp bind(_workspace_uri, open_id, user_uri) when is_binary(open_id) do
    Agent.update(__MODULE__, fn s ->
      %{s | binds: [{:bind, open_id, user_uri} | s.binds]}
    end)

    results = Agent.get(__MODULE__, & &1.results)
    uri_str = URI.to_string(user_uri)

    case Map.get(results, open_id) do
      {:ok, result} -> {:ok, Map.put(result, :open_id, open_id)}
      {:error, reason} -> {:error, reason}
      nil -> {:ok, %{open_id: open_id, user_uri: uri_str}}
    end
  end

  # --- Assertion helpers ---

  @doc "How many list_current calls were recorded."
  def list_current_count do
    Agent.get(__MODULE__, &length(&1.list_currents))
  end

  @doc "Return the list of recorded bind calls in order."
  def binds do
    Agent.get(__MODULE__, &Enum.reverse(&1.binds))
  end

  @doc "How many bind calls were recorded."
  def bind_count do
    Agent.get(__MODULE__, &length(&1.binds))
  end

  @doc "Reset the recorded state."
  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{binds: [], list_currents: [], existing: [], results: %{}}
    end)
  end

  defp cursor, do: :list_current
end
