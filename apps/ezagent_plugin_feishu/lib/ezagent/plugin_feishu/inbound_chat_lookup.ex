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

  ## Cardinality

  V1: one chat_id maps to at most one session per
  `(adapter_id, target_id)` natural key. The query selects on
  `adapter_id = "feishu"` AND `target_id = chat_id` — if the same
  chat_id is bound to multiple sessions (operator misconfig), the
  first row by `bound_at` wins. We log a warning so the operator
  sees the conflict, but we do NOT fail inbound delivery (P18 — no
  silent drops on user-facing surfaces).

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

  Returns `{:ok, %URI{}}` when exactly one binding exists for the
  chat_id under adapter `"feishu"`; `{:ok, %URI{}}` with a warning
  log when multiple bindings exist (first by `bound_at` wins); or
  `:error` when no binding exists.
  """
  @spec resolve(String.t()) :: {:ok, URI.t()} | :error
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
        {:ok, URI.parse(session_uri_str)}

      [session_uri_str | _rest] ->
        Logger.warning(
          "InboundChatLookup: chat_id #{chat_id} resolves to multiple sessions " <>
            "(#{length(rows)} bindings); using the first by bound_at (#{session_uri_str})"
        )

        {:ok, URI.parse(session_uri_str)}
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
