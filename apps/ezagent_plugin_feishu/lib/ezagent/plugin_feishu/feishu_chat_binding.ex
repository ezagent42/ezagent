defmodule EzagentPluginFeishu.FeishuChatBinding do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6 / §2.3) — Feishu Chat Binding for the
  generic ExternalMirror Domain.

  Stateful per-target transport — one binding instance owns the
  publish loop to ONE Lark chat (one `chat_id`). The
  `Ezagent.Entity.ExternalMirrorWorker` Kind is the GenServer
  skeleton; this module implements the transport callbacks.

  Per the SPEC §6.1 / §6.3 contract:

  - `init/1` opens the binding's runtime state (we reuse the existing
    `EzagentPluginFeishu.Client` GenServer for HTTP + tenant token —
    no per-binding HTTP client needed). State carries `chat_id` +
    rate-limit tracking fields.
  - `publish/2` performs the actual Lark API call(s) the Adapter
    translated; returns `{:ok, new_state}` on success or
    `{:error, reason, new_state}` on recoverable HTTP errors (4xx /
    5xx / network blip).
  - `terminate/2` is a no-op — no per-binding resources to release
    (the shared `Client` GenServer outlives all bindings).
  - RAISE on unrecoverable invariant violations (BEAM let-it-crash
    path); PerBindingSupervisor restarts per `:permanent` + 3/30s
    budget per SPEC §6.2.

  ## 429 / rate-limit handling

  The state tracks `last_retry_at`. On a 429 response we log + return
  `{:error, {:rate_limited, retry_after_ms}, new_state}` with
  `last_retry_at` updated. The Worker treats `{:error, _, _}` as
  recoverable per SPEC §2.3 — it logs + bumps `error_count` in the
  worker slice + carries new_state forward, but does NOT crash. The
  next publish from a fresh slice change retries.

  ## Why not a private HTTP client

  The retired `EzagentPluginFeishu.Behavior.FeishuOutbound` used the
  shared `EzagentPluginFeishu.Client` (token cache + multipart upload
  + send_text/send_image/send_file). Spinning a per-binding HTTP
  pool would (a) duplicate the tenant-token mint logic, (b) cost a
  pool per (session × chat) combination, (c) lose the existing
  `Client.peek_token/0` fast path the `react/2` work-around relies
  on. We keep `Client` as the single Lark gateway and the Binding
  just sequences API calls.
  """

  @behaviour Ezagent.ExternalMirror.Binding

  require Logger

  alias EzagentPluginFeishu.Client

  @impl Ezagent.ExternalMirror.Binding
  def adapter_module, do: EzagentPluginFeishu.FeishuAdapter

  @impl Ezagent.ExternalMirror.Binding
  def init({chat_id, _adapter, opts}) when is_binary(chat_id) do
    # Defensive: chat_id must look like a Feishu open-chat-id. The
    # facade's `target_ownership_check/2` is the primary gate; this
    # is the structural sanity check that surfaces a typoed bind
    # before the first publish.
    if String.starts_with?(chat_id, "oc_") do
      {:ok,
       %{
         chat_id: chat_id,
         opts: opts,
         publish_count: 0,
         error_count: 0,
         last_retry_at: nil
       }}
    else
      {:error, {:invalid_chat_id, chat_id}}
    end
  end

  def init({other, _adapter, _opts}),
    do: {:error, {:invalid_target_id, other}}

  @doc """
  Send the Adapter's payload list to Lark.

  `payload` is the `event_to_payload/1` return value — for chat
  events this is a LIST of tagged tuples (text + zero or more
  attachments). We fold the list: success-paths accumulate the
  publish_count; first hard error stops the fold and returns
  `{:error, reason, new_state}` per the SPEC §2.3 recoverable shape.

  The `:credentials_not_configured` error from `Client` (operator
  hasn't filled `feishu.yaml`) is mapped to a recoverable error so
  the binding doesn't crash-loop on an unconfigured plugin install
  — operator sees telemetry, fills creds, next slice change publishes.
  """
  @impl Ezagent.ExternalMirror.Binding
  def publish(payloads, state) when is_list(payloads) do
    do_publish_each(payloads, state)
  end

  def publish(other, state) do
    Logger.warning(
      "FeishuChatBinding: unexpected payload shape from Adapter: #{inspect(other)}; " <>
        "expected a list of tagged tuples from FeishuAdapter.event_to_payload/1"
    )

    {:error, {:invalid_payload, other}, state}
  end

  # codex r1 HIGH fix (2026-05-25): distinguish PRE-publish failure
  # from PARTIAL-publish failure. The Worker
  # (`Ezagent.Behavior.ExternalMirrorWorker.invoke(:publish, ...)`)
  # advances `publisher_cursor` on `{:error, _, _}` returns —
  # treating ANY publish failure as recoverable silently drops the
  # unsent remainder of a multi-payload mirror (text + N attachments
  # where one attachment fails → text-only in Lark + unsent
  # attachments lost forever, cursor moves on).
  #
  # Fix:
  #
  # 1. **Pre-publish failure** (`sent == 0`) — nothing reached Lark
  #    yet; recoverable `{:error, _, _}` is correct (next slice
  #    change retries cleanly).
  #
  # 2. **Partial-publish failure** (`sent >= 1`) — some bytes already
  #    landed in Lark. RAISE so the Worker crashes;
  #    PerBindingSupervisor restarts; cursor resets to `:latest` per
  #    SPEC §3 (no replay). Partial Lark state is observable but the
  #    NEXT message gets a fresh attempt — no silent payload loss,
  #    no cursor-advance past unprocessed data.
  #
  # Per-message atomicity is impossible (Lark has no transactional
  # multi-send); RAISE preserves the invariant that
  # `cursor-advance => every payload for the event was attempted`.
  defp do_publish_each([], state),
    do: {:ok, %{state | publish_count: state.publish_count + 1}}

  defp do_publish_each(payloads, state) when is_list(payloads),
    do: do_publish_each_with_sent(payloads, state, 0)

  defp do_publish_each_with_sent([], state, _sent),
    do: {:ok, %{state | publish_count: state.publish_count + 1}}

  defp do_publish_each_with_sent([payload | rest], state, sent) do
    case do_publish_one(payload, state) do
      :ok ->
        do_publish_each_with_sent(rest, state, sent + 1)

      {:error, reason} when sent == 0 ->
        Logger.warning(
          "FeishuChatBinding publish failed (pre-send, recoverable): " <>
            "chat_id=#{state.chat_id} reason=#{inspect(reason)} " <>
            "remaining=#{length(rest) + 1}"
        )

        {:error, reason,
         %{state | error_count: state.error_count + 1, last_retry_at: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.error(
          "FeishuChatBinding partial-publish failure (raising to prevent " <>
            "cursor-advance past unprocessed payloads): chat_id=#{state.chat_id} " <>
            "reason=#{inspect(reason)} sent=#{sent} unsent_remaining=#{length(rest) + 1}"
        )

        raise "FeishuChatBinding partial-publish failure on chat_id=#{state.chat_id} " <>
                "after #{sent} payload(s) succeeded: #{inspect(reason)}"
    end
  end

  # Tag dispatch — keeps the binding stateless w.r.t. the tag shape;
  # adding a new payload tag in FeishuAdapter is one new clause here.

  # Test-only payload tags: let unit tests exercise the partial-publish
  # RAISE branch without mocking the Client GenServer. NOT produced by
  # FeishuAdapter.event_to_payload/1 (production callers never emit
  # these). Compiled IN under `Mix.env() == :test` only — `if` guards
  # at runtime would still ship the clause; we use module attribute
  # branching at compile time.
  if Mix.env() == :test do
    defp do_publish_one({:lark_test_ok, _label}, _state), do: :ok
    defp do_publish_one({:lark_test_fail, reason}, _state), do: {:error, reason}
  end

  defp do_publish_one({:lark_text, text}, state) when is_binary(text),
    do: Client.send_text(state.chat_id, text)

  defp do_publish_one({:lark_image_passthrough, file_key, _name}, state),
    do: Client.send_image(state.chat_id, file_key)

  defp do_publish_one({:lark_file_passthrough, file_key, _name}, state),
    do: Client.send_file(state.chat_id, file_key)

  defp do_publish_one({:lark_image_upload, path, name, prefix}, state) do
    with {:ok, image_key} <- Client.upload_image(path),
         :ok <- Client.send_text(state.chat_id, prefix <> "[image: #{name}]") do
      Client.send_image(state.chat_id, image_key)
    end
  end

  defp do_publish_one({:lark_file_upload, path, name, prefix}, state) do
    with {:ok, file_key} <- Client.upload_file(path, name),
         :ok <- Client.send_text(state.chat_id, prefix <> "[file: #{name}]") do
      Client.send_file(state.chat_id, file_key)
    end
  end

  defp do_publish_one(other, _state) do
    Logger.warning("FeishuChatBinding: unknown payload tag #{inspect(other)} — dropping")
    {:error, {:unknown_payload_tag, other}}
  end

  @impl Ezagent.ExternalMirror.Binding
  def terminate(_reason, _state), do: :ok
end
