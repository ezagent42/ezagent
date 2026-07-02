defmodule Ezagent.Socialware.ExternalFeedAdapter.Allow do
  @moduledoc """
  Cap-only Allow Behavior for the `external_feed` `:pull` adapter.
  """

  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:allow_external_feed]

  @impl Ezagent.ActionSet
  def cap_subjects,
    do: [{:allow_external_feed, "Authorize the external-feed pull adapter on this session."}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{allow_external_feed: Ezagent.Capability.cap(:session, __MODULE__, :allow_external_feed)}

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any
end

defmodule Ezagent.Socialware.ExternalFeedAdapter do
  @moduledoc """
  `:pull` adapter for the socialware external feed.

  The adapter restores the ExternalMirror registration frame around the existing
  `Ezagent.Socialware.ExternalFeed` projection and cursor replay protocol.
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  alias Ezagent.ActionSet.Session.Delivery
  alias Ezagent.Session.ExternalDelivery
  alias Ezagent.Socialware.ExternalFeed

  @adapter_id "external_feed"

  @empty_projection %{
    messages: [],
    page: nil,
    shell: nil,
    shell_css: nil
  }

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def display_name, do: "External Feed"

  @impl true
  def description,
    do: "External socialware projection served with cursor-replay live delivery."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def delivery_discipline, do: :cursor_replay

  @impl true
  def participation_profile, do: :participatory

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.ExternalFeedAdapter.Allow,
      description: "Authorize the external-feed pull adapter on this session."
    }
  end

  @impl true
  def render(%URI{} = session_uri, ctx) when is_map(ctx) do
    caller = Map.get(ctx, :caller) || Map.get(ctx, "caller")

    case ExternalFeed.snapshot(session_uri, caller) do
      {:ok, snapshot} -> snapshot
      {:error, _} -> @empty_projection
    end
  end

  @impl true
  def live_topics(%URI{} = session_uri) do
    [
      ExternalDelivery.topic(session_uri),
      Delivery.session_events_topic(session_uri)
    ]
  end

  @impl true
  def join_with_cursor(%URI{} = session_uri, %URI{} = caller) do
    ExternalFeed.join(session_uri, caller)
  end

  @impl true
  def replay(%URI{} = session_uri, %URI{} = caller, cursor) when is_integer(cursor) do
    ExternalFeed.replay(session_uri, caller, cursor)
  end

  @impl true
  def history(%URI{} = session_uri, %URI{} = caller) do
    ExternalFeed.history(session_uri, caller)
  end
end
