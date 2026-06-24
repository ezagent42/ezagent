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

  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentPluginFeishu.InboundChatLookup

  # Sandbox provided by EzagentCore.DataCase (#92).

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
      session_uri = "session://system/default/main"

      insert_row(session_uri, "feishu", chat_id)

      assert {:ok, %URI{scheme: "session"} = parsed} = InboundChatLookup.resolve(chat_id)
      assert URI.to_string(parsed) == session_uri
    end

    test "ignores rows for OTHER adapters with the same target_id" do
      # A hypothetical Slack adapter binding the same string as target_id.
      # The Feishu inbound lookup must filter on adapter_id="feishu".
      chat_id = "oc_disambiguation_" <> uniq()
      session_uri = "session://system/default/main"

      insert_row(session_uri, "slack_hypothetical", chat_id)

      assert :error = InboundChatLookup.resolve(chat_id)
    end

    # codex r1 HIGH fix (2026-05-25) — fail closed on duplicate bindings.
    # The external_mirror_bindings natural key is
    # (session_uri, adapter_id, target_id) so the same Feishu chat_id
    # CAN be bound to multiple sessions at the DB level. Pre-fix this
    # silently picked the oldest by bound_at → wrong-session routing
    # + the correct rebind could never win. Post-fix: hard error.
    test "returns {:error, :ambiguous_chat_binding} when 2+ sessions are bound to the same chat_id" do
      chat_id = "oc_dup_" <> uniq()
      insert_row("session://system/default/team_a_" <> uniq(), "feishu", chat_id)
      insert_row("session://system/default/team_b_" <> uniq(), "feishu", chat_id)

      assert {:error, :ambiguous_chat_binding} = InboundChatLookup.resolve(chat_id)
    end
  end

  describe "resolve/2 — @-mention disambiguation" do
    # The membership reader is injected per-test so we don't spin up the
    # full Session Kind supervision tree. We register a stub mapping of
    # session_uri string → list of member URI strings via persistent_term;
    # the stub returns `[]` for anything not registered (mirrors a
    # non-live session, which `Session.session_member_uris/1` does too).
    setup do
      :persistent_term.put({__MODULE__, :members}, %{})

      Application.put_env(
        :ezagent_plugin_feishu,
        :session_member_reader,
        {__MODULE__, :stub_member_uris}
      )

      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_feishu, :session_member_reader)
        :persistent_term.erase({__MODULE__, :members})
      end)

      :ok
    end

    # (a) single binding is unchanged — mentions are ignored, no ambiguity.
    test "single binding returns {:ok, uri} regardless of mentions" do
      chat_id = "oc_one_" <> uniq()
      session_uri = "session://system/default/solo_" <> uniq()
      insert_row(session_uri, "feishu", chat_id)

      mention = Ezagent.URI.new!("entity://default/agent/cc_architect")

      assert {:ok, %URI{} = parsed} = InboundChatLookup.resolve(chat_id, [mention])
      assert URI.to_string(parsed) == session_uri
    end

    # (b) 2 bindings + an @-mention whose agent is in EXACTLY ONE bound
    # session → route to that session.
    test "2 bindings + mention in exactly one session → routes there" do
      chat_id = "oc_disambig_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      # @architect is a member of session A only.
      set_members(%{
        sess_a => ["entity://default/agent/cc_architect"],
        sess_b => ["entity://default/agent/cc_reviewer"]
      })

      mention = Ezagent.URI.new!("entity://default/agent/cc_architect")

      assert {:ok, %URI{} = parsed} = InboundChatLookup.resolve(chat_id, [mention])
      assert URI.to_string(parsed) == sess_a
    end

    # (c) 2 bindings + NO mention → still fails closed.
    test "2 bindings + no mention → :ambiguous_chat_binding" do
      chat_id = "oc_nomention_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      set_members(%{
        sess_a => ["entity://default/agent/cc_architect"],
        sess_b => ["entity://default/agent/cc_reviewer"]
      })

      assert {:error, :ambiguous_chat_binding} = InboundChatLookup.resolve(chat_id, [])
    end

    # (d) 2 bindings + a mention whose agent is a member of BOTH bound
    # sessions → cannot narrow to one → still fails closed.
    test "2 bindings + mention in two of them → :ambiguous_chat_binding" do
      chat_id = "oc_shared_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      # @shared is a member of BOTH bound sessions → 2 candidates → fail closed.
      set_members(%{
        sess_a => ["entity://default/agent/cc_shared"],
        sess_b => ["entity://default/agent/cc_shared"]
      })

      mention = Ezagent.URI.new!("entity://default/agent/cc_shared")

      assert {:error, :ambiguous_chat_binding} =
               InboundChatLookup.resolve(chat_id, [mention])
    end

    # Bonus: 2 bindings + a mention whose agent is in NEITHER bound
    # session → 0 candidates → fail closed (the mention targets an agent
    # that lives in some other chat).
    test "2 bindings + mention in neither → :ambiguous_chat_binding" do
      chat_id = "oc_miss_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      set_members(%{
        sess_a => ["entity://default/agent/cc_architect"],
        sess_b => ["entity://default/agent/cc_reviewer"]
      })

      mention = Ezagent.URI.new!("entity://default/agent/cc_stranger")

      assert {:error, :ambiguous_chat_binding} =
               InboundChatLookup.resolve(chat_id, [mention])
    end

    test "resolve/1 delegates to resolve(chat_id, []) — back-compat" do
      chat_id = "oc_backcompat_" <> uniq()
      session_uri = "session://system/default/backcompat_" <> uniq()
      insert_row(session_uri, "feishu", chat_id)

      assert {:ok, %URI{} = parsed} = InboundChatLookup.resolve(chat_id)
      assert URI.to_string(parsed) == session_uri
    end

    defp set_members(map), do: :persistent_term.put({__MODULE__, :members}, map)
  end

  # team-routing-unification §3.6 (PR-6, codex 2026-06-01 MED #3) — a shared
  # Feishu chat bound to multiple sessions, with ONLY an `@<legend>` (no
  # concrete agent mention), is narrowed by resolving the typed token against
  # EACH candidate session's legend registry. Legends are session-scoped, so
  # the same `@传话游戏` may name a legend in one bound session but not another.
  describe "resolve/3 — @-legend disambiguation" do
    setup do
      :persistent_term.put({__MODULE__, :members}, %{})
      :persistent_term.put({__MODULE__, :legends}, %{})

      Application.put_env(
        :ezagent_plugin_feishu,
        :session_member_reader,
        {__MODULE__, :stub_member_uris}
      )

      Application.put_env(
        :ezagent_plugin_feishu,
        :session_legends_reader,
        {__MODULE__, :stub_legends}
      )

      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_feishu, :session_member_reader)
        Application.delete_env(:ezagent_plugin_feishu, :session_legends_reader)
        :persistent_term.erase({__MODULE__, :members})
        :persistent_term.erase({__MODULE__, :legends})
      end)

      :ok
    end

    test "2 bindings + ONLY @legend that is registered in exactly ONE session → routes there" do
      chat_id = "oc_legend_disambig_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      # `传话游戏` is a legend in session A only (no concrete agent mention,
      # no members signal). The legend narrows the ambiguous set to A.
      set_legends(%{
        sess_a => Ezagent.Routing.Legend.put(%{}, "传话游戏", bound_rule_set: "telephone")
      })

      assert {:ok, %URI{} = parsed} =
               InboundChatLookup.resolve(chat_id, [], "@传话游戏 开始")

      assert URI.to_string(parsed) == sess_a
    end

    test "2 bindings + @legend registered in BOTH → fail closed" do
      chat_id = "oc_legend_both_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      set_legends(%{
        sess_a => Ezagent.Routing.Legend.put(%{}, "传话游戏", bound_rule_set: "telephone"),
        sess_b => Ezagent.Routing.Legend.put(%{}, "传话游戏", bound_rule_set: "telephone")
      })

      assert {:error, :ambiguous_chat_binding} =
               InboundChatLookup.resolve(chat_id, [], "@传话游戏 hi")
    end

    test "2 bindings + @legend registered in NEITHER → fail closed" do
      chat_id = "oc_legend_neither_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      # No session registers `传话游戏`.
      set_legends(%{})

      assert {:error, :ambiguous_chat_binding} =
               InboundChatLookup.resolve(chat_id, [], "@传话游戏 hi")
    end

    test "legend AND mention both narrow to the same single session → routes there" do
      chat_id = "oc_legend_plus_mention_" <> uniq()
      sess_a = "session://system/default/team_a_" <> uniq()
      sess_b = "session://system/default/team_b_" <> uniq()

      insert_row(sess_a, "feishu", chat_id)
      insert_row(sess_b, "feishu", chat_id)

      set_members(%{sess_a => ["entity://default/agent/cc_relay"]})
      set_legends(%{sess_a => Ezagent.Routing.Legend.put(%{}, "传话游戏", bound_rule_set: "rs")})

      mention = Ezagent.URI.new!("entity://default/agent/cc_relay")

      assert {:ok, %URI{} = parsed} =
               InboundChatLookup.resolve(chat_id, [mention], "@传话游戏 @cc_relay go")

      assert URI.to_string(parsed) == sess_a
    end

    defp set_legends(map), do: :persistent_term.put({__MODULE__, :legends}, map)
  end

  # Stub legend-registry reader injected via :session_legends_reader. Keyed on
  # canonical session URI string; returns the session's legend registry (`%{}`
  # for an unregistered / non-live session, mirroring Session.session_legends/1).
  def stub_legends(%URI{} = session_uri) do
    :persistent_term.get({__MODULE__, :legends}, %{})
    |> Map.get(URI.to_string(session_uri), %{})
  end

  # Stub membership reader injected via :session_member_reader. Keyed on
  # the canonical session URI string; returns member URI structs (the
  # real reader returns URIs, and the lookup compares on canonical form).
  def stub_member_uris(%URI{} = session_uri) do
    :persistent_term.get({__MODULE__, :members}, %{})
    |> Map.get(URI.to_string(session_uri), [])
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  describe "chat_ids_for/1" do
    test "returns [] for a session with no feishu bindings" do
      uri = URI.parse("session://system/default/nobindings_" <> uniq())
      assert [] = InboundChatLookup.chat_ids_for(uri)
    end

    test "returns all feishu chat_ids bound to the session" do
      session_uri = "session://system/default/multi_" <> uniq()
      insert_row(session_uri, "feishu", "oc_a_" <> uniq())
      insert_row(session_uri, "feishu", "oc_b_" <> uniq())
      insert_row(session_uri, "feishu", "oc_c_" <> uniq())

      result = InboundChatLookup.chat_ids_for(session_uri)
      assert length(result) == 3
      assert Enum.all?(result, &String.starts_with?(&1, "oc_"))
    end

    test "filters out non-feishu adapter rows on the same session" do
      session_uri = "session://system/default/mixed_" <> uniq()
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
    session_uri = Ezagent.URI.new!(session_uri_str)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)

    attrs = %{
      id: BindingRow.row_id(session_uri, adapter_id, target_id),
      session_uri: session_uri_str,
      adapter_id: adapter_id,
      target_id: target_id,
      opts_json: "{}",
      bound_by: "entity://system/user/admin",
      bound_at: DateTime.utc_now(),
      workspace_uri: workspace_uri
    }

    {:ok, _row} = BindingRow.insert(attrs)
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))
end
