defmodule Ezagent.Workspace.TaskWorkspace.GitRunnerTest do
  use ExUnit.Case, async: false

  alias Ezagent.Workspace.TaskWorkspace.{GitRunner, Paths}

  setup do
    previous_home = System.get_env("EZAGENT_HOME")

    root =
      Path.join(System.tmp_dir!(), "task-workspace-git-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)

    on_exit(fn ->
      restore_env("EZAGENT_HOME", previous_home)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "private, userinfo, and non-HTTPS remotes fail before executor invocation" do
    owner = self()
    executor = fn argv, _opts -> send(owner, {:os_process_started, argv}) end

    assert {:error, :private_checkout_not_supported} =
             GitRunner.prepare(request(visibility: :private, executor: executor))

    assert {:error, :remote_userinfo_not_allowed} =
             GitRunner.prepare(
               request(
                 remote_url: "https://token@git.example.test/acme/widgets.git",
                 executor: executor
               )
             )

    assert {:error, :https_remote_required} =
             GitRunner.prepare(
               request(
                 remote_url: "ssh://git.example.test/acme/widgets.git",
                 executor: executor
               )
             )

    refute_receive {:os_process_started, _}
  end

  test "command plans are argv-only and contain anonymous credential hardening" do
    owner = self()

    executor = fn argv, opts ->
      send(owner, {:argv, argv, opts})

      cond do
        Enum.take(argv, -3) == ["remote", "get-url", "origin"] ->
          {:ok,
           %{
             stdout: "https://git.example.test/acme/widgets.git\n",
             stderr: "",
             exit_status: 0
           }}

        "show-ref" in argv and Enum.at(argv, -1) =~ "/tags/" ->
          {:error, {:git_exit, 1}}

        "rev-parse" in argv ->
          {:ok, %{stdout: String.duplicate("a", 40) <> "\n", stderr: "", exit_status: 0}}

        true ->
          {:ok, %{stdout: "", stderr: "", exit_status: 0}}
      end
    end

    assert {:ok, ready} = GitRunner.prepare(request(executor: executor))
    commands = collect_argv([])

    for {argv, opts} <- commands do
      assert is_list(argv)
      assert Enum.all?(argv, &is_binary/1)
      assert "credential.helper=" in argv
      assert "core.askPass=" in argv
      refute Enum.any?(argv, &String.contains?(&1, ["token", "password", "private_key"]))
      assert opts.env == %{"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"}
    end

    assert ready.argv_history == Enum.map(commands, &elem(&1, 0))
  end

  test "prepare creates and verifies an isolated worktree from an explicit local fixture", %{
    root: root
  } do
    origin = local_origin!(root)

    assert {:ok, ready} =
             GitRunner.prepare(
               request(
                 remote_url: origin,
                 allow_local_fixture: true,
                 base_ref: "main"
               )
             )

    assert File.dir?(ready.worktree_path)
    assert :ok = GitRunner.verify(ready)
    assert :ok = GitRunner.remove(ready)
    assert :ok = GitRunner.verify_absent(ready)
    refute File.exists?(ready.worktree_path)
  end

  test "reused cache fetches a moved base ref and creates the deterministic branch", %{root: root} do
    %{origin: origin, source: source} = local_origin_with_source!(root)
    first = request(remote_url: origin, allow_local_fixture: true, generation: 1)

    assert {:ok, prepared_one} = GitRunner.prepare(first)
    moved_sha = advance_origin_main!(source)

    second = request(remote_url: origin, allow_local_fixture: true, generation: 2)
    assert {:ok, prepared_two} = GitRunner.prepare(second)

    assert prepared_two.resolved_base_commit == moved_sha
    assert prepared_two.local_branch_ref == GitRunner.local_branch_ref(second)

    assert String.trim(git!(prepared_two.worktree_path, ["symbolic-ref", "HEAD"])) ==
             prepared_two.local_branch_ref

    refute prepared_one.resolved_base_commit == prepared_two.resolved_base_commit
  end

  test "reused cache fetches a newly-created base ref", %{root: root} do
    %{origin: origin, source: source} = local_origin_with_source!(root)

    assert {:ok, _prepared} =
             GitRunner.prepare(
               request(remote_url: origin, allow_local_fixture: true, generation: 1)
             )

    new_sha = create_origin_branch!(source, "release")

    request =
      request(
        remote_url: origin,
        allow_local_fixture: true,
        base_ref: "release",
        generation: 2
      )

    assert {:ok, prepared} = GitRunner.prepare(request)
    assert prepared.resolved_base_commit == new_sha
    assert prepared.local_branch_ref == GitRunner.local_branch_ref(request)
  end

  test "an exact head and tag collision is rejected as ambiguous", %{root: root} do
    %{origin: origin, source: source} = local_origin_with_source!(root)
    git!(source, ["tag", "main"])
    git!(source, ["push", "origin", "refs/tags/main"])

    assert {:error, :ambiguous_base_ref} =
             GitRunner.prepare(
               request(remote_url: origin, allow_local_fixture: true, base_ref: "main")
             )
  end

  test "a deterministic branch checked out by another worktree is not reset", %{root: root} do
    %{origin: origin} = local_origin_with_source!(root)

    assert {:ok, first} =
             GitRunner.prepare(
               request(remote_url: origin, allow_local_fixture: true, generation: 1)
             )

    target = request(remote_url: origin, allow_local_fixture: true, generation: 2)
    branch_ref = GitRunner.local_branch_ref(target)
    branch_name = String.replace_prefix(branch_ref, "refs/heads/", "")
    other_worktree = Path.join(root, "other-branch-owner")

    git!(root, ["--git-dir", first.cache_path, "branch", branch_name, first.resolved_base_commit])
    git!(root, ["--git-dir", first.cache_path, "worktree", "add", other_worktree, branch_name])

    assert {:error, :workspace_branch_conflict} = GitRunner.prepare(target)
    assert String.trim(git!(other_worktree, ["rev-parse", "HEAD"])) == first.resolved_base_commit
  end

  test "same-target retry converges without force-updating its checked-out branch", %{root: root} do
    %{origin: origin} = local_origin_with_source!(root)
    request = request(remote_url: origin, allow_local_fixture: true)

    assert {:ok, first} = GitRunner.prepare(request)
    assert {:ok, retried} = GitRunner.prepare(request)

    assert retried.worktree_path == first.worktree_path
    assert retried.local_branch_ref == first.local_branch_ref
    assert retried.resolved_base_commit == first.resolved_base_commit
    refute Enum.any?(retried.argv_history, &Enum.member?(&1, "-f"))
    refute Enum.any?(retried.argv_history, &("add" in &1 and "worktree" in &1))
  end

  test "worktree parsing handles spaces and canonical symlink aliases", %{root: root} do
    actual_home = Path.join(root, "actual home with spaces")
    linked_home = Path.join(root, "linked-home")
    File.mkdir_p!(actual_home)
    File.ln_s!(actual_home, linked_home)
    System.put_env("EZAGENT_HOME", linked_home)
    %{origin: origin} = local_origin_with_source!(root)
    request = request(remote_url: origin, allow_local_fixture: true)

    assert {:ok, first} = GitRunner.prepare(request)
    assert {:ok, retried} = GitRunner.prepare(request)
    assert retried.worktree_path == first.worktree_path
    assert :ok = GitRunner.verify(retried)
  end

  test "one unexpected ref probe failure is propagated even when the other ref exists" do
    executor =
      probe_executor(%{
        head: {:error, :git_command_timeout},
        tag: {:ok, %{stdout: "", stderr: "", exit_status: 0}}
      })

    assert {:error, :git_command_timeout} = GitRunner.prepare(request(executor: executor))
  end

  test "both unexpected ref probe failures propagate the first failure" do
    executor =
      probe_executor(%{
        head: {:error, :git_output_limit_exceeded},
        tag: {:error, {:git_exit, 128}}
      })

    assert {:error, :git_output_limit_exceeded} = GitRunner.prepare(request(executor: executor))
  end

  test "fetch and branch command plan owns refs and preserves anonymous execution" do
    owner = self()

    executor = fn argv, opts ->
      send(owner, {:planned_argv, argv, opts})

      stdout =
        cond do
          Enum.take(argv, -3) == ["remote", "get-url", "origin"] ->
            "https://git.example.test/acme/widgets.git\n"

          "show-ref" in argv and Enum.at(argv, -1) =~ "/heads/" ->
            "a" <> String.duplicate("0", 39) <> " refs/ezagent/origin/heads/main\n"

          "show-ref" in argv ->
            ""

          "rev-parse" in argv ->
            String.duplicate("a", 40) <> "\n"

          true ->
            ""
        end

      if "show-ref" in argv and Enum.at(argv, -1) =~ "/tags/" do
        {:error, {:git_exit, 1}}
      else
        {:ok, %{stdout: stdout, stderr: "", exit_status: 0}}
      end
    end

    assert {:ok, prepared} = GitRunner.prepare(request(executor: executor))
    commands = collect_planned_argv([])
    argv_plans = Enum.map(commands, &elem(&1, 0))

    assert Enum.map(argv_plans, &command_kind/1) == [
             :clone,
             :remote,
             :fetch,
             :head_probe,
             :tag_probe,
             :resolve,
             :worktree_list,
             :branch,
             :worktree_add
           ]

    assert Enum.any?(commands, fn {argv, _opts} ->
             Enum.take(argv, -4) == [
               "--prune",
               "origin",
               "+refs/heads/*:refs/ezagent/origin/heads/*",
               "+refs/tags/*:refs/ezagent/origin/tags/*"
             ]
           end)

    refute Enum.any?(commands, fn {argv, _opts} ->
             Enum.any?(argv, &(&1 == prepared.local_branch_ref)) and "fetch" in argv
           end)

    refute Enum.any?(argv_plans, &Enum.member?(&1, "task/task-one"))

    for {argv, opts} <- commands do
      assert is_list(argv)
      assert opts.env == %{"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"}
      refute Map.has_key?(opts, :shell)
      refute Enum.any?(argv, &String.contains?(&1, ["token", "password", "private_key"]))
    end
  end

  test "absence requires both no exact Git registration and no exact directory", %{root: root} do
    worktree = Path.join(root, "still-present")
    File.mkdir_p!(worktree)

    executor = fn _argv, _opts ->
      {:ok, %{stdout: "", stderr: "", exit_status: 0}}
    end

    assert {:error, :worktree_still_present} =
             GitRunner.verify_absent(%{
               cache_path: Path.join(root, "cache.git"),
               worktree_path: worktree,
               runner_opts: %{executor: executor}
             })
  end

  test "absence is idempotent when neither exact cache nor worktree exists", %{root: root} do
    assert :ok =
             GitRunner.verify_absent(%{
               cache_path: Path.join(root, "missing-cache.git"),
               worktree_path: Path.join(root, "missing-worktree")
             })
  end

  test "remove clears only an exact unregistered residual directory", %{root: root} do
    worktree = Path.join(root, "canonical-target")
    unrelated = Path.join(root, "unrelated")
    File.mkdir_p!(worktree)
    File.mkdir_p!(unrelated)

    executor = fn argv, _opts ->
      if "remove" in argv,
        do: {:error, :not_registered},
        else: {:ok, %{stdout: "", stderr: "", exit_status: 0}}
    end

    assert :ok =
             GitRunner.remove(%{
               cache_path: Path.join(root, "cache.git"),
               worktree_path: worktree,
               worktree_identity: "canonical-target",
               runner_opts: %{executor: executor}
             })

    refute File.exists?(worktree)
    assert File.dir?(unrelated)
  end

  test "the command owner enforces its deadline", %{root: root} do
    origin = local_origin!(root)

    assert {:error, {:cache_clone_failed, :git_command_timeout}} =
             GitRunner.prepare(
               request(
                 remote_url: origin,
                 allow_local_fixture: true,
                 deadline_ms: 0
               )
             )
  end

  test "the command owner caps combined output", %{root: root} do
    origin = local_origin!(root)

    assert {:error, {:cache_clone_failed, :git_output_limit_exceeded}} =
             GitRunner.prepare(
               request(
                 remote_url: origin,
                 allow_local_fixture: true,
                 max_output_bytes: 1
               )
             )
  end

  test "verify requires an exact canonical worktree entry" do
    owner = self()
    worktree = Path.join(System.tmp_dir!(), "expected-worktree")

    executor = fn argv, _opts ->
      send(owner, {:verify_argv, argv})

      if "list" in argv do
        {:ok, %{stdout: "worktree #{worktree}-attacker\nHEAD abc\n", stderr: "", exit_status: 0}}
      else
        {:ok, %{stdout: "true\n", stderr: "", exit_status: 0}}
      end
    end

    assert {:error, :worktree_verification_failed} =
             GitRunner.verify(%{
               cache_path: Path.join(System.tmp_dir!(), "cache.git"),
               worktree_path: worktree,
               runner_opts: %{executor: executor}
             })

    assert_receive {:verify_argv, argv}
    assert "list" in argv
    refute_receive {:verify_argv, _}
  end

  test "an existing cache must match the requested origin before worktree creation" do
    owner = self()
    attrs = request([])
    assert {:ok, paths} = Paths.derive(attrs)
    File.mkdir_p!(paths.cache_path)

    executor = fn argv, _opts ->
      send(owner, {:cache_check_argv, argv})

      {:ok,
       %{
         stdout: "https://git.example.test/attacker/repository.git\n",
         stderr: "",
         exit_status: 0
       }}
    end

    assert {:error, :cache_remote_mismatch} =
             attrs |> Map.put(:executor, executor) |> GitRunner.prepare()

    assert_receive {:cache_check_argv, argv}
    assert Enum.take(argv, -3) == ["remote", "get-url", "origin"]
    refute_receive {:cache_check_argv, _}
    refute File.exists?(paths.worktree_path)
  end

  test "configured Git executable must be an absolute existing executable" do
    previous = Application.get_env(:ezagent_domain_workspace, :git_executable)
    Application.put_env(:ezagent_domain_workspace, :git_executable, "relative/git")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezagent_domain_workspace, :git_executable, previous),
        else: Application.delete_env(:ezagent_domain_workspace, :git_executable)
    end)

    executor = fn _argv, _opts -> flunk("invalid executable reached command execution") end
    assert {:error, :invalid_git_executable} = GitRunner.prepare(request(executor: executor))
  end

  test "a failed cache clone removes its partial destination" do
    owner = self()

    executor = fn argv, _opts ->
      destination = List.last(argv)
      File.mkdir_p!(destination)
      File.write!(Path.join(destination, "partial"), "incomplete")
      send(owner, {:partial_cache, destination})
      {:error, :simulated_clone_failure}
    end

    assert {:error, {:cache_clone_failed, :simulated_clone_failure}} =
             GitRunner.prepare(request(executor: executor))

    assert_receive {:partial_cache, destination}
    refute File.exists?(destination)
  end

  test "production source has no shell, System.cmd, or naked Port entry" do
    source =
      File.read!("lib/ezagent/workspace/task_workspace/git_runner.ex")

    refute source =~ "System.cmd"
    refute source =~ "Port.open"
    refute source =~ "sh -c"
    assert source =~ "Ezagent.Runtime.OsProcess"
    assert source =~ "Process.flag(:trap_exit, true)"
    assert source =~ "OsProcess.stop(state.exec_pid)"
    assert source =~ "max_output_bytes"
    assert source =~ "deadline_ms"
    assert source =~ "clear_env: true"
    assert source =~ "@local_fixtures_enabled Mix.env() == :test"
    assert source =~ ":test_injection_not_allowed"
    assert source =~ "if @local_fixtures_enabled"
  end

  defp request(overrides) do
    base = %{
      workspace_uri: Ezagent.URI.workspace("git-runner-team"),
      repository_uri: Ezagent.URI.resource("git-runner-team", "git-repository", "widgets"),
      remote_url: "https://git.example.test/acme/widgets.git",
      base_ref: "main",
      provision_id: "provision-one",
      generation: 1,
      allowed_head_ref: "task/task-one",
      visibility: :public
    }

    Enum.into(overrides, base)
  end

  defp local_origin!(test_root) do
    local_origin_with_source!(test_root).origin
  end

  defp local_origin_with_source!(test_root) do
    root = Path.join(test_root, "origin-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(source)

    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
    %{origin: origin, source: source}
  end

  defp advance_origin_main!(source) do
    File.write!(Path.join(source, "README.md"), "moved\n")
    git!(source, ["add", "README.md"])
    commit_fixture!(source, "move main")
    git!(source, ["push", "origin", "main"])
    String.trim(git!(source, ["rev-parse", "HEAD"]))
  end

  defp create_origin_branch!(source, branch) do
    git!(source, ["checkout", "-b", branch])
    File.write!(Path.join(source, "NEW.md"), "new ref\n")
    git!(source, ["add", "NEW.md"])
    commit_fixture!(source, "new ref")
    git!(source, ["push", "origin", branch])
    String.trim(git!(source, ["rev-parse", "HEAD"]))
  end

  defp commit_fixture!(source, message) do
    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      message
    ])
  end

  defp collect_planned_argv(acc) do
    receive do
      {:planned_argv, argv, opts} -> collect_planned_argv([{argv, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_argv(acc) do
    receive do
      {:argv, argv, opts} -> collect_argv([{argv, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp command_kind(argv) do
    cond do
      "clone" in argv -> :clone
      "remote" in argv -> :remote
      "fetch" in argv -> :fetch
      "show-ref" in argv and Enum.at(argv, -1) =~ "/heads/" -> :head_probe
      "show-ref" in argv -> :tag_probe
      "rev-parse" in argv -> :resolve
      "worktree" in argv and "list" in argv -> :worktree_list
      "branch" in argv -> :branch
      "worktree" in argv and "add" in argv -> :worktree_add
    end
  end

  defp probe_executor(results) do
    fn argv, _opts ->
      cond do
        Enum.take(argv, -3) == ["remote", "get-url", "origin"] ->
          {:ok,
           %{
             stdout: "https://git.example.test/acme/widgets.git\n",
             stderr: "",
             exit_status: 0
           }}

        "show-ref" in argv and Enum.at(argv, -1) =~ "/heads/" ->
          results.head

        "show-ref" in argv ->
          results.tag

        true ->
          {:ok, %{stdout: "", stderr: "", exit_status: 0}}
      end
    end
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    output
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
