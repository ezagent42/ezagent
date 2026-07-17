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
  def maximum_provision_duration_ms, do: @default_deadline_ms * 11

  @doc false
  @spec local_branch_ref(map()) :: String.t()
  def local_branch_ref(%{provision_id: provision_id, generation: generation}) do
    digest =
      :sha256
      |> :crypto.hash(provision_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "refs/heads/ezagent/task/#{digest}/g#{generation}"
  end

  @doc "Prepares a bare cache and isolated attached worktree."
  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{visibility: :private}), do: {:error, :private_checkout_not_supported}

  def prepare(%{visibility: :public} = request) do
    with :ok <- validate_test_injection(request),
         :ok <- validate_remote(request),
         :ok <- validate_git_executable(),
         {:ok, paths} <- Paths.derive(request),
         :ok <- File.mkdir_p(Path.dirname(paths.cache_path)),
         {:ok, clone_history} <- ensure_cache(request, paths),
         opts = command_opts(request),
         remote_argv =
           git_argv(["--git-dir", paths.cache_path, "remote", "get-url", "origin"]),
         :ok <- execute_matching_remote(remote_argv, opts, request.remote_url),
         fetch_argv =
           git_argv([
             "--git-dir",
             paths.cache_path,
             "fetch",
             "--prune",
             "origin",
             "+refs/heads/*:refs/ezagent/origin/heads/*",
             "+refs/tags/*:refs/ezagent/origin/tags/*"
           ]),
         {:ok, _fetch} <- execute(fetch_argv, opts),
         head_ref = "refs/ezagent/origin/heads/#{request.base_ref}",
         tag_ref = "refs/ezagent/origin/tags/#{request.base_ref}",
         head_probe =
           git_argv(["--git-dir", paths.cache_path, "show-ref", "--verify", "--quiet", head_ref]),
         tag_probe =
           git_argv(["--git-dir", paths.cache_path, "show-ref", "--verify", "--quiet", tag_ref]),
         {:ok, resolved_ref} <-
           resolve_exactly_one_ref(head_ref, head_probe, tag_ref, tag_probe, opts),
         resolve_argv =
           git_argv([
             "--git-dir",
             paths.cache_path,
             "rev-parse",
             "--verify",
             "#{resolved_ref}^{commit}"
           ]),
         {:ok, resolved} <- execute(resolve_argv, opts),
         {:ok, resolved_sha} <- validate_object_id(resolved.stdout),
         local_branch = local_branch_ref(request),
         local_branch_name = String.replace_prefix(local_branch, "refs/heads/", ""),
         branch_owner_argv =
           git_argv(["--git-dir", paths.cache_path, "worktree", "list", "--porcelain", "-z"]),
         {:ok, branch_owners} <- execute(branch_owner_argv, opts),
         proof =
           Map.merge(paths, %{
             resolved_base_commit: resolved_sha,
             local_branch_ref: local_branch
           }),
         {:ok, worktree_history} <-
           prepare_worktree(
             branch_owners.stdout,
             local_branch,
             local_branch_name,
             resolved_sha,
             paths,
             proof,
             opts
           ) do
      {:ok,
       Map.merge(paths, %{
         argv_history:
           clone_history ++
             [
               remote_argv,
               fetch_argv,
               head_probe,
               tag_probe,
               resolve_argv,
               branch_owner_argv
             ] ++ worktree_history,
         base_ref: request.base_ref,
         resolved_base_commit: resolved_sha,
         local_branch_ref: local_branch,
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
    list_argv = git_argv(["--git-dir", cache, "worktree", "list", "--porcelain", "-z"])
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

    if File.exists?(cache) do
      opts = command_opts(Map.get(ready, :runner_opts, %{}))

      case execute(argv, opts) do
        {:ok, _result} -> remove_exact_residual(worktree, ready)
        {:error, _reason} = error -> remove_if_unregistered(cache, worktree, ready, opts, error)
      end
    else
      remove_exact_residual(worktree, ready)
    end
  end

  def remove(_ready), do: {:error, :invalid_ready_workspace}

  @doc "Verifies the exact worktree is absent from Git and the filesystem."
  @spec verify_absent(map()) :: :ok | {:error, term()}
  def verify_absent(%{cache_path: cache, worktree_path: worktree} = ready)
      when is_binary(cache) and is_binary(worktree) do
    if File.exists?(cache) do
      argv = git_argv(["--git-dir", cache, "worktree", "list", "--porcelain", "-z"])

      with {:ok, result} <- execute(argv, command_opts(Map.get(ready, :runner_opts, %{}))),
           false <- listed_worktree?(result.stdout, worktree),
           false <- File.exists?(worktree) do
        :ok
      else
        true -> {:error, :worktree_still_present}
        {:error, _reason} = error -> error
      end
    else
      if File.exists?(worktree), do: {:error, :worktree_still_present}, else: :ok
    end
  end

  def verify_absent(_ready), do: {:error, :invalid_ready_workspace}

  defp remove_if_unregistered(cache, worktree, ready, opts, original_error) do
    list_argv = git_argv(["--git-dir", cache, "worktree", "list", "--porcelain", "-z"])

    case execute(list_argv, opts) do
      {:ok, result} ->
        if listed_worktree?(result.stdout, worktree),
          do: original_error,
          else: remove_exact_residual(worktree, ready)

      {:error, _reason} ->
        original_error
    end
  end

  defp remove_exact_residual(worktree, %{worktree_identity: identity})
       when is_binary(identity) and identity != "" do
    expanded = Path.expand(worktree)

    if Path.type(worktree) == :absolute and expanded == worktree and
         Path.dirname(expanded) != expanded and Path.basename(expanded) == identity do
      case File.rm_rf(worktree) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, {:worktree_residual_remove_failed, reason}}
      end
    else
      {:error, :invalid_ready_workspace}
    end
  end

  defp remove_exact_residual(_worktree, _ready), do: {:error, :invalid_ready_workspace}

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

  def handle_info({:EXIT, exec_pid, {:exit_status, status}}, %{exec_pid: exec_pid} = state) do
    error =
      case :exec.status(status) do
        {:status, exit_status} -> {:git_exit, exit_status}
        {:signal, _signal, _core_dump?} -> :git_process_failed
      end

    reply_and_stop({:error, error}, state)
  end

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
      {:ok, []}
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

  defp matching_remote(result, expected) do
    if String.trim(result.stdout) == expected, do: :ok, else: {:error, :cache_remote_mismatch}
  end

  defp execute_matching_remote(argv, opts, expected) do
    case execute(argv, opts) do
      {:ok, result} -> matching_remote(result, expected)
      {:error, _reason} -> {:error, :cache_remote_mismatch}
    end
  end

  defp resolve_exactly_one_ref(head_ref, head_argv, tag_ref, tag_argv, opts) do
    head = probe_ref(head_argv, opts)
    tag = probe_ref(tag_argv, opts)

    case {head, tag} do
      {{:error, reason}, _tag} -> {:error, reason}
      {_head, {:error, reason}} -> {:error, reason}
      {:present, :absent} -> {:ok, head_ref}
      {:absent, :present} -> {:ok, tag_ref}
      {:absent, :absent} -> {:error, :base_ref_not_found}
      {:present, :present} -> {:error, :ambiguous_base_ref}
    end
  end

  defp probe_ref(argv, opts) do
    case execute(argv, opts) do
      {:ok, _result} -> :present
      {:error, {:git_exit, 1}} -> :absent
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_object_id(stdout) do
    object_id = String.trim(stdout)

    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, object_id),
      do: {:ok, object_id},
      else: {:error, :invalid_resolved_object_id}
  end

  defp prepare_worktree(
         porcelain,
         branch_ref,
         branch_name,
         resolved_sha,
         paths,
         proof,
         opts
       ) do
    case branch_owner(porcelain, branch_ref, paths.worktree_path) do
      :available ->
        branch_argv =
          git_argv([
            "--git-dir",
            paths.cache_path,
            "branch",
            "-f",
            branch_name,
            resolved_sha
          ])

        worktree_argv =
          git_argv([
            "--git-dir",
            paths.cache_path,
            "worktree",
            "add",
            paths.worktree_path,
            branch_name
          ])

        with {:ok, _branch} <- execute(branch_argv, opts),
             :ok <- File.mkdir_p(Path.dirname(paths.worktree_path)) do
          case execute(worktree_argv, opts) do
            {:ok, _result} -> {:ok, [branch_argv, worktree_argv]}
            {:error, reason} -> {:error, {:worktree_add_failed, reason}, proof}
          end
        end

      {:same_target, ^resolved_sha} ->
        {:ok, []}

      {:same_target, _other_sha} ->
        {:error, :workspace_branch_conflict}

      :conflict ->
        {:error, :workspace_branch_conflict}
    end
  end

  defp branch_owner(porcelain, branch_ref, expected_path) do
    porcelain
    |> worktree_entries()
    |> Enum.find(&(&1.branch == branch_ref))
    |> case do
      nil ->
        :available

      %{path: path, head: head} ->
        if File.dir?(expected_path) and same_path?(path, expected_path),
          do: {:same_target, head},
          else: :conflict
    end
  end

  defp worktree_entries(porcelain) do
    porcelain
    |> String.split(<<0, 0>>, trim: true)
    |> Enum.map(fn record ->
      fields = String.split(record, <<0>>, trim: true)

      %{
        path: field_value(fields, "worktree "),
        head: field_value(fields, "HEAD "),
        branch: field_value(fields, "branch ")
      }
    end)
  end

  defp field_value(fields, prefix) do
    Enum.find_value(fields, fn field ->
      if String.starts_with?(field, prefix), do: String.replace_prefix(field, prefix, "")
    end)
  end

  defp same_path?(left, right) do
    left = Path.expand(left)
    right = Path.expand(right)

    case {File.stat(left), File.stat(right)} do
      {{:ok, left_stat}, {:ok, right_stat}} ->
        left_stat.inode == right_stat.inode and
          left_stat.major_device == right_stat.major_device and
          left_stat.minor_device == right_stat.minor_device

      _missing ->
        left == right
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
    case Ezagent.URI.strict_external_new(remote) do
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
    porcelain
    |> worktree_entries()
    |> Enum.any?(fn %{path: path} ->
      is_binary(path) and same_path?(path, expected_path)
    end)
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
