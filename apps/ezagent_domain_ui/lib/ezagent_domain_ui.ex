defmodule EzagentDomainUi do
  @moduledoc """
  UI domain — small shadcn-like HEEx component primitives.

  Operator UI pages and future 3rd-party plugins import these via
  `use EzagentDomainUi.Components` to get consistent styling without each page
  reinventing button / card / badge styles.

  Phase 6 PR 3: extracted as the shared UI layer. Validates the "UI as plugin"
  path — a plugin author writes pages on top of this library + Phoenix.LiveView
  without touching ezagent or core.
  """
end
