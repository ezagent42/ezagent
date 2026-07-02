defmodule Ezagent.ActionSet.ExternalMirrorWorker.SendKey do
  @moduledoc """
  Pure send-key derivation for `Ezagent.ActionSet.ExternalMirrorWorker`
  — extracts the composite dedupe key `{message_id, send_cursor}` from a
  publisher event's chat slice (#25 Phase-3, PR-3O).

  **Pure module.** No process state, no effects, no DB — every function
  is a total transformation over its argument.
  """

  alias Ezagent.Publisher.Event

  @doc """
  Extract the COMPOSITE dedupe key `{message_id, send_cursor}` from the
  publisher event's payload. Only the `:chat` slice carries a
  `:last_message` `Ezagent.Message` struct (the id half) alongside a
  `:send_cursor` counter (bumped on every `Chat.invoke(:send)`); other
  slices return `nil` (and the worker falls through to adapter-side
  `:skip`).

  PR #420 codex r4 MED (2026-06-01): the pair — not the id alone — is
  the dedupe key. A retry-send reuses `msg.id` but bumps `send_cursor`,
  so it must publish; a true replay carries the same pair, so it must
  dedupe.

  String and atom keys are both accepted because the MessageStore JSON
  roundtrip serialises atom keys as strings. `send_cursor` defaults to
  0 when absent (a chat slice that predates the PR-EM-6-PRE
  `:send_cursor` field) so the key is still a stable pair.
  """
  @spec extract_event_send_key(term()) :: {term(), term()} | nil
  def extract_event_send_key(%Event{payload: %{} = payload, slice_key: :session}) do
    new_slice =
      (Map.get(payload, :new_slice) || Map.get(payload, "new_slice"))
      |> unwrap_chat_slice()

    case new_slice do
      %{last_message: %Ezagent.Message{id: id}} = ns ->
        {id, fetch_send_cursor(ns)}

      %{"last_message" => %Ezagent.Message{id: id}} = ns ->
        {id, fetch_send_cursor(ns)}

      _ ->
        nil
    end
  end

  def extract_event_send_key(_), do: nil

  @doc """
  Unwrap a publisher payload's `new_slice` to its persistent view.

  The publisher payload's `new_slice` is `strip_transients/1`'d
  (`SessionImpl.build_payload/2`), so a Lifecycle two-container slice
  arrives WRAPPED as `%{state: ...}` (or `%{"state" => ...}` post-JSON),
  NOT flat. Unwrap before reading `last_message`/`send_cursor` —
  otherwise the dedupe key is silently `nil` for every Lifecycle chat
  slice and true replays are NOT deduped (codex r-2026-06-01 HIGH).
  Mirrors `FeishuAdapter.slice_state/1`; legacy flat slices pass through
  unchanged.
  """
  @spec unwrap_chat_slice(term()) :: term()
  def unwrap_chat_slice(nil), do: nil
  def unwrap_chat_slice(%{"state" => %{} = inner}), do: Ezagent.Kind.normalize_slice_view(inner)
  def unwrap_chat_slice(other), do: Ezagent.Kind.normalize_slice_view(other)

  @doc """
  Read `:send_cursor` from the chat new_slice (atom or string key),
  defaulting to 0 when absent.
  """
  @spec fetch_send_cursor(map()) :: term()
  def fetch_send_cursor(new_slice) do
    Map.get(new_slice, :send_cursor) || Map.get(new_slice, "send_cursor") || 0
  end
end
