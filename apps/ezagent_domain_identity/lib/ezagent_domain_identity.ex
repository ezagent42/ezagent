defmodule EzagentDomainIdentity do
  @moduledoc """
  Identity domain — User Kind + caps + provisioning.

  Public surface:
  - `Ezagent.Entity.User` — User Kind
  - `Ezagent.ActionSet.Identity` — list_caps / has_cap? actions
  - `Ezagent.Identity` — facade for CapBAC checks
  - `Ezagent.Users` — Postgres provisioning (login lookup, bcrypt)

  Phase 6 PR 2: extracted from ezagent_core. See SPEC.
  """
end
