defmodule EzagentDomainChat.Integration.SessionCreateOrchestratorUnifiedTest do
  @moduledoc """
  Acceptance tests for SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap A — `EzagentDomainChat.create_session/3` now auto-spawns the
  orchestrator Agent Kind and returns the new 3-tuple
  `{:ok, session_uri, meta}` shape.

  Maps to the SPEC's Acceptance Criteria table:

    * A1: `create_session/3` returns the 3-tuple with an orchestrator
      meta map.
    * A2: After `create_session`, `Ezagent.KindRegistry.lookup(orch_uri)`
      returns `{:ok, pid}`.
    * A3: Orchestrator spawn failure surfaces as
      `orchestrator_status: :failed` with `orchestrator_error`
      populated (the session itself stays alive — Invariant #9
      structural surfacing, NOT a silent fallback).

  Plus an invariant assertion that the session URI shape is unchanged
  vs the pre-Gap-A path (regression guard for the SPEC #366 + #324
  URI invariants).
  """

  use ExUnit.Case, async: false

  alias Ezagent.{KindRegistry}
  alias Ezagent.Entity.{Session, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Make sure admin User Kind is alive (orchestrator-spawn paths read
    # owner lineage — admin's the bootstrap principal in test env).
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "Gap A (A1) — create_session/3 returns 3-tuple meta" do
    test "happy path: ready status + orchestrator_uri populated" do
      short = "unified-a1-#{System.unique_integer([:positive])}"

      assert {:ok, session_uri, meta} =
               EzagentDomainChat.create_session(short, User.admin_uri(),
                 template_name: "default"
               )

      assert URI.to_string(session_uri) == "session://default/system/#{short}"
      assert is_map(meta)
      assert Map.has_key?(meta, :orchestrator_uri)
      assert Map.has_key?(meta, :orchestrator_status)
      assert Map.has_key?(meta, :orchestrator_error)

      # The orchestrator step ran successfully — `Agent.spawn_fresh`
      # spawned a fresh Agent Kind or adopted an already-present one
      # in the same workspace. Either way status is `:ready` and
      # `orchestrator_uri` is a populated `%URI{}`.
      assert meta.orchestrator_status == :ready,
             "expected :ready, got #{inspect(meta.orchestrator_status)} (error=#{inspect(meta.orchestrator_error)})"

      assert %URI{scheme: "entity", host: "agent"} = meta.orchestrator_uri
      assert is_nil(meta.orchestrator_error)
    end
  end

  describe "Gap A (A2) — orchestrator Agent Kind alive in KindRegistry after create_session" do
    test "lookup(meta.orchestrator_uri) returns {:ok, pid}" do
      short = "unified-a2-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      assert meta.orchestrator_status == :ready
      assert {:ok, pid} = KindRegistry.lookup(meta.orchestrator_uri)
      assert Process.alive?(pid)
    end

    test "orchestrator URI matches `derive_orchestrator_uri` for this session" do
      short = "unified-a2-shape-#{System.unique_integer([:positive])}"

      {:ok, session_uri, meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())
      expected = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      assert URI.to_string(meta.orchestrator_uri) == URI.to_string(expected)
    end
  end

  describe "Gap A (A3) — orchestrator spawn failure surfaces structurally" do
    @tag :skip
    test "force-failure path returns :failed + populated orchestrator_error" do
      # Tested in Session.ensure_orchestrator/3's own tests by
      # constructing a foreign-lineage candidate. Reproducing here
      # would re-stage the same scenario; left as a placeholder
      # documenting the SPEC's A3 surface — the call SIGNATURE
      # supports `:failed` (covered by the unit test of
      # `ensure_orchestrator_meta`'s `:error` branch — see
      # `session_test.exs`). The session-level e2e would require a
      # poisoned ETS state that the rest of the suite doesn't tolerate.
      assert true
    end

    test "meta map has the 3 required keys regardless of status" do
      # Structural test — defends against a refactor that drops
      # `:orchestrator_error` from the happy-path meta (would be an
      # API break for callers that always inspect all 3).
      short = "unified-a3-struct-#{System.unique_integer([:positive])}"

      {:ok, _session_uri, meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      assert MapSet.subset?(
               MapSet.new([:orchestrator_uri, :orchestrator_status, :orchestrator_error]),
               MapSet.new(Map.keys(meta))
             )
    end
  end

  describe "URI invariant — session URI shape unchanged vs pre-Gap-A path" do
    test "default template still yields session://default/system/<short>" do
      # SPEC #366 + #324 invariant — the auto-spawn shouldn't have
      # changed the session URI itself.
      short = "unified-uri-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      assert URI.to_string(session_uri) == "session://default/system/#{short}"
    end
  end
end
