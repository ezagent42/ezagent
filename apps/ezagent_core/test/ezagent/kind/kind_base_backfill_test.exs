defmodule Ezagent.Kind.KindBaseBackfillTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.KindBaseBackfill
  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.SnapshotFixtures

  @workspace "workspace://system"

  # A session-like Kind that REQUIRES an explicit (non-nil) :kind_base (the
  # P5-0b scoped guard) and declares the CHAT Session set. Used to prove the
  # backfilled minimal-chat row reloads via effective_set/2 without raising.
  defmodule ChatSessionLikeKind do
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors,
      do: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Publisher.SessionImpl,
        Ezagent.ActionSet.ExternalMirror,
        Ezagent.ActionSet.KindBase
      ]

    @impl true
    def persistence, do: :ephemeral
    @impl true
    def supervisor, do: Ezagent.Kind.Server
    @impl true
    def requires_explicit_behavior_set?, do: true
  end

  # Seed a "session" snapshot row with the given decoded state map. Routes
  # through the sanctioned `SnapshotFixtures.upsert_kind_snapshot/5` helper
  # (gate #20) rather than calling `KindSnapshot.upsert/5` directly.
  defp seed_session(uri_str, state) do
    binary = :erlang.term_to_binary(state)
    {:ok, _row} = SnapshotFixtures.upsert_kind_snapshot(uri_str, "session", binary, 0, @workspace)
    uri_str
  end

  defp decode(uri_str) do
    {:ok, state} = KindSnapshot.decode_state(KindSnapshot.get(uri_str))
    state
  end

  # A chat-shaped state: has :external_mirror, no socialware slices. nil kind_base.
  defp chat_state do
    %{
      session: %{state: %{owner_uri: nil, members: MapSet.new()}, transients: %{}},
      publisher: %{state: %{}, transients: %{}},
      external_mirror: %{state: %{bindings: []}, transients: %{}},
      kind_base: %{state: %{behaviors: nil}, transients: %{}}
    }
  end

  # A MINIMAL chat-shaped state: ONLY :chat, NO :external_mirror, NO socialware
  # slices. This is the real shape a chat Session persists with when no mirror
  # binding has ever been created (proof fixture:
  # apps/ezagent_domain_session/test/integration/
  # orchestrator_mcp_reregister_test.exs saves `%{session: chat_slice}` only).
  # `:external_mirror` is OPTIONAL for chat — chat is the DEFAULT classification.
  defp minimal_chat_state do
    %{
      session: %{state: %{owner_uri: nil, members: MapSet.new()}, transients: %{}},
      kind_base: %{state: %{behaviors: nil}, transients: %{}}
    }
  end

  # A socialware-shaped state: has :surface + :turns. nil kind_base.
  defp socialware_state do
    %{
      session: %{state: %{owner_uri: nil, members: MapSet.new()}, transients: %{}},
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
      assert {:ok, :instance_message} = KindBaseBackfill.classify_session_state(chat_state())
    end

    test "minimal :chat-only (NO external_mirror, NO socialware) ⇒ chat (chat is the DEFAULT)" do
      # The proof-fixture shape: a real chat Session that never created a mirror
      # binding persists with ONLY :chat. It MUST classify as chat — not be
      # rejected as unclassifiable. :external_mirror is optional for chat.
      assert {:ok, :instance_message} =
               KindBaseBackfill.classify_session_state(minimal_chat_state())

      assert {:ok, :instance_message} = KindBaseBackfill.classify_session_state(%{session: %{}})
    end

    test "recognizable session by :publisher alone (no mirror, no socialware) ⇒ chat" do
      assert {:ok, :instance_message} = KindBaseBackfill.classify_session_state(%{publisher: %{}})
    end

    test "socialware slices AND external_mirror ⇒ ambiguous (fail loud)" do
      ambiguous = Map.put(socialware_state(), :external_mirror, %{state: %{}, transients: %{}})
      assert {:error, {:ambiguous, _keys}} = KindBaseBackfill.classify_session_state(ambiguous)
    end

    test "non-session (no :chat, no :publisher, no session slice) ⇒ unclassifiable (fail loud)" do
      assert {:error, {:unclassifiable, _keys}} =
               KindBaseBackfill.classify_session_state(%{kind_base: %{}})

      assert {:error, {:unclassifiable, _keys}} =
               KindBaseBackfill.classify_session_state(%{some_other: %{}})
    end

    test "legacy JSON-column row (STRING session keys) ⇒ legacy_json_unsupported (precise fail loud)" do
      # A snapshot decoded via the legacy `state` JSON column has STRING
      # top-level keys, not atoms. It MUST NOT be mis-reported as
      # `:unclassifiable` (it IS a recognizable session) — it gets a PRECISE
      # legacy error so the operator re-saves it as a binary snapshot first.
      assert {:error, {:legacy_json_unsupported, _keys}} =
               KindBaseBackfill.classify_session_state(%{"session" => %{}, "publisher" => %{}})

      assert {:error, {:legacy_json_unsupported, _keys}} =
               KindBaseBackfill.classify_session_state(%{"surface" => %{}, "turns" => %{}})

      assert {:error, {:legacy_json_unsupported, _keys}} =
               KindBaseBackfill.classify_session_state(%{"external_mirror" => %{}})
    end
  end

  describe "target_behaviors/1" do
    test "chat set" do
      assert KindBaseBackfill.target_behaviors(:instance_message) == [
               Ezagent.ActionSet.Session,
               Ezagent.ActionSet.Publisher.SessionImpl,
               Ezagent.ActionSet.ExternalMirror
             ]
    end

    test "socialware set matches Session.socialware_behaviors/0 order exactly" do
      assert KindBaseBackfill.target_behaviors(:socialware) == [
               Ezagent.ActionSet.Session,
               Ezagent.ActionSet.Turn,
               Ezagent.ActionSet.Surface,
               Ezagent.ActionSet.SupervisorApproval,
               Ezagent.ActionSet.Publisher.SessionImpl
             ]
    end
  end

  describe "kind_base_missing?/1" do
    test "true for nil/missing, false for present list" do
      assert KindBaseBackfill.kind_base_missing?(chat_state())
      refute Map.has_key?(%{}, :kind_base)
      assert KindBaseBackfill.kind_base_missing?(%{})

      present = %{kind_base: %{state: %{behaviors: [Ezagent.ActionSet.Session]}, transients: %{}}}
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
      assert captured == KindBaseBackfill.target_behaviors(:instance_message)
    end

    test "minimal :chat-only row → chat set in :kind_base (round-trip, no raise on reload)" do
      uri =
        seed_session(
          "session://default/system/min-#{System.unique_integer([:positive])}",
          minimal_chat_state()
        )

      {:ok, _counts} = KindBaseBackfill.run([])

      captured = KindBase.behaviors_in_slice(Map.get(decode(uri), :kind_base))
      assert captured == KindBaseBackfill.target_behaviors(:instance_message)

      # Round-trip: with :kind_base now a PRESENT list (the chat set), the scoped
      # guard is SATISFIED — effective_set/2 does NOT raise MissingKindBaseError;
      # it intersects the captured chat set with the declared chat set.
      slice_state = decode(uri)

      effective = Ezagent.Kind.BehaviorSet.effective_set(ChatSessionLikeKind, slice_state)
      assert Ezagent.ActionSet.Session in effective
      assert Ezagent.ActionSet.Publisher.SessionImpl in effective
      # ExternalMirror is in BOTH the backfilled chat set and the declared set,
      # so it is retained — the chat set is its own declared list (no over/under).
      assert Ezagent.ActionSet.ExternalMirror in effective
    end

    test "legacy JSON-column row is CLEARED (run does not abort) so the gate reaches zero" do
      # Seed a row in the legacy JSON `state` column (STRING keys, NO
      # state_binary) — the shape `KindSnapshot.decode_state/1` returns from its
      # legacy fallback. It cannot be auto-migrated (lossy) and the P5-0b guard
      # blocks a runtime re-save, so `run/1` DELETES it (Allen 2026-06-12): no
      # raise, no stranded row, and the gate reaches 0. Regression for the codex
      # P5 round-2 deadlock finding.
      uri = "session://default/system/legacy-#{System.unique_integer([:positive])}"

      {:ok, _} =
        EzagentCore.Repo.insert(%KindSnapshot{
          uri: uri,
          kind_type: "session",
          state: %{"session" => %{"state" => %{"owner_uri" => nil, "members" => %{}}}},
          state_binary: nil,
          version: 0,
          workspace_uri: @workspace,
          ever_created: true,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      assert {:ok, counts} = KindBaseBackfill.run([])
      assert counts.legacy_cleared >= 1
      assert counts.backfilled == 0

      # The unusable state was cleared, while the Lifecycle marker remains so
      # a revoked principal cannot later be misclassified as a genuine create.
      assert %KindSnapshot{ever_created: true, state: nil} = row = KindSnapshot.get(uri)
      assert {:ok, %{}} = KindSnapshot.decode_state(row)

      # The marker-only row is no longer legacy JSON, so the gate reaches 0.
      assert {:ok, 0} = KindBaseBackfill.gate()
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
          state: %{behaviors: [Ezagent.ActionSet.Session]},
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
