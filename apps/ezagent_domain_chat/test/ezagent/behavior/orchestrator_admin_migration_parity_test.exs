defmodule Ezagent.Behavior.OrchestratorAdminMigrationParityTest do
  @moduledoc """
  Phase 2-a r3 (2026-05-28) — migration parity tests for
  `Ezagent.Behavior.OrchestratorAdmin` after the SPEC 2026-05-28
  new-action-grammar migration.

  OrchestratorAdmin is a cap-only Behavior: its `:restart` handler is
  unreachable in practice (the LV reads the cap and dispatches
  `template.instantiate` on the cc-orchestrator template directly).
  The handler still exists so the macro's compile-time invariant
  (every declared action has a `handle_<action>/2`) is satisfied; the
  parity tests pin that the handler returns a clean error tuple
  rather than raising, and that the Behavior's introspection
  surface (actions, caps, cap_subjects, data_owner) is unchanged.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.OrchestratorAdmin

  describe "new-contract surface" do
    test "is a new-style Behavior (declared via use Ezagent.Behavior)" do
      assert OrchestratorAdmin.__behavior__?() == true
    end

    test "declares :restart action" do
      assert OrchestratorAdmin.__action_names__() == [:restart]
    end

    test "action spec for :restart carries cap + description" do
      spec = OrchestratorAdmin.__action_spec__(:restart)
      assert spec.name == :restart
      assert spec.modes == [:call]
      assert spec.caps == [:restart]
      assert spec.description =~ "session-owner authority"
    end

    test "actions/0 (legacy-compat) returns [:restart]" do
      assert OrchestratorAdmin.actions() == [:restart]
    end

    test "cap_subjects/0 includes :restart with English description" do
      [{:restart, desc}] = OrchestratorAdmin.cap_subjects()
      assert is_binary(desc)
      assert desc =~ "restart"
    end

    test "required_caps/0 produces a session-scoped restart cap" do
      caps = OrchestratorAdmin.required_caps()
      assert Map.has_key?(caps, :restart)
      %Ezagent.Capability{behavior: OrchestratorAdmin, action: :restart} = caps[:restart]
    end

    test "state_slice/0 is :orchestrator_admin" do
      assert OrchestratorAdmin.state_slice() == :orchestrator_admin
    end

    # Lifecycle migration (SPEC 2026-05-29 §2.3): `init_slice/1` now wraps
    # `create/1`'s (empty) persistent state in the two-container shape.
    test "init_slice/1 returns the two-container shape with empty persistent state" do
      assert OrchestratorAdmin.init_slice(%{}) == %{state: %{}, transients: %{}}
    end
  end

  describe "handle_restart/2 — cap-only action" do
    test "raises (cap-only — pre- and post-migration parity)" do
      # Cap-only Behavior: the handler is never expected to be
      # reached; if it is, raise. The runtime maps the raise to a
      # {:error, {:behavior_exception, _, _}} tuple for clean
      # propagation. Same shape as the legacy `invoke/4` clause.
      assert_raise RuntimeError, ~r/cap-only/, fn ->
        OrchestratorAdmin.handle_restart(%{}, %{})
      end
    end
  end

  describe "data_owner/1 — delegates to Chat for session URIs" do
    test ":any returns :any" do
      assert OrchestratorAdmin.data_owner(:any) == :any
    end

    test "non-session URI returns :no_owner" do
      assert OrchestratorAdmin.data_owner(URI.parse("entity://user/team-alpha/u")) ==
               :no_owner
    end
  end
end
