defmodule Ezagent.DomainGit.WorkspaceChangePort do
  @moduledoc """
  Closed contract for workspace-change collection implementations.

  An implementation fresh-reads the exact ready workspace-provision proof
  named by the request's `provision_id` + task/generation identity (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §4.2) and returns the bounded, normalized
  `[Ezagent.DomainGit.FileChange.t()]` V1 upsert envelope for that
  worktree, or a stable rejection when any reported change falls outside
  the V1 envelope (§2.2) or the configured `Ezagent.DomainGit.ChangeLimits`.
  Implementations never accept a caller-chosen filesystem path, never run
  provider HTTP, and never see a token.
  """

  alias __MODULE__.Request
  alias Ezagent.DomainGit.FileChange

  @type result :: {:ok, [FileChange.t()]} | {:error, term()}

  @callback collect(Request.t()) :: result()
end
