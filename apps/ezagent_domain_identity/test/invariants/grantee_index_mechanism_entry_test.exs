defmodule Ezagent.Invariants.GranteeIndexMechanismEntryTest do
  @moduledoc """
  RATCHET — freeze the caller set of the UNGATED reverse-index read.

  `EntityCaps.GranteeIndex.grantees_of_internal/1..3` deliberately skips the
  `Authority.manages?/3` administrator gate that `grantees_of/3..5` enforces.
  Allen 2026-07-31 sanctioned exactly one shape for that: a MECHANISM computing a
  projection inside its OWN domain over a SINGLE named target (e.g.
  `ActionSet.Session.Membership` deriving a session's roster from the caps held
  toward that session). The entity itself must never read the cap table, and no
  dispatch/transport path may reach this arity — otherwise it becomes a way to
  enumerate anyone's grantees with no witness at all.

  Nothing in the code enforces "mechanism-only" structurally, so this test is the
  enforcement: the set of production files calling it is an explicit allowlist.
  Adding one is a deliberate, reviewed act — not something that drifts in.
  """

  use ExUnit.Case, async: true

  # Repo-relative paths permitted to call the ungated arity. EMPTY until the
  # #1655 P4 consumer (`ActionSet.Session.Membership`) lands — P2 ships the entry
  # + this ratchet together so the gate exists BEFORE the first caller.
  @allowed []

  @call_pattern "grantees_of_internal"

  test "only allowlisted production files call the ungated grantees_of_internal arity" do
    repo_root = repo_root()

    callers =
      Path.wildcard(Path.join(repo_root, "apps/*/lib/**/*.ex"))
      |> Enum.filter(fn path ->
        # The definition site itself is not a caller.
        not String.ends_with?(path, "entity_caps/grantee_index.ex") and
          path |> File.read!() |> String.contains?(@call_pattern)
      end)
      |> Enum.map(&Path.relative_to(&1, repo_root))
      |> Enum.sort()

    assert callers == @allowed, """
    The ungated reverse-index read gained (or lost) a caller.

      expected: #{inspect(@allowed)}
      actual:   #{inspect(callers)}

    `grantees_of_internal/1..3` skips `Authority.manages?/3` on purpose and is
    sanctioned ONLY for a mechanism projecting its own domain over a single
    named target. If this is such a caller, add it to @allowed in this file WITH
    a one-line justification. If it is a dispatch/transport/entity path, use
    `grantees_of/3..5` (which requires a presented management witness) instead.
    """
  end

  defp repo_root do
    Path.expand("../../../..", __DIR__)
  end
end
