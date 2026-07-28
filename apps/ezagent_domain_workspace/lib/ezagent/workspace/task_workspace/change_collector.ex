defmodule Ezagent.Workspace.TaskWorkspace.ChangeCollector do
  @moduledoc """
  Collects the V1 bounded UTF-8 upsert change envelope from an owned, ready
  task workspace (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §2.2, §4.2).

  `collect/1` fresh-reads the exact ready `Provision` row named by the
  request's `provision_id`, cross-checks it against the request's
  `task_access_uri`/`task_uri`/`generation` identity (the "ready-provision
  proof"), then classifies every path `GitRunner.collect_status/1` reports
  against the worktree's index:

    * untracked (`??`) or modified (`M`/`A` on either side) regular files
      whose mode did not change become upsert candidates;
    * anything else outside the V1 envelope — deleted (`D`), renamed or
      copied (`R`/`C`, which `GitRunner` suppresses via `--no-renames` so
      they always present as a delete plus an untracked add and are
      caught by the delete half), unmerged (`U`), a symlink, a
      non-regular path (a submodule mount is a directory on disk — the
      same "must be a regular file" check that rejects symlinks rejects
      it too), a file whose HEAD/index/worktree mode disagree in either
      direction (adding or removing the executable bit) or a newly-added
      executable file, or content that is not valid UTF-8 or contains an
      embedded NUL byte — rejects the WHOLE collection with
      `{:error, :unsupported_workspace_change}`. This module never
      silently drops an offending path and returns the rest.

  Every candidate is also re-validated through
  `Ezagent.DomainGit.FileChange.new/1` (path traversal, `.git` segments,
  control bytes) and the batch through
  `Ezagent.DomainGit.FileChange.validate_many/1` (`ChangeLimits`) — both
  chokepoints this module reuses rather than re-implements.

  Closed result vocabulary:

    * `{:ok, [FileChange.t()]}` — one or more upserts.
    * `{:error, :workspace_not_ready}` — no ready provision matches
      `provision_id`.
    * `{:error, :workspace_identity_mismatch}` — a ready provision exists
      for `provision_id` but its task_access/task/generation identity does
      not match the request exactly.
    * `{:error, :no_changes_collected}` — the worktree has zero changes
      against its index. This is a non-retryable blocker, not a provider
      failure (design §7.1, "no_changes_collected" semantics) — V1 creates
      no PR for an empty diff. Classification of this code into the
      broader retry policy is P4's job; this module only ever produces it.
    * `{:error, :unsupported_workspace_change}` — see above.
    * `{:error, :change_limit_exceeded}` — `ChangeLimits` breached (a
      single file's bytes, the file count, or the total bytes).
    * `{:error, :workspace_read_failed}` — a reported path could not be
      read (a filesystem race between enumeration and read), or the
      underlying `GitRunner.collect_status/1` call itself failed for any
      infrastructure reason (timeout, output-limit, spawn failure, a
      checkout mismatch); every such reason is normalized to this one
      blocker and never forwarded.
    * `{:error, :invalid_change_limits_config}` — propagated from
      `Ezagent.DomainGit.ChangeLimits.current/0`.

  Never runs provider HTTP, never accepts a caller-chosen filesystem path,
  never sees a token.
  """

  @behaviour Ezagent.DomainGit.WorkspaceChangePort

  import Bitwise

  alias Ezagent.DomainGit.{ChangeLimits, FileChange, WorkspaceChangePort}
  alias Ezagent.Workspace.TaskWorkspace.{GitRunner, Provision, Store}

  @impl true
  @spec collect(WorkspaceChangePort.Request.t()) :: WorkspaceChangePort.result()
  def collect(%WorkspaceChangePort.Request{} = request) do
    with {:ok, row} <- fresh_ready_provision(request),
         {:ok, limits} <- ChangeLimits.current(),
         {:ok, entries} <- fetch_status(row.worktree_path),
         {:ok, candidate_paths} <- classify(entries),
         :ok <- at_least_one_change(candidate_paths),
         {:ok, changes} <- read_candidates(row.worktree_path, candidate_paths, limits),
         :ok <- FileChange.validate_many(changes) do
      {:ok, changes}
    end
  end

  def collect(_request), do: {:error, :invalid_change_request}

  defp fresh_ready_provision(request) do
    case Store.get_by_provision_id(request.provision_id) do
      %Provision{status: :ready} = row -> exact_identity(row, request)
      %Provision{} -> {:error, :workspace_not_ready}
      nil -> {:error, :workspace_not_ready}
    end
  end

  defp exact_identity(row, request) do
    if row.task_access_uri == URI.to_string(request.task_access_uri) and
         row.task_uri == URI.to_string(request.task_uri) and
         row.generation == request.generation do
      {:ok, row}
    else
      {:error, :workspace_identity_mismatch}
    end
  end

  # `GitRunner.collect_status/1`'s failures (a stable `:workspace_checkout_mismatch`,
  # or a raw infrastructure reason such as `:git_output_limit_exceeded` or
  # `{:git_spawn_failed, reason}`) are outside this module's closed
  # vocabulary. Normalize every one of them to the single stable blocker,
  # dropping the underlying reason rather than forwarding it.
  defp fetch_status(worktree_path) do
    case GitRunner.configured().collect_status(%{worktree_path: worktree_path}) do
      {:ok, entries} -> {:ok, entries}
      {:error, _reason} -> {:error, :workspace_read_failed}
    end
  end

  defp at_least_one_change([]), do: {:error, :no_changes_collected}
  defp at_least_one_change(_paths), do: :ok

  defp classify(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case classify_entry(entry) do
        {:upsert, path} -> {:cont, {:ok, [path | acc]}}
        :ignored -> {:cont, {:ok, acc}}
        :unsupported -> {:halt, {:error, :unsupported_workspace_change}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _reason} = error -> error
    end
  end

  defp classify_entry(%{index_status: "?", worktree_status: "?", path: path}),
    do: {:upsert, path}

  defp classify_entry(%{index_status: "!", worktree_status: "!"}), do: :ignored

  defp classify_entry(%{index_status: x, worktree_status: y})
       when x in ~w(D R C U) or y in ~w(D R C U),
       do: :unsupported

  defp classify_entry(%{index_status: x, worktree_status: y, path: path} = entry)
       when x in ~w(M A) or y in ~w(M A) do
    if mode_changed?(entry), do: :unsupported, else: {:upsert, path}
  end

  defp classify_entry(_entry), do: :unsupported

  # `GitRunner.collect_status/1` (porcelain v2) reports the HEAD, index, and
  # worktree file mode for every ordinary tracked entry. Design §2.2 forbids
  # a mode change in either direction, so any deviation among the three is
  # rejected here — not just "is the worktree copy currently executable"
  # (that alone only ever catches the add-executable-bit direction; see the
  # existing `not_executable/1` check below, which stays as the
  # filesystem-level fallback for untracked paths that have no HEAD mode to
  # compare against).
  defp mode_changed?(%{head_mode: nil}), do: false

  defp mode_changed?(%{head_mode: "000000", worktree_mode: worktree_mode}),
    do: executable_mode?(worktree_mode)

  defp mode_changed?(%{
         head_mode: head_mode,
         index_mode: index_mode,
         worktree_mode: worktree_mode
       }),
       do: head_mode != index_mode or head_mode != worktree_mode

  defp mode_changed?(_entry), do: false

  defp executable_mode?(mode) when is_binary(mode) do
    case Integer.parse(mode, 8) do
      {value, ""} -> (value &&& 0o111) != 0
      _other -> false
    end
  end

  defp executable_mode?(_mode), do: false

  defp read_candidates(worktree_path, paths, limits) do
    worktree_root = Path.expand(worktree_path)

    paths
    |> Enum.reduce_while({:ok, [], 0, 0}, fn path, {:ok, acc, count, total_bytes} ->
      read_one(worktree_root, path, limits, acc, count, total_bytes)
    end)
    |> case do
      {:ok, changes, _count, _total_bytes} -> {:ok, Enum.reverse(changes)}
      {:error, _reason} = error -> error
    end
  end

  defp read_one(worktree_root, path, limits, acc, count, total_bytes) do
    with {:ok, full_path} <- contained_path(worktree_root, path),
         {:ok, stat} <- safe_lstat(full_path),
         :ok <- regular_file(stat),
         :ok <- not_executable(stat),
         {:ok, content} <- read_bounded(full_path, limits.max_file_bytes),
         next_count = count + 1,
         next_total = total_bytes + byte_size(content),
         :ok <- within_batch_limits(next_count, next_total, limits),
         :ok <- not_binary(content),
         {:ok, change} <- FileChange.new(%{path: path, operation: :upsert, content: content}) do
      {:cont, {:ok, [change | acc], next_count, next_total}}
    else
      {:error, :change_limit_exceeded} -> {:halt, {:error, :change_limit_exceeded}}
      {:error, :workspace_read_failed} -> {:halt, {:error, :workspace_read_failed}}
      {:error, _reason} -> {:halt, {:error, :unsupported_workspace_change}}
    end
  end

  defp contained_path(_worktree_root, "/" <> _rest), do: {:error, :path_escapes_worktree}

  defp contained_path(worktree_root, relative_path) do
    full_path = Path.expand(Path.join(worktree_root, relative_path))

    if full_path == worktree_root or String.starts_with?(full_path, worktree_root <> "/") do
      {:ok, full_path}
    else
      {:error, :path_escapes_worktree}
    end
  end

  defp safe_lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _reason} -> {:error, :workspace_read_failed}
    end
  end

  defp regular_file(%File.Stat{type: :regular}), do: :ok
  defp regular_file(%File.Stat{}), do: {:error, :not_regular_file}

  defp not_executable(%File.Stat{mode: mode}) do
    if (mode &&& 0o111) == 0, do: :ok, else: {:error, :executable_mode}
  end

  defp within_batch_limits(count, total_bytes, limits) do
    if count <= limits.max_files and total_bytes <= limits.max_total_bytes,
      do: :ok,
      else: {:error, :change_limit_exceeded}
  end

  # `contained_path/2` + `safe_lstat/1` above establish that `full_path` is
  # inside the worktree and, at that instant, a regular non-executable
  # file — but the check and this read are two separate syscalls, not one
  # atomic operation, so a concurrent writer can still grow or replace the
  # path in between. That gap is accepted here, not closed: the sole
  # concurrent writer into a task worktree is the managed Agent, in-VM code
  # this project's threat model already trusts (CLAUDE.md security
  # posture; the actor-convergence Path A scoping). A future change that
  # lets untrusted code write into a task worktree invalidates this
  # assumption and the gap must be closed then.
  #
  # What IS closed here: the read itself never allocates more than
  # `max_file_bytes + 1` bytes, so a file that grows after the stat above
  # captured a small size cannot force an unbounded read — the limit is
  # enforced by the read call itself, not by trusting the earlier stat.
  defp read_bounded(path, max_file_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, max_file_bytes + 1) do
            :eof -> {:ok, ""}
            {:error, _reason} -> {:error, :workspace_read_failed}
            content when byte_size(content) > max_file_bytes -> {:error, :change_limit_exceeded}
            content -> {:ok, content}
          end
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :workspace_read_failed}
    end
  end

  defp not_binary(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, :binary_content}
  end
end
