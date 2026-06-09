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

  ## Envelope contract (PR-EM-6 r3)

  Reads the real Publisher envelope as built by
  `Ezagent.Behavior.Publisher.SessionImpl.build_payload/1`:

      %Ezagent.Publisher.Event{
        slice_key: :chat,
        payload: %{
          action: atom(),                # the Behavior action that fired
          caller: URI.t() | nil,
          new_slice: chat_slice_map(),   # post-mutation snapshot
          old_slice: chat_slice_map() | nil  # pre-mutation snapshot (nil on first emit)
        }
      }

  The chat slice carries the three PR-EM-6-PRE fields the rewrite
  depends on (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex`
  `init_slice/1`):

  - `:last_message_id` — id of the most recent `Chat.send` message
  - `:last_message` — full `%Ezagent.Message{}` (sender / body /
    attachments / session_uri / workspace_uri / inserted_at)
  - `:send_cursor` — monotonic counter, bumped on every `:send`
    invocation even when `msg.id` collides with a prior persisted row
    (handles MessageStore's idempotent `on_conflict: :nothing` retry
    case — without this, a retried send wouldn't change the slice).

  ## Skip semantics

  - `slice_key != :chat` → `:skip`. V1 parity: today's external
    mirrors only act on chat sends. Adapters that want member / agent
    state diffs ship later.
  - `new_slice.last_message_id == old_slice.last_message_id` AND
    `new_slice.send_cursor == old_slice.send_cursor` → `:skip`. The
    chat slice changed for some non-send reason (e.g. a future
    `:add_member` mutation lands on the same slice). Without this
    guard, every member-list change would re-publish the last chat
    message.
  - `new_slice.last_message` missing or not a `%Ezagent.Message{}` →
    `:skip` (defensive — pre-PR-EM-6-PRE legacy snapshot, or a future
    slice mutation that intentionally leaves `:last_message` `nil`).
  - Self-echo (`body[:_feishu_origin]` or `body["_feishu_origin"]`)
    → `:skip` (loop guard preserved from old FeishuOutbound).

  ## Multi-event payload shape

  A single chat message can produce MULTIPLE Lark API calls (text +
  one or more attachments). We return `{:publish, list}` where the
  list elements are the tagged tuples the Binding's `publish/2`
  iterates over. The Binding accumulates rate-limit state across
  the list so a 429 on one attachment doesn't lose the rest.
  """
  @impl Ezagent.ExternalMirror.Adapter
  def event_to_payload(%Event{slice_key: :chat, payload: %{} = payload}) do
    # Two-container Lifecycle migration (2026-05-29) wraps the developer slice
    # as `%{state: <persistent>, transients: ...}`. The Publisher event carries
    # that wrapped shape, but every reader below (chat_send_occurred?,
    # extract_last_message) expects the FLAT slice. Unwrap `:state` here —
    # tolerant of both the new nested shape and the legacy flat shape — so chat
    # sends are detected and mirrored. (Before this fix: new_slice = %{state: …}
    # → `chat_send_occurred?` always false → every message SILENTLY skipped, the
    # post-lifecycle feishu-mirror outage. Allen 2026-05-31.)
    new_slice = slice_state(Map.get(payload, :new_slice) || Map.get(payload, "new_slice"))
    old_slice = slice_state(Map.get(payload, :old_slice) || Map.get(payload, "old_slice"))

    cond do
      not is_map(new_slice) ->
        Logger.warning(
          "FeishuAdapter.event_to_payload: SKIP (new_slice not a map) — chat slice-change " <>
            "dropped from mirror. new_slice=#{inspect(new_slice, limit: 5)}"
        )

        :skip

      not chat_send_occurred?(new_slice, old_slice) ->
        Logger.warning(
          "FeishuAdapter.event_to_payload: SKIP (chat_send_occurred? = false) — chat send " <>
            "NOT mirrored to external. new_slice keys=#{inspect(slice_diag(new_slice))} " <>
            "old_slice keys=#{inspect(slice_diag(old_slice))}"
        )

        :skip

      true ->
        case extract_last_message(new_slice) do
          {:ok, msg} ->
            if from_feishu?(msg) do
              Logger.debug("FeishuAdapter.event_to_payload: SKIP (from_feishu? echo-guard)")
              :skip
            else
              case build_lark_payloads(msg) do
                [] ->
                  Logger.warning(
                    "FeishuAdapter.event_to_payload: SKIP (build_lark_payloads = []) — " <>
                      "no renderable payload for msg id=#{inspect(Map.get(msg, :id))} " <>
                      "body_keys=#{inspect(msg.body |> case do
                        m when is_map(m) -> Map.keys(m)
                        _ -> :not_map
                      end)}"
                  )

                  :skip

                list ->
                  {:publish, list}
              end
            end

          :error ->
            Logger.warning(
              "FeishuAdapter.event_to_payload: SKIP (extract_last_message :error) — " <>
                "no :last_message in slice. new_slice keys=#{inspect(slice_diag(new_slice))}"
            )

            :skip
        end
    end
  end

  def event_to_payload(%Event{}), do: :skip

  # Diagnostic helper: surface a slice's shape (top-level keys) without dumping
  # full content, so a silent mirror-skip is traceable (Allen 2026-05-31:
  # silent failure violates the no-silent-drop rule).
  defp slice_diag(s) when is_map(s), do: Map.keys(s)
  defp slice_diag(other), do: {:not_a_map, other}

  # Unwrap the two-container Lifecycle slice (`%{state: <persistent>, ...}`) to
  # the flat developer slice the rest of this module reads.
  #
  # 2026-05-31 orchestrator-startup-atomicity §8 (Unwrap A+C2 fold) — DELEGATE
  # the atom-keyed case to the single `Ezagent.Kind.normalize_slice_view/1`
  # chokepoint instead of duplicating the unwrap logic here. The chokepoint
  # handles the two real two-container shapes: the in-memory `%{state,
  # transients}` and the persisted single-key `%{state}` (transients stripped),
  # plus passthrough for a legacy-flat slice.
  #
  # The chokepoint is ATOM-keyed only; the Feishu event payload can carry a
  # string-keyed `%{"state" => ...}` (post-JSON over the wire). We keep a THIN
  # string-key shim that unwraps `"state"` to its map, then hands the atom-keyed
  # inner map back through the chokepoint (idempotent — a flat inner map is
  # passthrough). We deliberately do NOT broaden `normalize_slice_view/1` to
  # string keys (it guards core-Kind state shapes; a string-key clause there
  # could wrongly unwrap an unrelated map).
  defp slice_state(%{"state" => %{} = inner}), do: Ezagent.Kind.normalize_slice_view(inner)
  defp slice_state(other), do: Ezagent.Kind.normalize_slice_view(other)

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

  # Did this slice change carry a NEW chat send?
  #
  # The chat slice mutates for `Chat.send` (PR-EM-6-PRE) and may mutate
  # for other future actions (`:add_member`, `:remove_member`,
  # `template_working_copy` edits, …). External mirroring only cares
  # about sends, so we compare the two PR-EM-6-PRE marker fields:
  #
  # - `:last_message_id` — changes when a NEW message id lands.
  # - `:send_cursor` — bumps on EVERY `:send` invocation, including
  #   retries that collide on `msg.id` (MessageStore's
  #   `on_conflict: :nothing` returns the same row). The cursor delta
  #   is what lets us re-publish a retried send (`feedback_let_it_crash`
  #   — we surface the retry to the operator rather than silently
  #   dropping it).
  #
  # `nil` old_slice (first event ever from this publisher) — treat as
  # "send occurred" iff the new_slice already carries a message
  # (covers the cold-start race where the very first emitted event IS
  # the first send).
  defp chat_send_occurred?(new_slice, nil) do
    Map.get(new_slice, :last_message_id) != nil or
      Map.get(new_slice, :send_cursor, 0) > 0
  end

  defp chat_send_occurred?(new_slice, old_slice) when is_map(old_slice) do
    new_id = Map.get(new_slice, :last_message_id)
    old_id = Map.get(old_slice, :last_message_id)
    new_cursor = Map.get(new_slice, :send_cursor, 0)
    old_cursor = Map.get(old_slice, :send_cursor, 0)

    new_id != old_id or new_cursor != old_cursor
  end

  defp chat_send_occurred?(_, _), do: false

  # Pull the full Message struct out of the new slice's `:last_message`.
  # Defensive: accept both atom (fresh in-memory write) AND string key
  # (post-JSON-roundtrip persisted rehydrate path). The struct
  # round-trip caveat in old FeishuOutbound applied to BODY only; the
  # message itself comes straight off the Publisher event before any
  # DB hop, so the atom-key path is the production path.
  defp extract_last_message(%{last_message: %Ezagent.Message{} = msg}), do: {:ok, msg}
  defp extract_last_message(%{"last_message" => %Ezagent.Message{} = msg}), do: {:ok, msg}
  defp extract_last_message(_), do: :error

  # Self-echo guard — preserved from old FeishuOutbound. Inbound Feishu
  # messages get `_feishu_origin: true` stamped on body by
  # `InboundDispatcher.do_dispatch/4`; without this skip the mirror
  # would echo every webhook straight back to Lark and spin a loop.
  # Accept both atom AND string key shapes because MessageStore's JSON
  # round-trip produces string keys.
  defp from_feishu?(%Ezagent.Message{body: %{_feishu_origin: true}}), do: true
  defp from_feishu?(%Ezagent.Message{body: %{"_feishu_origin" => true}}), do: true
  defp from_feishu?(_), do: false

  defp build_lark_payloads(%Ezagent.Message{} = msg) do
    text = extract_text(msg.body)
    attachments = extract_attachments(msg.body)
    sender_label = sender_label(msg.sender)
    source_label = source_session_label(msg)
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

  # Source session for the `[session | sender]` prefix. PR-EM-6-PRE
  # stamps `session_uri` on the Message in `MessageStore.write/2`, so
  # we read it straight off the struct (no need to plumb the
  # publisher_uri or slice payload). Defensive `"session"` fallback
  # for the legacy case where a Message somehow lacks the field —
  # better operator-visible than a crash.
  defp source_session_label(%Ezagent.Message{session_uri: %URI{} = u}), do: URI.to_string(u)
  defp source_session_label(%Ezagent.Message{session_uri: s}) when is_binary(s), do: s
  defp source_session_label(_), do: "session"
end
