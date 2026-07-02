defmodule Ezagent.ActionSet.Workspace.AgentCreate.FlavorValidation do
  @moduledoc false

  # Per-flavor create-arg validators, factored out of `agent_create.ex` so that
  # file stays under the `gt_1000` LOC arch gate. Pure functions (no state, no
  # dispatch) — the `cwd`-requirement-per-flavor + `--from`-support-per-flavor
  # rules. `agent_create.ex` delegates `validate_cwd_for_flavor/3` and
  # `validate_from_for_flavor/2` here.

  @doc """
  Empty cwd is accepted for cc / cc-headless / codex / codex-remote so the
  file-flavor template builder can default project_cwd to the per-agent
  config_dir. Non-empty cwd values must still point to an existing directory.
  """
  @spec validate_cwd_for_flavor(String.t(), boolean(), String.t()) :: :ok | {:error, term()}
  def validate_cwd_for_flavor("cc", _with_pty?, ""), do: :ok
  def validate_cwd_for_flavor("cc", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  def validate_cwd_for_flavor("cc-headless", _with_pty?, ""), do: :ok

  def validate_cwd_for_flavor("cc-headless", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  def validate_cwd_for_flavor("codex", _with_pty?, ""), do: :ok
  def validate_cwd_for_flavor("codex", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  def validate_cwd_for_flavor("codex-remote", _with_pty?, ""), do: :ok

  def validate_cwd_for_flavor("codex-remote", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  def validate_cwd_for_flavor("curl", _with_pty?, _cwd), do: :ok
  def validate_cwd_for_flavor(_, _, _), do: :ok

  defp validate_cwd_dir(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    if File.dir?(expanded), do: :ok, else: {:error, {:cwd_not_a_dir, cwd}}
  end

  @doc """
  `--from` is only meaningful for flavors with a per-agent config_dir to
  clone — today `cc` only (curl/np/py have no CLAUDE_CONFIG_DIR clone
  concept).
  """
  @spec validate_from_for_flavor(String.t(), URI.t() | nil) :: :ok | {:error, term()}
  def validate_from_for_flavor(_flavor, nil), do: :ok
  def validate_from_for_flavor("cc", %URI{}), do: :ok

  def validate_from_for_flavor(other_flavor, %URI{}),
    do: {:error, {:from_unsupported_for_flavor, other_flavor}}
end
