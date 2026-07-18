defmodule Ezagent.ProviderConnection.UnavailableAssuranceValidator do
  @moduledoc "Fail-closed assurance validator used until backend verification is wired."

  @behaviour Ezagent.ProviderConnection.AssuranceValidator

  @impl true
  def validate(_action, _assurance, _context),
    do: {:error, :assurance_validation_unavailable}
end
