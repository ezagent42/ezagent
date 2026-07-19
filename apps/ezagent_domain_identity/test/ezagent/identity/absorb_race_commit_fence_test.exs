defmodule Ezagent.Identity.AbsorbRaceCommitFenceTest do
  @moduledoc """
  task #180 (delete = atomic revocation), codex finding F2 — the absorb
  race: a cap delivery CLAIMED while the target was alive can pass the
  `handle_absorb_cap` deleted-recipient guard pre-tombstone and commit its
  slice post-tombstone (a resurrection of revoked authority, and — for a
  not-yet-destroyed Kind — a snapshot-row rewrite the teardown just
  cleared).

  The fix is a SECOND fence check at SLICE-COMMIT time in
  `Ezagent.Kind.Server` (not only at handler entry): a delivery replay
  (an invocation carrying `:cap_delivery_id`) re-runs the
  `Ezagent.SpawnFence` tombstone check immediately before its slice
  commits, so a mid-flight tombstone aborts the commit.

  These tests FAIL if the commit-time re-check is removed: without it the
  replay below commits the artifact into the fenced principal's slice
  (the exact pre-fix race).

  The scenario uses a test fence flipped mid-flight — the deterministic
  form of "the tombstone landed between handler entry and slice commit"
  (a real tombstone tears the Kind down, so the window cannot be staged
  with a live Kind any other way).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5]

  alias Ezagent.Users

  defp live_user(tag) do
    uri = "entity://team-alpha/user/f2-#{tag}-#{System.unique_integer([:positive])}"
    {:ok, _} = Users.create(uri, "pw", [])
    parsed = Ezagent.URI.new!(uri)
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: parsed, initial_caps: []})
    parsed
  end

  defp register_test_fence(target) do
    target_key = Ezagent.URI.stable_key(target)

    :ok =
      Ezagent.SpawnFence.register(:f2_commit_race, fn
        %URI{} = uri ->
          if Ezagent.URI.stable_key(uri) == target_key do
            {:error, {:principal_tombstoned, uri}}
          else
            :ok
          end
      end)

    on_exit(fn -> Ezagent.SpawnFence.unregister(:f2_commit_race) end)
  end

  test "a delivery replay whose target was tombstoned mid-flight does NOT commit its slice" do
    user_uri = live_user("commit")

    artifact =
      signed_fixture_cap!(user_uri, :user, Ezagent.ActionSet.Identity, :list_caps, user_uri)

    # The tombstone lands AFTER the handler-entry guard would pass (the
    # user is alive + the Kind is live) but BEFORE the slice commits.
    register_test_fence(user_uri)

    replay_inv = %Ezagent.Invocation{
      target: Ezagent.URI.with_action(user_uri, :identity, :absorb_cap),
      mode: :cast,
      args: %{artifact: artifact},
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        reply: {:caller_inbox, self()},
        cap_delivery_producer: :identity_absorb,
        cap_delivery_id: 0,
        cap_delivery_claim_token: "commit-fence-test"
      },
      origin: :trusted_internal
    }

    assert :ok = Ezagent.Invocation.dispatch(replay_inv)

    assert_receive {:ezagent_reply, {:error, {:principal_tombstoned, _}}}, 2_000

    # The slice NEVER committed — nothing stored, in-memory or durable.
    persisted = Ezagent.EntityCaps.load_persisted(user_uri)
    refute Enum.any?(persisted, &(&1 == artifact))

    # CONTROL: the SAME handler on the SAME fenced target, but invoked
    # WITHOUT the delivery machinery (plain `:vm_internal` absorb — no
    # `:cap_delivery_id`, no producer tag), commits fine — the refusal is
    # the commit-time delivery fence, not a blanket absorb denial.
    control_inv = %Ezagent.Invocation{
      replay_inv
      | ctx: %{
          caller: :vm_internal,
          caps: MapSet.new(),
          reply: {:caller_inbox, self()}
        }
    }

    assert :ok = Ezagent.Invocation.dispatch(control_inv)
    assert_receive {:ezagent_reply, {:ok, _}}, 2_000

    assert Enum.any?(Ezagent.EntityCaps.load(user_uri), &(&1 == artifact))
  end

  test "a delivery replay to an ACTIVE (unfenced) target still commits (no blanket denial)" do
    user_uri = live_user("active")

    artifact =
      signed_fixture_cap!(user_uri, :user, Ezagent.ActionSet.Identity, :list_caps, user_uri)

    replay_inv = %Ezagent.Invocation{
      target: Ezagent.URI.with_action(user_uri, :identity, :absorb_cap),
      mode: :cast,
      args: %{artifact: artifact},
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        reply: {:caller_inbox, self()},
        cap_delivery_producer: :identity_absorb,
        cap_delivery_id: 0,
        cap_delivery_claim_token: "commit-fence-active"
      },
      origin: :trusted_internal
    }

    assert :ok = Ezagent.Invocation.dispatch(replay_inv)
    assert_receive {:ezagent_reply, {:ok, _}}, 2_000

    assert Enum.any?(Ezagent.EntityCaps.load(user_uri), &(&1 == artifact))
  end
end
