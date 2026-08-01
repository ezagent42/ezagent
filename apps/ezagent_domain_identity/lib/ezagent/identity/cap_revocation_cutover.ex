defmodule Ezagent.Identity.CapRevocationCutover do
  @moduledoc """
  Fenced, crash-atomic v2 capability re-mint for the per-grant revocation epoch.

  This module is a prestart maintenance command, never an application child.
  The serving node and every other writer must remain stopped while it runs.
  A transaction-scoped advisory lock plus table locks are a mechanical backstop;
  they do not replace that operational writer-exclusion rule.
  """

  import Ecto.Query

  alias Ezagent.Cap.{Authority, DeliveryOutbox, RevocationEpoch}
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.EntityCaps.Store
  alias Ezagent.Identity.RecipeCapBinding
  alias EzagentCore.Repo

  @advisory_lock_key 2_026_080_100_020
  @test_seams Mix.env() == :test

  @type report :: %{
          holders: non_neg_integer(),
          caps: non_neg_integer(),
          pending_deleted: non_neg_integer(),
          would_be_lost: [map()],
          would_be_added: [map()],
          manifest_hash: String.t()
        }

  @doc """
  Rebuild and activate the per-cap revocation plane in one transaction.

  A non-empty semantic diff is refused unless `:approved_manifest_hash` exactly
  matches the reported hash. `dry_run: true` computes the same locked plan and
  rolls it back without changing any row.
  """
  @spec run(keyword()) ::
          {:ok, report() | %{status: :already_active}}
          | {:dry_run, report()}
          | {:error, term()}
  def run(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    approved_hash = Keyword.get(opts, :approved_manifest_hash)
    dry_run? = Keyword.get(opts, :dry_run, false)

    io.("=== per-cap revocation v2 cutover ===")

    case {Ezagent.Identity.Cutover.status(), RevocationEpoch.status()} do
      {:active, :active} ->
        {:ok, %{status: :already_active}}

      {:active, :inactive} ->
        transact(dry_run?, approved_hash, io)

      {:unknown, _} ->
        {:error, :identity_epoch_unreadable}

      {_, :unknown} ->
        {:error, :cap_revocation_epoch_unreadable}

      {:inactive, _} ->
        {:error, :identity_store_cutover_not_active}
    end
  end

  defp transact(dry_run?, approved_hash, io) do
    Repo.transaction(fn ->
      lock_rebuild_plane!()

      case RevocationEpoch.status() do
        :active ->
          Repo.rollback({:already_active, %{status: :already_active}})

        :unknown ->
          Repo.rollback(:cap_revocation_epoch_unreadable)

        :inactive ->
          plan = build_plan!()
          report = diff_report(plan.old_by_holder, plan.derived_by_holder)

          io.(
            "Plan: #{report.holders} holder(s), #{report.caps} current capability(ies), " <>
              "lost=#{length(report.would_be_lost)}, added=#{length(report.would_be_added)}"
          )

          cond do
            dry_run? ->
              Repo.rollback({:dry_run, report})

            diff?(report) and approved_hash != report.manifest_hash ->
              Repo.rollback({:manifest_required, report})

            true ->
              pending_deleted = apply_plan!(plan)
              :ok = maybe_force_crash_after_wipe()

              case RevocationEpoch.activate_in_txn() do
                :ok ->
                  Map.put(report, :pending_deleted, pending_deleted)

                {:error, reason} ->
                  Repo.rollback({:activation_failed, reason})
              end
          end
      end
    end)
    |> case do
      {:ok, report} ->
        :ok = RevocationEpoch.prime()
        {:ok, report}

      {:error, {:dry_run, report}} ->
        {:dry_run, report}

      {:error, {:already_active, report}} ->
        {:ok, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_rebuild_plane! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@advisory_lock_key])

    Repo.query!("""
    LOCK TABLE identity_caps, kind_snapshots, cap_delivery_outbox, users,
      recipe_cap_bindings, kind_cap_authorities
    IN SHARE ROW EXCLUSIVE MODE
    """)
  end

  defp build_plan! do
    store_rows = Store.cutover_rows_in_txn()
    rows_by_uri = Map.new(store_rows, &{&1.uri, &1})

    holder_uris =
      (Map.keys(rows_by_uri) ++ DeliveryOutbox.pending_absorb_target_uris_in_txn())
      |> Enum.map(&canonical_holder!/1)
      |> Enum.uniq()
      |> Enum.sort()

    old_by_holder =
      Map.new(holder_uris, fn holder_uri ->
        holder = Ezagent.URI.new!(holder_uri)

        case Ezagent.EntityCaps.effective_caps_persisted(holder) do
          {:ok, caps} -> {holder_uri, caps}
          {:error, reason} -> Repo.rollback({:effective_read_failed, holder_uri, reason})
        end
      end)

    reminted_by_holder =
      Map.new(old_by_holder, fn {holder_uri, caps} ->
        receiver = Ezagent.URI.new!(holder_uri)

        reminted =
          Enum.map(caps, fn cap ->
            case Authority.remint_current_in_txn(cap, receiver) do
              {:ok, artifact} -> artifact
              {:error, reason} -> Repo.rollback({:remint_failed, holder_uri, reason})
            end
          end)

        {holder_uri, reminted}
      end)
      |> ensure_admin_self_license!()

    entries = build_store_entries(reminted_by_holder, rows_by_uri)

    derived_by_holder =
      Map.new(entries, fn entry ->
        caps = if entry.identity_status == "active", do: entry.caps, else: []
        {entry.uri, caps}
      end)

    old_by_holder = Map.put_new(old_by_holder, admin_key(), [])

    %{
      old_by_holder: old_by_holder,
      derived_by_holder: derived_by_holder,
      entries: entries
    }
  end

  defp ensure_admin_self_license!(by_holder) do
    admin = Ezagent.URI.user(:system, :admin)
    key = canonical_holder!(admin)
    caps = Map.get(by_holder, key, [])

    if Enum.any?(caps, &(Capability.action_of(&1) == :self_license)) do
      Map.put(by_holder, key, caps)
    else
      {:ok, kind_type} = Ezagent.URI.type(admin)

      requested =
        Capability.cap(
          String.to_existing_atom(kind_type),
          Ezagent.ActionSet.Identity,
          :self_license,
          admin,
          Ezagent.URI.workspace_of(admin)
        )

      case Authority.mint_root_self_license_in_txn(requested, admin) do
        {:ok, license} -> Map.put(by_holder, key, [license | caps])
        {:error, reason} -> Repo.rollback({:admin_self_license_failed, reason})
      end
    end
  end

  defp build_store_entries(reminted_by_holder, rows_by_uri) do
    reminted_by_holder
    |> Enum.map(fn {holder_uri, caps} ->
      row = Map.get(rows_by_uri, holder_uri)
      status = cutover_status(row, holder_uri, caps)

      %{
        uri: holder_uri,
        workspace_uri: row_workspace(row, holder_uri),
        identity_status: status,
        provisioning_receipt: row && row.provisioning_receipt,
        caps: caps
      }
    end)
    |> Enum.sort_by(& &1.uri)
  end

  defp cutover_status(%Store{identity_status: status}, _holder_uri, _caps)
       when status in ["revoked_unprovisioned", "tombstoned"],
       do: status

  defp cutover_status(_row, holder_uri, caps) do
    if Store.has_current_self_license?(caps, holder_uri),
      do: "active",
      else: "revoked_unprovisioned"
  end

  defp row_workspace(%Store{workspace_uri: workspace}, _holder_uri) when is_binary(workspace),
    do: workspace

  defp row_workspace(nil, holder_uri) do
    case holder_uri |> Ezagent.URI.new!() |> Ezagent.Persistence.workspace_uri_for!() do
      %URI{} = workspace -> URI.to_string(workspace)
      workspace when is_binary(workspace) -> workspace
    end
  end

  defp apply_plan!(plan) do
    :ok = Store.replace_all_for_cutover_in_txn(plan.entries)
    :ok = rewrite_snapshots(plan.derived_by_holder)
    rewrite_users(plan.derived_by_holder)
    :ok = RecipeCapBinding.remint_artifacts_in_txn(plan.derived_by_holder)
    pending_deleted = DeliveryOutbox.clear_pending_in_txn()

    case Authority.remint_all_anchors_in_txn() do
      :ok -> pending_deleted
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp rewrite_snapshots(by_holder) do
    from(snapshot in KindSnapshot, order_by: [asc: snapshot.uri], lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn snapshot, :ok ->
      case KindSnapshot.decode_state(snapshot) do
        {:ok, state} ->
          holder_key = canonical_holder_or_original(snapshot.uri)

          state =
            case Map.fetch(by_holder, holder_key) do
              {:ok, caps} -> put_identity_caps(state, caps)
              :error -> Map.delete(state, :identity)
            end

          snapshot
          |> Ecto.Changeset.change(
            state_binary: :erlang.term_to_binary(state, [:deterministic]),
            state: nil,
            updated_at: DateTime.utc_now()
          )
          |> Repo.update()
          |> case do
            {:ok, _updated} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {snapshot.uri, reason}}}
          end

        error ->
          {:halt, {:error, {snapshot.uri, error}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:snapshot_rewrite_failed, reason})
    end
  end

  defp put_identity_caps(state, caps) do
    caps = MapSet.new(caps)

    identity =
      case Map.get(state, :identity) do
        %{state: inner} = slice when is_map(inner) ->
          %{slice | state: Map.put(inner, :caps, caps)}

        %{caps: _} = slice ->
          Map.put(slice, :caps, caps)

        _ ->
          %{caps: caps}
      end

    Map.put(state, :identity, identity)
  end

  defp rewrite_users(by_holder) do
    from(user in Ezagent.Users, lock: "FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn user ->
      caps = Map.get(by_holder, canonical_holder_or_original(user.uri), [])
      encoded = caps |> Enum.map(&Capability.to_map/1) |> Jason.encode!()

      user
      |> Ecto.Changeset.change(caps_json: encoded)
      |> Repo.update!()
    end)
  end

  defp diff_report(old_by_holder, derived_by_holder) do
    old = semantic_index(old_by_holder)
    derived = semantic_index(derived_by_holder)
    old_keys = old |> Map.keys() |> MapSet.new()
    derived_keys = derived |> Map.keys() |> MapSet.new()

    lost =
      old_keys
      |> MapSet.difference(derived_keys)
      |> Enum.sort()
      |> Enum.map(&diff_entry(:lost, &1, Map.fetch!(old, &1)))

    added =
      derived_keys
      |> MapSet.difference(old_keys)
      |> Enum.sort()
      |> Enum.map(&diff_entry(:added, &1, Map.fetch!(derived, &1)))

    manifest_hash =
      :sha256
      |> :crypto.hash(
        :erlang.term_to_binary({Enum.map(lost, & &1.key), Enum.map(added, & &1.key)}, [
          :deterministic
        ])
      )
      |> Base.encode16(case: :lower)

    %{
      holders: map_size(derived_by_holder),
      caps: Enum.sum(Enum.map(derived_by_holder, fn {_holder, caps} -> length(caps) end)),
      pending_deleted: 0,
      would_be_lost: lost,
      would_be_added: added,
      manifest_hash: manifest_hash
    }
  end

  defp semantic_index(by_holder) do
    for {holder_uri, caps} <- by_holder,
        cap <- caps,
        into: %{} do
      key = {holder_uri, Capability.identity_key(cap)}
      {key, cap}
    end
  end

  defp diff_entry(direction, {holder_uri, identity_key} = key, cap) do
    reason =
      if direction == :added and holder_uri == admin_key() and
           Capability.action_of(cap) == :self_license,
         do: :required_admin_self_license,
         else: :semantic_plane_change

    %{
      key: key,
      holder_uri: holder_uri,
      identity_key: identity_key,
      source: :durable_effective,
      reason: reason
    }
  end

  defp diff?(report),
    do: report.would_be_lost != [] or report.would_be_added != []

  defp canonical_holder!(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp canonical_holder!(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> canonical_holder!()

  defp canonical_holder_or_original(uri) do
    canonical_holder!(uri)
  rescue
    _ -> uri
  end

  defp admin_key, do: Ezagent.URI.user(:system, :admin) |> canonical_holder!()

  if @test_seams do
    defp maybe_force_crash_after_wipe do
      if Application.get_env(:ezagent_domain_identity, :cap_revocation_cutover_crash_after_wipe) do
        raise "forced cap revocation cutover crash after wipe"
      end

      :ok
    end
  else
    defp maybe_force_crash_after_wipe, do: :ok
  end
end
