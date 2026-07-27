defmodule Ezagent.Workspace.TaskWorkspace.ChangeCollectorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.DomainGit.WorkspaceChangePort.Request
  alias Ezagent.DomainGit.WorkspaceProvisionPort.Request, as: ProvisionRequest
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{ChangeCollector, Provisioner}
  alias EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner

  setup do
    previous_home = System.get_env("EZAGENT_HOME")

    root =
      Path.join(System.tmp_dir!(), "change-collector-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      Ezagent.Workspace.TaskWorkspace.GitRunner
    )

    on_exit(fn ->
      if is_nil(previous_home),
        do: System.delete_env("EZAGENT_HOME"),
        else: System.put_env("EZAGENT_HOME", previous_home)

      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_collect_status_result)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_owner)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  describe "collect/1 happy path" do
    test "collects a single new UTF-8 file as one upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "notes.md"), "hello from the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "notes.md"
      assert change.operation == :upsert
      assert change.content == "hello from the task\n"
    end

    test "collects a modified tracked file as an upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "README.md"), "modified by the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "README.md"
      assert change.content == "modified by the task\n"
    end

    test "rejects an empty diff", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      assert {:error, :no_changes_collected} = ChangeCollector.collect(change_request)
    end

    test "rejects when no ready provision matches provision_id", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      unready = %{
        change_request
        | provision_id: "never-provisioned-#{System.unique_integer([:positive])}"
      }

      assert {:error, :workspace_not_ready} = ChangeCollector.collect(unready)
    end

    test "rejects when generation does not match the provisioned identity", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      mismatched = %{change_request | generation: change_request.generation + 1}

      assert {:error, :workspace_identity_mismatch} = ChangeCollector.collect(mismatched)
    end

    test "rejects when task_uri does not match the provisioned identity, without invoking the runner",
         %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())

      %URI{} = task_uri = change_request.task_uri
      mismatched = %{change_request | task_uri: %{task_uri | path: task_uri.path <> "-other"}}

      assert {:error, :workspace_identity_mismatch} = ChangeCollector.collect(mismatched)
      refute_receive {:git_collect_status, _ready}
    end

    test "rejects when task_access_uri does not match the provisioned identity, without invoking the runner",
         %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())

      %URI{} = task_access_uri = change_request.task_access_uri

      mismatched = %{
        change_request
        | task_access_uri: %{task_access_uri | path: task_access_uri.path <> "-other"}
      }

      assert {:error, :workspace_identity_mismatch} = ChangeCollector.collect(mismatched)
      refute_receive {:git_collect_status, _ready}
    end

    test "rejects a malformed argument closed to the port contract" do
      assert {:error, :invalid_change_request} = ChangeCollector.collect(:not_a_request)
    end
  end

  describe "collect/1 rejects filesystem-shape violations" do
    test "rejects a symlink even when it points inside the worktree", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      target = Path.join(worktree_path, "README.md")
      link = Path.join(worktree_path, "shortcut.md")
      File.ln_s!(target, link)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a deleted tracked file", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.rm!(Path.join(worktree_path, "README.md"))

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a rename (seen as a delete plus an untracked add, since V1 disables rename detection)",
         %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      old_path = Path.join(worktree_path, "README.md")
      new_path = Path.join(worktree_path, "RENAMED.md")
      File.rename!(old_path, new_path)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a staged rename without crashing the parser", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      # A staged rename (`git mv`, or `git add` after a filesystem rename)
      # is reported by `git status --porcelain -z` as a single two-path
      # record ("R  RENAMED.md\0README.md\0"), not the delete-plus-add pair
      # produced by an unstaged rename above. Before the fix this crashed
      # the porcelain parser (`FunctionClauseError`) instead of returning
      # the stable rejection.
      git!(worktree_path, ["mv", "README.md", "RENAMED.md"])

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects an executable mode change on an otherwise-unmodified file", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.chmod!(Path.join(worktree_path, "README.md"), 0o755)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects removing the executable bit from a tracked executable file", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      # The mode check must reject BOTH directions (design §2.2). Adding
      # the executable bit is covered above; this covers the direction the
      # filesystem-only check missed: a file tracked as executable in HEAD
      # whose worktree copy has since lost the bit still classifies as a
      # plain `M` candidate whose CURRENT mode is non-executable, so a
      # check limited to "is it executable right now" lets it through.
      script_path = Path.join(worktree_path, "script.sh")
      File.write!(script_path, "#!/bin/sh\necho hi\n")
      File.chmod!(script_path, 0o755)
      git!(worktree_path, ["add", "script.sh"])
      commit_fixture!(worktree_path, "add executable script")

      File.chmod!(script_path, 0o644)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects content containing an embedded NUL byte, even though it is valid UTF-8", %{
      root: root
    } do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "binary.dat"), "abc" <> <<0>> <> "def")

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects content that is not valid UTF-8", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "invalid_utf8.dat"), <<255, 254, 253>>)

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a relative path that climbs out of the worktree", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "../../etc/passwd", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects an absolute path reported in place of a worktree-relative one", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "/etc/passwd", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end
  end

  describe "collect/1 rejects submodule changes" do
    # Each test here creates a REAL nested repository and a real gitlink
    # entry (mode 160000) in the parent index, then drives the actual
    # `git status`/classification/read path end to end — replacing a prior
    # version of this coverage that fabricated a `??`-status entry for a
    # plain directory and never exercised git's real submodule reporting
    # (which never uses `??` for a submodule at all; see the mode/status
    # combinations captured in the P2 fix report).

    test "rejects a newly-added submodule", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} =
        ready_fixture!(root, "submodule-added")

      submodule_source = build_submodule_source!(root, "submodule-added")

      git!(worktree_path, [
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        submodule_source,
        "vendor/sub"
      ])

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a removed submodule", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} =
        ready_fixture_with_submodule!(root, "submodule-removed")

      git!(worktree_path, ["rm", "-q", "--cached", "vendor/sub"])
      File.rm_rf!(Path.join(worktree_path, "vendor/sub"))

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a submodule whose recorded commit has advanced (a modified gitlink)", %{
      root: root
    } do
      %{worktree_path: worktree_path, change_request: change_request} =
        ready_fixture_with_submodule!(root, "submodule-gitlink")

      sub_path = Path.join(worktree_path, "vendor/sub")
      File.write!(Path.join(sub_path, "extra.txt"), "advance\n")
      git!(sub_path, ["add", "extra.txt"])
      commit_fixture!(sub_path, "advance submodule")

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end

    test "rejects a dirty submodule (untracked content inside, gitlink unchanged)", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} =
        ready_fixture_with_submodule!(root, "submodule-dirty")

      File.write!(Path.join(worktree_path, "vendor/sub/untracked.txt"), "dirty\n")

      assert {:error, :unsupported_workspace_change} = ChangeCollector.collect(change_request)
    end
  end

  describe "collect/1 rejects limit and read-failure violations" do
    setup do
      previous = Application.get_env(:ezagent_domain_git, :change_limits, :absent)
      on_exit(fn -> restore_change_limits(previous) end)
      :ok
    end

    test "rejects a single file over max_file_bytes", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 100,
        max_file_bytes: 10,
        max_total_bytes: 1_000
      })

      File.write!(Path.join(worktree_path, "too_big.txt"), String.duplicate("a", 11))

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "rejects when the file count exceeds max_files", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 2,
        max_file_bytes: 1_000,
        max_total_bytes: 1_000_000
      })

      for n <- 1..3 do
        File.write!(Path.join(worktree_path, "file-#{n}.txt"), "content #{n}\n")
      end

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "rejects when total bytes exceed max_total_bytes", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      Application.put_env(:ezagent_domain_git, :change_limits, %{
        max_files: 100,
        max_file_bytes: 1_000,
        max_total_bytes: 15
      })

      File.write!(Path.join(worktree_path, "a.txt"), String.duplicate("a", 10))
      File.write!(Path.join(worktree_path, "b.txt"), String.duplicate("b", 10))

      assert {:error, :change_limit_exceeded} = ChangeCollector.collect(change_request)
    end

    test "surfaces a vanished reported path as workspace_read_failed, not a false rejection", %{
      root: root
    } do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      Application.put_env(
        :ezagent_domain_workspace,
        :provisioner_test_collect_status_result,
        {:ok, [%{path: "vanished.txt", index_status: "?", worktree_status: "?"}]}
      )

      assert {:error, :workspace_read_failed} = ChangeCollector.collect(change_request)
    end

    test "normalizes any runner infrastructure failure to workspace_read_failed", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      Application.put_env(
        :ezagent_domain_workspace,
        :task_workspace_git_runner,
        FakeTaskWorkspaceGitRunner
      )

      # These are real `GitRunner.collect_status/1` failure shapes (see
      # git_runner.ex: `:git_output_limit_exceeded` from the output-cap
      # guard, `{:git_spawn_failed, reason}` from the spawn failure branch,
      # `:workspace_checkout_mismatch` from a non-zero git exit) — none of
      # them belong to this module's declared closed vocabulary, so all
      # must collapse to the same stable blocker with no raw reason
      # attached.
      for raw_reason <- [
            :git_output_limit_exceeded,
            {:git_spawn_failed, :enoent},
            :git_command_timeout,
            :workspace_checkout_mismatch
          ] do
        Application.put_env(
          :ezagent_domain_workspace,
          :provisioner_test_collect_status_result,
          {:error, raw_reason}
        )

        assert {:error, :workspace_read_failed} = ChangeCollector.collect(change_request)
      end
    end
  end

  defp restore_change_limits(:absent),
    do: Application.delete_env(:ezagent_domain_git, :change_limits)

  defp restore_change_limits(value),
    do: Application.put_env(:ezagent_domain_git, :change_limits, value)

  defp ready_fixture!(root, suffix \\ "one", local_origin_opts \\ []) do
    origin = local_origin!(root, local_origin_opts)
    workspace = "change-collector-#{suffix}-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace)
    task_id = "task-#{suffix}"

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: :fixture,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: :public
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: "task-access-#{suffix}-#{System.unique_integer([:positive])}",
        task_id: task_id,
        generation: 1,
        workspace_uri: workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: Ezagent.URI.agent(workspace, "worker"),
        repository: repository,
        provider_adapter: :fixture,
        allowed_head_ref: "task/#{task_id}",
        allowed_actions: [:provision_workspace, :cleanup_workspace],
        idempotency_inputs: %{task_id: task_id, generation: 1}
      })

    task_access_uri = GitTaskAccess.uri_from_args(policy)
    assert {:ok, _pid} = Ezagent.DomainGit.TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> Ezagent.DomainGit.TaskAccessSupervisor.teardown(task_access_uri) end)

    task_uri = Ezagent.URI.resource(workspace, "kanban-task", task_id)
    provision_id = "provision-#{suffix}-#{System.unique_integer([:positive])}"

    {:ok, provision_request} =
      ProvisionRequest.new_authorized(
        %{
          task_access_uri: task_access_uri,
          task_uri: task_uri,
          generation: 1,
          operation: :prepare,
          provision_id: provision_id
        },
        policy
      )

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _, _ ->
      %{remote_url: origin, allow_local_fixture: true}
    end)

    assert {:ok, %{status: :ready, cwd: worktree_path}} = Provisioner.prepare(provision_request)

    {:ok, change_request} =
      Request.new(%{
        task_access_uri: task_access_uri,
        task_uri: task_uri,
        generation: 1,
        provision_id: provision_id
      })

    %{
      worktree_path: worktree_path,
      change_request: change_request,
      task_access_uri: task_access_uri,
      task_uri: task_uri
    }
  end

  defp local_origin!(root, opts) do
    origin = Path.join(root, "origin-#{System.unique_integer([:positive])}.git")
    source = Path.join(root, "source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)

    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])
    commit_fixture!(source, "fixture")

    case Keyword.get(opts, :submodule_source) do
      nil ->
        :ok

      submodule_source ->
        git!(source, [
          "-c",
          "protocol.file.allow=always",
          "submodule",
          "add",
          submodule_source,
          "vendor/sub"
        ])

        commit_fixture!(source, "add submodule")
    end

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
    origin
  end

  # Builds a small, real, standalone Git repository suitable for use as a
  # `git submodule add` source (a plain non-bare local repo works fine as a
  # submodule origin — no bare intermediate is needed for this fixture).
  defp build_submodule_source!(root, suffix) do
    sub = Path.join(root, "submodule-src-#{suffix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sub)
    git!(sub, ["init", "-b", "main"])
    File.write!(Path.join(sub, "sub.txt"), "sub content\n")
    git!(sub, ["add", "sub.txt"])
    commit_fixture!(sub, "sub init")
    sub
  end

  # A ready task worktree whose base commit already carries a submodule
  # (`vendor/sub`) — for the "removed" / "modified gitlink" / "dirty"
  # submodule scenarios, which all need the submodule already present and
  # committed before the test mutates it further. `git worktree add` (what
  # `Provisioner.prepare` uses under the hood) does not itself initialize
  # submodules, so this explicitly runs `submodule update --init` against
  # the resulting worktree, exactly as a real agent would need to before it
  # could see or touch the submodule's contents.
  defp ready_fixture_with_submodule!(root, suffix) do
    submodule_source = build_submodule_source!(root, suffix)
    fixture = ready_fixture!(root, suffix, submodule_source: submodule_source)

    git!(fixture.worktree_path, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "update",
      "--init"
    ])

    fixture
  end

  defp commit_fixture!(cd, message) do
    git!(cd, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      message
    ])
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    output
  end
end
