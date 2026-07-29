defmodule EzagentPluginGitWorkflow.DeterministicRef do
  @moduledoc """
  Server-derived deterministic head ref for a workflow run (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.2).

  The same run always yields the same ref: `allowed_head_namespace <>
  "run-" <>` the first 24 hex characters of the run id's digest. The run id
  is already `"run_" <> sha256_hex(unique_key)` (`WorkflowRun.generate_id/3`)
  — this module does not compute or store anything new, only slices it.
  """

  @digest_prefix_length 24

  @doc "Derives the deterministic head ref for a run under its binding's allowed namespace."
  @spec derive(String.t(), String.t()) :: String.t()
  def derive(allowed_head_namespace, "run_" <> digest = _run_id)
      when is_binary(allowed_head_namespace) do
    allowed_head_namespace <> "run-" <> String.slice(digest, 0, @digest_prefix_length)
  end
end
