defmodule Ezagent.Socialware.CustomerFeedAdapter.Allow do
  @moduledoc """
  Cap-only Allow Behavior for the P3-2 `:pull` customer-feed adapter
  (`adapter_id: "customer_feed"`).

  Mirrors the P3-1 pull `*.Allow` shape (`dispatchable?/0 == false`): a `:pull`
  adapter still declares a `cap_subject/0` so the per-adapter authorization cap
  (`allow_customer_feed`) exists on `Ezagent.Entity.Session`. The behavior is
  never dispatched — it is the Check-2 cap subject only.
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_customer_feed]

  @impl true
  def cap_subjects,
    do: [{:allow_customer_feed, "Authorize the customer-feed pull adapter on this session."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_customer_feed

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "CustomerFeedAdapter.Allow is cap-only (Check-2 subject) — never dispatched."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def required_caps,
    do: %{allow_customer_feed: Ezagent.Capability.cap(:session, __MODULE__, :allow_customer_feed)}

  @impl true
  def data_owner(_), do: :any
end

defmodule Ezagent.Socialware.CustomerFeedAdapter do
  @moduledoc """
  P3-2 — the socialware customer feed as a registered `:pull`
  `Ezagent.ExternalMirror.Adapter` (`adapter_id: "customer_feed"`).

  A `:pull` adapter (P3-1) has NO per-binding external transport: no
  `binding_module/0`, no `target_ownership_check/2`, no `event_to_payload/1`,
  and registering it spawns NO Worker. It is served on demand by its CALLER's
  Phoenix channel (`EzagentWeb.Socialware.CustomerChannel`), which owns the
  per-connection auth (`CustomerAuth`), the lower-bound cursor, and the
  `{:customer_delivery}` advisory subscription.

  `render/2` is the stateless projection chokepoint: it returns the gated
  customer snapshot (`%{messages, page}`) via `CustomerFeed.snapshot/2` — the
  SAME `Surface.customer_tree`-derived projection the channel already serves
  (behavior-preserving). `ctx` carries the caller's customer token under
  `:token`; an unauthorized token renders the empty/denied projection
  (`%{messages: [], page: nil}`) rather than raising, so a stale/forged token
  yields no content rather than crashing the caller's channel process.

  Declared as a BARE module in `EzagentPluginAdvisor.Application.adapters/0`
  (the owning plugin), mirroring the P3-1 bare-module pull declaration shape.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  alias Ezagent.Socialware.CustomerFeed

  @adapter_id "customer_feed"

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def display_name, do: "Customer Feed"

  @impl true
  def description,
    do: "Gated socialware customer projection, served on demand over the customer channel."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.CustomerFeedAdapter.Allow,
      description: "Authorize the customer-feed pull adapter on this session."
    }
  end

  @impl true
  def render(%URI{} = session_uri, ctx) when is_map(ctx) do
    token = Map.get(ctx, :token) || Map.get(ctx, "token")

    case CustomerFeed.snapshot(session_uri, token) do
      {:ok, snapshot} -> snapshot
      {:error, _} -> %{messages: [], page: nil}
    end
  end
end
