defmodule Ezagent.Kind.SnapshotTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.Snapshot
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Test.TestKind

  test "load_or_init for :ephemeral returns fresh slices" do
    uri =
      URI.parse("entity://agent/team-alpha/test_snap-eph-#{System.unique_integer([:positive])}")

    state = Snapshot.load_or_init(uri, TestKind, %{uri: uri})

    assert state == %{test: %{count: 0, last_msg: nil}}
  end

  test "load_or_init for :on_change Kind without prior snapshot init_fresh" do
    uri = URI.parse("entity://user/team-alpha/snap-noprior-#{System.unique_integer([:positive])}")
    state = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    # PR #126 added ApiKeys behavior to User → :api_keys slice
    # coexists with :identity. ApiKeys default empty.
    #
    # PR-OWN-3 (caps-data-ownership-v2 SPEC #306) added self-Identity
    # cap provisioning at init — the entity gets a `Behavior.Identity`
    # cap on its own URI so dispatch-path list_caps/has_cap? authorize.
    assert %{api_keys: %{keys: %{}}, identity: %{caps: caps}} = state

    assert MapSet.size(caps) == 1
    [self_cap] = MapSet.to_list(caps)
    assert self_cap.behavior == Ezagent.Behavior.Identity
    assert self_cap.instance == uri
  end

  test "maybe_save no-op for :ephemeral" do
    uri =
      URI.parse("entity://agent/team-alpha/test_snap-eph-#{System.unique_integer([:positive])}")

    assert :ok = Snapshot.maybe_save(uri, TestKind, %{}, %{test: %{count: 1}})
  end

  test "maybe_save no-op for unchanged on_change Kind" do
    state = %{identity: %{caps: MapSet.new()}}

    uri =
      URI.parse("entity://user/team-alpha/snap-nochange-#{System.unique_integer([:positive])}")

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

    uri = URI.parse("entity://user/team-alpha/snap-written-#{System.unique_integer([:positive])}")
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

  test "load_or_init restores from DB if snapshot present (round-trip)" do
    uri = URI.parse("entity://user/team-alpha/snap-rt-#{System.unique_integer([:positive])}")
    caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{identity: %{caps: caps}})

    loaded = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})
    # PR #126: load_or_init merges any fresh-init slices from new Behaviors
    # (here :api_keys was added after the saved snapshot) onto the loaded
    # state. The saved :identity slice survives; :api_keys gets its
    # init_slice default.
    assert loaded == %{identity: %{caps: caps}, api_keys: %{keys: %{}}}
  end

  test "term_to_binary survives MapSet round-trip (Q1: lossless encoding)" do
    uri = URI.parse("entity://user/team-alpha/snap-mapset-#{System.unique_integer([:positive])}")
    caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{identity: %{caps: caps}})

    %{identity: %{caps: loaded_caps}} =
      Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})

    assert %MapSet{} = loaded_caps
    assert MapSet.equal?(loaded_caps, caps)
  end

  test "load_or_init merges fresh init with loaded state (Q5: new Behavior path)" do
    # Persist a state that's MISSING a slice the Kind would normally init
    uri = URI.parse("entity://user/team-alpha/snap-merge-#{System.unique_integer([:positive])}")
    # Save an empty map (simulates a snapshot from when no Behaviors existed)
    :ok = Snapshot.save_now(uri, Ezagent.Entity.User, %{})

    # Now load — the merge should make Identity's fresh init appear
    loaded = Snapshot.load_or_init(uri, Ezagent.Entity.User, %{uri: uri})
    assert %{identity: %{caps: %MapSet{}}} = loaded
  end
end
