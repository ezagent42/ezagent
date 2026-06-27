defmodule EzagentWeb.TestSupport.SessionFeedAdapterState do
  @moduledoc false

  @table :ezagent_web_session_feed_adapter_state

  def reset! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    else
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  def put(key, value), do: :ets.insert(@table, {key, value})

  def get(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  def bump(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end
end

defmodule EzagentWeb.TestSupport.SnapshotPullAdapter do
  @moduledoc false
  @behaviour Ezagent.ExternalMirror.Adapter

  alias EzagentWeb.TestSupport.SessionFeedAdapterState, as: State

  @impl true
  def adapter_id, do: "web_snapshot"

  @impl true
  def display_name, do: "Web Snapshot Fixture"

  @impl true
  def description, do: "Snapshot-refresh fixture for SessionFeedChannel tests."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def delivery_discipline, do: :snapshot_refresh

  @impl true
  def participation_profile, do: :read_only

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.ChatFeedAdapter.Allow,
      description: "Fixture cap subject."
    }
  end

  @impl true
  def render(%URI{} = _session_uri, _ctx), do: snapshot("render")

  @impl true
  def render_authorized(%URI{} = session_uri, %URI{} = _caller) do
    if State.get({__MODULE__, :unauthorized}, false) do
      {:error, :unauthorized}
    else
      version = State.bump({__MODULE__, :renders})

      if State.get({__MODULE__, :broadcast_during_render}, false) and version == 1 do
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          topic(session_uri),
          {:fixture_advisory, version}
        )
      end

      {:ok, snapshot("snapshot-#{version}")}
    end
  end

  @impl true
  def live_topics(%URI{} = session_uri), do: [topic(session_uri)]

  defp topic(session_uri), do: "web_snapshot:" <> URI.to_string(session_uri)

  defp snapshot(label) do
    %{messages: [], page: %{type: "container", props: %{label: label}, children: []}}
  end
end

defmodule EzagentWeb.TestSupport.CursorPullAdapter do
  @moduledoc false
  @behaviour Ezagent.ExternalMirror.Adapter

  alias EzagentWeb.TestSupport.SessionFeedAdapterState, as: State

  @impl true
  def adapter_id, do: "web_cursor"

  @impl true
  def display_name, do: "Web Cursor Fixture"

  @impl true
  def description, do: "Cursor-replay fixture for SessionFeedChannel tests."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def delivery_discipline, do: :cursor_replay

  @impl true
  def participation_profile, do: :participatory

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.ChatFeedAdapter.Allow,
      description: "Fixture cap subject."
    }
  end

  @impl true
  def render(%URI{} = _session_uri, _ctx), do: snapshot("render")

  @impl true
  def live_topics(%URI{} = session_uri), do: [topic(session_uri)]

  @impl true
  def join_with_cursor(%URI{} = _session_uri, %URI{} = _caller) do
    {:ok, %{snapshot: snapshot("join"), cursor: 41}}
  end

  @impl true
  def replay(%URI{} = _session_uri, %URI{} = _caller, cursor) when is_integer(cursor) do
    if State.get({__MODULE__, :unauthorized}, false) do
      {:error, :unauthorized}
    else
      State.put({__MODULE__, :last_replay_cursor}, cursor)
      {:ok, %{snapshot: snapshot("replay-from-#{cursor}"), cursor: cursor + 1}}
    end
  end

  defp topic(session_uri), do: "web_cursor:" <> URI.to_string(session_uri)

  defp snapshot(label) do
    %{messages: [], page: %{type: "container", props: %{label: label}, children: []}}
  end
end

defmodule EzagentWeb.TestSupport.ParticipatoryPullAdapter do
  @moduledoc false
  @behaviour Ezagent.ExternalMirror.Adapter

  alias EzagentWeb.TestSupport.SessionFeedAdapterState, as: State

  @impl true
  def adapter_id, do: "web_participatory"

  @impl true
  def display_name, do: "Web Participatory Fixture"

  @impl true
  def description, do: "Participatory fixture for SessionFeedChannel tests."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def delivery_discipline, do: :cursor_replay

  @impl true
  def participation_profile, do: :participatory

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.ChatFeedAdapter.Allow,
      description: "Fixture cap subject."
    }
  end

  @impl true
  def render(%URI{} = _session_uri, _ctx), do: snapshot("render")

  @impl true
  def live_topics(%URI{} = session_uri), do: [topic(session_uri)]

  @impl true
  def join_with_cursor(%URI{} = _session_uri, %URI{} = _caller) do
    {:ok, %{snapshot: snapshot("join"), cursor: 0}}
  end

  @impl true
  def replay(%URI{} = _session_uri, %URI{} = _caller, cursor) when is_integer(cursor) do
    {:ok, %{snapshot: snapshot("replay-from-#{cursor}"), cursor: cursor + 1}}
  end

  @impl true
  def post(%URI{} = session_uri, %URI{} = caller, text) when is_binary(text) do
    State.put({__MODULE__, :last_post}, {session_uri, caller, text})
    :ok
  end

  defp topic(session_uri), do: "web_participatory:" <> URI.to_string(session_uri)

  defp snapshot(label) do
    %{messages: [], page: %{type: "container", props: %{label: label}, children: []}}
  end
end
