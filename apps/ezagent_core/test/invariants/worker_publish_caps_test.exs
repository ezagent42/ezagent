defmodule Ezagent.Invariants.WorkerPublishCapsTest do
  @moduledoc """
  2026-05-26 (Allen e2e blocker): pins the cap shape needed by
  `Ezagent.Behavior.ExternalMirrorWorker.subscribe_to_session_publisher/2`.

  When a Feishu (or any external_mirror) binding is created, a Worker
  Kind is spawned and immediately tries to subscribe to its bound
  session's Publisher via:

      session://<class>/<workspace>/<name>?action=publisher.subscribe_from

  Per SPEC §8.1 the worker uses the `system://worker-publish` system
  principal's caps for this internal dispatch. Without a `(:session,
  Publisher.SessionImpl, :subscribe_from)` cap in that principal,
  CapBAC step 5.5 denies the worker and outbound external_mirror
  delivery never works — exactly the symptom main-agent reproduced in
  the Feishu binding e2e (2026-05-26 03:09Z, target_id
  `oc_83a4f1ff0bf627ffe26aa60647e5b04a`).

  This test pins:

  1. The `system://worker-publish` principal exists in
     `Ezagent.SystemPrincipal.Catalog.principals/0`.
  2. Its caps include the `(:session, PublisherSI, :subscribe_from)`
     shape (the actual gate the worker needs).
  3. Its caps also still include the `(:external_mirror_worker,
     ExternalMirrorWorker, :publish)` shape (the worker's own outbound
     dispatch — pre-existing).

  Per `feedback_completion_requires_invariant_test`: deleting the
  subscribe_from cap or renaming the action breaks this test before
  the bug reaches production.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Capability

  @principal "system://worker-publish"

  test "principal exists in the Catalog" do
    principal_uris = Ezagent.SystemPrincipal.Catalog.uris()

    assert @principal in principal_uris,
           """
           The Catalog must declare `#{@principal}`. The
           ExternalMirrorWorker's internal dispatches run under this
           principal — deleting it breaks every outbound binding.
           """
  end

  test "worker-publish includes (:session, PublisherSI, :subscribe_from) — outbound subscription gate" do
    caps = Ezagent.SystemPrincipal.caps(@principal)

    needed_cap =
      Capability.cap(
        :session,
        Ezagent.Behavior.Publisher.SessionImpl,
        :subscribe_from
      )

    assert MapSet.member?(caps, needed_cap),
           """
           `#{@principal}` is missing the cap

             #{inspect(needed_cap)}

           This is the cap CapBAC step 5.5 checks when the Worker
           dispatches `session://...?action=publisher.subscribe_from`
           (SPEC §8.1). Without it, every external_mirror binding
           crash-loops on `:unauthorized` and no outbound event ever
           reaches Feishu / Slack / any adapter.

           Hold caps in this principal:
           #{inspect(MapSet.to_list(caps), pretty: true, limit: :infinity)}
           """
  end

  test "worker-publish includes (:external_mirror_worker, ExternalMirrorWorker, :publish) — worker's own publish action" do
    caps = Ezagent.SystemPrincipal.caps(@principal)

    expected =
      Capability.cap(
        :external_mirror_worker,
        Ezagent.Behavior.ExternalMirrorWorker,
        :publish
      )

    assert MapSet.member?(caps, expected),
           "`#{@principal}` lost the pre-existing `:publish` cap; this gates Worker → self publish-event dispatch."
  end
end
