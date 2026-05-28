defmodule Ezagent.Behavior.OrchestratorAdminTest do
  @moduledoc """
  RFC #402 (Allen 2026-05-26) — `OrchestratorAdmin` is a cap-only
  Behavior anchoring the session-owner authority to restart this
  session's orchestrator.

  This test pins:

    1. The Behavior's contract shape (`actions/0`, `cap_subjects/0`,
       `dispatchable?/0`, `required_caps/0`, `data_owner/1`).
    2. `dispatchable?/0 == false` so registration writes ONLY the
       subjects table (no accidental dispatch path).
    3. `invoke/4` raises with a clear error if ever reached (defence
       in depth).
    4. `data_owner/1` for a session URI delegates to
       `Behavior.Chat.data_owner/1`, which reads `slice.chat.owner_uri`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.OrchestratorAdmin

  describe "Behavior contract shape" do
    test "actions/0 declares only :restart" do
      assert OrchestratorAdmin.actions() == [:restart]
    end

    test "cap_subjects/0 has a description for :restart" do
      subjects = OrchestratorAdmin.cap_subjects()
      assert {:restart, desc} = List.keyfind(subjects, :restart, 0)
      assert is_binary(desc)
      assert String.length(desc) > 0
    end

    test "dispatchable?/0 is false (cap-only Behavior)" do
      refute OrchestratorAdmin.dispatchable?()
    end

    test "required_caps/0 declares cap shape on :session kind" do
      caps = OrchestratorAdmin.required_caps()
      assert %{restart: %Ezagent.Capability{} = cap} = caps
      assert cap.kind == :session
      assert cap.behavior == OrchestratorAdmin
    end

    test "state_slice/0 is :orchestrator_admin" do
      assert OrchestratorAdmin.state_slice() == :orchestrator_admin
    end

    test "init_slice/1 is empty (no per-instance state needed)" do
      assert OrchestratorAdmin.init_slice(%{}) == %{}
    end

    test "invoke/4 raises (cap-only — should never be dispatched)" do
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        EzagentDomainChat.Test.BehaviorLegacyInvoke.invoke(Ezagent.Behavior.OrchestratorAdmin, :restart, %{}, %{}, %{})
      end
    end
  end

  describe "data_owner/1" do
    test "for a session URI, delegates to Behavior.Chat.data_owner/1" do
      # Behavior.Chat.data_owner reads slice.chat.owner_uri via
      # Session.owner/1. Without a live session, owner/1 returns
      # {:error, _} and Chat.data_owner returns :no_owner.
      session_uri = URI.parse("session://default/system/dead-test-session-#{:rand.uniform(99999)}")
      assert OrchestratorAdmin.data_owner(session_uri) == :no_owner
    end

    test "for :any, returns :any (class-wide cap)" do
      assert OrchestratorAdmin.data_owner(:any) == :any
    end

    test "for any other input, returns :no_owner" do
      assert OrchestratorAdmin.data_owner(URI.parse("workspace://system")) == :no_owner
      assert OrchestratorAdmin.data_owner(URI.parse("entity://user/system/admin")) == :no_owner
    end
  end
end
