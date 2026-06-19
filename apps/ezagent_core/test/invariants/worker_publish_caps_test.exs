defmodule Ezagent.Invariants.WorkerPublishCapsTest do
  @moduledoc """
  System-principal elimination (north star / Decision #154), 2026-06-19.

  HISTORY: this test originally pinned the `system://worker-publish`
  principal's two caps (the e2e blocker fix of 2026-05-26). That principal
  is now ELIMINATED — the `Ezagent.Behavior.ExternalMirrorWorker`'s two
  internal self-dispatches (the `publisher.subscribe_from` subscribe + the
  `:publish` self-dispatch) carry their OWN inline authorizer caps in
  `ctx.caps` (with `caller: self_uri`), instead of borrowing an ambient
  system principal.

  This `ezagent_core` test pins the ELIMINATION (core owns the Catalog):

  1. `system://worker-publish` is GONE from the Catalog (the ratchet must
     not regress by re-adding it).
  2. `caps_for!/1` raises for the eliminated principal (the closed Catalog
     no longer mints its ambient caps).

  The REPLACEMENT self-authority cap shapes (`(:external_mirror_worker,
  ExternalMirrorWorker, :publish)` + `(:session, PublisherSI,
  :subscribe_from)`) are pinned in the external_mirror app, where the
  Behavior module is loaded:
  `Ezagent.Behavior.ExternalMirrorWorkerSelfCapsTest`. The live publish +
  subscribe behavior is exercised end-to-end in
  `Ezagent.ExternalMirror.WorkerPublishTest`.

  Per `feedback_completion_requires_invariant_test`: this fails the moment
  the principal is re-introduced.
  """

  use ExUnit.Case, async: true

  @principal "system://worker-publish"

  test "the eliminated `system://worker-publish` principal is GONE from the Catalog" do
    principal_uris = Ezagent.SystemPrincipal.Catalog.uris()

    refute @principal in principal_uris,
           """
           `#{@principal}` reappeared in the Catalog. The north star is to
           ELIMINATE system principals — the ExternalMirrorWorker's internal
           dispatches now carry their own inline authorizer caps (see
           `Ezagent.Behavior.ExternalMirrorWorker.worker_publish_caps/1` +
           `worker_subscribe_caps/0`). Do not re-add the principal.
           """
  end

  test "caps_for!/1 raises for the eliminated principal" do
    assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
      Ezagent.SystemPrincipal.Catalog.caps_for!(@principal)
    end
  end
end
