defmodule Ezagent.Integration.LoaderOwnershipUnmaskTest do
  @moduledoc """
  #108 regression guard for the `Loader.load_all/0` OwnershipError unmask.

  ## What it pins (and what it does NOT claim)

  This is NOT a reproduction of the CI flake's timing race. That race
  (the Ecto SQL Sandbox pool reverting to `:manual` under the full concurrent
  ubuntu umbrella) is not reproducible on a quiet developer box — the same seed
  is red on the runner and green on macOS (diagnosis §3). What IS reproducible,
  deterministically and OS-independently, is the *trap that hides it*: when the
  sandbox pool is in `:manual`, `Workspace.Store.list_all/0` raises
  `DBConnection.OwnershipError`, and the production `load_all/0` rescue swallows
  it into a silent `[]`. Downstream, that empty result surfaces as the
  misleading "workspace never appeared with children" assertion — the symptom
  that has masqueraded as a flake on every PR.

  The fix unmasks that rescue in `:test` so a broken sandbox connection FAILS
  LOUD (re-raises the OwnershipError) instead of returning a silent `[]`. This
  test forces the adverse pool state and asserts the loud behavior:

  - on `origin/main`: `load_all/0` swallows the OwnershipError → returns `[]`.
  - with the fix: `load_all/0` re-raises → the real cause names itself.

  Making the swallow loud is the durable cure for the *class*: multiple distinct
  silent-`[]` paths (this rescue, a reverted-sandbox dispatch, the unsealed
  flavor-registry gate) all collapse into the same indistinguishable symptom; an
  unmasked rescue ensures the next occurrence is diagnosable rather than silent.
  """

  use EzagentCore.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ezagent.Workspace

  test "load_all/0 re-raises an OwnershipError in :test instead of silently swallowing it to []" do
    # Persist a workspace so list_all/0 has a row to read (and so a silent `[]`
    # would be observably WRONG — the row exists, the connection is what's gone).
    workspace_name = "unmask-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(workspace_name, %{})

    # `load_all/0` short-circuits to `[]` when the AgentFlavorRegistry is not yet
    # sealed (a legitimate composition gate when the cc/codex flavor plugins are
    # absent, as in the standalone workspace-app run). Seal it so the test
    # reaches the rescue under test rather than the seal gate. `seal!/0` is
    # idempotent.
    if Code.ensure_loaded?(Ezagent.AgentFlavorRegistry) and
         function_exported?(Ezagent.AgentFlavorRegistry, :seal!, 0) do
      Ezagent.AgentFlavorRegistry.seal!()
    end

    # Force the adverse condition the CI race produces non-deterministically:
    # a pool with no live owner for this process. `list_all/0` then raises
    # DBConnection.OwnershipError from within `load_all/0`.
    #
    # `Sandbox.mode/2` is BEAM-GLOBAL, so flipping it to `:manual` here would
    # leak into any concurrent `async: true` test in this BEAM. Restore the
    # DataCase shared owner immediately after the assertion AND defensively in
    # `on_exit` so the window is as small as possible and the BEAM is never left
    # in `:manual`. (This suite is `async: false`, so it does not run alongside
    # other `async: false` tests; the restore covers the `async: true` overlap.)
    restore_shared = fn ->
      _ = Sandbox.checkout(EzagentCore.Repo)
      Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    end

    on_exit(restore_shared)

    Sandbox.mode(EzagentCore.Repo, :manual)

    try do
      # With the fix, the rescue is unmasked in :test → load_all re-raises.
      # On origin/main, the rescue swallows it and returns [] (no raise).
      assert_raise DBConnection.OwnershipError, fn ->
        Workspace.Loader.load_all()
      end
    after
      restore_shared.()
    end
  end
end
