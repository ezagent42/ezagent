defmodule EzagentPluginCr.CrLint do
  @moduledoc """
  CR lint rules (R01-R05 placeholder — returns :ok for MVP).

  R01: No broken symlinks in sandbox
  R02: All required files present (CLAUDE.md, skills/, kb/)
  R03: No empty skill directories
  R04: Slot template syntax valid (balanced {{ }})
  R05: KB database integrity check

  All rules are no-ops in this MVP stub.
  """

  @doc """
  Run all lint checks against the tenant's sandbox.
  Returns `:ok` on success (all rules pass) or `{:error, reasons}` on failure.
  """
  @spec check(String.t()) :: :ok | {:error, [String.t()]}
  def check(_tid) do
    # MVP stub — all checks pass unconditionally
    :ok
  end
end
