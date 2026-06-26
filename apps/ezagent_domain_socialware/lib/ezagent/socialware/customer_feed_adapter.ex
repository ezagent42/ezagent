defmodule Ezagent.Socialware.CustomerFeedAdapter.Allow do
  @moduledoc """
  Cap-only Allow Behavior for the P3-2 `:pull` customer-feed adapter
  (`adapter_id: "customer_feed"`).

  Mirrors the P3-1 pull `*.Allow` shape (`dispatchable?/0 == false`): a `:pull`
  adapter still declares a `cap_subject/0` so the per-adapter authorization cap
  (`allow_customer_feed`) exists on `Ezagent.Entity.Session`. The behavior is
  never dispatched — it is the Check-2 cap subject only.
  """
  # `use Ezagent.Lifecycle` — the macro auto-derives `state_slice/0` and provides
  # `create/1` + the dispatch machinery, so this cap-only subject carries NO
  # retired `state_slice/0`/`init_slice/1`/`invoke/4` callbacks (the lifecycle
  # invariant forbids them). It is `dispatchable?: false` (never dispatched), so
  # the macro's default handlers are never exercised — it exists only as the
  # Check-2 cap subject for `allow_customer_feed`.
  use Ezagent.Lifecycle

  @impl Ezagent.Behavior
  def actions, do: [:allow_customer_feed]

  @impl Ezagent.Behavior
  def cap_subjects,
    do: [{:allow_customer_feed, "Authorize the customer-feed pull adapter on this session."}]

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def interface, do: %{}

  @impl Ezagent.Behavior
  def required_caps,
    do: %{allow_customer_feed: Ezagent.Capability.cap(:session, __MODULE__, :allow_customer_feed)}

  @impl Ezagent.Behavior
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

  NOTE (2026-06-26, `chore/retire-session-advisor`): this adapter was originally
  declared as a BARE module in the retired `EzagentPluginAdvisor.Application.adapters/0`.
  With the advisor vertical removed, NO plugin currently declares it, so its
  `allow_customer_feed` cap subject is no longer published at boot. The live
  customer feed does NOT depend on that registration — the channel calls
  `CustomerFeed.snapshot/2` directly (proven by the socialware/web suites). The
  module is retained as the projection chokepoint for any future plugin that
  re-declares it via the bare-module pull declaration shape.
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
