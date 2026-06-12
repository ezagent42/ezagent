defmodule Ezagent.Kind.KindBaseBackfillTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.KindBaseBackfill
  alias Ezagent.Behavior.KindBase
  alias Ezagent.Ecto.KindSnapshot

  @workspace "workspace://system"

  # Seed a "session" snapshot row with the given decoded state map.
  defp seed_session(uri_str, state) do
    binary = :erlang.term_to_binary(state)
    {:ok, _row} = KindSnapshot.upsert(uri_str, "session", binary, 0, @workspace)
    uri_str
  end

  defp decode(uri_str) do
    {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
    state
  end

  # A chat-shaped state: has :external_mirror, no socialware slices. nil kind_base.
  defp chat_state do
    %{
      chat: %{state: %{owner_uri: nil, members: MapSet.new()}, transients: %{}},
      publisher: %{state: %{}, transients: %{}},
      external_mirror: %{state: %{bindings: []}, transients: %{}},
      kind_base: %{state: %{behaviors: nil}, transients: %{}}
    }
  end

  # A socialware-shaped state: has :surface + :turns. nil kind_base.
  defp socialware_state do
    %{
      chat: %{state: %{owner_uri: nil, members: MapSet.new()}, transients: %{}},
      publisher: %{state: %{}, transients: %{}},
      turns: %{state: %{}, transients: %{}},
      surface: %{state: %{versions: []}, transients: %{}},
      kind_base: %{state: %{behaviors: nil}, transients: %{}}
    }
  end

  describe "classify_session_state/1" do
    test "surface/turns slice ⇒ socialware" do
      assert {:ok, :socialware} = KindBaseBackfill.classify_session_state(socialware_state())
      assert {:ok, :socialware} = KindBaseBackfill.classify_session_state(%{turns: %{}})
      assert {:ok, :socialware} = KindBaseBackfill.classify_session_state(%{surface: %{}})
    end

    test "external_mirror without socialware slices ⇒ chat" do
      assert {:ok, :chat} = KindBaseBackfill.classify_session_state(chat_state())
    end

    test "socialware slices AND external_mirror ⇒ ambiguous (fail loud)" do
      ambiguous = Map.put(socialware_state(), :external_mirror, %{state: %{}, transients: %{}})
      assert {:error, {:ambiguous, _keys}} = KindBaseBackfill.classify_session_state(ambiguous)
    end

    test "neither shape ⇒ unclassifiable (fail loud)" do
      assert {:error, {:unclassifiable, _keys}} =
               KindBaseBackfill.classify_session_state(%{chat: %{}, kind_base: %{}})
    end
  end

  describe "target_behaviors/1" do
    test "chat set" do
      assert KindBaseBackfill.target_behaviors(:chat) == [
               Ezagent.Behavior.Chat,
               Ezagent.Behavior.Publisher.SessionImpl,
               Ezagent.Behavior.ExternalMirror
             ]
    end

    test "socialware set" do
      assert KindBaseBackfill.target_behaviors(:socialware) == [
               Ezagent.Behavior.Chat,
               Ezagent.Behavior.Publisher.SessionImpl,
               Ezagent.Behavior.Turn,
               Ezagent.Behavior.Surface
             ]
    end
  end

  describe "kind_base_missing?/1" do
    test "true for nil/missing, false for present list" do
      assert KindBaseBackfill.kind_base_missing?(chat_state())
      refute Map.has_key?(%{}, :kind_base)
      assert KindBaseBackfill.kind_base_missing?(%{})

      present = %{kind_base: %{state: %{behaviors: [Ezagent.Behavior.Chat]}, transients: %{}}}
      refute KindBaseBackfill.kind_base_missing?(present)
    end
  end

  describe "run/1 backfill (DB)" do
    test "socialware-shaped row → socialware set in :kind_base" do
      uri =
        seed_session(
          "session://advisor/system/sw-#{System.unique_integer([:positive])}",
          socialware_state()
        )

      {:ok, counts} = KindBaseBackfill.run([])
      assert counts.backfilled >= 1

      captured = KindBase.behaviors_in_slice(Map.get(decode(uri), :kind_base))
      assert captured == KindBaseBackfill.target_behaviors(:socialware)
    end

    test "chat-shaped row → chat set in :kind_base" do
      uri =
        seed_session(
          "session://default/system/chat-#{System.unique_integer([:positive])}",
          chat_state()
        )

      {:ok, _counts} = KindBaseBackfill.run([])

      captured = KindBase.behaviors_in_slice(Map.get(decode(uri), :kind_base))
      assert captured == KindBaseBackfill.target_behaviors(:chat)
    end

    test "ambiguous row fails loud" do
      ambiguous = Map.put(socialware_state(), :external_mirror, %{state: %{}, transients: %{}})

      _uri =
        seed_session("session://x/system/amb-#{System.unique_integer([:positive])}", ambiguous)

      assert_raise ArgumentError, ~r/unclassifiable\/ambiguous/, fn ->
        KindBaseBackfill.run([])
      end
    end

    test "already-backfilled row is skipped (idempotent)" do
      already =
        Map.put(chat_state(), :kind_base, %{
          state: %{behaviors: [Ezagent.Behavior.Chat]},
          transients: %{}
        })

      _uri =
        seed_session(
          "session://default/system/done-#{System.unique_integer([:positive])}",
          already
        )

      {:ok, counts} = KindBaseBackfill.run([])
      assert counts.already >= 1
    end
  end

  describe "gate/0" do
    test ">0 before backfill, 0 after" do
      _ =
        seed_session(
          "session://default/system/g1-#{System.unique_integer([:positive])}",
          chat_state()
        )

      _ =
        seed_session(
          "session://advisor/system/g2-#{System.unique_integer([:positive])}",
          socialware_state()
        )

      {:ok, before} = KindBaseBackfill.gate()
      assert before >= 2

      {:ok, _} = KindBaseBackfill.run([])

      {:ok, after_count} = KindBaseBackfill.gate()
      assert after_count == 0
    end
  end
end
