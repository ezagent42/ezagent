defmodule EzagentPluginFeishu.Behavior.FeishuOutbound do
  @moduledoc """
  PR #144 SPEC v2 §5.8 — outbound Feishu mirror as a Session Kind Behavior.

  Replaces the deleted `Ezagent.Entity.FeishuChat` Receiver Kind +
  `EzagentPluginFeishu.Behavior.FeishuReceive` Behavior. The kind+behavior
  shape was per-room because the kind URI WAS the chat_id; the new
  shape is per-Session, with the chat_id looked up via
  `EzagentPluginFeishu.SessionBinding.chat_ids_for/1`.

  ## Why this lives on Session Kind, not on a feishu-owned Kind

  Per SPEC v2 §5.8 the architectural rule "plugins MUST NOT own a
  top-level scheme". The Feishu plugin's outbound side-channel
  therefore registers a Behavior against the existing `Ezagent.Entity.Session`
  Kind and reads the binding from a side join table. No `feishu://`
  URI is needed; the Session URI itself carries the destination
  identity, the binding gives the chat_id.

  ## Dispatch path

  `Ezagent.Behavior.Chat.invoke(:send)` ends its fan-out by
  opportunistically dispatching `<self_uri>?action=feishu_outbound.notify_external`
  if `BehaviorRegistry.lookup(SessionKind, :notify_external)` returns
  this module. The behavior's `:notify_external` action reads the
  session's binding(s) and calls the Feishu Open API for each enabled
  binding.

  ## Self-echo prevention

  When `InboundDispatcher` builds a Message from a Feishu webhook, it
  stamps `body[:_feishu_origin] = true`. FeishuOutbound checks that
  flag (atom OR string key, since MessageStore JSON round-trip
  produces string keys) and skips — without this guard, every
  inbound Feishu message would mirror straight back into Feishu and
  spin a loop.

  The flag travels on the Message envelope's body map. The
  alternative (sniff `msg.sender` for a feishu-origin URI shape) is
  fragile because today's bound users have plain `entity://user/default/X`
  URIs with no origin marker.

  ## Slice

  `:feishu_outbound` tracks `{send_calls, total_bytes}` for operator
  observability via the existing per-Kind state dump. Mirror of the
  old `:feishu_send` slice name, renamed to reflect the new
  ownership.
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.Message
  alias EzagentPluginFeishu.{Client, SessionBinding}

  @action :notify_external

  @impl Ezagent.Behavior
  def actions, do: [@action]

  @impl Ezagent.Behavior
  def state_slice, do: :feishu_outbound

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{send_calls: 0, total_bytes: 0}

  @impl Ezagent.Behavior
  def invoke(@action, slice, %{message: %Message{} = msg}, ctx) do
    self_uri = Map.get(ctx, :self_uri) || ctx[:target_uri]

    # Lazy slice init — Session Kinds that pre-date PR #144 don't
    # have the feishu_outbound slice in their snapshot. Mirrors the
    # PR #146 Pty Behavior lazy-init pattern (same reason: a Kind
    # module can't list a plugin's Behavior statically).
    slice = Map.merge(%{send_calls: 0, total_bytes: 0}, slice)

    cond do
      from_feishu?(msg) ->
        Logger.debug(
          "FeishuOutbound #{maybe_uri(self_uri)}: skipping self-echo from #{maybe_uri(msg.sender)}"
        )

        {:ok, slice, %{skipped: :self_echo}}

      true ->
        case SessionBinding.chat_ids_for(self_uri) do
          [] ->
            # Session has no Feishu binding — nothing to mirror. This
            # is the steady-state for most sessions; not an error.
            {:ok, slice, %{skipped: :no_binding}}

          chat_ids ->
            mirror_to_chats(chat_ids, msg, slice, ctx, self_uri)
        end
    end
  end

  defp mirror_to_chats(chat_ids, %Message{} = msg, slice, ctx, self_uri) do
    text = extract_text(msg.body)
    attachments = extract_attachments(msg.body)
    sender_label = sender_label(msg.sender)
    source_session = source_session_label(ctx, self_uri)
    prefix = "[#{source_session} | #{sender_label}] "

    # For each bound chat_id, run the send pipeline. Aggregate counters
    # across all chats — most sessions today have a single binding so
    # this is a fold of one element; the list shape keeps future
    # one-session-to-many-chats fan-out source-compatible.
    results =
      Enum.map(chat_ids, fn chat_id ->
        send_to_one_chat(chat_id, text, attachments, prefix)
      end)

    total_bytes_sent =
      Enum.reduce(results, 0, fn {_chat_id, _r, bytes}, acc -> acc + bytes end)

    failures = Enum.filter(results, fn {_, r, _} -> match?({:error, _}, r) end)

    new_slice = %{
      slice
      | send_calls: slice.send_calls + 1,
        total_bytes: slice.total_bytes + total_bytes_sent
    }

    if failures == [] do
      {:ok, new_slice, %{bytes_sent: total_bytes_sent, chats_notified: length(chat_ids)}}
    else
      Logger.warning(
        "FeishuOutbound #{maybe_uri(self_uri)}: failures=#{inspect(failures)}"
      )

      {:error, {:partial_send, failures}}
    end
  end

  defp send_to_one_chat(chat_id, text, attachments, prefix) do
    text_result =
      if text != "" do
        Client.send_text(chat_id, prefix <> text)
      else
        :ok
      end

    attachment_results =
      Enum.map(attachments, fn att ->
        send_attachment(chat_id, att, prefix)
      end)

    bytes =
      byte_size(text || "") +
        Enum.sum(Enum.map(attachments, &(&1[:size_bytes] || 0)))

    cond do
      text_result == :ok and Enum.all?(attachment_results, &(&1 == :ok)) ->
        {chat_id, :ok, bytes}

      true ->
        {chat_id, {:error, %{text: text_result, attachments: attachment_results}}, bytes}
    end
  end

  defp send_attachment(chat_id, %{type: type, source: "feishu", file_key: file_key} = att, prefix)
       when is_binary(file_key) do
    # Inbound attachment from Feishu (sent by user). Forward by the
    # original file_key — Feishu accepts it without re-upload as long
    # as the same app owns both ends.
    case type do
      :image ->
        _ = Client.send_text(chat_id, prefix <> "[image: #{att[:name]}]")
        Client.send_image(chat_id, file_key)

      :file ->
        _ = Client.send_text(chat_id, prefix <> "[file: #{att[:name]}]")
        Client.send_file(chat_id, file_key)

      _ ->
        Client.send_text(
          chat_id,
          prefix <> "[unsupported attachment type=#{type} name=#{att[:name]}]"
        )
    end
  end

  defp send_attachment(chat_id, %{type: type, local_path: path, name: name} = _att, prefix)
       when is_binary(path) do
    # Outbound attachment from CC / agent — upload bytes from local path.
    case type do
      :image ->
        with {:ok, image_key} <- Client.upload_image(path) do
          _ = Client.send_text(chat_id, prefix <> "[image: #{name}]")
          Client.send_image(chat_id, image_key)
        end

      :file ->
        with {:ok, file_key} <- Client.upload_file(path, name) do
          _ = Client.send_text(chat_id, prefix <> "[file: #{name}]")
          Client.send_file(chat_id, file_key)
        end

      _ ->
        Client.send_text(
          chat_id,
          prefix <> "[unsupported outbound attachment type=#{type} path=#{path}]"
        )
    end
  end

  defp send_attachment(chat_id, att, prefix) do
    Client.send_text(
      chat_id,
      prefix <> "[attachment metadata only: #{inspect(att)}]"
    )
  end

  @impl Ezagent.Behavior
  def interface do
    # Same Message shape as Ezagent.Behavior.Chat's interface — same
    # dispatch path delivers the same payload. InterfaceValidator
    # rejects bare `:any` for the struct, so the per-field schema is
    # required.
    # PR #149: Message struct renamed `uri` → `id` (plain UUID) and
    # `ref` → `ref_id` (plain string). Schema must follow.
    msg_schema = %{
      id: :string,
      sender: :uri,
      mentions: {:list, :uri},
      body: :map,
      ref_id: {:option, :string},
      inserted_at: :map
    }

    %{
      @action => %{
        description: "Mirror a session message out to its bound Feishu chats",
        args: %{message: msg_schema},
        returns: %{},
        # Cast: outbound mirror is fire-and-forget from Chat.send's
        # perspective. Failures are logged + tracked in slice
        # counters; no need to surface them synchronously to the
        # original sender.
        modes: [:cast]
      }
    }
  end

  # PR #144 self-echo guard — read the origin flag stamped by
  # `EzagentPluginFeishu.InboundDispatcher.do_dispatch/4` on inbound
  # bodies. Accept both atom and string key shapes because
  # `Ezagent.MessageStore` persists `body` as a JSON map and reload
  # produces string keys (writes use atoms; reloads use strings).
  defp from_feishu?(%Message{body: %{_feishu_origin: true}}), do: true
  defp from_feishu?(%Message{body: %{"_feishu_origin" => true}}), do: true
  defp from_feishu?(_), do: false

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(other) when is_map(other), do: ""
  defp extract_text(other), do: inspect(other)

  defp extract_attachments(%{attachments: list}) when is_list(list), do: list
  defp extract_attachments(%{"attachments" => list}) when is_list(list), do: normalize(list)
  defp extract_attachments(_), do: []

  defp normalize(list), do: Enum.map(list, &normalize_one/1)

  defp normalize_one(%{} = m) do
    Map.new(m, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), normalize_value(k, v)}
      kv -> kv
    end)
  end

  defp normalize_one(other), do: other

  defp normalize_value("type", v) when is_binary(v), do: String.to_atom(v)
  defp normalize_value(_, v), do: v

  defp sender_label(%URI{} = u), do: URI.to_string(u)
  defp sender_label(other), do: inspect(other)

  defp source_session_label(ctx, fallback_uri) do
    case Map.get(ctx, :self_uri) || fallback_uri do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> "(unknown session)"
    end
  end

  defp maybe_uri(%URI{} = u), do: URI.to_string(u)
  defp maybe_uri(s) when is_binary(s), do: s
  defp maybe_uri(other), do: inspect(other)
end
