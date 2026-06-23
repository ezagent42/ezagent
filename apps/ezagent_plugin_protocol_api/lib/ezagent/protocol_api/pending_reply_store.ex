defmodule Ezagent.ProtocolApi.PendingReplyStore do
  @moduledoc """
  In-memory store for ack-then-async-reply (handoff §2.3 "virtual request").

  Stores pending request state and completed replies, keyed by request_id.
  Uses an ETS table (owned by the plugin Application process).
  """

  @table :protocol_api_pending_replies

  @doc "Initialize the ETS table. Called once at plugin boot."
  def init do
    _ = :ets.new(@table, [:named_table, :public, :set,
      {:read_concurrency, true}, {:write_concurrency, false}])
    :ok
  end

  @doc "Register a pending request."
  def put_pending(request_id) do
    :ets.insert(@table, {request_id, :pending, nil})
  end

  @doc "Store a completed reply."
  def put_reply(request_id, reply) do
    :ets.insert(@table, {request_id, :done, reply})
  end

  @doc "Store an error."
  def put_error(request_id, error) do
    :ets.insert(@table, {request_id, :error, error})
  end

  @doc "Get request status. Returns {:ok, :pending} | {:ok, reply} | {:error, reason} | :not_found."
  def get(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, :pending, _}] -> {:ok, :pending}
      [{^request_id, :done, reply}] -> {:ok, reply}
      [{^request_id, :error, error}] -> {:error, error}
      [] -> :not_found
    end
  end

  @doc "Clean up old entries (called periodically or on retrieval)."
  def delete(request_id) do
    :ets.delete(@table, request_id)
  end
end
