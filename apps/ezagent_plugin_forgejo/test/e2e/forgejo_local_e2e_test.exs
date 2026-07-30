defmodule EzagentPluginForgejo.E2E.ForgejoLocalE2ETest do
  @moduledoc """
  Slice F4 — local end-to-end against a STATEFUL in-memory Forgejo.

  Plan E §8's central assertion is idempotency: the same inputs run twice must
  leave **one** branch, **one** effective commit and **one** pull request, with
  the second pass allowed to re-read but not to mutate.

  That property cannot be checked against a per-request stub — a stateless stub
  answers the second write exactly like the first, so a duplicate commit looks
  identical to a correct resume. `EzagentPluginForgejo.StubForgejoInstance`
  therefore keeps state and counts mutations, and reproduces the two measured
  Forgejo behaviours the adapter has to survive: `POST /contents` is not
  idempotent, and a duplicate branch is 409 from `POST /branches` but 422 from
  `POST /contents`.

  Scope, stated plainly: this drives the ADAPTER through the full read+write
  surface, not the workflow's StageRunner. The Forgejo-specific risk lives in
  the adapter (non-idempotent writes, resume decisions, PR matching), and the
  workflow's own harness (`plan_e_e2e_case.ex`) is wired to GitHub — mirroring
  it belongs to the workflow owner, whose code this slice must not touch.
  """
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }

  alias Ezagent.ProviderConnection.Connection
  alias EzagentCore.Repo
  alias EzagentPluginForgejo.{ForgejoAdapter, ForgejoCredentialBackend, StubForgejoInstance}

  @ws "workspace://acme"
  @owner "entity://acme/user/dev"
  @host "code.hyprial.test"
  @repo_id "gagameow/ezagent-forgejo-test"
  @base_sha String.duplicate("1", 40)
  @head_ref "task/p4e/run-e2e01"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, instance} = StubForgejoInstance.start_link(base_ref: "main", base_sha: @base_sha)

    previous = Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts)

    Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts,
      plug: StubForgejoInstance.plug(instance),
      retry: false
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ezagent_plugin_forgejo, :adapter_req_opts)
        value -> Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, value)
      end
    end)

    {:ok, %{credential_ref: ref}} =
      ForgejoCredentialBackend.store(%{
        credential_material: {:write_only_handoff, Jason.encode!(%{"access_token" => "at-e2e"})}
      })

    Repo.insert!(%Connection{
      connection_id: Ecto.UUID.generate(),
      workspace_uri: @ws,
      owner_uri: @owner,
      provider_id: "forgejo",
      governed_host: @host,
      execution_identity: "connected_user",
      external_account_id: "7",
      acquisition_method: "oauth_user",
      status: "active",
      credential_backend_ref: ref,
      credential_version: 1,
      authorization_backend_ref: "auth-e2e",
      backend_pair_id: "pair-forgejo-v1",
      authorization_backend_id: "local-authorization-v1",
      credential_backend_id: "forgejo-credential-v1"
    })

    {:ok, instance: instance}
  end

  defp ctx do
    hash = String.duplicate("a", 64)

    {:ok, context} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.new!("entity://acme/worker/gta_#{hash}"),
        caller_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        grantee_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        credential_owner_uri: Ezagent.URI.new!(@owner),
        idempotency_key: "e2e-1"
      })

    context
  end

  defp repo! do
    {:ok, ref} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.new!("resource://acme/git-repository/main"),
        provider_adapter: :forgejo,
        provider_host: @host,
        external_id: @repo_id,
        owner_path: "gagameow",
        base_ref: "main",
        visibility: :private
      })

    ref
  end

  defp changes(content \\ "hello from the run\n") do
    {:ok, change} = FileChange.new(%{path: "docs/run.md", operation: :upsert, content: content})
    [change]
  end

  defp request! do
    {:ok, sha} = CommitSha.new(%{value: @base_sha})

    {:ok, req} =
      CreateChangeRequest.new(%{
        title: "Automated change from run e2e01",
        body: "opened by the Forgejo provider",
        head_ref: @head_ref,
        expected_base_sha: sha,
        # Design §6.1: the run's own accept-time instant, never a wall clock —
        # this is what makes a retry rebuild a byte-identical commit.
        commit_date: ~U[2026-07-29 10:00:00Z]
      })

    req
  end

  describe "main scenario" do
    test "collects a change, commits it on a pinned branch, and opens a PR", %{
      instance: instance
    } do
      assert {:ok, cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert cr.head_ref == @head_ref
      assert cr.base_ref == "main"
      assert cr.state == :open

      # The branch was created at the verified base and then advanced by the
      # commit -- it is no longer sitting at base.
      head = StubForgejoInstance.branch_sha(instance, @head_ref)
      assert is_binary(head)
      refute head == @base_sha
      assert cr.head_sha == head

      assert StubForgejoInstance.count(instance, :branches) == 1
      assert StubForgejoInstance.count(instance, :contents) == 1
      assert StubForgejoInstance.count(instance, :pulls) == 1
    end

    test "the created PR is then readable, with its checks and reviews", %{instance: instance} do
      {:ok, cr} = ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
      {:ok, id} = ChangeRequestId.new(%{external_id: cr.external_id})
      {:ok, head} = CommitSha.new(%{value: cr.head_sha})

      assert {:ok, read_back} = ForgejoAdapter.read_change_request(ctx(), repo!(), id)
      assert read_back.external_id == cr.external_id
      assert read_back.state == :open

      # Plan E §6.3: empty checks and empty reviews are valid facts, not a pass
      # and not an approval.
      assert {:ok, []} = ForgejoAdapter.list_checks(ctx(), repo!(), head)
      assert {:ok, []} = ForgejoAdapter.list_reviews(ctx(), repo!(), id)

      StubForgejoInstance.put_status(instance, cr.head_sha, %{
        "id" => 1,
        "context" => "ci / test",
        "status" => "success",
        "target_url" => ""
      })

      StubForgejoInstance.put_review(instance, cr.external_id, %{
        "id" => 11,
        "state" => "APPROVED",
        "dismissed" => false,
        "user" => %{"login" => "alice"},
        "submitted_at" => "2026-07-29T11:00:00Z"
      })

      # A review REQUEST is not a review (measured) and must not be counted.
      StubForgejoInstance.put_review(instance, cr.external_id, %{
        "id" => 12,
        "state" => "REQUEST_REVIEW",
        "dismissed" => false,
        "user" => %{"login" => "bob"}
      })

      assert {:ok, [%{name: "ci / test", conclusion: :succeeded}]} =
               ForgejoAdapter.list_checks(ctx(), repo!(), head)

      assert {:ok, [%{author_label: "alice", state: :approved}]} =
               ForgejoAdapter.list_reviews(ctx(), repo!(), id)
    end
  end

  describe "the same run executed twice (Plan E §8)" do
    # THE assertion of this slice. `POST /contents` is not idempotent, so a
    # second pass that re-sent the write would leave two commits and the branch
    # one commit further along — invisible to any stateless stub.
    test "leaves one branch, one commit and one PR", %{instance: instance} do
      assert {:ok, first} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      head_after_first = StubForgejoInstance.branch_sha(instance, @head_ref)

      assert {:ok, second} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert StubForgejoInstance.count(instance, :branches) == 1
      assert StubForgejoInstance.count(instance, :contents) == 1
      assert StubForgejoInstance.count(instance, :pulls) == 1

      assert StubForgejoInstance.branch_sha(instance, @head_ref) == head_after_first
      assert second.external_id == first.external_id
      assert second.head_sha == first.head_sha
      assert length(StubForgejoInstance.pulls(instance)) == 1
    end

    test "a third pass still mutates nothing", %{instance: instance} do
      for _pass <- 1..3 do
        assert {:ok, _} =
                 ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
      end

      assert StubForgejoInstance.count(instance, :contents) == 1
      assert StubForgejoInstance.count(instance, :pulls) == 1
    end
  end

  describe "crash windows recovered against real state (design §7.5)" do
    # Window: the branch was created and the response was lost. The branch sits
    # at base, so the resume must write into it rather than fail on a duplicate.
    test "resumes when the branch exists but is still at base", %{instance: instance} do
      # Reproduce the interrupted first attempt exactly: create the branch, stop.
      {:ok, _} =
        EzagentPluginForgejo.ForgejoClient.post(
          "https://#{@host}/api/v1",
          "/repos/#{@repo_id}/branches",
          "at-e2e",
          %{new_branch_name: @head_ref, old_ref_name: @base_sha},
          Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
        )

      assert StubForgejoInstance.branch_sha(instance, @head_ref) == @base_sha

      assert {:ok, cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # One commit, and no second branch-creation attempt succeeded.
      assert StubForgejoInstance.count(instance, :contents) == 1
      assert StubForgejoInstance.count(instance, :branches) == 1
      refute cr.head_sha == @base_sha
    end

    # Window: a branch of the same name exists but carries someone else's work.
    # Resuming onto it, or force-moving it, would destroy that work.
    test "refuses a branch advanced by someone else", %{instance: instance} do
      opts = Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
      base = "https://#{@host}/api/v1"

      {:ok, _} =
        EzagentPluginForgejo.ForgejoClient.post(
          base,
          "/repos/#{@repo_id}/branches",
          "at-e2e",
          %{new_branch_name: @head_ref, old_ref_name: @base_sha},
          opts
        )

      {:ok, _} =
        EzagentPluginForgejo.ForgejoClient.post(
          base,
          "/repos/#{@repo_id}/contents",
          "at-e2e",
          %{
            branch: @head_ref,
            message: "somebody else's commit",
            files: [%{operation: "create", path: "other.md", content: Base.encode64("x")}],
            dates: %{author: "2026-01-01T00:00:00Z", committer: "2026-01-01T00:00:00Z"}
          },
          opts
        )

      foreign_head = StubForgejoInstance.branch_sha(instance, @head_ref)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # Nothing was written and the foreign commit still stands.
      assert StubForgejoInstance.branch_sha(instance, @head_ref) == foreign_head
      assert StubForgejoInstance.count(instance, :contents) == 1
      assert StubForgejoInstance.count(instance, :pulls) == 0
    end
  end

  describe "a changed file on a resumed branch" do
    # An upsert onto a branch this run already wrote is a resume, not a new
    # change: the adapter recognises its own commit and does not write again,
    # even though the file now exists.
    test "does not write a second time", %{instance: instance} do
      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert StubForgejoInstance.count(instance, :contents) == 1

      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert StubForgejoInstance.count(instance, :contents) == 1
    end
  end

  describe "the credential never leaves the plugin" do
    test "no returned value carries the access token", %{instance: _instance} do
      {:ok, cr} = ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
      {:ok, id} = ChangeRequestId.new(%{external_id: cr.external_id})
      {:ok, head} = CommitSha.new(%{value: cr.head_sha})

      {:ok, read_back} = ForgejoAdapter.read_change_request(ctx(), repo!(), id)
      {:ok, checks} = ForgejoAdapter.list_checks(ctx(), repo!(), head)
      {:ok, reviews} = ForgejoAdapter.list_reviews(ctx(), repo!(), id)

      for value <- [cr, read_back, checks, reviews] do
        refute inspect(value) =~ "at-e2e"
      end
    end

    # Design §4.2: leased per callback, never cached. Removing the credential
    # between two operations must stop the second one.
    test "a credential removed between operations stops the next call" do
      {:ok, cr} = ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
      {:ok, id} = ChangeRequestId.new(%{external_id: cr.external_id})

      :ets.delete_all_objects(:forgejo_credential_tokens)

      assert {:error, :credential_backend_unavailable} =
               ForgejoAdapter.read_change_request(ctx(), repo!(), id)
    end
  end
end
