defmodule Ezagent.ProtocolApi.PendingReplyStoreTest do
  @moduledoc """
  P1 test-supplement — the ack-then-async-reply ETS store backing
  `GET /v1/chat/completions/:id` polling. The table is created once at
  plugin boot (`init/0`, called from `EzagentPluginProtocolApi.Application`)
  so these tests exercise the ALREADY-LIVE table rather than re-creating it.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ProtocolApi.PendingReplyStore

  test "unknown request_id -> :not_found" do
    assert :not_found = PendingReplyStore.get(unique_id())
  end

  test "put_pending/1 then get/1 -> {:ok, :pending}" do
    id = unique_id()
    PendingReplyStore.put_pending(id)
    assert {:ok, :pending} = PendingReplyStore.get(id)
  end

  test "put_reply/2 then get/1 -> {:ok, reply}, overriding a prior :pending" do
    id = unique_id()
    PendingReplyStore.put_pending(id)
    PendingReplyStore.put_reply(id, %{"status" => "done"})
    assert {:ok, %{"status" => "done"}} = PendingReplyStore.get(id)
  end

  test "put_error/2 then get/1 -> {:error, reason}" do
    id = unique_id()
    PendingReplyStore.put_pending(id)
    PendingReplyStore.put_error(id, :timeout)
    assert {:error, :timeout} = PendingReplyStore.get(id)
  end

  test "delete/1 removes the entry -> subsequent get/1 is :not_found" do
    id = unique_id()
    PendingReplyStore.put_reply(id, %{"ok" => true})
    assert {:ok, _} = PendingReplyStore.get(id)

    PendingReplyStore.delete(id)
    assert :not_found = PendingReplyStore.get(id)
  end

  defp unique_id, do: "prs_#{System.unique_integer([:positive, :monotonic])}"
end
