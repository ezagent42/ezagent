defmodule Ezagent.Domain.Python.Spec do
  @moduledoc """
  Input struct for `Ezagent.Domain.Python.start_subprocess/1`.

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md` §3.1.
  Validated in the CALLER process by `validate/1` before the
  DynamicSupervisor is touched — preflight failures (`:uv_not_found`,
  `:bad_cwd`, missing required field) never produce a half-started
  child or restart loop (let-it-crash; mirrors PtyServer's `cmd_env` /
  `cmd_override` shape).

  ## `:command` discriminator

  Three accepted shapes (SPEC §3.1):

    * **list of strings** — caller-built argv, used verbatim. Element 0
      MUST be an absolute path (execve(3) performs no $PATH search —
      bare `"uv"` would fail). No uv resolution; caller is responsible.
    * **`:uv_script`** — Server resolves uv via `System.find_executable/1`
      then builds `[<uv>, "run", "--script", spec.script_path]` (PEP-723
      inline-deps single-file script). Requires `:script_path`.
    * **`:uv_project`** — `[<uv>, "run", "--directory", spec.project_dir,
      "--", "python", "-m", spec.entry_module]` (multi-file project with
      pyproject.toml). Requires `:project_dir` + `:entry_module`.
  """

  @enforce_keys [:handle, :command, :cwd]
  defstruct [
    # required
    :handle,
    :command,
    :cwd,
    # discriminator-conditional
    :script_path,
    :project_dir,
    :entry_module,
    # optional
    env: %{},
    shutdown_grace_ms: 2_000,
    ping_timeout_ms: 5_000,
    test_mode: nil,
    # bounded stderr (codex round-2 MEDIUM-5)
    stderr_log_max_bytes: 4 * 1024 * 1024
  ]

  @type command :: [String.t()] | :uv_script | :uv_project
  @type t :: %__MODULE__{
          handle: URI.t() | binary(),
          command: command(),
          cwd: String.t(),
          script_path: String.t() | nil,
          project_dir: String.t() | nil,
          entry_module: String.t() | nil,
          env: %{String.t() => String.t()},
          shutdown_grace_ms: pos_integer(),
          ping_timeout_ms: pos_integer(),
          test_mode: boolean() | nil,
          stderr_log_max_bytes: pos_integer()
        }

  @doc """
  Validate the Spec. Returns `:ok` or `{:error, reason}`.

  Reasons:
    * `:bad_handle`       — handle is not %URI{} or a binary
    * `:bad_cwd`          — cwd is not a string, or directory does not exist
    * `:bad_command`      — command is not a known shape
    * `{:missing, atom}`  — required field missing for the command discriminator
                            (`:script_path` for `:uv_script`;
                            `:project_dir` / `:entry_module` for `:uv_project`)
    * `:bad_env`          — env is not a map of string→string
  """
  @spec validate(t()) :: :ok | {:error, atom() | {atom(), atom()}}
  def validate(%__MODULE__{} = spec) do
    with :ok <- validate_handle(spec.handle),
         :ok <- validate_cwd(spec.cwd),
         :ok <- validate_env(spec.env),
         :ok <- validate_command(spec) do
      :ok
    end
  end

  defp validate_handle(%URI{}), do: :ok
  defp validate_handle(bin) when is_binary(bin), do: :ok
  defp validate_handle(_), do: {:error, :bad_handle}

  defp validate_cwd(cwd) when is_binary(cwd) do
    if File.dir?(cwd), do: :ok, else: {:error, :bad_cwd}
  end

  defp validate_cwd(_), do: {:error, :bad_cwd}

  defp validate_env(env) when is_map(env) do
    ok? =
      Enum.all?(env, fn
        {k, v} when is_binary(k) and is_binary(v) -> true
        _ -> false
      end)

    if ok?, do: :ok, else: {:error, :bad_env}
  end

  defp validate_env(_), do: {:error, :bad_env}

  defp validate_command(%__MODULE__{command: cmd}) when is_list(cmd) and cmd != [] do
    if Enum.all?(cmd, &is_binary/1), do: :ok, else: {:error, :bad_command}
  end

  defp validate_command(%__MODULE__{command: :uv_script, script_path: path}) do
    if is_binary(path) and path != "", do: :ok, else: {:error, {:missing, :script_path}}
  end

  defp validate_command(%__MODULE__{
         command: :uv_project,
         project_dir: dir,
         entry_module: mod
       }) do
    cond do
      not (is_binary(dir) and dir != "") -> {:error, {:missing, :project_dir}}
      not (is_binary(mod) and mod != "") -> {:error, {:missing, :entry_module}}
      true -> :ok
    end
  end

  defp validate_command(_), do: {:error, :bad_command}

  @doc """
  Build the argv list erlexec consumes. Returns
  `{:ok, [String.t()]}` or `{:error, :uv_not_found}` when the
  variants need `uv` and it is absent from `$PATH`.

  Caller is `start_subprocess/1` — runs in the calling process, BEFORE
  the supervisor is touched. Mirrors `resolve_claude_executable/1` in
  the cc plugin's Template (let-it-crash; no shell fallback).
  """
  @spec to_argv(t()) :: {:ok, [String.t()]} | {:error, :uv_not_found}
  def to_argv(%__MODULE__{command: cmd}) when is_list(cmd), do: {:ok, cmd}

  def to_argv(%__MODULE__{command: :uv_script, script_path: path}) do
    case resolve_uv() do
      {:ok, uv} -> {:ok, [uv, "run", "--script", path]}
      {:error, _} = err -> err
    end
  end

  def to_argv(%__MODULE__{
        command: :uv_project,
        project_dir: dir,
        entry_module: mod
      }) do
    case resolve_uv() do
      {:ok, uv} -> {:ok, [uv, "run", "--directory", dir, "--", "python", "-m", mod]}
      {:error, _} = err -> err
    end
  end

  @spec resolve_uv() :: {:ok, String.t()} | {:error, :uv_not_found}
  defp resolve_uv do
    case System.find_executable("uv") do
      nil -> {:error, :uv_not_found}
      path -> {:ok, path}
    end
  end
end
