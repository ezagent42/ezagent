defmodule EzagentPluginFeishu.FeishuAdapter do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6 / §2.2) — Feishu (Lark) Adapter for the
  generic ExternalMirror Domain.

  Stateless wire-format translator: converts `Ezagent.Publisher.Event`
  values whose `slice_key == :chat` into Lark `im.v1.messages.create`
  JSON. The matching `EzagentPluginFeishu.FeishuChatBinding` GenServer
  owns the transport (HTTP client, tenant token cache, 429 backoff).

  Replaces the retired single-tenant
  `EzagentPluginFeishu.Behavior.FeishuOutbound` (311 LOC) + the
  side-table `EzagentPluginFeishu.SessionBinding` (130 LOC). Behavior
  parity is intentional — same Lark API calls for the same input
  messages — so the migration is observably transparent at the Lark
  channel surface.

  ## Callbacks

  - `adapter_id/0` → `"feishu"`
  - `display_name/0` → `"Feishu (Lark)"`
  - `description/0` → operator-facing one-line description
  - `binding_module/0` → `EzagentPluginFeishu.FeishuChatBinding`
    (Grill-5 bidirectional declaration)
  - `cap_subject/0` → references
    `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow` (Cap 2
    in SPEC §4.2 / `Ezagent.ExternalMirror.bind/4` Check 2)
  - `target_ownership_check/2` → queries Lark
    `im.v1.chats.members.is_in_chat` to verify the caller's linked
    Feishu open_id is a member of the chat (Cap 3 in SPEC §4.2)
  - `target_ownership_check_timeout/0` → 10_000 ms (Lark API can be
    slow; default 5_000 is too tight for membership queries)
  - `event_to_payload/1` → `{:publish, payload}` for `:chat` slice
    events; `:skip` otherwise (V1 parity with old FeishuOutbound,
    which only acted on chat sends)

  ## event_to_payload payload shape

  The Binding consumes the returned payload verbatim — the Adapter
  decides the shape. For Feishu we emit a tagged tuple naming the
  Lark API call shape:

      {:lark_text, chat_id :: String.t(), prefixed_text :: String.t()}
      {:lark_image_passthrough, chat_id, file_key, label}
      {:lark_file_passthrough, chat_id, file_key, label}
      {:lark_image_upload, chat_id, local_path, label}
      {:lark_file_upload, chat_id, local_path, label}

  The tag captures both the message type (text / image / file) AND
  the upload-vs-passthrough distinction the old FeishuOutbound made
  inline. `chat_id` is fetched from the binding's stored target_id
  inside `FeishuChatBinding.publish/2`; we still pass it in the
  payload so the Binding doesn't need to re-resolve.

  ## Self-echo prevention (preserved from FeishuOutbound)

  Inbound messages stamped `body[:_feishu_origin]` (or
  `body["_feishu_origin"]`) by
  `EzagentPluginFeishu.InboundDispatcher.do_dispatch/4` MUST NOT be
  echoed back to Feishu — that would spin a loop. We honour the flag
  by returning `:skip` from `event_to_payload/1`. Same atom-vs-string
  key handling as old FeishuOutbound (MessageStore JSON round-trip
  produces string keys).

  ## Why event_to_payload is pure (no Lark API calls)

  The Worker Kind invokes `event_to_payload/1` synchronously inside
  its `:publish` action handler — blocking on an HTTP call here would
  stall the Worker's mailbox and defeat the per-binding crash
  boundary. The Binding's `publish/2` is where Lark bytes flow. The
  exception is `target_ownership_check/2` which legitimately needs to
  ask Lark "is this caller a member of this chat?" — that's the ONE
  external-I/O callback the SPEC permits (§2.2 r4).
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  require Logger

  alias Ezagent.Publisher.Event
  alias EzagentPluginFeishu.{Client, UserBinding}

  @impl Ezagent.ExternalMirror.Adapter
  def adapter_id, do: "feishu"

  @impl Ezagent.ExternalMirror.Adapter
  def display_name, do: "Feishu (Lark)"

  @impl Ezagent.ExternalMirror.Adapter
  def description,
    do: "Mirror session chat messages out to a Lark group chat via the Lark Open API."

  @impl Ezagent.ExternalMirror.Adapter
  def binding_module, do: EzagentPluginFeishu.FeishuChatBinding

  @impl Ezagent.ExternalMirror.Adapter
  def cap_subject do
    %{
      behavior_module: EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow,
      description: "Authorize binding the `feishu` external-mirror adapter on this session."
    }
  end

  @impl Ezagent.ExternalMirror.Adapter
  def target_ownership_check_timeout, do: 10_000

  @doc """
  Bind-time check: is the caller's linked Feishu `open_id` a member
  of the Lark chat `chat_id`?

  Steps:

  1. Resolve `caller_uri` to a Feishu `open_id` via
     `EzagentPluginFeishu.UserBinding.list_all/0` (reverse lookup —
     `user_uri → open_id`). No binding → `{:error, :no_feishu_identity}`.
  2. Call Lark `im.v1.chats.members.is_in_chat` (HTTP GET to
     `/open-apis/im/v1/chats/{chat_id}/members/is_in_chat`) using
     `Client.peek_token/0`. The endpoint returns
     `{"code": 0, "data": {"is_in_chat": true/false}}` per Lark
     open-api docs.
  3. `true` → `:ok`. `false` → `{:error, :not_a_member}`.
  4. Any HTTP / Lark error → `{:error, {:lark_check_failed, reason}}`
     (P18 — Domain surfaces verbatim; operator sees the exact reason).

  ## Contract

  - Runs inside an `async_nolink` `Task` under
    `Ezagent.ExternalMirror.TargetCheckTaskSup` with a 10_000 ms
    timeout (override of the 5_000 ms default — Lark membership
    checks observed up to 6-8s on cold tenant token paths).
  - MUST NOT call `Ezagent.Invocation.dispatch/1` directly or
    transitively (re-entering dispatch from a bind-time callback
    would deadlock — `:bind` is itself a dispatched action). The
    only external I/O here is the Lark HTTP call.
  - Returns `{:error, :credentials_not_configured}` verbatim from
    `Client.peek_token/0` when the feishu.yaml template has the
    `cli_REPLACE_ME` placeholder — operator sees the actionable
    reason rather than a generic "denied".
  """
  @impl Ezagent.ExternalMirror.Adapter
  def target_ownership_check(%URI{} = caller_uri, chat_id) when is_binary(chat_id) do
    with {:ok, open_id} <- caller_open_id(caller_uri),
         {:ok, token} <- Client.peek_token() do
      check_chat_membership(chat_id, open_id, token)
    end
  end

  def target_ownership_check(_caller, _target_id),
    do: {:error, :invalid_target}

  @doc """
  Translate a Publisher event into a Lark API payload. Pure — no I/O.

  - `:chat` slice changes carrying a `%Ezagent.Message{}` → emit the
    Lark text + attachment payloads (same shape as the retired
    `FeishuOutbound.mirror_to_chats/5`).
  - All other slice keys → `:skip`. V1 parity: today's FeishuOutbound
    is wired to `:notify_external` which fires only on chat sends.
    Adapters that want to mirror agent state / membership / etc. ship
    later (the `:skip` path is the documented extension point).
  - Self-echo (body carries `_feishu_origin`) → `:skip` (loop guard).

  ## Multi-event payload shape

  A single chat message can produce MULTIPLE Lark API calls (text +
  one or more attachments). We return `{:publish, list}` where the
  list elements are the tagged tuples the Binding's `publish/2`
  iterates over. The Binding accumulates rate-limit state across
  the list so a 429 on one attachment doesn't lose the rest.
  """
  @impl Ezagent.ExternalMirror.Adapter
  def event_to_payload(%Event{slice_key: :chat, payload: payload}) do
    case extract_message(payload) do
      {:ok, msg} ->
        cond do
          from_feishu?(msg) ->
            :skip

          true ->
            payload_list = build_lark_payloads(msg, payload)

            case payload_list do
              [] -> :skip
              list -> {:publish, list}
            end
        end

      :error ->
        :skip
    end
  end

  def event_to_payload(%Event{}), do: :skip

  # ----- internals: caller → open_id ----------------------------------------

  defp caller_open_id(%URI{} = caller_uri) do
    target = URI.to_string(caller_uri)

    UserBinding.list_all()
    |> Enum.find(fn row -> row.user_uri == target end)
    |> case do
      nil -> {:error, :no_feishu_identity}
      %{open_id: open_id} -> {:ok, open_id}
    end
  end

  # ----- internals: Lark membership probe ----------------------------------

  defp check_chat_membership(chat_id, open_id, token) do
    url =
      "https://open.feishu.cn/open-apis/im/v1/chats/" <>
        URI.encode_www_form(chat_id) <>
        "/members/is_in_chat?member_id_type=open_id&member_id=" <>
        URI.encode_www_form(open_id)

    headers = [{~c"Authorization", String.to_charlist("Bearer #{token}")}]

    request = {String.to_charlist(url), headers}

    # 8s HTTP timeout leaves slack inside the 10s task timeout so the
    # caller sees `:lark_check_failed, {:http_error, :timeout}` rather
    # than the Domain's `:target_check_timeout` brutal-kill (clearer
    # operator error message).
    case :httpc.request(:get, request, [{:timeout, 8000}, {:connect_timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, %{"code" => 0, "data" => %{"is_in_chat" => true}}} ->
            :ok

          {:ok, %{"code" => 0, "data" => %{"is_in_chat" => false}}} ->
            {:error, :not_a_member}

          {:ok, %{"code" => code, "msg" => msg}} ->
            {:error, {:lark_check_failed, {:lark_error, code, msg}}}

          {:ok, other} ->
            {:error, {:lark_check_failed, {:unexpected_response, other}}}

          {:error, reason} ->
            {:error, {:lark_check_failed, {:decode, reason}}}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, {:lark_check_failed, {:http_status, status, to_string(body)}}}

      {:error, reason} ->
        {:error, {:lark_check_failed, {:http_error, reason}}}
    end
  end

  # ----- internals: event_to_payload ---------------------------------------

  # The Session Publisher emits SliceChange envelopes wrapped in
  # `%Ezagent.Publisher.Event{}` where `payload` is the chat slice's
  # `:new_slice` map (per PR-EM-0 Event docs). For chat sends, the
  # Session.invoke(:send, ...) updates `slice.messages` (most recent
  # at head) and the slice's `:last_message` field carries the
  # struct directly — but in r2's wire shape we look at whatever the
  # SliceChange envelope carries.
  #
  # Defensive: we accept both `:last_message` (atom key, fresh write)
  # and `"last_message"` (string key, post-JSON-roundtrip persisted
  # rehydrate path). The struct round-trip caveat in old FeishuOutbound
  # applied to BODY only; the message itself comes straight off the
  # Publisher event before any DB hop.
  defp extract_message(%{last_message: %Ezagent.Message{} = msg}), do: {:ok, msg}
  defp extract_message(%{"last_message" => %Ezagent.Message{} = msg}), do: {:ok, msg}

  defp extract_message(%{messages: [%Ezagent.Message{} = msg | _]}), do: {:ok, msg}
  defp extract_message(%{"messages" => [%Ezagent.Message{} = msg | _]}), do: {:ok, msg}

  defp extract_message(%{message: %Ezagent.Message{} = msg}), do: {:ok, msg}

  defp extract_message(_), do: :error

  # Self-echo guard — preserved from old FeishuOutbound. Inbound Feishu
  # messages get `_feishu_origin: true` stamped on body by
  # `InboundDispatcher.do_dispatch/4`; without this skip the mirror
  # would echo every webhook straight back to Lark and spin a loop.
  # Accept both atom AND string key shapes because MessageStore's JSON
  # round-trip produces string keys.
  defp from_feishu?(%Ezagent.Message{body: %{_feishu_origin: true}}), do: true
  defp from_feishu?(%Ezagent.Message{body: %{"_feishu_origin" => true}}), do: true
  defp from_feishu?(_), do: false

  defp build_lark_payloads(%Ezagent.Message{} = msg, slice_payload) do
    text = extract_text(msg.body)
    attachments = extract_attachments(msg.body)
    sender_label = sender_label(msg.sender)
    source_label = source_session_label(slice_payload)
    prefix = "[#{source_label} | #{sender_label}] "

    text_payload =
      if text != "", do: [{:lark_text, prefix <> text}], else: []

    attachment_payloads = Enum.flat_map(attachments, &lark_attachment_payloads(&1, prefix))

    text_payload ++ attachment_payloads
  end

  # codex r1 MED fix (2026-05-25): no `String.to_atom/1` on untrusted
  # attachment maps. Dispatch on the att-type allowlist via
  # `att_type/1` (atom result coerced from `{:image | :file | "image"
  # | "file"}` — anything else falls into `:unsupported` without
  # interning a new atom). Field reads use the dual atom/string
  # `att_get/2` so MessageStore JSON-roundtrip rehydrate works
  # without `String.to_atom/1`.
  defp lark_attachment_payloads(%{} = att, prefix) do
    type = att_type(att)
    source = att_get(att, :source)
    file_key = att_get(att, :file_key)
    local_path = att_get(att, :local_path)
    name = att_get(att, :name) || "attachment"

    cond do
      type == :unsupported ->
        [{:lark_text, prefix <> "[unsupported attachment name=#{name}]"}]

      source == "feishu" and is_binary(file_key) and type == :image ->
        [
          {:lark_text, prefix <> "[image: #{name}]"},
          {:lark_image_passthrough, file_key, name}
        ]

      source == "feishu" and is_binary(file_key) and type == :file ->
        [
          {:lark_text, prefix <> "[file: #{name}]"},
          {:lark_file_passthrough, file_key, name}
        ]

      is_binary(local_path) and type == :image ->
        [{:lark_image_upload, local_path, name, prefix}]

      is_binary(local_path) and type == :file ->
        [{:lark_file_upload, local_path, name, prefix}]

      true ->
        [{:lark_text, prefix <> "[attachment metadata only: #{inspect(att)}]"}]
    end
  end

  defp lark_attachment_payloads(att, prefix) do
    [{:lark_text, prefix <> "[attachment metadata only: #{inspect(att)}]"}]
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(other) when is_map(other), do: ""
  defp extract_text(other), do: inspect(other)

  defp extract_attachments(%{attachments: list}) when is_list(list), do: list
  defp extract_attachments(%{"attachments" => list}) when is_list(list), do: list
  defp extract_attachments(_), do: []

  # codex r1 MED fix (2026-05-25): the prior `normalize_attachment/1`
  # called `String.to_atom/1` on untrusted attachment keys + the
  # `type` string value. Atom-interning attacker-controlled bytes
  # exhausts the VM atom table (P9 stdlib non-negotiable).
  # We now access attachment fields via the dual atom/string fetcher
  # below, and compare `type` values against a fixed allowlist of
  # known atoms (so a hostile `type: "syscalls"` never coerces to a
  # new atom — it just falls through to the "unsupported" branch).
  defp att_type(att) do
    case att_get(att, :type) do
      :image -> :image
      :file -> :file
      "image" -> :image
      "file" -> :file
      _ -> :unsupported
    end
  end

  defp att_get(%{} = att, key) when is_atom(key) do
    case Map.fetch(att, key) do
      {:ok, v} -> v
      :error -> Map.get(att, Atom.to_string(key))
    end
  end

  defp att_get(_, _), do: nil

  defp sender_label(%URI{} = u), do: URI.to_string(u)
  defp sender_label(other), do: inspect(other)

  defp source_session_label(slice_payload) do
    case Map.get(slice_payload, :session_uri) || Map.get(slice_payload, "session_uri") do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> "session"
    end
  end
end
