defmodule EzagentDomainAgent.TestSupport.CredentialConnectionTemplate do
  @moduledoc false

  def credential_connection(opts), do: Keyword.fetch!(opts, :connection)
end
