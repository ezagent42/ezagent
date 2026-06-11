defmodule Ezagent.Socialware.ChatFeed do
  @moduledoc """
  P4 — a CHAT session's external SPA view, served over the SAME `:pull`
  adapter + Phoenix-channel + json-render SPA machinery P3-2 built for the
  socialware customer feed (`CustomerFeed`), but projecting the **chat message
  slice** over the **chat message ordering** (`inserted_at`) instead of the
  socialware committed-delivery cursor (chat has NO settlement model).

  This proves the substrate's "ANY session → external SPA" generalization: P3
  built the adapter + surface for socialware; P4 reuses it for chat with NO
  chat-specific surface code. The internal chat operator LiveView
  (`ConversationView`) is UNCHANGED — this is purely an additive external read.

  ## What is the SAME as `CustomerFeed` (reused)

    * the `:pull` adapter shape (`ChatFeedAdapter` — a bare-module `render/2` +
      cap-only `.Allow`, mirroring `CustomerFeedAdapter`);
    * the json-render output shape (`%{type: "container", ...}` — `chat_tree/1`
      mirrors `Surface.customer_tree` over chat messages);
    * the lower-bound cursor JOIN protocol (`join/3` captures `lower` BEFORE the
      content read, renders the snapshot, then replays from `lower`, so a commit
      landing in the join window — even with its advisory dropped — is never
      skipped; replay is idempotent so a row may be re-rendered but never lost);
    * the SPA (`customer_app.js` / `json_render.mjs`) + Channel framework.

  ## What is DIFFERENT (the only P4-specific code)

    * the cursor is the chat message ordering — `inserted_at` (per Spec 5 P5-D8,
      `id` is NOT monotonic so the chat cursor is `inserted_at`). The replay
      primitive is `MessageStore.chat_visible_since/2`, mirroring
      `committed_deliveries_since/2` but over `inserted_at`;
    * the read authority is **chat membership** (a chat session has no
      "customer" / settlement token): the SAME live, fail-closed owner/member
      predicate P3-3 specified, extracted into the shared
      `Ezagent.Socialware.ChatMembership` so the chat_feed authz and
      `SocialwarePublisherRead` stay byte-equivalent on the security boundary;
    * per-message visibility — only `:customer_visible` messages are projected
      (an `:operator_only` chat message is dropped from the external read).
  """

  alias Ezagent.Socialware.ChatMembership
  alias Ezagent.URI, as: EzURI

  @history_limit 200

  # ----- P4-1: the PURE chat → customer_tree projection ----------------------

  @doc """
  Project a list of chat `%Message{}`s into the json-render `customer_tree`
  shape the customer SPA renders: a `stack` container whose children are one
  `text` node per `:customer_visible` message (in input order). `:operator_only`
  messages are filtered out (per-message visibility — they never leak to the
  external read). Pure + deterministic.
  """
  @spec chat_tree([Ezagent.Message.t()]) :: map()
  def chat_tree(messages) when is_list(messages) do
    children =
      messages
      |> Enum.filter(&customer_visible?/1)
      |> Enum.map(&text_node/1)

    %{type: "container", props: %{layout: "stack"}, children: children}
  end

  defp customer_visible?(%{visibility: :operator_only}), do: false
  defp customer_visible?(_message), do: true

  defp text_node(message) do
    %{type: "text", key: message.id, props: %{text: message_text(message)}}
  end

  defp message_text(%{body: body}) when is_map(body) do
    Map.get(body, "text") || Map.get(body, :text) || ""
  end

  defp message_text(_message), do: ""

  # ----- P4-2/P4-3 wiring is appended below in this module -------------------

  @doc false
  def history_limit, do: @history_limit

  @doc false
  def workspace(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, workspace_str} -> {:ok, EzURI.new!(workspace_str)}
      {:error, _} -> {:error, :unbound_session}
    end
  end

  @doc false
  def chat_membership_module, do: ChatMembership
end
