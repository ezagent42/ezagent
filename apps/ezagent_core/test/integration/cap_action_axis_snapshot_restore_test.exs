defmodule Ezagent.Integration.CapActionAxisSnapshotRestoreTest do
  @moduledoc """
  SPEC 2026-05-27 capability-action-axis §5 B3 — matcher tolerance for
  legacy snapshot-restored caps that lack the `:action` key.

  PRE-SPEC `binary_to_term`'d caps don't have the `:action` key.
  Per §3.7 r3, the matcher reads via `action_of/1` (`Map.get(cap,
  :action, :any)`) so missing keys are treated as the wildcard.
  Result: pre-SPEC caps preserve their original semantics
  ("any action on this Behavior") AS the action-axis match dimension
  reads them.

  This is the structural alternative to `normalize_loaded/2` /
  `reconcile_after_load/2`, which §3.7 r3 REJECTED.

  Async-safe: pure data + Erlang term encoding round-trip; no Repo,
  no GenServer.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability

  test "B3 — Map.delete'd legacy cap matches concrete needed action as wildcard" do
    # (1) construct a cap and strip its `:action` key to simulate a
    # pre-action-axis snapshot.
    fresh =
      %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.Session,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

    legacy_in_memory = Map.delete(fresh, :action)

    refute Map.has_key?(legacy_in_memory, :action),
           "test fixture invariant: stripping `:action` must produce a map without the key"

    # (2) term_to_binary / binary_to_term round-trip — confirms the
    # deserialized term ALSO lacks the key (Erlang's binary term format
    # preserves map shape verbatim).
    deserialized = legacy_in_memory |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    refute Map.has_key?(deserialized, :action),
           "post-deserialize: the round-tripped map MUST still lack `:action` — that's the structural shape of pre-SPEC snapshots"

    # (3) build a needed map asking for a CONCRETE action and check
    # that the deserialized legacy cap matches (action_of returns :any
    # which matches any concrete needed action).
    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.Session,
      action: :send,
      instance: URI.new!("session://team-alpha/default/main"),
      workspace_uri: URI.new!("workspace://team-alpha")
    }

    # (4) matches? returns true — missing-key tolerance preserves
    # wildcard semantics.
    assert Capability.matches?(deserialized, needed),
           "matches?/2 MUST tolerate legacy caps missing `:action` via action_of/1's `:any` default. Without this tolerance, every pre-SPEC snapshot would silently DENY post-deploy until the next save_now cycle — defeating the SPEC's `feedback_let_it_crash_no_workarounds` no-shim posture for the migration."

    # (5) no exception, no crash — explicit assertion that matches?/2
    # doesn't raise for the legacy cap shape (the chokepoint behavior
    # that closes §3.7 r3).
    try do
      assert is_boolean(Capability.matches?(deserialized, needed)),
             "matches?/2 must return a boolean for legacy caps"
    rescue
      e ->
        flunk(
          "matches?/2 raised on legacy cap missing :action — " <>
            "action_of/1 chokepoint failed: #{inspect(e)}"
        )
    end
  end

  test "B3 — action_of/1 on legacy cap returns :any (no raise)" do
    legacy =
      %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.Session,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
      |> Map.delete(:action)

    refute Map.has_key?(legacy, :action),
           "test fixture invariant: legacy cap lacks `:action`"

    assert Capability.action_of(legacy) == :any,
           "action_of/1's `Map.get(cap, :action, :any)` MUST return `:any` for legacy caps — this is the chokepoint that closes §3.7 r3 strategy"
  end

  test "B3 — legacy cap with concrete narrowing on OTHER axes still narrows correctly" do
    # A legacy cap that narrowed via behavior/workspace_uri should
    # CONTINUE to narrow post-SPEC; only the missing action axis is
    # tolerated as wildcard.
    legacy =
      %Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: :any,
        workspace_uri: URI.new!("workspace://team-alpha"),
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
      |> Map.delete(:action)

    # Same workspace — match.
    needed_same_ws = %{
      kind: :workspace,
      behavior: Ezagent.Behavior.Workspace,
      action: :create_session,
      instance: URI.new!("workspace://team-alpha"),
      workspace_uri: URI.new!("workspace://team-alpha")
    }

    assert Capability.matches?(legacy, needed_same_ws),
           "legacy cap should still match within its workspace"

    # Different workspace — no match (workspace_uri narrowing holds).
    needed_other_ws = %{
      kind: :workspace,
      behavior: Ezagent.Behavior.Workspace,
      action: :create_session,
      instance: URI.new!("workspace://team-beta"),
      workspace_uri: URI.new!("workspace://team-beta")
    }

    refute Capability.matches?(legacy, needed_other_ws),
           "legacy cap with concrete workspace_uri MUST still narrow on the workspace axis — only the missing `:action` key gets the wildcard treatment"
  end
end
