defmodule EzagentPluginFeishu.InboundChatLookup do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6) — chat_id → session_uri reverse lookup
  for the inbound Feishu webhook path.

  Replaces `EzagentPluginFeishu.SessionBinding.resolve/1` (retired in
  this PR along with the rest of the one-off path). The data lives in
  the generic `external_mirror_bindings` projection table maintained
  by `Ezagent.Behavior.ExternalMirror`'s `:bind` / `:unbind` actions
  (PR-EM-3). Inbound direction reads the same table the outbound
  Worker subscribes off of — single SoT, no parallel join table.

  ## Cardinality (codex r1 HIGH fix 2026-05-25 — fail-closed)

  The `external_mirror_bindings` natural key is
  `(session_uri, adapter_id, target_id)` — so the SAME Feishu
  chat_id CAN be bound to multiple sessions. The retired
  `feishu_session_bindings` had `chat_id` as PRIMARY KEY so this
  ambiguity was impossible; the new schema permits it.

  V1 policy: **fail closed on ambiguity** rather than silently
  routing to the oldest (the pre-r1 behavior). An operator who
  legitimately wants a shared chat must explicitly resolve the
  policy. The inbound dispatcher receives
  `{:error, :ambiguous_chat_binding}` and surfaces it back to
  Feishu with a distinct react + text body so the operator sees
  the exact reason rather than messages mysteriously landing in
  the wrong session.

  Per `feedback_let_it_crash_no_workarounds`: no `:warning` + degrade
  paths. A duplicate binding is an operator-actionable
  misconfiguration; the inbound surface flags it loudly + drops
  the message rather than picking one arbitrarily.

  ## Why a tiny query module not inline in the dispatcher

  Keeps the inbound dispatcher transport-agnostic and the lookup
  logic test-isolatable. The dispatcher just asks
  `InboundChatLookup.resolve/1`; the lookup module owns the SQL
  query + the multi-row conflict handling.
  """

  require Logger

  import Ecto.Query

  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @adapter_id "feishu"

  @doc """
  Resolve a Feishu `chat_id` to its bound session URI.

  Returns:

  - `{:ok, %URI{}}` when EXACTLY ONE binding exists for the chat_id
    under adapter `"feishu"`.
  - `{:error, :ambiguous_chat_binding}` when 2+ bindings exist
    (codex r1 HIGH fix — fail-closed instead of silently routing
    to the oldest). The caller (`InboundDispatcher`) surfaces
    the error back to the user via a distinct Feishu react +
    text body.
  - `:error` when no binding exists.
  """
  @spec resolve(String.t()) :: {:ok, URI.t()} | {:error, :ambiguous_chat_binding} | :error
  def resolve(chat_id) when is_binary(chat_id) and chat_id != "" do
    rows =
      from(r in BindingRow,
        where: r.adapter_id == ^@adapter_id and r.target_id == ^chat_id,
        order_by: r.bound_at,
        select: r.session_uri
      )
      |> Repo.all()

    case rows do
      [] ->
        :error

      [session_uri_str] ->
        {:ok, Ezagent.URI.new!(session_uri_str)}

      multiple ->
        # codex r1 HIGH fix (2026-05-25): fail closed on duplicate
        # bindings instead of silently picking the oldest. The
        # external_mirror_bindings natural key is
        # (session_uri, adapter_id, target_id), so the same Feishu
        # chat_id CAN be bound to multiple sessions — that's an
        # operator misconfig and must surface as a hard error.
        Logger.error(
          "InboundChatLookup: chat_id #{chat_id} resolves to MULTIPLE sessions " <>
            "(#{length(multiple)} bindings): #{inspect(multiple)} — failing closed " <>
            "(operator must unbind the stale row(s) explicitly)"
        )

        {:error, :ambiguous_chat_binding}
    end
  end

  def resolve(_), do: :error

  @doc """
  Reverse: every chat_id currently bound to `session_uri` under the
  Feishu adapter. Used by the admin LV's session-context panel
  (replaces `EzagentPluginFeishu.SessionBinding.chat_ids_for/1`).
  """
  @spec chat_ids_for(URI.t() | String.t()) :: [String.t()]
  def chat_ids_for(%URI{} = session_uri),
    do: chat_ids_for(URI.to_string(session_uri))

  def chat_ids_for(session_uri) when is_binary(session_uri) do
    from(r in BindingRow,
      where: r.session_uri == ^session_uri and r.adapter_id == ^@adapter_id,
      order_by: r.bound_at,
      select: r.target_id
    )
    |> Repo.all()
  end

  def chat_ids_for(_), do: []
end
