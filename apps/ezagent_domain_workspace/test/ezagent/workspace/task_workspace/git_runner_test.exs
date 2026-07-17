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
      {:ok, %{stdout: "", stderr: "", exit_status: 0}}
    end

    assert {:ok, ready} = GitRunner.prepare(request(executor: executor))
    assert_receive {:argv, clone, clone_opts}
    assert_receive {:argv, worktree, worktree_opts}

    for argv <- [clone, worktree] do
      assert is_list(argv)
      assert Enum.all?(argv, &is_binary/1)
      assert "credential.helper=" in argv
      assert "core.askPass=" in argv
      refute Enum.any?(argv, &String.contains?(&1, ["token", "password", "private_key"]))
    end

    assert clone_opts[:env] == %{"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"}
    assert worktree_opts[:env] == clone_opts[:env]
    assert ready.argv_history == [clone, worktree]
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
    origin
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    output
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
