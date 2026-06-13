defmodule EzagentCore.Invariants.NoDefaultWorkspaceSeededTest do
  @moduledoc """
  SPEC v2 PR-F invariant — the `default` workspace is no longer
  boot-seeded.

  This is the completion gate per memory
  `feedback_completion_requires_invariant_test`: PR-F is "done" iff
  this test passes AND would fail if any code path re-introduces a
  boot-time `default` workspace seed.

  ## What this pins

  After SPEC v2 PR-C (#295) deleted the operator-user + `default`
  workspace seeds, only `workspace://system` (hidden) is created at
  boot. PR-F (this PR) is the cleanup sweep that ensures no callsite
  silently re-seeds `default` via:

  - A new `ensure_workspace("default", _)` call in any
    `Application.start/2` callback or `after_boot/0` hook.
  - A `Workspace.Store.create("default", _)` in plugin code.
  - A boot-time helper that hydrates a stale snapshot.

  ## Why this lives in `ezagent_core/test/invariants/`

  The invariant is cross-app (any plugin could re-add the seed), so
  the test reaches across the whole umbrella: it asks
  `Ezagent.Workspace.list_all/0` after a clean DataCase boot and
  asserts no `default` row exists.

  Tests that *create* a `default` workspace as a per-test fixture
  (e.g. `system_workspace_membership_test.exs`) are NOT in conflict —
  this test uses `async: false` + a fresh DataCase sandbox, so it
  sees only the boot-seeded set, not other tests' fixtures.

  ## Scope: 1st-pass cleanup (lib only)

  PR-F 1st pass touches `apps/*/lib/`. Test fixtures + docs that
  still reference `entity://default/user/...` / `session://default/
  default/...` are deferred to a 2nd PR; the URI string literal is
  not a workspace row, so this invariant remains green regardless.
  """
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  test "no `default` workspace row is boot-seeded" do
    # Sanity: the system workspace IS seeded (in :test the chat
    # plugin short-circuits its `ensure_system_workspace/0`, but
    # other tests / fixtures may have hydrated it earlier in the
    # suite). We don't depend on system being present — we only
    # assert that `default` is absent.
    names = Ezagent.Workspace.list_all() |> Enum.map(& &1.name)

    refute "default" in names,
           "expected no boot-seeded `default` workspace after SPEC v2 PR-C #295; " <>
             "found names=#{inspect(names)}. If a new plugin/app seeded `default` at " <>
             "boot, remove the seed and pass workspace explicitly per SPEC v2 §4."
  end
end
