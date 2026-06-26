defmodule Ezagent.Socialware.ChatFeedAdapter.Allow do
  @moduledoc """
  Cap-only Allow Behavior for the P4 `:pull` chat-feed adapter
  (`adapter_id: "chat_feed"`).

  Mirrors `CustomerFeedAdapter.Allow` (the P3-2 pull `*.Allow` shape,
  `dispatchable?/0 == false`): a `:pull` adapter still declares a `cap_subject/0`
  so the per-adapter authorization cap (`allow_chat_feed`) exists on
  `Ezagent.Entity.Session`. The behavior is never dispatched — it is the Check-2
  cap subject only.
  """
  # `use Ezagent.Lifecycle` — the macro auto-derives `state_slice/0` and provides
  # `create/1` + the dispatch machinery, so this cap-only subject carries NO
  # retired `state_slice/0`/`init_slice/1`/`invoke/4` callbacks (the lifecycle
  # invariant forbids them). It is `dispatchable?: false` (never dispatched), so
  # the macro's default handlers are never exercised — it exists only as the
  # Check-2 cap subject for `allow_chat_feed`.
  use Ezagent.Lifecycle

  @impl Ezagent.Behavior
  def actions, do: [:allow_chat_feed]

  @impl Ezagent.Behavior
  def cap_subjects,
    do: [{:allow_chat_feed, "Authorize the chat-feed pull adapter on this session."}]

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def interface, do: %{}

  @impl Ezagent.Behavior
  def required_caps,
    do: %{allow_chat_feed: Ezagent.Capability.cap(:session, __MODULE__, :allow_chat_feed)}

  @impl Ezagent.Behavior
  def data_owner(_), do: :any
end

defmodule Ezagent.Socialware.ChatFeedAdapter do
  @moduledoc """
  P4 — a CHAT session's external SPA view as a registered `:pull`
  `Ezagent.ExternalMirror.Adapter` (`adapter_id: "chat_feed"`), the SECOND pull
  adapter alongside `CustomerFeedAdapter`. It shares the P3-2 SPA + Phoenix
  channel + json-render shape; only the SOURCE (the chat `inserted_at` cursor —
  chat has no settlement model) and the AUTHORITY (chat membership, not a
  customer token) differ.

  A `:pull` adapter (P3-1) has NO per-binding external transport: no
  `binding_module/0`, no `target_ownership_check/2`, no `event_to_payload/1`,
  and registering it spawns NO Worker. It is served on demand by its CALLER's
  Phoenix channel, which owns the per-connection state (the caller identity and
  the advisory subscription) and re-reads the windowed snapshot on each advisory
  (no delta cursor — chat uses snapshot-refresh, unlike the customer feed).

  `render/2` is the stateless projection chokepoint: it returns the gated chat
  snapshot (`%{messages, page}`) via `ChatFeed.snapshot/2` — the chat-message
  projection in the SAME `customer_tree` json-render shape. `ctx` carries the
  caller's identity `%URI{}` under `:caller`; a non-member / nil / malformed /
  crafted caller renders the empty/denied projection (`%{messages: [], page:
  empty container}`) rather than raising, so a stranger yields no content rather
  than crashing the caller's channel process. The LIVE fail-closed chat
  membership check is the SAME predicate as P3-3 (via `ChatMembership`).

  NOTE (2026-06-26, `chore/retire-session-advisor`): this adapter was originally
  declared as a BARE module in the retired `EzagentPluginAdvisor.Application.adapters/0`.
  With the advisor vertical removed, NO plugin currently declares it, so its
  `allow_chat_feed` cap subject is no longer published at boot. The live chat feed
  does NOT depend on that registration — the channel calls `ChatFeed` directly
  (proven by the socialware/web suites). The module is retained as the projection
  chokepoint for any future plugin that re-declares it via the bare-module pull
  declaration shape.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  alias Ezagent.Socialware.ChatFeed

  @adapter_id "chat_feed"

  @empty_projection %{
    messages: [],
    page: %{type: "container", props: %{layout: "stack"}, children: []}
  }

  @impl true
  def adapter_id, do: @adapter_id

  @impl true
  def display_name, do: "Chat Feed"

  @impl true
  def description,
    do: "Chat session projection as an external SPA, served on demand over the customer channel."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.Socialware.ChatFeedAdapter.Allow,
      description: "Authorize the chat-feed pull adapter on this session."
    }
  end

  @impl true
  def render(%URI{} = session_uri, ctx) when is_map(ctx) do
    caller = Map.get(ctx, :caller) || Map.get(ctx, "caller")

    case ChatFeed.snapshot(session_uri, caller) do
      {:ok, snapshot} -> snapshot
      {:error, _} -> @empty_projection
    end
  end
end
