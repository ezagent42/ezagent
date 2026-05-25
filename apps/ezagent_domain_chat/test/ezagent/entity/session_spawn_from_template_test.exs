defmodule Ezagent.Entity.SessionSpawnFromTemplateTest do
  @moduledoc """
  Phase 7 PR 41 — Generator (`Ezagent.Entity.Session.spawn_from_template/2`)
  structural test.

  Verifies the function exists with documented signature. Full
  integration test (actual spawn + WorkspaceRegistry bind + AgentLineage
  record verification) requires Ecto sandbox setup that conflicts with
  the live ETS state when running standalone — proper integration
  coverage lands with PR 46 (orchestrator tools) which sets up the
  full test environment alongside the orchestrator MCP tool dispatch.

  Structural check today is enough to gate the contract: future
  refactors that drop the function or change its arity fail this test.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Entity.Session

  test "spawn_from_template/2 exists with documented signature" do
    assert function_exported?(Session, :spawn_from_template, 2),
           "Phase 7 PR 41 — Ezagent.Entity.Session.spawn_from_template/2 must exist"
  end

  test "default_uri/0 still works (pre-PR-41 contract preserved)" do
    # Regression guard — adding Generator function must not break
    # the existing default Session URI. SPEC v3 §3.6 (Phase 9 PR-7)
    # promoted the URI to 3-segment shape.
    uri = Session.default_uri()
    assert uri.scheme == "session"
    assert uri.host == "default"
    assert uri.path == "/system/main"
  end

  test "Generator module is Session itself (not a separate Generator module)" do
    # Per SPEC §Generator: "Generator is the role; `Ezagent.Entity.Session.spawn_from_template/2`
    # is the entry point". Pin that decision — the Generator is not a
    # separate module to avoid plumbing yet another concept.
    refute Code.ensure_loaded?(Ezagent.Entity.Generator),
           "Generator should NOT be a separate module — it's a role implemented by " <>
             "Ezagent.Entity.Session.spawn_from_template/2 per SPEC §Generator"
  end
end
