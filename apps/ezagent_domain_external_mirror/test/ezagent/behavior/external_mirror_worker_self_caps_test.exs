defmodule Ezagent.ActionSet.ExternalMirrorWorkerSelfCapsTest do
  @moduledoc """
  System-principal elimination (north star / Decision #154), 2026-06-19.

  Pins the SELF-AUTHORITY caps the `Ezagent.ActionSet.ExternalMirrorWorker`
  carries inline (in `ctx.caps`) on its two internal self-dispatches, now
  that the `system://worker-publish` principal is GONE.

  These are the `granted_via_ctx_caps?` step-5.5 authorizers; they must
  match the actions they gate, else the worker's publish + subscribe
  dispatches are denied `:unauthorized` (the same crash-loop symptom the
  deleted principal originally fixed). The live behavior is exercised
  end-to-end in `Ezagent.ExternalMirror.WorkerPublishTest`; this is the
  fast invariant that fails the moment a cap shape drifts.

  Per `feedback_completion_requires_invariant_test`.
  """

  use ExUnit.Case, async: true

  test "worker inline authorizers are issued through K.grant, never raw constructors" do
    behavior_source =
      File.read!(
        Path.expand(
          "../../../lib/ezagent/behavior/external_mirror_worker.ex",
          __DIR__
        )
      )

    spawn_source =
      File.read!(
        Path.expand(
          "../../../lib/ezagent/external_mirror/worker_spawn.ex",
          __DIR__
        )
      )

    assert behavior_source =~ "Ezagent.Identity.Grant.issue_cap("
    assert spawn_source =~ "Ezagent.Identity.Grant.issue_cap("
    refute behavior_source =~ "def worker_publish_caps"
    refute behavior_source =~ "def worker_subscribe_caps"
  end
end
