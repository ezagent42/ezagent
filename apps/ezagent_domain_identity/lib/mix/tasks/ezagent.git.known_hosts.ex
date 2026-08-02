defmodule Mix.Tasks.Ezagent.Git.KnownHosts do
  @shortdoc "生成节点级 known_hosts（SSH 凭据 1b）"

  @moduledoc """
  Scan forge host keys into the node-level `known_hosts` that every agent's git
  identity copies from.

      mix ezagent.git.known_hosts github.com --out /var/lib/ezagent/git/known_hosts

  Then point the runtime at it:

      config :ezagent_core, :git_known_hosts_path, "/var/lib/ezagent/git/known_hosts"

  `--out` may be omitted only when that config value is already set (the task
  then OVERWRITES it). There is **no default path** — writing an operator
  file under a guessed location is worse than asking.

  ## Why not ship forge host keys in the repo

  They rotate. A stale committed key surfaces as node-wide clone failure with no
  hint about which file to fix.

  ## This REPLACES the file's entire contents — it does not merge

  Every invocation truncates and rewrites `--out` from scratch (M4, Task 5
  复审 — an earlier version of this doc said "refreshes it in place", which
  reads like a merge; it isn't one). Running this task a second time for a
  different forge does not ADD to the first forge's entry, it OVERWRITES it,
  and every agent whose git identity depends on the now-missing entry starts
  failing `StrictHostKeyChecking=yes`. List every host you need in ONE
  invocation:

      mix ezagent.git.known_hosts github.com gitlab.internal --out /var/lib/ezagent/git/known_hosts

  ## Why an empty scan is refused

  `write_scanned/2`'s empty-output check is a SECOND line of defense, not the
  primary one (H1, Task 5 复审 — an earlier version of this doc got the
  causality backwards here). `ssh-keyscan`'s exit-code contract is "did it
  get AT LEAST ONE key", not "did every requested host resolve" — scanning
  several hosts where only some are reachable can still exit 0, with output
  that silently omits the unreachable ones. That per-host gap is
  `missing_hosts/2`'s job (see below), not this one. Empirically, on this
  platform (OpenSSH, verified 2026-08-02), a scan that resolves NOTHING at
  all exits 1, not 0 — so `run/1`'s normal flow cannot actually reach
  `write_scanned("")`; `scan/1` already turns that into
  `{:error, {:ssh_keyscan_exit, 1}}` first. Kept anyway because that exit-code
  behavior is not a contract this task can rely on across every platform and
  OpenSSH version — an empty `known_hosts` is refused either way it's reached.

  ## Partial scans are refused too

  Requesting N hosts and getting keys for fewer than N is refused
  (`{:error, {:hosts_not_scanned, missing}}`, naming exactly which ones) —
  see `missing_hosts/2`. Without this, an operator scanning `github.com
  gitlab.internal` while `gitlab.internal` happens to be down gets a
  `known_hosts` that looks complete (the task prints `wrote ...`) but is
  silently missing an entry; every agent cloning from `gitlab.internal` then
  fails host-key verification, with no hint that THIS task is where the gap
  came from.
  """

  use Mix.Task

  alias Ezagent.Credential.GitIdentityRuntime

  @requirements ["app.config"]
  @scan_timeout_ms 15_000
  @file_mode 0o644

  @impl Mix.Task
  def run(argv) do
    # M5 (Task 5 复审): no `Mix.Task.run("app.start")` — this task only reads
    # config (`GitIdentityRuntime.known_hosts_path/0` is a plain
    # `Application.get_env`) and shells out to `ssh-keyscan`; it dispatches
    # into nothing and touches no DB. `@requirements ["app.config"]` above
    # already loads config. Booting the full umbrella here would make this
    # NODE-BOOTSTRAP-TIME task (the operator runs it to prep host keys BEFORE
    # agents can clone) fail outright on a fresh machine whose DB isn't
    # migrated yet — exactly the moment it's meant to be run. (The grant task
    # genuinely dispatches into a live User Kind, so it keeps `app.start`.)
    with {:ok, %{hosts: hosts, out: out}} <- plan(argv),
         {:ok, scanned} <- scan(hosts),
         :ok <- write_scanned(out, scanned) do
      Mix.shell().info("wrote #{out}")
      Mix.shell().info(~s|set: config :ezagent_core, :git_known_hosts_path, "#{out}"|)
    else
      {:error, reason} -> Mix.raise("ezagent.git.known_hosts failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec plan([String.t()]) :: {:ok, %{hosts: [String.t()], out: String.t()}} | {:error, term()}
  def plan(argv) do
    {opts, hosts, _} = OptionParser.parse(argv, strict: [out: :string])

    out = Keyword.get(opts, :out) || GitIdentityRuntime.known_hosts_path()

    cond do
      hosts == [] -> {:error, :no_hosts}
      is_nil(out) -> {:error, :no_output_path}
      true -> {:ok, %{hosts: hosts, out: out}}
    end
  end

  @doc false
  @spec write_scanned(String.t(), String.t()) :: :ok | {:error, term()}
  def write_scanned(out, scanned) when is_binary(scanned) do
    if String.trim(scanned) == "" do
      {:error, :empty_scan}
    else
      with :ok <- File.mkdir_p(Path.dirname(out)),
           :ok <- File.write(out, scanned),
           :ok <- File.chmod(out, @file_mode) do
        :ok
      end
    end
  end

  # H1 (Task 5 复审): `ssh-keyscan`'s exit code means "got at least one key",
  # not "got every requested host" — scanning `github.com gitlab.internal`
  # while `gitlab.internal` is down still exits 0, with output that just
  # omits it. Diff the requested hosts against what actually came back and
  # refuse (naming what's missing) rather than silently writing a partial
  # known_hosts that looks complete.
  defp scan(hosts) do
    case run_keyscan(hosts) do
      {:ok, {out, 0}} ->
        case missing_hosts(hosts, out) do
          [] -> {:ok, out}
          missing -> {:error, {:hosts_not_scanned, missing}}
        end

      {:ok, {_out, code}} ->
        {:error, {:ssh_keyscan_exit, code}}

      {:error, _reason} = error ->
        error
    end
  end

  # M6 (Task 5 复审): the pure part of H1's fix, exposed so it is directly
  # unit-testable without ever invoking a real `ssh-keyscan` — feed it a
  # requested host list and a scan output string, assert on the diff.
  # `ssh-keyscan` writes one key per line, `<host> <keytype> <base64key>`;
  # the host is the first whitespace-delimited field.
  @doc false
  @spec missing_hosts([String.t()], String.t()) :: [String.t()]
  def missing_hosts(requested_hosts, scanned) do
    found =
      scanned
      |> String.split("\n", trim: true)
      |> Enum.map(&scanned_host/1)
      |> MapSet.new()

    Enum.reject(requested_hosts, &MapSet.member?(found, &1))
  end

  defp scanned_host(line) do
    line
    |> String.split(" ", parts: 2)
    |> List.first()
  end

  # H2 (Task 5 复审): mirrors `Ezagent.ActionSet.UserSshIdentity.run_ssh_keygen/2`
  # (user_ssh_identity.ex) — `Task.async` LINKS the spawned process to this
  # one, so `System.cmd/3` raising (e.g. `:enoent` when `ssh-keyscan` isn't on
  # PATH) must be caught INSIDE the task fn, or the EXIT crosses the link and
  # takes the CALLING process down before `Task.yield/2` ever gets a chance to
  # return — the `rescue` that used to sit at this function's own definition
  # (outside the Task boundary) could never actually run. Also handles
  # `Task.yield/2`'s documented `{:exit, reason}` shape, which had no clause
  # here before (a `CaseClauseError` — not an `ErlangError` — would have
  # escaped the same non-existent outer rescue too).
  @doc false
  @spec run_keyscan([String.t()]) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_keyscan(hosts) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd("ssh-keyscan", hosts, stderr_to_stdout: false)}
        rescue
          e in ErlangError -> {:error, {:ssh_keyscan_unavailable, Exception.message(e)}}
        end
      end)

    case Task.yield(task, @scan_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:ssh_keyscan_crashed, reason}}
      nil -> {:error, :ssh_keyscan_timeout}
    end
  end
end
