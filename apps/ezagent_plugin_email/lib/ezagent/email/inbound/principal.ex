defmodule Ezagent.Email.Inbound.Principal do
  @moduledoc """
  Namespace retained for compatibility after authority-bearing construction
  moved to `Ezagent.Email.Inbound.Authority`.

  No public mint API is exposed: a synthetic inbound principal may only be
  created as the result of a fresh, verified durable binding decision.
  """
end
