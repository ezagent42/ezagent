defmodule Ezagent.Email.Adapter do
  @moduledoc """
  #88 PR-1 (SPEC §4.1) — Email Adapter for the generic ExternalMirror
  Domain. Modeled on `EzagentPluginFeishu.FeishuAdapter`.

  Stateless, pure wire-format translator: converts `Ezagent.Publisher.Event`
  values whose `slice_key == :session` (a chat send) into an email payload
  map. The matching `Ezagent.Email.Binding` GenServer owns the transport
  (`Ezagent.Email.send/4`), the bound recipient (`target_id`), and the
  durable RFC threading state.

  ## Payload shape

      {:publish, %{
        subject: String.t(),       # pinned, sanitized of CR/LF + control chars
        text: String.t(),          # "[<session> | <sender>] <body text>"
        html: nil,                 # v1 is text-only
        session_uri: URI.t() | String.t()   # SERVER-STAMPED context (see below)
      }}

  The `To:` is NOT in the payload — the Binding owns `target_id` (the bound
  human address), exactly as `FeishuChatBinding` owns the `chat_id`.

  ## Why `session_uri` IS in the payload (and why it's safe)

  The Binding keys its durable threading state by
  `BindingRow.row_id(session_uri, "email", target_id)`, but `Binding.init/1`
  receives only `{target_id, adapter, opts}` — `session_uri` is not in that
  tuple, and reading it from caller `opts` would be forgeable (the per-binding
  Worker forwards caller-controlled opts into `init/1` unfiltered). So the
  Adapter reads `msg.session_uri`, which is **server-stamped** in
  `Ezagent.MessageStore.write/2` (not caller-controllable), and passes it in
  the payload as CONTEXT (not the recipient). The Binding normalizes it and
  computes the row id — the same id the bind path persisted. Feishu reads the
  same field (`FeishuAdapter.source_session_label/1`).

  ## Self-echo / skip semantics (parity with FeishuAdapter)

  - `slice_key != :session` → `:skip`.
  - no chat-send delta (`last_message_id` + `send_cursor` unchanged) → `:skip`.
  - `_email_origin` stamped (inbound came IN from email — PR-2) → `:skip`
    (loop guard; atom + string key).
  - missing / non-`%Ezagent.Message{}` `:last_message` → `:skip` (defensive).

  ## Header-injection prevention (Q4)

  The pinned subject is the only session-derived value that reaches a mail
  HEADER. `sanitize_header_value!/1` strips CR/LF + other control chars from
  it before it leaves this module. (The Binding applies the same helper to the
  threading headers it mints.)
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  require Logger

  alias Ezagent.Publisher.Event

  @impl Ezagent.ExternalMirror.Adapter
  def adapter_id, do: "email"

  @impl Ezagent.ExternalMirror.Adapter
  def display_name, do: "Email"

  @impl Ezagent.ExternalMirror.Adapter
  def description,
    do: "Mirror session chat messages out to a bound email address as a threaded conversation."

  @impl Ezagent.ExternalMirror.Adapter
  def adapter_kind, do: :push

  @impl Ezagent.ExternalMirror.Adapter
  def binding_module, do: Ezagent.Email.Binding

  @impl Ezagent.ExternalMirror.Adapter
  def cap_subject do
    %{
      behavior_module: EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow,
      description: "Authorize binding the `email` external-mirror adapter on this session."
    }
  end

  @doc """
  Bind-time check. For email this is a cheap RFC-5322 address-format sanity
  check only — it does NOT perform the human verification handshake (that
  cannot run inside the bounded ~5s bind Task; it is the separate async
  verification lifecycle in PR-2). A well-formed address → `:ok`; malformed
  → `{:error, :invalid_address}`.

  MUST NOT call `Ezagent.Invocation.dispatch/1` (no dispatch re-entry).
  """
  @impl Ezagent.ExternalMirror.Adapter
  def target_ownership_check(%URI{} = _caller, target_id) when is_binary(target_id) do
    if valid_address?(target_id), do: :ok, else: {:error, :invalid_address}
  end

  def target_ownership_check(_caller, _target_id), do: {:error, :invalid_address}

  @doc """
  Translate a Publisher event into the email payload. Pure — no I/O.

  Reads the real Publisher envelope (`%Event{slice_key: :session, payload:
  %{new_slice:, old_slice:}}`), unwraps the two-container Lifecycle slice,
  detects a chat send (the `{last_message_id, send_cursor}` delta), and emits
  `{:publish, payload}` or `:skip`.
  """
  @impl Ezagent.ExternalMirror.Adapter
  def event_to_payload(%Event{slice_key: :session, payload: %{} = payload}) do
    new_slice = slice_state(Map.get(payload, :new_slice) || Map.get(payload, "new_slice"))
    old_slice = slice_state(Map.get(payload, :old_slice) || Map.get(payload, "old_slice"))

    cond do
      not is_map(new_slice) ->
        Logger.warning(
          "Email.Adapter: SKIP (new_slice not a map) — chat send dropped from mirror"
        )

        :skip

      not chat_send_occurred?(new_slice, old_slice) ->
        :skip

      true ->
        case extract_last_message(new_slice) do
          {:ok, msg} ->
            if from_email?(msg), do: :skip, else: build_payload(msg)

          :error ->
            Logger.warning("Email.Adapter: SKIP (no :last_message in slice)")
            :skip
        end
    end
  end

  def event_to_payload(%Event{}), do: :skip

  # ----- payload construction ------------------------------------------------

  defp build_payload(%Ezagent.Message{} = msg) do
    text = extract_text(msg.body)
    sender = sender_label(msg.sender)
    source = source_session_label(msg)
    subject = sanitize_header_value!("[#{source}] message from #{sender}")
    body_text = "[#{source} | #{sender}] #{text}"

    {:publish,
     %{
       subject: subject,
       text: body_text,
       html: nil,
       # SERVER-STAMPED context — the Binding computes the thread row id from it.
       session_uri: msg.session_uri
     }}
  end

  @doc """
  Strip CR/LF + other control chars from a value bound for a mail HEADER
  (header-injection prevention, Q4). Public so the Binding reuses the one
  copy for the threading headers it mints.
  """
  @spec sanitize_header_value!(String.t()) :: String.t()
  def sanitize_header_value!(value) when is_binary(value) do
    String.replace(value, ~r/[\x00-\x1f\x7f]/, " ")
  end

  # ----- slice / send-detection (parity with FeishuAdapter) ------------------

  defp slice_state(%{"state" => %{} = inner}), do: Ezagent.Kind.normalize_slice_view(inner)
  defp slice_state(other), do: Ezagent.Kind.normalize_slice_view(other)

  defp chat_send_occurred?(new_slice, nil) do
    Map.get(new_slice, :last_message_id) != nil or Map.get(new_slice, :send_cursor, 0) > 0
  end

  defp chat_send_occurred?(new_slice, old_slice) when is_map(old_slice) do
    Map.get(new_slice, :last_message_id) != Map.get(old_slice, :last_message_id) or
      Map.get(new_slice, :send_cursor, 0) != Map.get(old_slice, :send_cursor, 0)
  end

  defp chat_send_occurred?(_, _), do: false

  defp extract_last_message(%{last_message: %Ezagent.Message{} = msg}), do: {:ok, msg}
  defp extract_last_message(%{"last_message" => %Ezagent.Message{} = msg}), do: {:ok, msg}
  defp extract_last_message(_), do: :error

  # Self-echo guard — inbound email (PR-2) stamps `_email_origin: true` so the
  # mirror does not echo it back out and spin a loop. Atom + string key.
  defp from_email?(%Ezagent.Message{body: %{_email_origin: true}}), do: true
  defp from_email?(%Ezagent.Message{body: %{"_email_origin" => true}}), do: true
  defp from_email?(_), do: false

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(other) when is_map(other), do: ""
  defp extract_text(other), do: inspect(other)

  defp sender_label(%URI{} = u), do: URI.to_string(u)
  defp sender_label(other), do: inspect(other)

  defp source_session_label(%Ezagent.Message{session_uri: %URI{} = u}), do: URI.to_string(u)
  defp source_session_label(%Ezagent.Message{session_uri: s}) when is_binary(s), do: s
  defp source_session_label(_), do: "session"

  # Minimal RFC-5322-ish sanity: one `@`, non-empty local + domain, a dot in
  # the domain, no whitespace / control chars. Not a full grammar — just
  # enough to reject obvious garbage at bind/init.
  defp valid_address?(addr) when is_binary(addr) do
    Regex.match?(~r/^[^\s@\x00-\x1f]+@[^\s@\x00-\x1f]+\.[^\s@\x00-\x1f]+$/, addr)
  end
end
