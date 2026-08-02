defmodule Mix.Tasks.Ezagent.Git.KnownHosts do
  @shortdoc "生成节点级 known_hosts（SSH 凭据 1b）"

  @moduledoc """
  Scan forge host keys into the node-level `known_hosts` that every agent's git
  identity copies from.

      mix ezagent.git.known_hosts github.com --out /var/lib/ezagent/git/known_hosts

  Then point the runtime at it:

      config :ezagent_core, :git_known_hosts_path, "/var/lib/ezagent/git/known_hosts"

  `--out` may be omitted only when that config value is already set (the task
  then refreshes it in place). There is **no default path** — writing an
  operator file under a guessed location is worse than asking.

  ## Why not ship forge host keys in the repo

  They rotate. A stale committed key surfaces as node-wide clone failure with no
  hint about which file to fix.

  ## Why an empty scan is refused

  `ssh-keyscan` exits 0 with empty output for an unreachable host. Writing that
  out produces a `known_hosts` that fails every connection while looking
  configured.
  """

  use Mix.Task

  alias Ezagent.Credential.GitIdentityRuntime

  @requirements ["app.config"]
  @scan_timeout_ms 15_000
  @file_mode 0o644

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

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

  defp scan(hosts) do
    task =
      Task.async(fn ->
        System.cmd("ssh-keyscan", hosts, stderr_to_stdout: false)
      end)

    case Task.yield(task, @scan_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {_out, code}} -> {:error, {:ssh_keyscan_exit, code}}
      nil -> {:error, :ssh_keyscan_timeout}
    end
  rescue
    e in ErlangError -> {:error, {:ssh_keyscan_unavailable, Exception.message(e)}}
  end
end
