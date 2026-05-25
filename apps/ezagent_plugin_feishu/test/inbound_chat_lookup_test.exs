defmodule EzagentPluginFeishu.InboundChatLookupTest do
  @moduledoc """
  PR-EM-6 unit tests for `EzagentPluginFeishu.InboundChatLookup` —
  the chat_id → session_uri reverse lookup that replaces the retired
  `EzagentPluginFeishu.SessionBinding.resolve/1`.

  These tests insert rows directly into `external_mirror_bindings`
  via `Ezagent.ExternalMirror.BindingRow.insert/1` (the same path
  PR-EM-3's `:bind` action body uses) and verify the lookup module
  reads them back correctly.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentPluginFeishu.InboundChatLookup

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "resolve/1" do
    test "returns :error for a chat_id with no binding row" do
      assert :error = InboundChatLookup.resolve("oc_nonexistent_chat")
    end

    test "returns :error for an empty string" do
      assert :error = InboundChatLookup.resolve("")
    end

    test "returns :error for a non-binary" do
      assert :error = InboundChatLookup.resolve(nil)
      assert :error = InboundChatLookup.resolve(42)
    end

    test "returns {:ok, session_uri} for a feishu-adapter row" do
      chat_id = "oc_lookup_test_" <> uniq()
      session_uri = "session://default/default/main"

      insert_row(session_uri, "feishu", chat_id)

      assert {:ok, %URI{scheme: "session"} = parsed} = InboundChatLookup.resolve(chat_id)
      assert URI.to_string(parsed) == session_uri
    end

    test "ignores rows for OTHER adapters with the same target_id" do
      # A hypothetical Slack adapter binding the same string as target_id.
      # The Feishu inbound lookup must filter on adapter_id="feishu".
      chat_id = "oc_disambiguation_" <> uniq()
      session_uri = "session://default/default/main"

      insert_row(session_uri, "slack_hypothetical", chat_id)

      assert :error = InboundChatLookup.resolve(chat_id)
    end
  end

  describe "chat_ids_for/1" do
    test "returns [] for a session with no feishu bindings" do
      uri = URI.parse("session://default/default/nobindings_" <> uniq())
      assert [] = InboundChatLookup.chat_ids_for(uri)
    end

    test "returns all feishu chat_ids bound to the session" do
      session_uri = "session://default/default/multi_" <> uniq()
      insert_row(session_uri, "feishu", "oc_a_" <> uniq())
      insert_row(session_uri, "feishu", "oc_b_" <> uniq())
      insert_row(session_uri, "feishu", "oc_c_" <> uniq())

      result = InboundChatLookup.chat_ids_for(session_uri)
      assert length(result) == 3
      assert Enum.all?(result, &String.starts_with?(&1, "oc_"))
    end

    test "filters out non-feishu adapter rows on the same session" do
      session_uri = "session://default/default/mixed_" <> uniq()
      insert_row(session_uri, "feishu", "oc_keep_" <> uniq())
      insert_row(session_uri, "slack_hypothetical", "C_drop_" <> uniq())

      result = InboundChatLookup.chat_ids_for(session_uri)
      assert length(result) == 1
      [chat_id] = result
      assert String.starts_with?(chat_id, "oc_keep_")
    end
  end

  # ----- helpers -----------------------------------------------------------

  defp insert_row(session_uri_str, adapter_id, target_id) do
    session_uri = URI.parse(session_uri_str)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    attrs = %{
      id: BindingRow.row_id(session_uri, adapter_id, target_id),
      session_uri: session_uri_str,
      adapter_id: adapter_id,
      target_id: target_id,
      opts_json: "{}",
      bound_by: "entity://user/system/admin",
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri
    }

    {:ok, _row} = BindingRow.insert(attrs)
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))
end
