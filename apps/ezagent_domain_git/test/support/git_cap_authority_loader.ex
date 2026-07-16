defmodule Ezagent.DomainGit.TestSupport.GitCapAuthorityLoader do
  @moduledoc false

  @behaviour Ezagent.Cap.AuthorityLoader

  alias Ezagent.Capability

  @impl true
  def read_held_caps(actor) do
    if actor == Ezagent.URI.user(:system, :admin) do
      MapSet.new([Capability.admin_genesis_cap()])
    else
      MapSet.new()
    end
  end
end
