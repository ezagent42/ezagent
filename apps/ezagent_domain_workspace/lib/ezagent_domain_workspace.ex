defmodule EzagentDomainWorkspace do
  @moduledoc """
  Workspace domain — declarative `workspace://<name>` Kinds that hold
  Sessions + their members across restarts.

  Public surface:
  - `Ezagent.Workspace` — facade for CRUD + dispatch
  - `Ezagent.Workspace.Loader` — boot-time re-spawn
  - `Ezagent.Workspace.Store` — Ecto schema
  - `Ezagent.Entity.Workspace` — Kind
  - `Ezagent.ActionSet.Workspace` — Behavior

  Phase 6 PR 2: extracted from ezagent_core. See SPEC.
  """
end
