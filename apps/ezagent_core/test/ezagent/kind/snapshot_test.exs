defmodule Ezagent.Kind.SnapshotTest do
  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Kind.Snapshot
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.TestKind

  test "load_or_init for :ephemeral returns fresh slices" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_snap-eph-#{System.unique_integer([:positive])}"
      )

    state = Snapshot.load_or_init(uri, TestKind, %{uri: uri})

    # P1 (socialware substrate): every Kind now composes the `KindBase` base
    # behavior, which materializes the `:kind_base` slice capturing the instance
    # set. With no `:behaviors` spawn arg, KindBase persists the legacy sentinel
    # `nil` (→ full declared list at reload). The universal `Manage` base
    # behavior stays a SET member but is dispatch-only (no materialized slice).
    assert state == %{
             test: %{count: 0, last_msg: nil},
             kind_base: %{state: %{behaviors: nil}, transients: %{}}
           }
  end

  test "load_or_init for :on_change Kind without prior snapshot init_fresh" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-noprior-#{System.unique_integer([:positive])}"
      )

    state = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    # Allen 2026-05-26 — PR #126 originally added ApiKeys to User; the
    # 2026-05-26 flip moved it to Agent Kind. User now has Identity +
    # UserCredentials + UserTokens slices ONLY.
    #
    # cap-signing Stage 6: unsigned init-time self grants are forbidden.
    # Identity starts empty and receives only target-signed grants through
    # the framework-owned issuance path.
    # remediation C-D — the slice is now two-container (state/transients).
    assert %{identity: %{state: %{caps: caps}}} = state

    refute Map.has_key?(state, :api_keys),
           "User Kind no longer holds :api_keys post Allen 2026-05-26 flip"

    assert caps == MapSet.new()
  end

  test "maybe_save no-op for :ephemeral" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/test_snap-eph-#{System.unique_integer([:positive])}"
      )

    assert :ok = Snapshot.maybe_save(uri, TestKind, %{}, %{test: %{count: 1}})
  end

  test "maybe_save no-op for unchanged on_change Kind" do
    state = %{identity: %{caps: MapSet.new()}}

    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-nochange-#{System.unique_integer([:positive])}"
      )

    assert :ok = Snapshot.maybe_save(uri, Ezagent.Entity.User, state, state)
    # No row written
    assert nil == KindSnapshot.get(URI.to_string(uri))
  end

  test "maybe_save emits :written telemetry + writes Repo row when changed" do
    test_pid = self()
    ref = make_ref()
    handler_id = "snap-written-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:ezagent, :persistence, :written],
      fn _e, _m, _meta, _config -> send(test_pid, {ref, :seen}) end,
      nil
    )

    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-written-#{System.unique_integer([:positive])}"
      )

    uri_str = URI.to_string(uri)

    assert :ok =
             Snapshot.maybe_save(uri, Ezagent.Entity.User, %{}, %{identity: %{caps: MapSet.new()}})

    assert_receive {^ref, :seen}, 500
    :telemetry.detach(handler_id)

    row = KindSnapshot.get(uri_str)
    assert row.kind_type == "user"
    assert is_binary(row.state_binary)
    assert {:ok, %{identity: %{caps: %MapSet{}}}} = KindSnapshot.decode_state(row)
  end

  test "load_or_init PRUNES orphan slice keys not declared by the Kind (codex HIGH-2 closure)" do
    # Allen 2026-05-26 — when a Behavior is removed from a Kind's
    # `behaviors/0` (e.g. ApiKeys flipped from User to Agent in this
    # PR), pre-flip snapshots still carry the removed Behavior's
    # slice in `state_binary`. Without pruning, the orphan data
    # survives forever in memory + DB; admin LVs that render raw
    # slices (e.g. AutoDerive) would leak its content (in ApiKeys'
    # case: plaintext keys).
    #
    # Save a synthetic User snapshot carrying the LEGACY `:api_keys`
    # slice content (the pre-flip shape) AND the post-flip slices,
    # then re-load and assert the orphan is gone.
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-orphan-#{System.unique_integer([:positive])}"
      )

    pre_flip_state = %{
      identity: %{caps: MapSet.new()},
      # LEGACY slice — User no longer declares ApiKeys post Allen
      # 2026-05-26 flip; this represents what an old snapshot carried.
      api_keys: %{keys: %{"deepseek" => "sk-LEGACY-LEAKY-KEY"}},
      user_credentials: %{set_password_count: 0},
      user_tokens: %{mint_count: 0, revoke_count: 0}
    }

    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, pre_flip_state)

    loaded = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    refute Map.has_key?(loaded, :api_keys),
           "load_or_init must PRUNE orphan slice keys not declared in " <>
             "Kind.behaviors/0; the legacy :api_keys slice would leak " <>
             "plaintext credentials to AutoDerive LV otherwise. Got: #{inspect(loaded)}"

    # The other slices are still present.
    assert Map.has_key?(loaded, :identity)
    assert Map.has_key?(loaded, :user_credentials)
    assert Map.has_key?(loaded, :user_tokens)

    # Sentinel check — the plaintext key MUST NOT round-trip through
    # the loaded state.
    refute inspect(loaded) =~ "LEAKY-KEY",
           "plaintext from the orphan :api_keys slice leaked into loaded state"
  end

  test "load_or_init restores from DB if snapshot present (round-trip)" do
    uri =
      Ezagent.URI.new!("entity://team-alpha/user/snap-rt-#{System.unique_integer([:positive])}")

    # Legacy unsigned artifacts may still be present in a pre-cutover snapshot,
    # but born-signed rehydration must discard them.
    stored_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{identity: %{caps: stored_caps}})

    loaded = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})
    # PR #126: load_or_init merges any fresh-init slices from new Behaviors
    # onto the loaded state. The saved :identity slice survives; every
    # other Behavior contributes its `init_slice` default.
    #
    # 2026-05-26: PR #356 (HIGH-2) added `Ezagent.ActionSet.UserCredentials`
    # + `Ezagent.ActionSet.UserTokens`, so the merged shape grew. Allen
    # 2026-05-26 ApiKeys-to-Agent flip then REMOVED `:api_keys` from User.
    # Asserting the full structure here keeps the invariant tight —
    # adding a new User-Behavior should force this assertion to be
    # updated alongside.
    # remediation C-D — each slice is now two-container (state/transients).
    # P1 (socialware substrate): the saved snapshot pre-dates KindBase (no
    # `:kind_base` slice), so the reload path SEEDS it with the legacy sentinel
    # `nil` (deploy-safety migration — full declared list, nothing pruned). The
    # universal `Manage` base behavior stays a set member but materializes no
    # slice.
    assert loaded == %{
             identity: %{state: %{caps: %MapSet{}}, transients: %{}},
             user_credentials: %{state: %{set_password_count: 0}, transients: %{}},
             user_tokens: %{state: %{mint_count: 0, revoke_count: 0}, transients: %{}},
             kind_base: %{state: %{behaviors: nil}, transients: %{}}
           }
  end

  test "term_to_binary survives MapSet round-trip (Q1: lossless encoding)" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-mapset-#{System.unique_integer([:positive])}"
      )

    cap =
      signed_fixture_cap!(
        uri,
        :user,
        Ezagent.ActionSet.Identity,
        :list_caps,
        uri
      )

    caps = MapSet.new([cap])

    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{identity: %{caps: caps}})

    # remediation C-D — the slice is now two-container (state/transients).
    %{identity: %{state: %{caps: loaded_caps}}} =
      Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    assert %MapSet{} = loaded_caps
    assert MapSet.equal?(loaded_caps, caps)
  end

  test "snapshot rehydration drops unsigned caps before the identity slice loads" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-verify-#{System.unique_integer([:positive])}"
      )

    valid =
      signed_fixture_cap!(
        uri,
        :user,
        Ezagent.ActionSet.Identity,
        :list_caps,
        uri
      )

    unsigned = Ezagent.Capability.admin_genesis_cap()

    :ok =
      Snapshot.save_now(uri, Ezagent.Entity.User, %{
        identity: %{caps: MapSet.new([valid, unsigned])}
      })

    %{identity: %{state: %{caps: loaded_caps}}} =
      Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    assert MapSet.equal?(loaded_caps, MapSet.new([valid]))
  end

  test "load_or_init merges fresh init with loaded state (Q5: new Behavior path)" do
    # Persist a state that's MISSING a slice the Kind would normally init
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-merge-#{System.unique_integer([:positive])}"
      )

    # Save an empty map (simulates a snapshot from when no Behaviors existed)
    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{})

    # Now load — the merge should make Identity's fresh init appear
    loaded = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})
    # remediation C-D — the slice is now two-container (state/transients).
    assert %{identity: %{state: %{caps: %MapSet{}}}} = loaded
  end

  test "load_or_init FAILS LOUD when a row is PRESENT but unloadable — never resets to fresh (PR-4 blocker #2: empty-over-good wipe)" do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/snap-unloadable-#{System.unique_integer([:positive])}"
      )

    uri_str = URI.to_string(uri)
    caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    # Seed a GOOD snapshot row (stand-in for the live 256KB session snapshot).
    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{identity: %{caps: caps}})
    good_row = KindSnapshot.get(uri_str)
    assert good_row != nil
    good_binary = good_row.state_binary

    # Make it PRESENT-but-unloadable: bump the stored version past the declared
    # version → check_version returns {:error, :snapshot_version_too_new}. This
    # is the cold-boot failure class (version mismatch / decode failure) that
    # previously made load_or_init silently fall back to `fresh`, which
    # Kind.Server.init then persisted EMPTY over the good row (256KB→91b wipe).
    {:ok, _} =
      good_row
      |> Ecto.Changeset.change(version: 999_999)
      |> EzagentCore.Repo.update()

    # FIXED: load_or_init refuses to reset to fresh over a present-but-unloadable
    # row — it fails loud so durable state is never silently destroyed.
    assert_raise RuntimeError, ~r/unloadable/, fn ->
      Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})
    end

    # The good row is untouched — no wipe.
    assert KindSnapshot.get(uri_str).state_binary == good_binary
  end
end
