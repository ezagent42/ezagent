defmodule Ezagent.Workspace.TaskWorkspace.GitRunner do
  @moduledoc """
  Executes bounded anonymous Git argv plans for task workspace preparation.

  Production transport accepts HTTPS without userinfo. A local path is accepted
  only behind the explicit test-fixture flag. Every real command is owned by a
  trapping GenServer and spawned through `Ezagent.Runtime.OsProcess`.
  """

  use GenServer

  alias Ezagent.Runtime.OsProcess
  alias Ezagent.Workspace.TaskWorkspace.Paths

  @git_env %{"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"}
  @git_args_prefix ["-c", "credential.helper=", "-c", "core.askPass="]
  @default_deadline_ms 30_000
  @default_max_output_bytes 65_536
  @local_fixtures_enabled Mix.env() == :test

  @type command_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_status: non_neg_integer()
        }

  @doc false
  def maximum_provision_duration_ms, do: @default_deadline_ms * 4

  @doc "Prepares a bare cache and isolated detached worktree."
  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{visibility: :private}), do: {:error, :private_checkout_not_supported}

  def prepare(%{visibility: :public} = request) do
    with :ok <- validate_test_injection(request),
         :ok <- validate_remote(request),
         :ok <- validate_git_executable(),
         {:ok, paths} <- Paths.derive(request),
         :ok <- File.mkdir_p(Path.dirname(paths.cache_path)),
         {:ok, clone_history} <- ensure_cache(request, paths),
         :ok <- File.mkdir_p(Path.dirname(paths.worktree_path)),
         worktree_argv <-
           git_argv([
             "--git-dir",
             paths.cache_path,
             "worktree",
             "add",
             "--detach",
             paths.worktree_path,
             request.base_ref
           ]),
         {:ok, _result} <- execute_worktree_add(worktree_argv, request) do
      {:ok,
       Map.merge(paths, %{
         argv_history: clone_history ++ [worktree_argv],
         base_ref: request.base_ref,
         allowed_head_ref: request.allowed_head_ref,
         runner_opts: retained_runner_opts(request)
       })}
    end
  end

  def prepare(%{visibility: _other}), do: {:error, :invalid_visibility}
  def prepare(_request), do: {:error, :invalid_git_request}

  @doc "Verifies that Git recognizes the expected cache-owned worktree."
  @spec verify(map()) :: :ok | {:error, term()}
  def verify(%{cache_path: cache, worktree_path: worktree} = ready)
      when is_binary(cache) and is_binary(worktree) do
    opts = command_opts(Map.get(ready, :runner_opts, %{}))
    list_argv = git_argv(["--git-dir", cache, "worktree", "list", "--porcelain"])
    inside_argv = git_argv(["-C", worktree, "rev-parse", "--is-inside-work-tree"])

    with {:ok, list} <- execute(list_argv, opts),
         true <- listed_worktree?(list.stdout, worktree),
         {:ok, inside} <- execute(inside_argv, opts),
         true <- String.trim(inside.stdout) == "true" do
      :ok
    else
      false -> {:error, :worktree_verification_failed}
      {:error, _reason} = error -> error
    end
  end

  def verify(_ready), do: {:error, :invalid_ready_workspace}

  @doc "Removes the isolated worktree through its owning bare cache."
  @spec remove(map()) :: :ok | {:error, term()}
  def remove(%{cache_path: cache, worktree_path: worktree} = ready)
      when is_binary(cache) and is_binary(worktree) do
    argv = git_argv(["--git-dir", cache, "worktree", "remove", "--force", worktree])

    case execute(argv, command_opts(Map.get(ready, :runner_opts, %{}))) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def remove(_ready), do: {:error, :invalid_ready_workspace}

  @doc false
  @impl true
  def init({argv, opts}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       argv: argv,
       opts: opts,
       caller: nil,
       exec_pid: nil,
       os_pid: nil,
       stdout: "",
       stderr: "",
       output_bytes: 0,
       timer: nil
     }}
  end

  @doc false
  @impl true
  def handle_call(:await, caller, state),
    do: {:noreply, %{state | caller: caller}, {:continue, :spawn}}

  @doc false
  @impl true
  def handle_continue(:spawn, state) do
    spawn_opts = [
      cd: state.opts.cd,
      env: state.opts.env,
      clear_env: true,
      stderr: :separate
    ]

    case OsProcess.spawn(state.argv, spawn_opts) do
      {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} ->
        timer = Process.send_after(self(), :deadline, state.opts.deadline_ms)
        {:noreply, %{state | exec_pid: exec_pid, os_pid: os_pid, timer: timer}}

      {:error, reason} ->
        reply_and_stop({:error, {:git_spawn_failed, reason}}, state)
    end
  end

  @doc false
  @impl true
  def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid} = state),
    do: append_output(:stdout, bytes, state)

  def handle_info({:stderr, os_pid, bytes}, %{os_pid: os_pid} = state),
    do: append_output(:stderr, bytes, state)

  def handle_info({:EXIT, exec_pid, :normal}, %{exec_pid: exec_pid} = state) do
    reply_and_stop(
      {:ok, %{stdout: state.stdout, stderr: state.stderr, exit_status: 0}},
      state
    )
  end

  def handle_info({:EXIT, exec_pid, {:exit_status, status}}, %{exec_pid: exec_pid} = state),
    do: reply_and_stop({:error, {:git_exit, status}}, state)

  def handle_info({:EXIT, exec_pid, _reason}, %{exec_pid: exec_pid} = state),
    do: reply_and_stop({:error, :git_process_failed}, state)

  def handle_info(:deadline, state) do
    :ok = OsProcess.stop(state.exec_pid)
    reply_and_stop({:error, :git_command_timeout}, %{state | exec_pid: nil})
  end

  @doc false
  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer)
    OsProcess.stop(state.exec_pid)
  end

  defp ensure_cache(request, paths) do
    if File.dir?(paths.cache_path) do
      verify_cache_remote(request, paths.cache_path)
    else
      argv = git_argv(["clone", "--bare", request.remote_url, paths.cache_path])

      case execute(argv, command_opts(request)) do
        {:ok, _result} ->
          {:ok, [argv]}

        {:error, reason} ->
          File.rm_rf(paths.cache_path)
          {:error, {:cache_clone_failed, reason}}
      end
    end
  end

  defp verify_cache_remote(request, cache_path) do
    argv = git_argv(["--git-dir", cache_path, "remote", "get-url", "origin"])

    case execute(argv, command_opts(request)) do
      {:ok, result} ->
        if String.trim(result.stdout) == request.remote_url,
          do: {:ok, [argv]},
          else: {:error, :cache_remote_mismatch}

      {:error, _reason} ->
        {:error, :cache_remote_mismatch}
    end
  end

  defp execute_worktree_add(argv, request) do
    case execute(argv, command_opts(request)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:worktree_add_failed, reason}}
    end
  end

  defp execute(argv, %{executor: executor} = opts) when is_function(executor, 2),
    do: executor.(argv, Map.drop(opts, [:executor]))

  defp execute(argv, opts) do
    with {:ok, owner} <- GenServer.start(__MODULE__, {argv, opts}) do
      GenServer.call(owner, :await, opts.deadline_ms + 2_000)
    end
  end

  defp append_output(stream, bytes, state) do
    binary = IO.iodata_to_binary(bytes)
    total = state.output_bytes + byte_size(binary)

    if total > state.opts.max_output_bytes do
      :ok = OsProcess.stop(state.exec_pid)
      reply_and_stop({:error, :git_output_limit_exceeded}, %{state | exec_pid: nil})
    else
      state = Map.update!(state, stream, &(&1 <> binary))
      {:noreply, %{state | output_bytes: total}}
    end
  end

  defp reply_and_stop(reply, state) do
    cancel_timer(state.timer)
    GenServer.reply(state.caller, reply)
    {:stop, :normal, state}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp validate_remote(%{remote_url: remote} = request) when is_binary(remote) do
    if @local_fixtures_enabled and Map.get(request, :allow_local_fixture, false) do
      if Path.type(remote) == :absolute and File.dir?(remote),
        do: :ok,
        else: validate_https(remote)
    else
      validate_https(remote)
    end
  end

  defp validate_remote(_request), do: {:error, :invalid_remote_url}

  defp validate_test_injection(request) do
    if Map.has_key?(request, :executor) and not @local_fixtures_enabled,
      do: {:error, :test_injection_not_allowed},
      else: :ok
  end

  defp validate_https(remote) do
    case URI.new(remote) do
      {:ok, %URI{userinfo: userinfo}} when not is_nil(userinfo) ->
        {:error, :remote_userinfo_not_allowed}

      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        :ok

      {:ok, %URI{}} ->
        {:error, :https_remote_required}

      {:error, _reason} ->
        {:error, :invalid_remote_url}
    end
  end

  defp git_argv(args), do: [git_executable() | @git_args_prefix ++ args]

  # erlexec receives an intentionally minimal environment, so executable
  # lookup must happen in the BEAM before that environment boundary.
  defp git_executable do
    Application.get_env(:ezagent_domain_workspace, :git_executable) ||
      System.find_executable("git") || "git"
  end

  defp validate_git_executable do
    executable = git_executable()

    if is_binary(executable) and Path.type(executable) == :absolute and
         File.regular?(executable) and System.find_executable(executable) == executable,
       do: :ok,
       else: {:error, :invalid_git_executable}
  end

  defp listed_worktree?(porcelain, expected_path) do
    expected = "worktree " <> Path.expand(expected_path)

    porcelain
    |> String.split("\n", trim: true)
    |> Enum.any?(&(&1 == expected))
  end

  defp command_opts(request) do
    %{
      cd: Map.get(request, :command_cwd, System.tmp_dir!()),
      env: @git_env,
      deadline_ms: Map.get(request, :deadline_ms, @default_deadline_ms),
      max_output_bytes: Map.get(request, :max_output_bytes, @default_max_output_bytes),
      executor: if(@local_fixtures_enabled, do: Map.get(request, :executor), else: nil)
    }
  end

  defp retained_runner_opts(request) do
    keys =
      if @local_fixtures_enabled,
        do: [:deadline_ms, :max_output_bytes, :executor],
        else: [:deadline_ms, :max_output_bytes]

    Map.take(request, keys)
  end
end
