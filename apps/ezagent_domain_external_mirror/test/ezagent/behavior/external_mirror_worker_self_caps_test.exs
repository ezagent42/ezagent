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

  alias Ezagent.Capability
  alias Ezagent.ActionSet.ExternalMirrorWorker

  test "the inline publish cap matches the `required_caps/0[:publish]` gate (self-authority)" do
    self_uri = Ezagent.URI.worker("team-alpha", "em_test")

    [publish_cap] = ExternalMirrorWorker.worker_publish_caps(self_uri)

    needed = ExternalMirrorWorker.required_caps()[:publish]

    assert Capability.matches?(publish_cap, %{
             kind: needed.kind,
             behavior: needed.behavior,
             action: Capability.action_of(needed),
             instance: needed.instance,
             workspace_uri: needed.workspace_uri
           }),
           """
           The worker's inline `:publish` authorizer cap no longer matches the
           `required_caps/0[:publish]` shape step 5.5 derives — the publish
           self-dispatch would be denied `:unauthorized`. Got:
             #{inspect(publish_cap)}
           Needed: #{inspect(needed)}
           """

    # Decision #154: granted_by is the worker entity ITSELF (genuine
    # self-authority), a real accountable entity — never a system:// principal.
    assert publish_cap.granted_by == self_uri
  end

  test "the inline subscribe cap carries the (:session, PublisherSI, :subscribe_from) shape" do
    [subscribe_cap] = ExternalMirrorWorker.worker_subscribe_caps()

    expected =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Publisher.SessionImpl,
        :subscribe_from
      )

    assert Capability.identity_key(subscribe_cap) == Capability.identity_key(expected),
           """
           The worker's inline subscribe authorizer cap drifted from the
           `(:session, PublisherSI, :subscribe_from)` shape CapBAC step 5.5
           checks when the Worker dispatches
           `session://...?action=publisher.subscribe_from` (SPEC §8.1).
           Got: #{inspect(subscribe_cap)}
           """

    # Decision #154: granted_by is a real accountable entity (the genesis
    # admin), not a system:// principal. (The formal {:within_session}
    # session-owner delegation is PR-EM-3 future work.)
    assert match?(%URI{scheme: "entity"}, subscribe_cap.granted_by)
  end
end
