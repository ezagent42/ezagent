defmodule Ezagent.Identity.OffboardingAtomicityTest do
  @moduledoc """
  task #180 (delete = atomic revocation), codex finding F4 — tombstone
  ATOMICITY invariant tests.

  Pre-fix, `Users.tombstone/3`'s post-commit teardown was best-effort and
  the idempotent retry branch IGNORED cap-clear / outbox / destroy
  failures before returning `{:ok, _}` — a partial revocation reported as
  success. Post-fix every step PROPAGATES: a failed cap-clear / outbox /
  teardown / cascade step yields a retryable `{:error, _}` (the durable
  marker is already committed, so the principal stays fenced), and a
  retry converges to full revocation with no residual capability.

  These tests FAIL if the propagation is removed (the error collapses back
  to a false `{:ok, _}`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Users

  @admin "entity://system/user/admin"

  defp disabled_user(tag, caps \\ []) do
    uri = "entity://team-alpha/user/f4-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, _} = Users.create(uri, "pw", caps)
    {:ok, _} = Users.disable(uri, @admin, "offboarding")
    uri
  end

  describe "F4 — teardown failure propagates (never :ok with a residual)" do
    test "a failed Kind teardown yields a retryable non-success; the retry converges" do
      uri = disabled_user("teardown")

      # Inject a deterministic teardown failure: register the TEST PROCESS
      # as the user's live Kind — `Lifecycle.destroy/2`'s self-destroy guard
      # then refuses the teardown with `:cannot_self_destroy`.
      :ok = Ezagent.KindRegistry.put_new(uri, self())
      on_exit(fn -> Registry.unregister(Ezagent.KindRegistry, uri) end)

      # The tombstone reports FAILURE — never a false success.
      assert {:error, :cannot_self_destroy} = Users.tombstone(uri, @admin, "gone")

      # The durable half IS committed (marker + cap-clear): the principal
      # stays fenced while the operator retries. This is the "retryable
      # non-success state", not a torn success.
      assert Users.deleted?(uri)
      assert Users.get_by_uri(uri).caps == []

      # Remove the failure cause; the idempotent retry converges and
      # re-asserts every step.
      Registry.unregister(Ezagent.KindRegistry, uri)
      assert {:ok, _} = Users.tombstone(uri, @admin, "gone")
      assert Users.deleted?(uri)
      assert Users.get_by_uri(uri).caps == []
      # No residual Kind/snapshot capability survived.
      assert Ezagent.Ecto.KindSnapshot.get(uri) == nil
      assert Ezagent.KindRegistry.lookup(uri) == :error
    end

    test "the idempotent retry itself PROPAGATES a still-failing teardown" do
      uri = disabled_user("retry-propagates")

      # First pass succeeds fully (no failure injected).
      assert {:ok, _} = Users.tombstone(uri, @admin, "gone")
      assert Users.deleted?(uri)

      # Now inject the teardown failure and re-run the RETRY branch: it must
      # propagate, not swallow, the failure.
      :ok = Ezagent.KindRegistry.put_new(uri, self())
      on_exit(fn -> Registry.unregister(Ezagent.KindRegistry, uri) end)

      assert {:error, :cannot_self_destroy} = Users.tombstone(uri, @admin, "gone")

      Registry.unregister(Ezagent.KindRegistry, uri)
      assert {:ok, _} = Users.tombstone(uri, @admin, "gone")
    end

    test "an ACTIVE user still hard-deletes cleanly end-to-end (propagation is not a blanket error)" do
      uri = disabled_user("happy")

      assert {:ok, decoded} = Users.tombstone(uri, @admin, "gone")
      assert decoded.deleted_at != nil
      assert Users.deleted?(uri)
      assert Users.get_by_uri(uri).caps == []
    end
  end
end
