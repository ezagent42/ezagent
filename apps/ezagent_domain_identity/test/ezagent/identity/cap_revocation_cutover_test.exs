defmodule Ezagent.Identity.CapRevocationCutoverTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.{Authority, Delivery, RevocationEpoch, RevocationLedger}
  alias Ezagent.Capability
  alias Ezagent.Ecto.{CapRevocationEpoch, KindSnapshot}
  alias Ezagent.IdentityCaps.Store
  alias Ezagent.Identity.{CapRevocationCutover, RecipeCapBinding}
  alias EzagentCore.Repo

  setup do
    previous_identity =
      Application.get_env(:ezagent_domain_identity, :identity_cutover_active_override)

    previous_cap = Application.get_env(:ezagent_core, :cap_revocation_epoch_override)

    Application.put_env(:ezagent_domain_identity, :identity_cutover_active_override, true)
    Application.put_env(:ezagent_core, :cap_revocation_epoch_override, :inactive)
    Application.delete_env(:ezagent_domain_identity, :cap_revocation_cutover_crash_after_wipe)
    Repo.delete_all(CapRevocationEpoch)

    on_exit(fn ->
      restore_env(:ezagent_domain_identity, :identity_cutover_active_override, previous_identity)
      restore_env(:ezagent_core, :cap_revocation_epoch_override, previous_cap)
      Application.delete_env(:ezagent_domain_identity, :cap_revocation_cutover_crash_after_wipe)
    end)

    :ok
  end

  test "atomically re-mints Store and projections, includes pending-only holders, and activates" do
    user = user_uri("durable")
    user_license = v1_self_license(user)
    user_cap = v1_action_cap(user, session_uri("user-target"), :send)
    assert {:ok, _user} = Ezagent.Users.create(user, nil, [])
    assert :ok = Store.persist(user, [user_license, user_cap])
    write_user_caps!(user, [user_license, user_cap])

    pending_holder = agent_uri("pending-only")
    pending_license = v1_self_license(pending_holder)
    pending_cap = v1_action_cap(pending_holder, session_uri("pending-target"), :join)
    write_snapshot!(pending_holder, [pending_license])
    assert :ok = Ezagent.Identity.absorb_cap(pending_holder, pending_cap)
    assert pending_delivery?(pending_holder)
    refute Store.has_row?(pending_holder)

    binding_holder = agent_uri("recipe-binding")
    binding_license = v1_self_license(binding_holder)
    binding_cap = v1_agent_cap(binding_holder)
    assert :ok = Store.persist(binding_holder, [binding_license, binding_cap])
    insert_recipe_binding!(binding_holder, binding_cap)

    {:ok, old_anchor} = Authority.anchor(pending_holder)

    assert {:dry_run, rehearsal} =
             CapRevocationCutover.run(dry_run: true, io: quiet())

    assert {:ok, report} =
             CapRevocationCutover.run(
               approved_manifest_hash: rehearsal.manifest_hash,
               io: quiet()
             )

    assert report.pending_deleted >= 1
    assert Repo.get(CapRevocationEpoch, "per_cap")

    assert Enum.any?(Store.load(Ezagent.URI.user(:system, :admin)), fn cap ->
             Capability.action_of(cap) == :self_license and cap.signing_version == 2
           end)

    reminted_by_holder =
      for {holder, old_caps} <- [
            {user, [user_license, user_cap]},
            {pending_holder, [pending_license, pending_cap]}
          ],
          into: %{} do
        reminted = Store.load(holder)
        assert identities(reminted) == identities(old_caps)
        assert Enum.all?(reminted, &(&1.signing_version == 2 and is_binary(&1.grant_id)))

        old_ids = old_caps |> Enum.map(& &1.grant_id) |> Enum.reject(&is_nil/1) |> MapSet.new()
        new_ids = reminted |> Enum.map(& &1.grant_id) |> MapSet.new()
        assert MapSet.disjoint?(old_ids, new_ids)
        {URI.to_string(holder), reminted}
      end

    Application.delete_env(:ezagent_core, :cap_revocation_epoch_override)
    assert RevocationEpoch.status() == :active
    refute Authority.verify_against_current(user_license, user, user)

    reminted_user_license =
      reminted_by_holder
      |> Map.fetch!(URI.to_string(user))
      |> Enum.find(&(Capability.action_of(&1) == :self_license))

    assert Authority.verify_against_current(reminted_user_license, user, user)

    assert Enum.all?(Ezagent.Users.get_by_uri(user).caps, &(&1.signing_version == 2))

    snapshot = Repo.get!(KindSnapshot, URI.to_string(pending_holder))
    assert {:ok, %{identity: identity}} = KindSnapshot.decode_state(snapshot)
    assert Enum.all?(slice_caps(identity), &(&1.signing_version == 2))

    refute pending_delivery?(pending_holder)

    assert {:ok, %{caps: [reminted_binding]}} = RecipeCapBinding.fetch(binding_holder)
    assert reminted_binding.signing_version == 2
    assert Capability.identity_key(reminted_binding) == Capability.identity_key(binding_cap)

    {:ok, new_anchor} = Authority.anchor(pending_holder)
    assert new_anchor.signing_version == 2
    assert new_anchor.grant_id != old_anchor.grant_id
  end

  test "a crash after the destructive rewrite rolls back the entire plane and epoch" do
    holder = user_uri("crash")
    old_caps = [v1_self_license(holder), v1_action_cap(holder, session_uri("crash"), :send)]
    assert {:ok, _user} = Ezagent.Users.create(holder, nil, [])
    assert :ok = Store.persist(holder, old_caps)
    write_user_caps!(holder, old_caps)

    assert {:dry_run, rehearsal} = CapRevocationCutover.run(dry_run: true, io: quiet())

    Application.put_env(
      :ezagent_domain_identity,
      :cap_revocation_cutover_crash_after_wipe,
      true
    )

    assert_raise RuntimeError, ~r/forced cap revocation cutover crash/, fn ->
      CapRevocationCutover.run(
        approved_manifest_hash: rehearsal.manifest_hash,
        io: quiet()
      )
    end

    assert Repo.get(CapRevocationEpoch, "per_cap") == nil
    assert Store.load(holder) == old_caps
    assert Ezagent.Users.get_by_uri(holder).caps == old_caps
  end

  test "a revoked v2 grant is not resurrected by the rebuild or a cold durable read" do
    holder = user_uri("revoked")
    license = v1_self_license(holder)
    revoked = v2_action_cap(holder, session_uri("revoked"), :send)
    assert {:ok, _user} = Ezagent.Users.create(holder, nil, [])
    assert :ok = Store.persist(holder, [license, revoked])
    write_user_caps!(holder, [license, revoked])
    assert :ok = mark_revoked(holder, revoked)

    assert {:dry_run, rehearsal} = CapRevocationCutover.run(dry_run: true, io: quiet())

    assert {:ok, _report} =
             CapRevocationCutover.run(
               approved_manifest_hash: rehearsal.manifest_hash,
               io: quiet()
             )

    Application.delete_env(:ezagent_core, :cap_revocation_epoch_override)
    assert RevocationEpoch.status() == :active

    refute Capability.identity_key(revoked) in identities(Store.load(holder))

    refute Capability.identity_key(revoked) in identities(
             Ezagent.IdentityCaps.load_persisted(holder)
           )
  end

  test "a bidirectional semantic diff refuses activation without the reviewed hash" do
    admin = Ezagent.URI.user(:system, :admin)
    admin_key = URI.to_string(admin)
    Repo.delete_all(from(row in Store, where: row.uri == ^admin_key))
    Repo.delete_all(from(snapshot in KindSnapshot, where: snapshot.uri == ^admin_key))

    Repo.update_all(from(user in Ezagent.Users, where: user.uri == ^admin_key),
      set: [caps_json: "[]"]
    )

    assert {:dry_run, report} = CapRevocationCutover.run(dry_run: true, io: quiet())
    assert Enum.any?(report.would_be_added, &(&1.reason == :required_admin_self_license))

    assert {:error, {:manifest_required, refused}} =
             CapRevocationCutover.run(io: quiet())

    assert refused.manifest_hash == report.manifest_hash
    assert Repo.get(CapRevocationEpoch, "per_cap") == nil
    refute Store.has_row?(admin)
  end

  test "the one-shot is release/mix prestart wiring, never an application child" do
    root = Path.expand("../../../../..", __DIR__)
    release = File.read!(Path.join(root, "apps/ezagent_core/lib/ezagent_core/release.ex"))

    mix_task =
      File.read!(
        Path.join(
          root,
          "apps/ezagent_domain_identity/lib/mix/tasks/ezagent.cap_revocation.cutover.ex"
        )
      )

    identity_app =
      File.read!(
        Path.join(
          root,
          "apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex"
        )
      )

    web_app = File.read!(Path.join(root, "apps/ezagent_web/lib/ezagent_web/application.ex"))

    assert release =~ "@cap_revocation_cutover Ezagent.Identity.CapRevocationCutover"
    assert release =~ "def cap_revocation_cutover(opts"
    assert mix_task =~ "CapRevocationCutover.run(opts)"
    refute identity_app =~ "CapRevocationCutover"
    refute web_app =~ "CapRevocationCutover"
  end

  defp v1_self_license(holder) do
    {:ok, type} = Ezagent.URI.type(holder)
    kind = String.to_existing_atom(type)
    {:ok, authority} = Authority.open(holder, kind)

    %Capability{
      kind: kind,
      behavior: Ezagent.ActionSet.Identity,
      action: :self_license,
      instance: holder,
      workspace_uri: Ezagent.URI.workspace_of(holder),
      granted_by: holder,
      granted_at: DateTime.utc_now(),
      grantee_uri: holder,
      signing_version: 1,
      grant_id: nil
    }
    |> then(&Authority.sign(authority, &1))
  end

  defp v1_action_cap(holder, target, action) do
    {:ok, authority} = Authority.open(target, :session)

    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: target,
      workspace_uri: Ezagent.URI.workspace_of(target),
      granted_by: Ezagent.URI.user(:system, :admin),
      granted_at: DateTime.utc_now(),
      grantee_uri: holder,
      signing_version: 1,
      grant_id: nil
    }
    |> then(&Authority.sign(authority, &1))
  end

  defp v2_action_cap(holder, target, action) do
    v1_action_cap(holder, target, action)
    |> Map.put(:signing_version, 2)
    |> Map.put(:grant_id, Ecto.UUID.generate())
    |> Map.put(:signature, nil)
    |> then(fn cap ->
      {:ok, authority} = Authority.open(target, :session)
      Authority.sign(authority, cap)
    end)
  end

  defp v1_agent_cap(holder) do
    {:ok, authority} = Authority.open(holder, :agent)

    %Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.IdentityAdmin,
      action: :store_cap,
      instance: holder,
      workspace_uri: Ezagent.URI.workspace_of(holder),
      granted_by: Ezagent.URI.user(:system, :admin),
      granted_at: DateTime.utc_now(),
      grantee_uri: holder,
      signing_version: 1,
      grant_id: nil
    }
    |> then(&Authority.sign(authority, &1))
  end

  defp insert_recipe_binding!(holder, cap) do
    now = DateTime.utc_now()

    %RecipeCapBinding{}
    |> Ecto.Changeset.change(%{
      agent_uri: URI.to_string(holder),
      workspace_uri: holder |> Ezagent.URI.workspace_of() |> URI.to_string(),
      recipe_name: "p2-cutover-test",
      issuer_uri: Ezagent.URI.user(:system, :admin) |> URI.to_string(),
      artifacts: %{"caps" => [Capability.to_map(cap)]},
      content_hash: "pre-cutover-v1",
      version: 1,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp write_user_caps!(holder, caps) do
    encoded = caps |> Enum.map(&Capability.to_map/1) |> Jason.encode!()

    from(user in Ezagent.Users, where: user.uri == ^URI.to_string(holder))
    |> Repo.update_all(set: [caps_json: encoded])
  end

  defp write_snapshot!(holder, caps) do
    workspace = holder |> Ezagent.URI.workspace_of() |> URI.to_string()

    %KindSnapshot{}
    |> Ecto.Changeset.change(%{
      uri: URI.to_string(holder),
      kind_type: "agent",
      state_binary: :erlang.term_to_binary(%{identity: %{caps: MapSet.new(caps)}}),
      version: 1,
      workspace_uri: workspace,
      ever_created: true,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp mark_revoked(holder, cap) do
    attrs = %{
      grant_id: cap.grant_id,
      workspace_uri: holder |> Ezagent.URI.workspace_of() |> Ezagent.URI.stable_key(),
      holder_uri: Ezagent.URI.stable_key(holder),
      cap_identity_key:
        :crypto.hash(:sha256, :erlang.term_to_binary(Capability.identity_key(cap))),
      revoked_at: DateTime.utc_now(),
      target_uri: Ezagent.URI.stable_key(cap.instance),
      key_id: cap.key_id
    }

    case RevocationLedger.mark(attrs) do
      {:ok, _marker} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending_delivery?(holder) do
    Repo.exists?(
      from(delivery in Delivery,
        where:
          delivery.target_uri == ^URI.to_string(holder) and delivery.status == :pending and
            delivery.op == :absorb_cap
      )
    )
  end

  defp identities(caps), do: caps |> Enum.map(&Capability.identity_key/1) |> MapSet.new()
  defp slice_caps(%{state: state}) when is_map(state), do: slice_caps(state)
  defp slice_caps(%{caps: caps}), do: Enum.to_list(caps)
  defp quiet, do: fn _message -> :ok end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp user_uri(suffix),
    do: URI.new!("entity://p2-cutover/user/#{suffix}-#{System.unique_integer([:positive])}")

  defp agent_uri(suffix),
    do: URI.new!("entity://p2-cutover/agent/#{suffix}-#{System.unique_integer([:positive])}")

  defp session_uri(suffix),
    do: URI.new!("session://p2-cutover/default/#{suffix}-#{System.unique_integer([:positive])}")
end
