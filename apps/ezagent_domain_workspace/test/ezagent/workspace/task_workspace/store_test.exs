defmodule Ezagent.Workspace.TaskWorkspace.StoreTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.TaskWorkspace.{Provision, Store}

  test "provision schema exposes durable start and checkout proof fields" do
    assert :starting in Provision.statuses()

    fields = Provision.__schema__(:fields)

    for field <- [
          :start_claim_token,
          :start_lease_until,
          :resolved_base_commit,
          :local_branch_ref
        ] do
      assert field in fields
    end
  end

  test "identity is idempotent and conflicting immutable fields fail" do
    assert {:ok, first} = Store.create_planned(attrs())
    assert {:ok, same} = Store.create_planned(attrs())
    assert first.id == same.id

    assert {:error, :conflicting_provision_identity} =
             Store.create_planned(%{attrs() | repository_uri: repository_uri("other")})

    assert {:error, :conflicting_provision_identity} =
             Store.create_planned(%{attrs() | checkout_fingerprint: "different-checkout"})
  end

  test "stale provision token cannot clean up a replacement claim" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, first} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)
    {:ok, second} = Store.claim_provision(row.id, now: at(31), lease_seconds: 30)

    assert {:error, :provision_lease_lost} =
             Store.fail_provision(row.id, first.claim_token, :checkout_unavailable)

    current = Repo.get!(Provision, row.id)
    assert current.status == :provisioning
    assert current.claim_token == second.claim_token

    assert {:ok, pending} =
             Store.fail_provision(row.id, second.claim_token, :checkout_unavailable, now: at(32))

    assert pending.status == :cleanup_pending
    assert pending.claim_token == nil
  end

  test "concurrent identity creation converges on one row" do
    results =
      1..8
      |> Task.async_stream(fn _ -> Store.create_planned(attrs()) end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, row}} -> row end)

    assert results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Provision, :count) == 1
  end

  test "private visibility is rejected before a provision row" do
    assert {:error, :private_checkout_not_supported} =
             Store.create_planned(%{attrs() | visibility: :private})

    assert Repo.aggregate(Provision, :count) == 0
  end

  test "expired provision lease is reclaimable and stale token or version cannot commit ready" do
    {:ok, row} = Store.create_planned(attrs())

    assert {:ok, first} =
             Store.claim_provision(row.id,
               now: at(0),
               lease_seconds: 30,
               expected_version: row.state_version
             )

    assert {:error, :provision_already_claimed} =
             Store.claim_provision(row.id, now: at(10), lease_seconds: 30)

    assert {:ok, second} =
             Store.claim_provision(row.id,
               now: at(31),
               lease_seconds: 30,
               expected_version: first.state_version
             )

    assert {:error, :provision_lease_lost} =
             Store.mark_ready(row.id, first.claim_token, ready_attrs(second.state_version),
               now: at(32)
             )

    assert {:error, :stale_provision_version} =
             Store.mark_ready(
               row.id,
               second.claim_token,
               ready_attrs(first.state_version),
               now: at(32)
             )

    assert {:ok, ready} =
             Store.mark_ready(
               row.id,
               second.claim_token,
               ready_attrs(second.state_version),
               now: at(32)
             )

    assert ready.status == :ready
    assert ready.state_version == second.state_version + 1
    assert is_binary(ready.start_token)
    assert ready.claim_token == nil
    assert ready.lease_until == nil
  end

  test "expired provision holder cannot commit before another claimant reclaims" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)

    assert {:error, :provision_lease_expired} =
             Store.mark_ready(
               row.id,
               claimed.claim_token,
               ready_attrs(claimed.state_version),
               now: at(31)
             )

    assert Repo.get!(Provision, row.id).status == :provisioning
  end

  test "concurrent provision claims have exactly one winner" do
    {:ok, row} = Store.create_planned(attrs())

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          Store.claim_provision(row.id,
            now: at(0),
            lease_seconds: 30,
            expected_version: row.state_version
          )
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Provision{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 7
  end

  test "claim_start moves ready to a leased starting state" do
    ready = ready_row()

    assert {:ok, starting} =
             Store.claim_start(ready.id, ready.start_token,
               now: at(0),
               lease_seconds: 30
             )

    assert starting.status == :starting
    assert is_binary(starting.start_claim_token)
    assert starting.start_token_consumed_at == at(0)
    assert starting.start_lease_until == at(30)
  end

  test "stale start claimant cannot complete after lease takeover" do
    ready = ready_row()
    {:ok, first} = Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30)
    {:ok, second} = Store.claim_start(ready.id, ready.start_token, now: at(31), lease_seconds: 30)

    assert first.start_claim_token != second.start_claim_token

    assert {:error, :sidecar_start_claim_lost} =
             Store.mark_started(first.id, first.start_claim_token, retirement_handle(first),
               now: at(32)
             )

    assert {:ok, started} =
             Store.mark_started(second.id, second.start_claim_token, retirement_handle(second),
               now: at(32)
             )

    assert started.status == :sidecar_started
    assert started.start_claim_token == nil
    assert started.start_lease_until == nil
  end

  test "current start claimant can renew and only it can fail into ambiguous cleanup" do
    ready = ready_row()
    {:ok, first} = Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30)
    {:ok, second} = Store.claim_start(ready.id, ready.start_token, now: at(31), lease_seconds: 30)

    assert {:error, :sidecar_start_claim_lost} =
             Store.renew_start_claim(first.id, first.start_claim_token,
               now: at(32),
               lease_seconds: 30
             )

    assert {:ok, renewed} =
             Store.renew_start_claim(second.id, second.start_claim_token,
               now: at(32),
               lease_seconds: 30
             )

    assert renewed.start_lease_until == at(62)

    assert {:error, :sidecar_start_claim_lost} =
             Store.fail_start(first.id, first.start_claim_token, :sidecar_start_failed,
               now: at(33)
             )

    assert {:ok, pending} =
             Store.fail_start(second.id, second.start_claim_token, :sidecar_start_failed,
               now: at(33)
             )

    assert pending.status == :cleanup_pending
    assert pending.cleanup_reason == "sidecar_start_failed"
    assert pending.start_claim_token == nil
    assert pending.start_lease_until == nil

    assert {:ok, :ambiguous_or_live, ^pending} =
             Store.request_cleanup(pending.id, :different_reason)
  end

  test "expired start holder cannot complete without takeover" do
    ready = ready_row()

    {:ok, starting} =
      Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30)

    assert {:error, :sidecar_start_claim_lost} =
             Store.mark_started(
               starting.id,
               starting.start_claim_token,
               retirement_handle(starting),
               now: at(31)
             )

    current = Repo.get!(Provision, ready.id)
    assert current.status == :starting
    assert current.start_claim_token == starting.start_claim_token
  end

  test "start lease boundary is expired for completion and renewable takeover" do
    ready = ready_row()
    {:ok, first} = Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30)

    assert {:error, :sidecar_start_claim_lost} =
             Store.mark_started(first.id, first.start_claim_token, retirement_handle(first),
               now: at(30)
             )

    assert {:error, :sidecar_start_claim_lost} =
             Store.renew_start_claim(first.id, first.start_claim_token,
               now: at(30),
               lease_seconds: 30
             )

    assert {:ok, second} =
             Store.claim_start(first.id, first.start_token, now: at(30), lease_seconds: 30)

    assert second.start_claim_token != first.start_claim_token
  end

  test "mark_started rejects a retirement attempt other than the prebound identity" do
    ready = ready_row()

    handle = %{
      agent_uri: "entity://task-workspace-store/agent/worker",
      provenance_root_uri: "entity://task-workspace-store/user/owner",
      creation_attempt_id: "unused"
    }

    {:ok, bound} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: handle.agent_uri,
        provenance_root_uri: handle.provenance_root_uri,
        workspace_uri: ready.workspace_uri,
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
        generation: ready.generation
      })

    {:ok, starting} =
      Store.claim_start(bound.id, bound.start_token, now: at(0), lease_seconds: 30)

    mismatched = %{handle | creation_attempt_id: "later-attempt"}

    assert {:error, :creation_attempt_mismatch} =
             Store.mark_started(starting.id, starting.start_claim_token, mismatched, now: at(1))

    assert Repo.get!(Provision, starting.id).creation_attempt_id == bound.creation_attempt_id
  end

  test "concurrent start claims have exactly one winner" do
    ready = ready_row()

    results =
      1..20
      |> Task.async_stream(
        fn _ -> Store.claim_start(ready.id, ready.start_token, now: at(0), lease_seconds: 30) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Provision{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :start_already_claimed})) == 19
  end

  test "cleanup lease is exclusive, reclaimable, and token-bound" do
    {:ok, row} = Store.create_planned(attrs())
    assert {:ok, :never_started, pending} = Store.request_cleanup(row.id, :task_cancelled)
    assert pending.status == :cleanup_pending

    assert {:ok, first} =
             Store.claim_cleanup(row.id,
               now: at(0),
               lease_seconds: 30,
               expected_version: pending.state_version
             )

    assert {:error, :cleanup_already_claimed} =
             Store.claim_cleanup(row.id, now: at(10), lease_seconds: 30)

    assert {:ok, second} =
             Store.claim_cleanup(row.id,
               now: at(31),
               lease_seconds: 30,
               expected_version: first.state_version
             )

    assert {:error, :cleanup_lease_lost} =
             Store.mark_cleaned(row.id, first.claim_token, now: at(32))

    assert {:ok, cleaned} = Store.mark_cleaned(row.id, second.claim_token, now: at(32))
    assert cleaned.status == :cleaned
    assert %DateTime{} = cleaned.cleaned_at
  end

  test "cleanup request atomically invalidates an unused start token and classifies no start" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)

    {:ok, ready} =
      Store.mark_ready(row.id, claimed.claim_token, ready_attrs(claimed.state_version),
        now: at(1)
      )

    assert {:ok, :never_started, pending} =
             Store.request_cleanup(ready.id, :task_cancelled)

    assert pending.status == :cleanup_pending
    assert pending.start_token == nil
    assert {:error, :invalid_start_transition} = Store.claim_start(ready.id, ready.start_token)
  end

  test "cleanup request classifies a consumed start as ambiguous or live" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)

    {:ok, ready} =
      Store.mark_ready(row.id, claimed.claim_token, ready_attrs(claimed.state_version),
        now: at(1)
      )

    {:ok, ready} = bind_start_intent(ready)
    {:ok, _starting} = Store.claim_start(ready.id, ready.start_token)

    assert {:ok, :ambiguous_or_live, pending} =
             Store.request_cleanup(ready.id, :task_cancelled)

    assert pending.start_token == ready.start_token
  end

  test "invalid ready cleanup is a versioned CAS and never races a consumed start" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(row.id, now: at(0), lease_seconds: 30)

    {:ok, ready} =
      Store.mark_ready(row.id, claimed.claim_token, ready_attrs(claimed.state_version),
        now: at(1)
      )

    {:ok, ready} = bind_start_intent(ready)
    {:ok, _starting} = Store.claim_start(ready.id, ready.start_token)

    assert {:error, :start_ambiguous_or_live} =
             Store.request_invalid_ready_cleanup(
               ready.id,
               ready.state_version,
               :workspace_missing
             )
  end

  test "cleanup claim must be current before an external effect" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, :never_started, pending} = Store.request_cleanup(row.id, :task_cancelled)
    {:ok, first} = Store.claim_cleanup(pending.id, now: at(0), lease_seconds: 30)
    {:ok, second} = Store.claim_cleanup(pending.id, now: at(31), lease_seconds: 30)

    assert {:error, :cleanup_lease_lost} =
             Store.validate_cleanup_claim(first.id, first.claim_token, now: at(32))

    assert {:ok, renewed} =
             Store.renew_cleanup_claim(second.id, second.claim_token,
               now: at(32),
               lease_seconds: 30
             )

    assert DateTime.compare(renewed.lease_until, at(62)) == :eq
  end

  test "expired cleanup holder cannot complete before another claimant reclaims" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, :never_started, pending} = Store.request_cleanup(row.id, :task_cancelled)
    {:ok, claimed} = Store.claim_cleanup(pending.id, now: at(0), lease_seconds: 30)

    assert {:error, :cleanup_lease_expired} =
             Store.mark_cleaned(claimed.id, claimed.claim_token, now: at(31))

    assert Repo.get!(Provision, row.id).status == :cleanup_pending
  end

  test "repeated cleanup request preserves an active cleanup claim" do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, :never_started, pending} = Store.request_cleanup(row.id, :task_cancelled)
    {:ok, claimed} = Store.claim_cleanup(pending.id, now: at(0), lease_seconds: 30)

    assert {:ok, :never_started, same} = Store.request_cleanup(row.id, :different_reason)
    assert same.id == claimed.id
    assert same.state_version == claimed.state_version
    assert same.claim_token == claimed.claim_token
    assert same.lease_until == claimed.lease_until
    assert same.cleanup_reason == "task_cancelled"
  end

  test "recoverable listing is bounded and excludes terminal rows" do
    {:ok, first} = Store.create_planned(attrs("a"))
    {:ok, second} = Store.create_planned(attrs("b"))
    {:ok, :never_started, pending} = Store.request_cleanup(second.id, :task_cancelled)
    {:ok, cleanup} = Store.claim_cleanup(pending.id, now: at(0), lease_seconds: 30)
    {:ok, _cleaned} = Store.mark_cleaned(cleanup.id, cleanup.claim_token, now: at(1))

    assert Store.list_recovery_candidates(1, now: at(2)) == []
    assert first.status == :planned
  end

  test "recoverable listing skips active leases" do
    {:ok, row} = Store.create_planned(attrs())

    assert {:ok, _claimed} =
             Store.claim_provision(row.id,
               now: DateTime.utc_now(),
               lease_seconds: 60
             )

    assert Store.list_recoverable(10) == []
  end

  test "schema has no credential, secret, or raw Git output fields" do
    forbidden = [
      :credential,
      :credential_ref,
      :secret,
      :access_token,
      :private_key,
      :git_output,
      :stdout,
      :stderr
    ]

    fields = Provision.__schema__(:fields)
    assert Enum.all?(forbidden, &(&1 not in fields))
  end

  defp attrs(suffix \\ "one") do
    %{
      provision_id: "provision-#{suffix}",
      workspace_uri: "workspace://task-workspace-store",
      task_uri: "resource://task-workspace-store/kanban-task/task-#{suffix}",
      generation: 1,
      task_access_uri: task_access_uri(suffix),
      repository_uri: repository_uri(suffix),
      checkout_fingerprint: "checkout-#{suffix}",
      base_ref: "main",
      allowed_head_ref: "task/task-#{suffix}",
      visibility: :public
    }
  end

  defp repository_uri(suffix),
    do: "resource://task-workspace-store/git-repository/repository-#{suffix}"

  defp task_access_uri(suffix) do
    digest = :sha256 |> :crypto.hash(suffix) |> Base.encode16(case: :lower)
    "entity://task-workspace-store/worker/gta_#{digest}"
  end

  defp ready_attrs(expected_version) do
    %{
      expected_version: expected_version,
      cache_identity: "cache-widgets-main",
      worktree_identity: "worktree-task-one-1",
      worktree_path: "/safe/workspaces/task-one-1",
      resolved_base_commit: String.duplicate("a", 40),
      local_branch_ref: "refs/heads/ezagent/task/ddaf3b818c7535a72662923c/g1"
    }
  end

  defp ready_row do
    {:ok, row} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(row.id, now: at(-2), lease_seconds: 30)

    {:ok, ready} =
      Store.mark_ready(row.id, claimed.claim_token, ready_attrs(claimed.state_version),
        now: at(-1)
      )

    {:ok, bound} = bind_start_intent(ready)

    bound
  end

  defp bind_start_intent(ready) do
    Store.bind_start_intent(ready.provision_id, %{
      agent_uri: "entity://task-workspace-store/agent/worker",
      provenance_root_uri: "entity://task-workspace-store/user/owner",
      workspace_uri: ready.workspace_uri,
      task_access_uri: ready.task_access_uri,
      task_uri: ready.task_uri,
      generation: ready.generation
    })
  end

  defp retirement_handle do
    %{
      agent_uri: "entity://acme/agent/worker",
      creation_attempt_id: "attempt-1",
      provenance_root_uri: "entity://acme/user/owner"
    }
  end

  defp retirement_handle(%Provision{} = row),
    do: %{retirement_handle() | creation_attempt_id: row.creation_attempt_id}

  defp at(seconds), do: DateTime.add(~U[2026-07-17 00:00:00.000000Z], seconds, :second)
end
