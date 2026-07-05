defmodule Ezagent.Integration.LoaderOwnershipUnmaskTest do
  @moduledoc """
  #108 regression guard for the `Loader.load_all/0` OwnershipError unmask.

  ## What it pins (and what it does NOT claim)

  This is NOT a reproduction of the CI flake's timing race. That race
  (the Ecto SQL Sandbox pool reverting to `:manual` under the full concurrent
  ubuntu umbrella) is not reproducible on a quiet developer box — the same seed
  is red on the runner and green on macOS (diagnosis §3). What IS reproducible,
  deterministically and OS-independently, is the *trap that hides it*: when a
  process has NO live sandbox owner (no ownership, no `$callers` chain to an
  owner), `Workspace.Store.list_all/0` raises `DBConnection.OwnershipError`, and
  the production `load_all/0` rescue swallows it into a silent `[]`. Downstream,
  that empty result surfaces as the misleading "workspace never appeared with
  children" assertion — the symptom that has masqueraded as a flake on every PR.

  The fix unmasks that rescue in `:test` so a broken sandbox connection FAILS
  LOUD (re-raises the OwnershipError) instead of returning a silent `[]`. This
  test forces the adverse condition and asserts the loud behavior:

  - on `origin/main`: `load_all/0` swallows the OwnershipError → returns `[]`.
  - with the fix: `load_all/0` re-raises → the real cause names itself.

  Making the swallow loud is the durable cure for the *class*: multiple distinct
  silent-`[]` paths (this rescue, a reverted-sandbox dispatch, the unsealed
  flavor-registry gate) all collapse into the same indistinguishable symptom; an
  unmasked rescue ensures the next occurrence is diagnosable rather than silent.

  ## Why this test does NOT touch global sandbox mode (#108 residual-1)

  A prior version of this test flipped `Sandbox.mode(Repo, :manual)`, which is
  BEAM-GLOBAL. Under the full umbrella that flip could revert the pool out from
  under a *sibling* test's globally-supervised Kind (which reaches the DB only
  via shared mode, being outside the owner's `$callers`) — making this test the
  root SOURCE of `DBConnection.OwnershipError` flakes elsewhere (spawn-side
  PluginIsolation, and `MentionFailedTest`).

  The production condition is: *a specific process — a globally-supervised Kind,
  outside `$callers` — has no connection*. We reproduce EXACTLY that, scoped to
  a single pid instead of stamping the whole BEAM: run `load_all/0` inside a
  raw-spawned process that has no sandbox ownership. Under `async: true` the pool
  is in per-connection `:manual` mode (test_helper baseline; never shared), so an
  un-owned process deterministically raises `OwnershipError` at checkout — while
  the global mode is never mutated and no sibling can be affected.
  """

  use EzagentCore.DataCase, async: true

  alias Ezagent.Workspace

  test "load_all/0 re-raises an OwnershipError in :test instead of silently swallowing it to []" do
    # `load_all/0` short-circuits to `[]` when the AgentFlavorRegistry is not yet
    # sealed (a legitimate composition gate when the cc/codex flavor plugins are
    # absent, as in the standalone workspace-app run). Seal it (from the owned
    # test process) so the raw-spawned reader reaches the rescue under test
    # rather than the seal gate. `seal!/0` is idempotent and its state lives in
    # the AgentFlavorRegistry (ETS/GenServer), not the DB.
    if Code.ensure_loaded?(Ezagent.AgentFlavorRegistry) and
         function_exported?(Ezagent.AgentFlavorRegistry, :seal!, 0) do
      Ezagent.AgentFlavorRegistry.seal!()
    end

    test_pid = self()

    # Force the adverse condition the CI race produces non-deterministically:
    # a process with no live sandbox owner. `Store.list_all/0` (invoked by
    # `load_all/0`) then raises `DBConnection.OwnershipError` at checkout.
    #
    # This MUST be a raw `Kernel.spawn` — NOT `Task.async`/`GenServer`. Those set
    # `$callers` = [test_pid, ...], and this test process IS allowed onto its
    # DataCase owner, so an inheriting child would find the owner via `$callers`
    # and NEVER raise — the assertion would silently false-pass. A raw spawn sets
    # no `$callers`, so the ownership lookup finds nothing → raises. (Do not
    # "refactor" this into a Task.)
    spawn(fn ->
      result =
        try do
          _ = Workspace.Loader.load_all()
          {:no_raise, nil}
        rescue
          e -> {:raised, e.__struct__}
        end

      send(test_pid, {:load_all_result, result})
    end)

    assert_receive {:load_all_result, {:raised, DBConnection.OwnershipError}}, 5_000
  end
end
