defmodule Ezagent.CapTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Signing}
  alias Ezagent.{Cap, Capability}
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)

    uri =
      Ezagent.URI.new!("entity://team-alpha/agent/cap-unit-#{System.unique_integer([:positive])}")

    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    state = :sys.get_state(pid)
    assert Ezagent.ReadyGate.status(uri) == :ready

    {:ok,
     authority: state.authority,
     pid: pid,
     uri: uri,
     admin: Ezagent.URI.user(:system, :admin),
     grantee: Ezagent.URI.new!("entity://team-alpha/user/cap-unit-grantee")}
  end

  describe "issue/3" do
    test "routes issuance through the target Kind and returns a receiver-bound artifact",
         context do
      before_issue = DateTime.utc_now()

      assert {:ok, artifact} =
               Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

      assert artifact.granted_by == context.admin
      assert artifact.grantee_uri == context.grantee
      assert artifact.instance == context.uri
      assert DateTime.compare(artifact.granted_at, before_issue) in [:eq, :gt]
      assert is_binary(artifact.signature)
      assert artifact.key_id == context.authority.key_id
      assert Authority.verify(context.authority, artifact, context.grantee)
    end

    test "rejects an issuer that has no grant authority on the target Kind", context do
      stranger = Ezagent.URI.new!("entity://team-alpha/user/cap-unit-stranger")

      assert {:error, :missing_cap} =
               Cap.issue({:held_by, stranger}, context.grantee, action_cap(context.uri))
    end

    test "only the canonical admin receives the sealed admin anchor", context do
      impostor = Ezagent.URI.new!("entity://team-alpha/user/admin")

      assert {:error, :canonical_admin_required} =
               Cap.issue({:admin, impostor}, context.grantee, action_cap(context.uri))
    end

    test "requires a concrete target and concrete URI grantee", context do
      wildcard = %{action_cap(context.uri) | instance: :any}

      assert {:error, :concrete_target_required} =
               Cap.issue({:admin, context.admin}, context.grantee, wildcard)

      for invalid_grantee <- [nil, :any] do
        assert_raise FunctionClauseError, fn ->
          Cap.issue({:admin, context.admin}, invalid_grantee, action_cap(context.uri))
        end
      end
    end
  end

  describe "receiver storage boundary" do
    test "validation checks signature and receiver without authorizing an action", context do
      {:ok, artifact} =
        Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

      assert :ok =
               Authority.with_current(context.authority, fn ->
                 Cap.validate_for_current_target(artifact, context.grantee)
               end)

      other = Ezagent.URI.new!("entity://team-alpha/user/cap-unit-other")

      assert {:error, :wrong_grantee} =
               Authority.with_current(context.authority, fn ->
                 Cap.validate_for_current_target(artifact, other)
               end)

      tampered = %{artifact | action: :raise}

      assert {:error, :invalid_cap_signature} =
               Authority.with_current(context.authority, fn ->
                 Cap.validate_for_current_target(tampered, context.grantee)
               end)
    end

    test "validates against durable active public authority while the target is cold",
         context do
      assert {:ok, artifact} =
               Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

      pid = context.pid
      monitor = Process.monitor(pid)
      :ok = GenServer.stop(context.pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      registry_barrier()
      assert :error = Ezagent.KindRegistry.lookup(context.uri)

      generations_before =
        context.uri
        |> Ezagent.URI.stable_key()
        |> Ezagent.Ecto.KindCapAuthority.list()

      assert :ok = Cap.validate_for_current_target(artifact, context.grantee)
      assert :error = Ezagent.KindRegistry.lookup(context.uri)

      assert Ezagent.Ecto.KindCapAuthority.list(Ezagent.URI.stable_key(context.uri)) ==
               generations_before

      wrong_target =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cap-unit-wrong-target-#{System.unique_integer([:positive])}"
        )

      assert {:ok, _authority} = Authority.open(wrong_target, :test)

      assert {:error, :invalid_cap_signature} =
               Cap.validate_for_current_target(
                 %{artifact | instance: wrong_target},
                 context.grantee
               )

      assert {:error, :invalid_cap_signature} =
               Cap.validate_for_current_target(
                 %{artifact | key_id: "kind-g1:wrong-key"},
                 context.grantee
               )

      other = Ezagent.URI.new!("entity://team-alpha/user/cap-unit-other-cold")

      assert {:error, :wrong_grantee} =
               Cap.validate_for_current_target(artifact, other)

      assert :ok = Authority.retire(context.uri)

      assert {:error, :invalid_cap_signature} =
               Cap.validate_for_current_target(artifact, context.grantee)

      assert {:ok, regenerated_authority} =
               Authority.regenesis(context.uri, :test, context.admin)

      refute regenerated_authority.key_id == artifact.key_id

      assert {:error, :invalid_cap_signature} =
               Cap.validate_for_current_target(artifact, context.grantee)
    end

    test "retains only structurally born-signed artifacts for the named receiver", context do
      assert {:ok, signed} =
               Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

      unsigned = %{signed | signature: nil, key_id: nil}
      other = Ezagent.URI.new!("entity://team-alpha/user/cap-unit-other")

      assert Cap.verified_set([signed, unsigned, :junk], context.grantee) == MapSet.new([signed])
      assert Cap.verified_set([signed], other) == MapSet.new()
      assert Cap.verified_set([signed], nil) == MapSet.new()
    end

    test "is structural only; cryptographic authorization remains at the target verifier",
         context do
      assert {:ok, signed} =
               Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

      tampered = %{signed | action: :raise}

      assert Cap.storable_for?(tampered, context.grantee)
      refute Authority.verify(context.authority, tampered, context.grantee)
    end
  end

  test "declarative capabilities remain unsigned sentinels" do
    declared = Capability.cap(:session, Ezagent.ActionSet.Session, :send)

    assert declared.granted_by == :plugin_declared
    assert declared.granted_at == :compile_time
    assert declared.signature == nil
    assert declared.key_id == nil
  end

  test "signing key selectors remain target-authority fingerprints", context do
    assert {:ok, artifact} =
             Cap.issue({:admin, context.admin}, context.grantee, action_cap(context.uri))

    refute artifact.key_id == Signing.key_id(1, Signing.trust_domain(artifact.workspace_uri))
    assert String.starts_with?(artifact.key_id, "kind-g1:")
  end

  defp action_cap(uri) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

  defp registry_barrier do
    for {_id, partition, :worker, [Registry.Partition]} <-
          Supervisor.which_children(Ezagent.KindRegistry) do
      _state = :sys.get_state(partition)
    end

    :ok
  end
end
