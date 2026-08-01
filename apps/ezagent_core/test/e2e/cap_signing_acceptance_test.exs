defmodule Ezagent.E2E.CapSigningAcceptanceTest do
  @moduledoc """
  §F fresh-stack acceptance for per-Kind signing under the reviewed-code
  (Path A) threat model. Every attack is an independent assertion that reaches
  the authorization boundary and leaves the representative handler untouched.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.Ecto.{KindCapAuthority, KindSnapshot}
  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Test.{OnChangeTestKind, TestBehavior, TestKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(admin()) => MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    :ok = Ezagent.BehaviorRegistry.register(OnChangeTestKind, :noop, TestBehavior)
    :ok
  end

  test "forge: unsigned capability is rejected fail-loud" do
    %{uri: uri, pid: pid, presenter: presenter} = start_target("forge")
    forged = unsigned_cap(uri, presenter)

    assert {:error, :missing_cap} = invoke(pid, uri, presenter, [forged])
    assert_unmodified(uri)
  end

  test "tamper: mutating a signed field invalidates the artifact" do
    %{uri: uri, pid: pid, presenter: presenter} = start_target("tamper")
    assert {:ok, signed} = issue_action_cap(uri, presenter)
    tampered = %{signed | granted_at: DateTime.add(signed.granted_at, 1, :second)}

    assert {:error, :missing_cap} = invoke(pid, uri, presenter, [tampered])
    assert_unmodified(uri)
  end

  test "retarget: an A-signed cap is rejected at B" do
    %{uri: uri_a, presenter: presenter} = start_target("retarget-a")
    %{uri: uri_b, pid: pid_b} = start_target("retarget-b", presenter)
    assert {:ok, signed_for_a} = issue_action_cap(uri_a, presenter)

    assert {:error, :missing_cap} =
             invoke(pid_b, uri_b, presenter, [signed_for_a])

    assert_unmodified(uri_b)
  end

  test "stolen cap plus spoofed presenter is rejected at an external edge" do
    attacker = unique_user("attacker")
    victim = unique_user("victim")
    %{uri: uri, pid: pid} = start_target("stolen", attacker)
    assert {:ok, stolen} = issue_action_cap(uri, victim)

    assert {:error, :presenter_mismatch} = invoke(pid, uri, attacker, [stolen])
    assert_unmodified(uri)
  end

  test "unstamped envelope is rejected before capability verification" do
    %{uri: uri, pid: pid, presenter: presenter} = start_target("unstamped")
    assert {:ok, signed} = issue_action_cap(uri, presenter)
    handler_id = "cap-signing-unstamped-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:ezagent, :cap, :verify, :accepted],
          [:ezagent, :cap, :verify, :rejected],
          [:ezagent, :cap, :verify, :non_cap]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:unexpected_verifier, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :unstamped_origin} =
             invoke(pid, uri, presenter, [signed], origin: nil)

    refute_receive {:unexpected_verifier, _, _}
    assert_unmodified(uri)
  end

  test "wrong target key cannot be selected by cap key_id" do
    %{uri: uri_a} = start_target("wrong-key-a")
    %{uri: uri_b, pid: pid_b, presenter: presenter} = start_target("wrong-key-b")
    assert {:ok, pid_a} = Ezagent.KindRegistry.lookup(uri_a)
    authority_a = :sys.get_state(pid_a).authority

    b_shaped_cap = %{unsigned_cap(uri_b, presenter) | grant_id: Ecto.UUID.generate()}
    wrong_key_cap = Authority.sign(authority_a, b_shaped_cap)

    assert wrong_key_cap.instance == uri_b

    assert {:error, :missing_cap} =
             invoke(pid_b, uri_b, presenter, [wrong_key_cap])

    assert_unmodified(uri_b)
  end

  test "issuer impersonation: K.grant rejects a caller without authority on K" do
    %{uri: uri, pid: pid, presenter: presenter} = start_target("issuer")
    grantee = unique_user("issuer-grantee")

    invocation = %Invocation{
      target: Ezagent.URI.with_action(uri, :cap, :grant),
      mode: :call,
      args: %{grantee: grantee, cap: action_cap(uri)},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new(),
        reply: :ignore
      },
      origin: :authenticated_external
    }

    license_holder(presenter, [action_cap(uri)])
    assert {:error, :missing_cap} = GenServer.call(pid, {:ezagent_dispatch, invocation})
    assert_unmodified(uri)
  end

  test "intent binding: validation-time target, action, and grantee are immutable" do
    %{uri: uri, presenter: presenter} = start_target("intent")
    grantee = unique_user("intent-grantee")
    assert {:ok, pid} = Ezagent.KindRegistry.lookup(uri)
    authority = :sys.get_state(pid).authority
    requested = action_cap(uri)
    intent = Grant.freeze(uri, presenter, grantee, requested)

    rewritten = %{
      requested
      | instance: unique_uri("rewritten"),
        action: :raise,
        grantee_uri: presenter
    }

    refute rewritten.action == intent.cap.action
    refute rewritten.instance == intent.target

    issued = Grant.issue(authority, intent)
    assert issued.instance == uri
    assert issued.action == :noop
    assert issued.grantee_uri == grantee
    assert Authority.verify(authority, issued, grantee)
  end

  test "genesis seal and reincarnation reject reuse and never resurrect an old key" do
    uri = unique_uri("genesis")
    admin = admin()

    assert {:ok, first} = Authority.open(uri, :test)
    assert {:ok, anchor} = Authority.anchor(uri)
    assert Authority.verify(first, anchor, admin)

    row = KindCapAuthority.active(Ezagent.URI.stable_key(uri))
    duplicate_attrs = row |> Map.from_struct() |> Map.delete(:__meta__)
    assert {:error, duplicate_changeset} = KindCapAuthority.insert(duplicate_attrs)
    refute duplicate_changeset.valid?

    assert :ok = Authority.retire(uri)
    assert {:error, :regenesis_required} = Authority.open(uri, :test)

    assert {:error, :cap_context_required} =
             Authority.regenesis(uri, :test, unique_user("not-admin"))

    assert {:error, :cap_context_required} = Authority.regenesis(uri, :test, admin)
    assert {:ok, second} = Authority.regenesis(uri, :test)
    assert second.generation == first.generation + 1
    refute second.key_id == first.key_id
    refute Authority.verify(second, anchor, admin)

    assert [old, current] = KindCapAuthority.list(Ezagent.URI.stable_key(uri))
    refute old.active
    assert old.sealed
    assert current.active
    assert current.sealed
  end

  test "key egress: slices, snapshot, event, and admin listing expose no key" do
    presenter = unique_user("egress")
    uri = unique_uri("egress")
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({OnChangeTestKind, %{uri: uri}})
    assert :ok = await_ready(uri)

    server_state = :sys.get_state(pid)
    private_key = server_state.authority.private_key
    refute contains_binary?(server_state.state, private_key)

    assert {:ok, normalized_slice} = Ezagent.Kind.read(uri, :test, spawn: :never)
    refute contains_binary?(normalized_slice, private_key)

    assert {:ok, raw_slice} = Ezagent.Kind.SliceAccess.get_raw_slice(uri, :test)
    refute contains_binary?(raw_slice, private_key)

    assert {:ok, runtime_view} = Ezagent.Kind.runtime_view(uri)
    refute Map.has_key?(runtime_view, :authority)
    refute contains_binary?(runtime_view, private_key)

    assert %KindSnapshot{} = snapshot = KindSnapshot.get(URI.to_string(uri))
    refute contains_binary?(snapshot.state_binary, private_key)

    assert {:ok, admin_listing} = EzagentDomainUi.AutoDerive.instance_detail(uri)
    refute contains_binary?(admin_listing, private_key)

    assert :ok = Ezagent.SliceChange.subscribe_unverified(uri)
    assert {:ok, signed} = issue_action_cap(uri, presenter)
    assert {:ok, %{echoed: "event"}} = invoke(pid, uri, presenter, [signed], message: "event")
    assert_receive {:slice_changed, event}, 500
    refute contains_binary?(event, private_key)
  end

  test "legit: a K.grant-minted cap is accepted for its authenticated grantee" do
    %{uri: uri, pid: pid, presenter: grantee} = start_target("legit")
    assert {:ok, signed} = issue_action_cap(uri, grantee)
    assert signed.grantee_uri == grantee
    assert is_binary(signed.signature)

    assert {:ok, %{echoed: "accepted"}} =
             invoke(pid, uri, grantee, [signed], message: "accepted")

    assert {:ok, %{count: 1, last_msg: "accepted"}} = Ezagent.Kind.read(uri, :test, spawn: :never)
  end

  defp start_target(suffix, presenter \\ nil) do
    uri = unique_uri(suffix)
    presenter = presenter || unique_user(suffix)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)
    %{uri: uri, pid: pid, presenter: presenter}
  end

  defp issue_action_cap(uri, presenter) do
    Ezagent.Cap.issue({:admin, admin()}, presenter, action_cap(uri))
  end

  defp invoke(pid, uri, presenter, caps, opts \\ []) do
    license_holder(presenter, caps)

    invocation = %Invocation{
      target: Ezagent.URI.with_action(uri, :test, :noop),
      mode: :call,
      args: %{msg: Keyword.get(opts, :message, "blocked")},
      ctx: %{
        caller: presenter,
        authenticated_principal: presenter,
        caps: MapSet.new(caps),
        reply: :ignore
      },
      origin: Keyword.get(opts, :origin, :authenticated_external)
    }

    GenServer.call(pid, {:ezagent_dispatch, invocation})
  end

  defp license_holder(presenter, caps) do
    by_holder =
      Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      Map.put(by_holder, Ezagent.URI.stable_key(presenter), MapSet.new(caps))
    )
  end

  defp unsigned_cap(uri, presenter) do
    %{
      action_cap(uri)
      | granted_by: admin(),
        granted_at: DateTime.utc_now(),
        grantee_uri: presenter
    }
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

  defp assert_unmodified(uri) do
    assert {:ok, %{count: 0, last_msg: nil}} = Ezagent.Kind.read(uri, :test, spawn: :never)
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/cap-signing-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/cap-signing-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp contains_binary?(term, needle),
    do: term |> :erlang.term_to_binary() |> contains_binary?(needle)

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
