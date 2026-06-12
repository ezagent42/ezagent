defmodule Ezagent.Session.SliceMigrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Session.SliceMigration
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.SnapshotFixtures

  @workspace "workspace://system"

  # Seed a "session" snapshot row with the given decoded state map (binary).
  defp seed_session(uri_str, state) do
    binary = :erlang.term_to_binary(state)
    {:ok, _row} = SnapshotFixtures.upsert_kind_snapshot(uri_str, "session", binary, 0, @workspace)
    uri_str
  end

  defp decode(uri_str) do
    {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
    state
  end

  describe "rename_slice_key/1 (pure)" do
    test "renames the top-level :chat key to :session, preserving the value" do
      chat_value = %{state: %{owner_uri: nil, members: %{}}, transients: %{}}

      assert {:renamed, new} =
               SliceMigration.rename_slice_key(%{
                 chat: chat_value,
                 publisher: %{state: %{}, transients: %{}}
               })

      assert new[:session] == chat_value
      refute Map.has_key?(new, :chat)
      # sibling slices untouched
      assert Map.has_key?(new, :publisher)
    end

    test ":session-keyed row is a no-op (fresh new-code snapshot)" do
      session_value = %{state: %{members: %{}}, transients: %{}}
      assert {:noop, state} = SliceMigration.rename_slice_key(%{session: session_value})
      assert state[:session] == session_value
    end

    test "non-session row (neither key) is a no-op" do
      assert {:noop, state} = SliceMigration.rename_slice_key(%{identity: %{}})
      assert state == %{identity: %{}}
    end

    test "a row carrying BOTH :chat and :session fails loud" do
      assert {:error, {:both_keys_present, keys}} =
               SliceMigration.rename_slice_key(%{chat: %{}, session: %{}})

      assert :chat in keys and :session in keys
    end
  end

  describe "run/1 against seeded :chat-keyed snapshot rows" do
    test "migrates a seeded :chat-keyed row to :session (the prod path)" do
      uri = "session://team-alpha/default/migrate-me"

      seed_session(uri, %{
        chat: %{state: %{owner_uri: nil, members: %{}, last_message_id: "m1"}, transients: %{}},
        publisher: %{state: %{}, transients: %{}}
      })

      # before: row carries :chat, not :session
      pre = decode(uri)
      assert Map.has_key?(pre, :chat)
      refute Map.has_key?(pre, :session)

      assert {:ok, counts} = SliceMigration.run()
      assert counts.renamed >= 1

      post = decode(uri)
      refute Map.has_key?(post, :chat)
      assert Map.has_key?(post, :session)
      # value preserved through the rename
      assert post[:session][:state][:last_message_id] == "m1"
      # sibling slice preserved
      assert Map.has_key?(post, :publisher)
    end

    test "migrates a NON-session (agent) row that carries the old :chat receive-state (codex P2)" do
      # The old Chat behavior was registered for :receive on the User AND Agent
      # Kinds too, so an agent/user snapshot that ever received a message carries
      # the same `:chat` slice. The migration MUST cover it (not just
      # kind_type==session) or the gate falsely green-lights with stale data.
      uri = "entity://team-alpha/agent/recv-state"
      binary = :erlang.term_to_binary(%{chat: %{state: %{last_received: "m9"}, transients: %{}}})
      {:ok, _} = SnapshotFixtures.upsert_kind_snapshot(uri, "agent", binary, 0, @workspace)

      assert {:ok, counts} = SliceMigration.run()
      assert counts.renamed >= 1

      post = decode(uri)
      refute Map.has_key?(post, :chat)
      assert post[:session][:state][:last_received] == "m9"

      # And the gate counts a stale :chat on a non-session Kind (no false green).
      {:ok, remaining} = SliceMigration.gate()
      assert remaining == 0
    end

    test "an already-:session row is counted as already, not rewritten" do
      uri = "session://team-alpha/default/fresh-session"
      seed_session(uri, %{session: %{state: %{members: %{}}, transients: %{}}})

      assert {:ok, counts} = SliceMigration.run()
      assert counts.already >= 1

      assert Map.has_key?(decode(uri), :session)
    end

    test "--dry-run reports without writing" do
      uri = "session://team-alpha/default/dry-run-me"
      seed_session(uri, %{chat: %{state: %{members: %{}}, transients: %{}}})

      assert {:ok, counts} = SliceMigration.run(dry_run: true)
      assert counts.dry_run >= 1
      # unchanged on disk
      assert Map.has_key?(decode(uri), :chat)
    end
  end

  describe "gate/0" do
    test "reports the count of rows still carrying a :chat slice; 0 after migration" do
      uri = "session://team-alpha/default/gate-me"
      seed_session(uri, %{chat: %{state: %{members: %{}}, transients: %{}}})

      assert {:ok, n} = SliceMigration.gate()
      assert n >= 1

      {:ok, _} = SliceMigration.run()
      assert {:ok, 0} = SliceMigration.gate()
    end
  end
end
