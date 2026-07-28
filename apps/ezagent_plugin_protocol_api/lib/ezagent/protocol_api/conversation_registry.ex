defmodule Ezagent.ProtocolApi.ConversationRegistry do
  @moduledoc """
  Durable `conversation_id ↔ session` binding.

  Reuses the existing `external_mirror_bindings` table (same pattern as
  Feishu's `chat_id ↔ session` via `InboundChatLookup`). An API consumer
  sends a `conversation_id` header/field and gets back the same session
  on every call — preserving agent identity, caps, cwd, and history.

  If no binding exists for the given conversation_id, a new session is
  spawned via the owner-gated `Ezagent.LocalRuntime.ensure_started/1` and bound
  via `BindingRow.insert/1`.
  """

  require Logger

  import Ecto.Query

  alias Ezagent.LocalRuntime
  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @adapter_id "protocol_api"

  @doc """
  Resolve a conversation_id to a session URI.

  Returns `{:ok, session_uri}` — either the existing bound session or a
  freshly-spawned one.
  """
  @spec resolve(String.t() | nil, URI.t(), URI.t()) :: {:ok, URI.t()} | {:error, term()}
  # Stateless (handoff §2.2): no conversation_id → ephemeral, unbound session
  def resolve(nil, workspace_uri, bound_by) do
    create_stateless(workspace_uri, bound_by)
  end

  def resolve(conversation_id, workspace_uri, bound_by)
      when is_binary(conversation_id) and is_struct(workspace_uri, URI) and
             is_struct(bound_by, URI) do
    case lookup(conversation_id) do
      {:ok, session_uri} ->
        {:ok, session_uri}

      {:error, :not_found} ->
        create_and_bind(conversation_id, workspace_uri, bound_by)
    end
  end

  # Stateless session: spawn without external_mirror_bindings entry.
  defp create_stateless(workspace_uri, _bound_by) do
    name = "stateless_#{stateless_suffix()}"
    session_uri = Ezagent.URI.session(:system, "generic", name)

    with {:ok, _pid} <- LocalRuntime.ensure_started(session_uri),
         :ok <- Ezagent.OwnerGatedWorkspace.bind(session_uri, workspace_uri) do
      Logger.info("ProtocolApi: stateless session #{Ezagent.URI.stable_key(session_uri)}")
      {:ok, session_uri}
    else
      {:error, reason} ->
        Logger.error("ProtocolApi: stateless session failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stateless_suffix do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp lookup(conversation_id) do
    rows =
      Repo.all(
        from(r in BindingRow,
          where: r.adapter_id == ^@adapter_id and r.target_id == ^conversation_id,
          order_by: r.bound_at,
          select: r.session_uri
        )
      )

    case rows do
      [] -> {:error, :not_found}
      [session_uri_str] -> {:ok, Ezagent.URI.new!(session_uri_str)}
      _multiple -> {:error, :ambiguous_conversation_binding}
    end
  end

  defp create_and_bind(conversation_id, workspace_uri, bound_by) do
    ws = Ezagent.URI.stable_key(workspace_uri) |> String.replace("://", "_")
    name = "conv_#{ws}_#{short_id(conversation_id)}"
    session_uri = Ezagent.URI.session(:system, "generic", name)

    with {:ok, _pid} <- LocalRuntime.ensure_started(session_uri),
         :ok <- Ezagent.OwnerGatedWorkspace.bind(session_uri, workspace_uri),
         {:ok, _row} <- insert_binding_row(conversation_id, session_uri, workspace_uri, bound_by) do
      Logger.info(
        "ProtocolApi: bound conversation_id=#{conversation_id} → " <>
          "#{Ezagent.URI.stable_key(session_uri)}"
      )

      {:ok, session_uri}
    else
      {:error, reason} ->
        Logger.error(
          "ProtocolApi: failed to create session for conversation_id=#{conversation_id}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp insert_binding_row(conversation_id, session_uri, workspace_uri, bound_by) do
    row_id = BindingRow.row_id(session_uri, @adapter_id, conversation_id)

    BindingRow.insert(%{
      id: row_id,
      session_uri: URI.to_string(session_uri),
      adapter_id: @adapter_id,
      target_id: conversation_id,
      opts_json: "{}",
      bound_by: URI.to_string(bound_by),
      bound_at: DateTime.utc_now(),
      workspace_uri: URI.to_string(workspace_uri)
    })
  end

  defp short_id(conv_id) do
    :crypto.hash(:sha256, conv_id) |> Base.encode16(case: :lower) |> String.slice(0..7)
  end
end
